import BreezePlugins
import BreezeRuntime
import CoreStorage
import Foundation
import SwiftData

@main
struct HomePresentationSmoke {
    @MainActor
    static func main() async throws {
        let storage = try WillowPersistence.make(inMemory: true)
        let context = storage.container.mainContext
        try await PluginService.shared.install(url: URL(fileURLWithPath: CommandLine.arguments[1]), context: context)
        let plugin = try context.fetch(FetchDescriptor<PluginRecord>())[0]
        let suite = "WillowDiscoveryTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let discover = DiscoverModel(defaults: defaults)
        discover.selectPlugin(plugin.uuid)
        let restoredDiscover = DiscoverModel(defaults: defaults)
        precondition(restoredDiscover.viewModel.selectedPluginID == plugin.uuid)
        precondition(restoredDiscover.activePlugin(in: [plugin])?.uuid == plugin.uuid)
        precondition(restoredDiscover.activePlugin(in: []) == nil)
        restoredDiscover.selectPlugin("temporarily-disabled-source")
        precondition(restoredDiscover.activePlugin(in: [plugin])?.uuid == plugin.uuid)
        precondition(restoredDiscover.viewModel.selectedPluginID == "temporarily-disabled-source")
        print("PASS: discovery selection persists and unavailable sources fall back without losing preference")
        let tabs = try await PluginService.shared.homeTabs(plugin: plugin)
        let cloud = PluginCloudHomeModel()
        await cloud.load(plugin: plugin)
        precondition(cloud.viewModel.loaded && cloud.viewModel.tabs.first?.id == "favorites")
        let cloudPage = PluginHomeModel(plugin: plugin, tab: cloud.viewModel.tabs[0])
        await cloudPage.load()
        precondition(cloudPage.viewModel.error == nil && cloudPage.viewModel.comics.first?.id == "comic/1")
        let model = PluginHomeModel(plugin: plugin, tab: tabs.first { $0.id == "ranking" }!)
        await model.load()
        precondition(model.viewModel.error == nil && model.viewModel.comics.first?.id == "rank/1")
        await model.loadMore()
        precondition(model.viewModel.comics.count == 2 && !model.viewModel.hasMore)
        await model.loadMore()
        precondition(model.viewModel.comics.count == 2)
        await model.load(reset: true)
        precondition(model.viewModel.comics.count == 1 && model.viewModel.hasMore)
        model.route(.object(["type": .string("openSearch"), "payload": .object([
            "keyword": .string("Adventure"), "categories": .array([.string("fiction")]),
            "extern": .object(["mode": .string("tag")])
        ])]))
        guard case .page(let search) = model.viewModel.destination else { fatalError("Search route missing") }
        precondition(search.scene["body"]["request"]["core"]["keyword"].string == "Adventure")
        precondition(search.scene["body"]["request"]["extern"]["categories"].array == [.string("fiction")])
        model.route(.object(["action": .object(["type": .string("openCloudFavorite")])]))
        precondition(model.viewModel.destination == .favorites)
        model.route(.object(["type": .string("openPluginFunction"), "payload": .object(["id": .string("ranking")])]))
        guard case .page(let function) = model.viewModel.destination else { fatalError("Function route missing") }
        let functionModel = PluginHomeModel(plugin: plugin, tab: function)
        await functionModel.load()
        precondition(functionModel.viewModel.error == nil && functionModel.viewModel.blocks.first?.comics.count == 1)
        let detail = try await PluginService.shared.detail(plugin: plugin, comicID: "comic/1")
        let detailModel = ComicDetailModel(sourceID: plugin.uuid, summary: detail.comic)
        let following = ComicFollowingModel(container: storage.container, privacy: ContentPrivacy(defaults: defaults))
        await detailModel.loadDetail(
            inputs: .init(records: [], plugins: [plugin], downloads: [], readChapters: []),
            context: context,
            following: following
        )
        let information = detailModel.viewModel.metadata
        precondition(!information.contains { $0.title == "其他信息" })
        precondition(information.first { $0.title == "状态" }?.values == ["连载中"])
        precondition(information.first { $0.title == "语言" }?.values == ["中文"])
        precondition(information.first { $0.title == "页数" }?.values == ["123"])
        precondition(information.first { $0.id == "tags" }?.values.count == 2)
        print("PASS: additional information has individual labeled rows while tags remain grouped")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = DownloadManager(context: context, directory: directory)
        detailModel.enqueueComic(plugin: plugin, context: context, downloads: downloads)
        for _ in 0..<200 where detailModel.viewModel.preparingDownload {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(!detailModel.viewModel.preparingDownload && detailModel.viewModel.actionError == nil)
        let records = try context.fetch(FetchDescriptor<DownloadRecord>())
        precondition(Set(records.map(\.chapterID)) == ["logical/1", "logical/2"])
        records.forEach { downloads.pause($0) }
        print("PASS: whole-comic download resolves and enqueues every chapter")
        try await PluginService.shared.uninstall(plugin: plugin, context: context)
        print("PASS: ranking presentation pagination/reset, search parameter routing, cloud favorites and function navigation")
    }
}
