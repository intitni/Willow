import Foundation
import CoreStorage
import BreezeRuntime
import BreezePlugins
import SwiftData
import Testing

@Suite("Breeze plugins", .serialized)
@MainActor
struct BreezePluginsTests {
    @Test func `Optional initialization does not block plugin home and real failures remain visible`() async throws {
        try requireIsolatedStorage()
        let directory = URL.temporaryDirectory.appending(path: "WillowOptionalInit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, initializer) in ["", "init: () => {},", "init: () => { throw Error('initialization-failed'); },"].enumerated() {
            let id = UUID().uuidString
            let file = directory.appending(path: "\(id).cjs")
            let source = """
            module.exports = {
              \(initializer)
              getPluginHomePagesBundle: () => ({data:{tabs:[{id:'home',title:'Home',page:{}}]}})
            };
            """
            try Data(source.utf8).write(to: file)
            let plugin = PluginRecord(uuid: id, name: "Optional Init", version: "1", bundlePath: file.path)
            if index < 2 {
                let tabs = try await PluginService.shared.homeTabs(plugin: plugin)
                #expect(tabs.first?.id == "home")
                let repeated = try await PluginService.shared.homeTabs(plugin: plugin)
                #expect(repeated.first?.id == "home")
            } else {
                do {
                    _ = try await PluginService.shared.homeTabs(plugin: plugin)
                    Issue.record("An initialization failure must remain visible.")
                } catch {
                    #expect(error.localizedDescription.contains("initialization-failed"))
                }
            }
            try await PluginRuntime.shared.unload(id: id)
        }
    }

    @Test func `Restored runtime initializes again at the same bundle path`() async throws {
        try requireIsolatedStorage()
        let directory = URL.temporaryDirectory.appending(path: "WillowReinit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString
        let file = directory.appending(path: "fixture.cjs")
        try Data("""
        let ready = false;
        module.exports = {
          init: () => { ready = true; },
          getPluginHomePagesBundle: () => {
            if (!ready) throw Error('not-initialized');
            return {data:{tabs:[{id:'home',title:'Home',page:{}}]}};
          }
        };
        """.utf8).write(to: file)
        let plugin = PluginRecord(uuid: id, name: "Restore", version: "1", bundlePath: file.path)
        _ = try await PluginService.shared.homeTabs(plugin: plugin)
        try await PluginRuntime.shared.unload(id: id)
        let tabs = try await PluginService.shared.homeTabs(plugin: plugin)
        #expect(tabs.first?.id == "home")
        try await PluginRuntime.shared.unload(id: id)
    }

    @Test func `Offline plugin contract and installation lifecycle`() async throws {
        try requireIsolatedStorage()
        let store = try WillowPersistence.make(inMemory: true)
        let context = store.container.mainContext
        let service = PluginService.shared
        let fixture = try #require(Bundle.module.url(forResource: "contract", withExtension: "cjs", subdirectory: "Fixtures"))
        try await service.install(url: fixture, context: context)
        let plugins = try context.fetch(FetchDescriptor<PluginRecord>())
        try #require(plugins.count == 1)
        let plugin = plugins[0]
        try #require(plugin.discoveryActions.count == 2)
        try #require(plugin.discoveryActions[0]["action"]["payload"]["id"].string == "ranking")
        try #require(plugin.discoveryActions[1]["action"]["type"].string == "openSearch")
        try #require(!plugin.bundlePath.hasPrefix("/"))
        let installedName = plugin.bundlePath
        let installedPath = try PluginRuntime.resolveBundlePath(installedName)
        plugin.bundlePath = "/old-app-container/Library/Application Support/WillowPlugins/" + installedName
        try context.save()
        let relocatedPath = try PluginRuntime.resolveBundlePath(plugin.bundlePath)
        try #require(relocatedPath == installedPath)
        try await PluginRuntime.shared.unload(id: plugin.uuid)
        let movedInfo = try await PluginRuntime.shared.call(id: plugin.uuid, path: plugin.bundlePath, function: "getInfo")
        try #require(movedInfo["uuid"].string == plugin.uuid)
        let registry = try PluginRuntime.storageDirectory().appendingPathComponent(plugin.uuid + ".path")
        try Data(plugin.bundlePath.utf8).write(to: registry)
        do {
            _ = try PluginRuntime.resolveBundlePath("missing-plugin.cjs")
            Issue.record("Missing plugin was accepted")
        } catch { try #require(error is PluginError, "A missing plugin must report a plugin error in either language.") }
        let homeTabs = try await service.homeTabs(plugin: plugin)
        try #require(homeTabs.map(\.id) == ["latest", "hot", "navigation", "ranking"])
        let hot = try await service.homeBlocks(plugin: plugin, page: homeTabs[1].page)
        try #require(hot.first?.links.first?.title == "Adventure")
        let navigation = try await service.homeBlocks(plugin: plugin, page: homeTabs[2].page)
        try #require(navigation.map(\.kind) == ["action-grid", "comic-grid"])
        try #require(navigation.last?.comics.first?.id == "comic/1")
        try #require(homeTabs[2].actions.first?["action"]["type"].string == "openCloudFavorite")
        let rank = homeTabs[3].listTab
        let (rankFields, rankValues) = try await service.sourceFavoriteFilters(plugin: plugin, tab: rank)
        let firstRank = try await service.sourceFavoritePage(plugin: plugin, tab: rank, page: 1, fields: rankFields, values: rankValues)
        let lastRank = try await service.sourceFavoritePage(plugin: plugin, tab: rank, page: 2, fields: rankFields, values: rankValues)
        try #require(firstRank.hasMore && !lastRank.hasMore && lastRank.comics.first?.id == "rank/2")
        let functionPage = try await service.functionPage(plugin: plugin, id: "ranking")
        let functionBlocks = try await service.homeBlocks(plugin: plugin, page: functionPage)
        try #require(functionBlocks.first?.comics.first?.id == "comic/1")
        let sections = try await service.home(plugin: plugin)
        try #require(sections.first?.comics.first?.id == "comic/1")
        let search = try await service.search(plugin: plugin, query: "Contract", page: 1)
        try #require(search.comics.count == 1 && !search.hasMore)
        try await checkSourceFeatures(service: service, plugin: plugin)
        let detail = try await service.detail(plugin: plugin, comicID: "comic/1")
        try #require(detail.chapters.first?.id == "logical/1")
        try #require(detail.sourceActions?.totalLikes == 1234 && detail.sourceActions?.totalComments == 56)
        try #require(detail.comic.author == "Test Author")
        try #require(detail.metadata?.first(where: { $0.id == "tags" })?.values == ["Adventure", "Fantasy"])
        try #require(detail.metadata?.first(where: { $0.id == "author" })?.actions?["Test Author"]?["payload"]["extern"]["author"].string == "Test Author")
        try #require(detail.metadata?.first(where: { $0.id == "titleMeta_0" })?.title == "页数")
        try #require(detail.metadata?.first(where: { $0.id == "titleMeta_0" })?.values == ["123"])
        let oldDetail: JSONValue = .object(["comic": try JSONValue.decode(JSONEncoder().encode(detail.comic)), "chapters": .array([])])
        let restored = try JSONDecoder().decode(ComicDetail.self, from: oldDetail.encoded())
        try #require(restored.metadata == nil)
        let originalCover = try #require(detail.comic.coverURL)
        let originalFragment = try #require(originalCover.fragment)
        let originalDescriptor = try #require(Data(base64Encoded: originalFragment))
        var coverDescriptor = try JSONValue.decode(originalDescriptor)["payload"].object
        coverDescriptor["testRun"] = .string(UUID().uuidString)
        let cover = try await PluginImageGateway.shared.register(sourceID: plugin.uuid, bundlePath: plugin.bundlePath, payload: .object(coverDescriptor))
        async let firstCover = ImageCache.shared.data(for: cover)
        async let secondCover = ImageCache.shared.data(for: cover)
        let coverData = try await (firstCover, secondCover)
        try #require(coverData.0 == coverData.1 && coverData.0.count > 8)
        let imageCount = try await PluginRuntime.shared.call(id: plugin.uuid, path: plugin.bundlePath, function: "coverRequestCount")
        try #require(imageCount.int == 1)
        let fragment = try #require(cover.fragment)
        let descriptorData = try #require(Data(base64Encoded: fragment))
        let descriptor = try JSONValue.decode(descriptorData)
        let updatedCover = try await PluginImageGateway.shared.register(sourceID: plugin.uuid, bundlePath: "/different/bundle.cjs", payload: descriptor["payload"])
        try #require(updatedCover.lastPathComponent == cover.lastPathComponent)
        let cachedCover = try await ImageCache.shared.data(for: updatedCover)
        try #require(cachedCover == coverData.0)
        let pages = try await service.pages(plugin: plugin, comicID: "comic/1", chapterID: "logical/1")
        let bytes = try await PluginImageGateway.shared.data(for: pages[0])
        try #require(bytes.count == 8)
        let settings = try await service.settings(plugin: plugin)
        try await service.saveSetting(plugin: plugin, setting: settings.fields[0], value: "reader")
        _ = try await service.loginForm(plugin: plugin)
        try await service.submitLogin(plugin: plugin, values: [:])
        let configRoot = try PluginRuntime.storageDirectory().appendingPathComponent("Configuration")
        let encrypted = try Data(contentsOf: configRoot.appendingPathComponent("plugin-config.encrypted"))
        try #require(!String(decoding: encrypted, as: UTF8.self).contains("reader"))
        try #require(!FileManager.default.fileExists(atPath: configRoot.appendingPathComponent("plugin-config.json").path))
        let configValues = try configRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
        try #require(configValues.isExcludedFromBackup == true)
        // A retained page URL remains valid after replacing the bundle.
        try await service.install(url: fixture, context: context)
        let updatedBytes = try await PluginImageGateway.shared.data(for: pages[0])
        try #require(updatedBytes == bytes)
        try await service.setEnabled(false, plugin: plugin, context: context)
        do {
            _ = try await PluginImageGateway.shared.data(for: pages[0])
            Issue.record("Disabled source executed an image request")
        } catch is PluginError {}
        do {
            _ = try await service.search(plugin: plugin, query: "Contract", page: 1)
            Issue.record("Disabled source executed")
        } catch is PluginError {}
        try await service.uninstall(plugin: plugin, context: context)
        let remaining = try context.fetchCount(FetchDescriptor<PluginRecord>())
        try #require(remaining == 0)
        // The current Breeze catalog contains this non-RFC identity. Exercise
        // installation and image resolution as well as catalog decoding.
        let compatibilityFixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cjs")
        defer { try? FileManager.default.removeItem(at: compatibilityFixture) }
        let source = try String(contentsOf: fixture, encoding: .utf8)
            .replacingOccurrences(of: "12345678-1234-4234-8234-123456789abc", with: "c8f3a1e2-7b4d-4e9a-8f2c-1d5a7b9e3f6a8")
        try source.write(to: compatibilityFixture, atomically: true, encoding: .utf8)
        try await service.install(url: compatibilityFixture, context: context)
        let compatiblePlugin = try context.fetch(FetchDescriptor<PluginRecord>())[0]
        let compatiblePages = try await service.pages(plugin: compatiblePlugin, comicID: "comic/1", chapterID: "logical/1")
        let compatibleBytes = try await PluginImageGateway.shared.data(for: compatiblePages[0])
        try #require(compatibleBytes == bytes)
        try await service.uninstall(plugin: compatiblePlugin, context: context)
    }

    @Test func `Catalog formats reject duplicate and unsafe identities`() throws {
        let url = URL(string: "https://example.com/plugins.json")!
        let entry: [String: Any] = ["manifest": ["uuid": "c8f3a1e2-7b4d-4e9a-8f2c-1d5a7b9e3f6a8", "name": "Compatibility", "version": "1.0"]]
        for payload: Any in [[entry], ["plugins": [entry]]] {
            let candidates = try PluginService.parseCatalog(JSONSerialization.data(withJSONObject: payload), subscriptionURL: url)
            try #require(candidates.count == 1 && candidates[0].id == "c8f3a1e2-7b4d-4e9a-8f2c-1d5a7b9e3f6a8")
        }
        do {
            _ = try PluginService.parseCatalog(JSONSerialization.data(withJSONObject: [entry, entry]), subscriptionURL: url)
            Issue.record("Duplicate identities accepted")
        } catch is PluginError {}
        for invalid in ["", "../escape", "a/b", "a\\b", "a%2fb", " spaced ", String(repeating: "a", count: 129)] {
            try #require(!PluginIdentity.isValid(invalid))
            do {
                _ = try PluginService.parseCatalog(JSONSerialization.data(withJSONObject: [["uuid": invalid]]), subscriptionURL: url)
                Issue.record("Unsafe identity accepted")
            } catch is PluginError {}
        }
    }

    @MainActor
    private func checkSourceFeatures(service: PluginService, plugin: PluginRecord) async throws {
        let comicID = "comic/1"
        try #require(plugin.supportsCloudFavorites)
        let tabs = try await service.sourceFavoriteTabs(plugin: plugin)
        try #require(tabs.count == 1)
        let (filters, selection) = try await service.sourceFavoriteFilters(plugin: plugin, tab: tabs[0])
        try #require(filters.first?.id == "folder" && selection["folder"] == .string("b"))
        let favorites = try await service.sourceFavoritePage(
            plugin: plugin, tab: tabs[0], page: 1, fields: filters, values: selection
        )
        try #require(favorites.comics.first?.id == comicID && !favorites.hasMore)

        let (fields, values) = try await service.advancedSearchFields(plugin: plugin)
        try #require(fields.map(\.kind) == ["text", "switch", "choice", "multiChoice"])
        let results = try await service.advancedSearch(plugin: plugin, keyword: "Advanced", page: 1, extern: values)
        try #require(results.comics.first?.id == comicID && !results.hasMore)

        let actions = try await service.sourceActions(plugin: plugin, comicID: comicID)
        try #require(actions.allowComments && actions.allowLike && actions.allowCollected && actions.allowDownload)
        let liked = try await service.toggleSourceLike(plugin: plugin, comicID: comicID, liked: actions.liked)
        try #require(liked)
        let favorite = try await service.startSourceFavorite(plugin: plugin, comicID: comicID, favorited: false)
        try #require(favorite["status"].string == "awaitingInput")
        let response = try await service.continueSourceFavorite(
            plugin: plugin, comicID: comicID, favorited: false, token: favorite["continuationToken"].string,
            input: .object(["key": .string("folder"), "value": .string("b")])
        )
        try #require(response["status"].string == "completed" && response["favorited"].bool)

        let feed = try await service.sourceComments(plugin: plugin, comicID: comicID, page: 1, parent: nil)
        try #require(feed.canPost && feed.canReply && feed.comments.map(\.id) == ["top", "c1"] && !feed.hasMore)
        let parent = feed.comments[1]
        let replies = try await service.sourceComments(plugin: plugin, comicID: comicID, page: 1, parent: parent)
        try #require(replies.comments.first?.id == "r1")
        try await service.postSourceComment(plugin: plugin, comicID: comicID, content: "Offline comment", parent: nil)
        try await service.postSourceComment(plugin: plugin, comicID: comicID, content: "Offline reply", parent: parent)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILLOW_TEST_LIVE_JM"] == "1"))
    func `Public JM release installs without login`() async throws {
        try requireIsolatedStorage()
        let persistence = try WillowPersistence.make(inMemory: true)
        let candidate = PluginCandidate(id: "bf99008d-010b-4f17-ac7c-61a9b57dc3d9", name: "禁漫天堂", version: "0.1.0", description: "", downloadURL: URL(string: "https://api.github.com/repos/deretame/Breeze-plugin-JmComic/releases/latest"), subscriptionURL: "", npmName: "breeze-plugin-jm-comic")
        try await PluginService.shared.install(candidate: candidate, context: persistence.container.mainContext)
        let plugin = try #require(persistence.container.mainContext.fetch(FetchDescriptor<PluginRecord>()).first)
        #expect(plugin.uuid == candidate.id)
        try await PluginService.shared.uninstall(plugin: plugin, context: persistence.container.mainContext)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WILLOW_TEST_CATALOG"] != nil))
    func `Provided catalog snapshot decodes`() throws {
        let path = try #require(ProcessInfo.processInfo.environment["WILLOW_TEST_CATALOG"])
        let catalog = try PluginService.parseCatalog(Data(contentsOf: URL(fileURLWithPath: path)),
            subscriptionURL: URL(string: "https://example.com/plugins.json")!)
        #expect(!catalog.isEmpty)
    }

    private func requireIsolatedStorage() throws {
        #if WILLOW_TESTING
        let path = try #require(ProcessInfo.processInfo.environment["WILLOW_PLUGIN_STORAGE_DIRECTORY"],
            "Run Scripts/test-plugins.sh to provide isolated plugin storage.")
        try #require(!path.isEmpty)
        #else
        throw TestConfigurationError.isolationNotEnabled
        #endif
    }

    private enum TestConfigurationError: Error {
        case isolationNotEnabled
    }

}
