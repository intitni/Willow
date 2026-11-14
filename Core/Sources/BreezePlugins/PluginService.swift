import BreezeRuntime
import CoreStorage
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
package final class PluginService {
    package static let shared = PluginService()
    package static let defaultSubscriptionURL = URL(string: "https://raw.githubusercontent.com/deretame/Breeze-plugin-list/main/plugins_data.json")!
    private var catalogs: [String: [PluginCandidate]] = [:]
    private var initialized: [String: UUID] = [:]
    private var chapterPayloads: [String: [String: JSONValue]] = [:]
    private var loginFunctions: [String: String] = [:]
    private var searchExtern: [String: JSONValue] = [:]

    package func addSubscription(url: URL, context: ModelContext) async throws {
        let candidates = try await PluginTransfer.shared.fetchCatalog(url)
        let key = url.absoluteString
        let existing = try context.fetch(FetchDescriptor<SubscriptionRecord>(predicate: #Predicate { $0.url == key })).first
        if let existing { existing.updatedAt = .now }
        else { context.insert(SubscriptionRecord(url: key, name: url.host ?? "Breeze")) }
        try context.save()
        catalogs[key] = candidates
    }

    package func refresh(subscription: SubscriptionRecord, context: ModelContext) async throws {
        guard let url = URL(string: subscription.url) else { throw PluginError.message(L10n.text("Subscription.InvalidURL")) }
        catalogs[subscription.url] = try await PluginTransfer.shared.fetchCatalog(url)
        subscription.updatedAt = .now
        try context.save()
    }

    package func subscriptionCandidates(subscription: SubscriptionRecord) async throws -> [PluginCandidate] {
        if let cached = catalogs[subscription.url] { return cached }
        guard let url = URL(string: subscription.url) else { throw PluginError.message(L10n.text("Subscription.InvalidURL")) }
        let result = try await PluginTransfer.shared.fetchCatalog(url)
        catalogs[subscription.url] = result
        return result
    }

    package func install(candidate: PluginCandidate, context: ModelContext) async throws {
        var source: String?
        var failures: [String] = []
        for url in try Self.packageDownloadURLs(candidate) {
            do {
                source = try await PluginTransfer.shared.downloadScript(url)
                break
            } catch {
                try Task.checkCancellation()
                failures.append(error.localizedDescription)
            }
        }
        if source == nil, let url = candidate.downloadURL {
            do { source = try await PluginTransfer.shared.scriptFromUpdateURL(url) }
            catch {
                try Task.checkCancellation()
                failures.append(error.localizedDescription)
            }
        }
        guard let source else {
            throw PluginError.message(failures.isEmpty ? L10n.text("PluginInstall.NoDownloadableFiles") :
                L10n.text("PluginInstall.DownloadFailures", defaultValue: "插件下载失败：\n\(Array(Set(failures)).sorted().joined(separator: "\n"))"))
        }
        try await install(source: source, expectedID: candidate.id, subscriptionURL: candidate.subscriptionURL, context: context)
    }

    package static func packageDownloadURLs(_ candidate: PluginCandidate) throws -> [URL] {
        guard !candidate.npmName.isEmpty else { return [] }
        let name = candidate.npmName
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        let validName = components.count == 1 || (components.count == 2 && name.hasPrefix("@"))
        guard validName, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [64, 47, 45, 95, 46].contains($0) }),
              !candidate.version.isEmpty,
              candidate.version.allSatisfy({ $0.isLetter || $0.isNumber || ".-_+".contains($0) }) else {
            throw PluginError.message(L10n.text("PluginInstall.InvalidPackage"))
        }
        // Breeze publishes compressed bundles too. Use both formats and the
        // CDN's alternate provider before falling back to GitHub Releases.
        return ["cdn.jsdelivr.net", "fastly.jsdelivr.net"].flatMap { host in
            ["cjs.br", "cjs"].compactMap { ext in
                URL(string: "https://\(host)/npm/\(name)@\(candidate.version)/dist/\(components.last!).bundle.\(ext)")
            }
        }
    }

    package func install(url: URL, context: ModelContext) async throws {
        let source = try await PluginTransfer.shared.importScript(url)
        try await install(source: source, expectedID: nil, subscriptionURL: nil, context: context)
    }

    package func setEnabled(_ enabled: Bool, plugin: PluginRecord, context: ModelContext) async throws {
        let previous = plugin.enabled
        plugin.enabled = enabled
        do {
            try context.save()
            try await updateImageAccess(plugin: plugin)
        } catch {
            plugin.enabled = previous
            try? context.save()
            try? await updateImageAccess(plugin: plugin)
            throw error
        }
        if !enabled { initialized.removeValue(forKey: plugin.uuid) }
    }

    private func updateImageAccess(plugin: PluginRecord) async throws {
        try await PluginTransfer.shared.updateImageAccess(id: plugin.uuid, path: plugin.bundlePath, enabled: plugin.enabled)
    }

    package func uninstall(plugin: PluginRecord, context: ModelContext) async throws {
        let id = plugin.uuid
        try await PluginRuntime.shared.unload(id: id)
        initialized.removeValue(forKey: id)
        let path = plugin.bundlePath
        context.delete(plugin)
        try context.save()
        try await PluginTransfer.shared.updateImageAccess(id: id, path: path, enabled: false)
        try await PluginTransfer.shared.removeBundle(path)
    }

    package func home(plugin: PluginRecord) async throws -> [HomeSection] {
        var sections: [HomeSection] = []
        for tab in try await homeTabs(plugin: plugin) {
            if !tab.scene.isNull {
                let (fields, values) = try await sourceFavoriteFilters(plugin: plugin, tab: tab.listTab)
                let page = try await sourceFavoritePage(plugin: plugin, tab: tab.listTab, page: 1, fields: fields, values: values)
                if !page.comics.isEmpty { sections.append(HomeSection(id: tab.id, title: tab.title, comics: page.comics)) }
            } else {
                for block in try await homeBlocks(plugin: plugin, page: tab.page) where !block.comics.isEmpty {
                    sections.append(HomeSection(id: tab.id + "." + block.id, title: block.title, comics: block.comics))
                }
            }
        }
        return sections
    }

    package func search(plugin: PluginRecord, query: String, page: Int) async throws -> SearchResult {
        let key = plugin.uuid + ":" + query
        let result = try await call(plugin, "searchComic", args: .object([
            "keyword": .string(query), "page": .number(Double(page)), "isSearchAggregate": .bool(false),
            "extern": page == 1 ? .object([:]) : (searchExtern[key] ?? .object([:]))
        ]))
        searchExtern[key] = result["extern"]
        let data = result["data"].isNull ? result : result["data"]
        let paging = data["paging"]
        let comics = try await summaries(items(in: result), plugin: plugin)
        let hasMore = !comics.isEmpty && !paging["hasReachedMax"].bool && !data["hasReachedMax"].bool && (paging["pages"].int == 0 || page < paging["pages"].int)
        return SearchResult(comics: comics, hasMore: hasMore)
    }

    package func detail(plugin: PluginRecord, comicID: String) async throws -> ComicDetail {
        let response = try await call(plugin, "getComicDetail", args: .object(["comicId": .string(comicID)]))
        let data = response["data"].isNull ? response : response["data"]
        let normal = data["normal"].isNull ? data : data["normal"]
        let comic = try await summary(normal["comicInfo"], plugin: plugin, fallbackID: comicID)
        var episodes = normal["eps"].array
        if episodes.allSatisfy({ $0["order"].int > 0 }) { episodes.sort { $0["order"].int < $1["order"].int } }
        var payloads: [String: JSONValue] = [:]
        var seen: Set<String> = []
        let chapters = episodes.enumerated().compactMap { index, ep -> ComicChapter? in
            let id = ep["logicalKey"].string.isEmpty ? ep["id"].string : ep["logicalKey"].string
            let key = id.isEmpty ? String(index + 1) : id
            guard seen.insert(key).inserted else { return nil }
            payloads[key] = ep
            return ComicChapter(id: key, title: ep["name"].string)
        }
        chapterPayloads[plugin.uuid + ":" + comicID] = payloads
        return ComicDetail(comic: comic, chapters: chapters, sourceActions: PluginComicActionState(normal: normal), metadata: Self.metadata(normal["comicInfo"]))
    }

    package func pages(plugin: PluginRecord, comicID: String, chapterID: String) async throws -> [URL] {
        let key = plugin.uuid + ":" + comicID
        if chapterPayloads[key] == nil { _ = try await detail(plugin: plugin, comicID: comicID) }
        let chapter = chapterPayloads[key]?[chapterID] ?? .object([:])
        var extern = chapter["extern"].object
        extern["order"] = chapter["order"]
        let requestID = chapter["requestId"].string.isEmpty ? chapterID : chapter["requestId"].string
        let response = try await call(plugin, "getReadSnapshot", args: .object([
            "comicId": .string(comicID), "chapterId": .string(requestID), "extern": .object(extern)
        ]))
        let data = response["data"].isNull ? response : response["data"]
        let pages = data["chapter"]["pages"].isNull ? data["chapter"]["docs"].array : data["chapter"]["pages"].array
        var urls: [URL] = []
        for page in pages {
            let url = page["url"].string.isEmpty ? page["fileServer"].string : page["url"].string
            guard !url.isEmpty else { throw PluginError.message(L10n.text("Reader.InvalidPageURL")) }
            var imageExtern = page["extern"].object
            imageExtern["comicId"] = .string(comicID)
            imageExtern["chapterId"] = .string(requestID)
            imageExtern["path"] = page["path"]
            urls.append(try await PluginImageGateway.shared.register(sourceID: plugin.uuid, bundlePath: plugin.bundlePath, payload: .object([
                "url": .string(url), "timeoutMs": .number(30_000), "extern": .object(imageExtern)
            ])))
        }
        guard !urls.isEmpty else { throw PluginError.message(L10n.text("Reader.NoPages")) }
        return urls
    }

    package func settings(plugin: PluginRecord) async throws -> PluginSettings {
        guard plugin.enabled else { throw PluginError.message(L10n.text("Plugin.Disabled")) }
        // Settings must be accessible even when init requires credentials.
        let result = try await PluginRuntime.shared.call(id: plugin.uuid, path: plugin.bundlePath, function: "getSettingsBundle")
        let values = result["data"]["values"]
        let fields = result["scheme"]["sections"].array.flatMap { section in
            section["fields"].array.map { field in
                PluginSetting(id: field["key"].string, title: field["label"].string, kind: field["kind"].string, value: values[field["key"].string].string, function: field["fnPath"].string.isEmpty ? "saveSettings" : field["fnPath"].string)
            }
        }
        return PluginSettings(fields: fields, canLogin: result["data"]["canLogin"].bool)
    }

    package func saveSetting(plugin: PluginRecord, setting: PluginSetting, value: String) async throws {
        guard plugin.enabled else { throw PluginError.message(L10n.text("Plugin.Disabled")) }
        let payload: JSONValue = setting.kind == "switch" ? .bool(value == "true") : .string(value)
        _ = try await PluginRuntime.shared.call(id: plugin.uuid, path: plugin.bundlePath, function: setting.function,
            args: .object(["key": .string(setting.id), "value": payload, "values": .object([setting.id: payload])]))
        initialized.removeValue(forKey: plugin.uuid)
    }

    package func loginForm(plugin: PluginRecord) async throws -> PluginLoginForm {
        guard plugin.enabled else { throw PluginError.message(L10n.text("Plugin.Disabled")) }
        let result = try await PluginRuntime.shared.call(id: plugin.uuid, path: plugin.bundlePath, function: "getLoginBundle")
        let scheme = result["scheme"]
        let function = scheme["action"]["fnPath"].string
        guard !function.isEmpty else { throw PluginError.message(L10n.text("PluginSignIn.UnsupportedForm")) }
        loginFunctions[plugin.uuid] = function
        let values = result["data"]["values"]
        let fields = scheme["fields"].array.map { field in
            PluginSetting(id: field["key"].string, title: field["label"].string, kind: field["kind"].string,
                value: values[field["key"].string].string, function: function)
        }
        return PluginLoginForm(title: scheme["title"].string, fields: fields, submitTitle: scheme["action"]["submitText"].string)
    }

    package func submitLogin(plugin: PluginRecord, values: [String: String]) async throws {
        guard plugin.enabled else { throw PluginError.message(L10n.text("Plugin.Disabled")) }
        guard let function = loginFunctions[plugin.uuid] else { throw PluginError.message(L10n.text("PluginSignIn.FormRequired")) }
        var payload = values.mapValues(JSONValue.string)
        payload["values"] = .object(values.mapValues(JSONValue.string))
        payload["extern"] = .object([:])
        let response = try await PluginRuntime.shared.call(id: plugin.uuid, path: plugin.bundlePath, function: function, args: .object(payload))
        if response["ok"] == .bool(false) || response["data"]["ok"] == .bool(false) {
            throw PluginError.message(response["message"].string.isEmpty ? L10n.text("PluginSignIn.Failed") : response["message"].string)
        }
        initialized.removeValue(forKey: plugin.uuid)
    }

    func call(_ plugin: PluginRecord, _ function: String, args: JSONValue = .object([:])) async throws -> JSONValue {
        guard plugin.enabled else { throw PluginError.message(L10n.text("Plugin.Disabled")) }
        let session = try await PluginRuntime.shared.sessionID(id: plugin.uuid, path: plugin.bundlePath)
        if session == nil || initialized[plugin.uuid] != session {
            do {
                _ = try await PluginRuntime.shared.call(id: plugin.uuid, path: plugin.bundlePath, function: "init")
            } catch PluginError.message(let message) {
                // Breeze 的 init 是可选方法；仅忽略未导出的情况，执行失败仍向上抛出。
                guard message.hasPrefix("target is not function: init; targetType=undefined;") else {
                    throw PluginError.message(message)
                }
            }
            initialized[plugin.uuid] = session
        }
        var payload = args.object
        if payload["extern"] == nil { payload["extern"] = .object([:]) }
        return try await PluginRuntime.shared.call(id: plugin.uuid, path: plugin.bundlePath, function: function, args: .object(payload))
    }

    func summary(_ item: JSONValue, plugin: PluginRecord, fallbackID: String = "") async throws -> ComicSummary {
        let cover = item["cover"]
        let address = cover.object.isEmpty ? cover.string : cover["url"].string
        var url: URL?
        if !address.isEmpty {
            url = try await PluginImageGateway.shared.register(sourceID: plugin.uuid, bundlePath: plugin.bundlePath, payload: .object([
                "url": .string(address), "timeoutMs": .number(30_000), "extern": .object(cover["extern"].object.merging(["path": cover["path"], "comicId": .string(item["id"].string.isEmpty ? fallbackID : item["id"].string)]) { existing, _ in existing })
            ]))
        }
        let authors = Self.metadata(item).first { ["author", "authors", "artist"].contains($0.id) }?.values.joined(separator: ", ") ?? ""
        let creator = item["creator"]["name"].string
        let author = !authors.isEmpty ? authors : (item["author"].string.isEmpty ? creator : item["author"].string)
        return ComicSummary(id: item["id"].string.isEmpty ? fallbackID : item["id"].string, title: item["title"].string,
            coverURL: url, author: author, summary: item["description"].string)
    }
    package static func metadata(_ item: JSONValue) -> [ComicMetadata] {
        func names(_ value: JSONValue) -> [String] {
            let entries = value.array.isEmpty ? [value] : value.array
            var seen = Set<String>()
            return entries.compactMap { entry in
                let text = (entry.object.isEmpty ? entry.string : entry["name"].string)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return !text.isEmpty && seen.insert(text).inserted ? text : nil
            }
        }
        var groups: [ComicMetadata] = []
        for entry in item["metadata"].array {
            let title = entry["name"].string
            let id = entry["type"].string.isEmpty ? title : entry["type"].string
            let values = names(entry["value"])
            var actions: [String: JSONValue] = [:]
            for value in entry["value"].array where !value["onTap"].object.isEmpty {
                actions[value["name"].string] = value["onTap"]
            }
            guard !id.isEmpty, !values.isEmpty else { continue }
            if let index = groups.firstIndex(where: { $0.id == id }) {
                let old = groups[index]
                groups[index] = ComicMetadata(id: id, title: old.title,
                    values: old.values + values.filter { !old.values.contains($0) },
                    actions: (old.actions ?? [:]).merging(actions) { _, new in new })
            } else {
                groups.append(ComicMetadata(id: id, title: title.isEmpty ? id : title, values: values, actions: actions))
            }
        }
        for (id, title) in [("author", L10n.text("ComicMetadata.Author")), ("tags", L10n.text("ComicMetadata.Tags")),
                            ("categories", L10n.text("ComicMetadata.Categories")), ("updatedAt", L10n.text("ComicMetadata.UpdatedAt"))] {
            guard !groups.contains(where: { $0.id == id }) else { continue }
            let value = item[id].isNull ? item["raw"][id] : item[id]
            let values = names(value)
            if !values.isEmpty { groups.append(ComicMetadata(id: id, title: title, values: values)) }
        }
        for (index, entry) in item["titleMeta"].array.enumerated() {
            let text = entry["name"].string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let parts = text.split(maxSplits: 1, whereSeparator: { $0 == "：" || $0 == ":" })
            let title = parts.count == 2 ? String(parts[0]) : L10n.text("ComicMetadata.OtherInformation")
            let value = parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : text
            let formatted = ISO8601DateFormatter().date(from: value).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? value
            groups.append(ComicMetadata(id: "titleMeta_\(index)", title: title, values: [formatted],
                actions: entry["onTap"].object.isEmpty ? nil : [formatted: entry["onTap"]]))
        }
        return groups
    }

    func summaries(_ items: [JSONValue], plugin: PluginRecord) async throws -> [ComicSummary] {
        var output: [ComicSummary] = []
        var seen: Set<String> = []
        for item in items where !item["id"].string.isEmpty {
            if seen.insert(item["id"].string).inserted { output.append(try await summary(item, plugin: plugin)) }
        }
        return output
    }
    func items(in response: JSONValue) -> [JSONValue] {
        let data = response["data"].isNull ? response : response["data"]
        if !data["items"].isNull { return data["items"].array }
        return data["sections"].array.flatMap { $0["items"].array }
    }

    private func install(source: String, expectedID: String?, subscriptionURL: String?, context: ModelContext) async throws {
        let prepared = try await PluginTransfer.shared.prepare(source: source, expectedID: expectedID)
        let info = prepared.info
        let destination = prepared.destination
        let id = info["uuid"].string
        let existing = try context.fetch(FetchDescriptor<PluginRecord>(predicate: #Predicate { $0.uuid == id })).first
        let oldPath = existing?.bundlePath
        let record = existing ?? PluginRecord(uuid: id, name: info["name"].string, version: info["version"].string, bundlePath: destination.lastPathComponent)
        if existing == nil { context.insert(record) }
        record.name = info["name"].string
        record.version = info["version"].string
        record.bundlePath = destination.lastPathComponent
        record.infoJSON = prepared.infoData
        record.subscriptionURL = subscriptionURL ?? record.subscriptionURL
        do { try context.save() } catch {
            context.rollback()
            try? await PluginTransfer.shared.removeFile(destination)
            throw error
        }
        try await updateImageAccess(plugin: record)
        try? await PluginRuntime.shared.unload(id: id)
        initialized.removeValue(forKey: id)
        if let oldPath { try? await PluginTransfer.shared.removeBundle(oldPath) }
    }

    package nonisolated static func parseCatalog(_ data: Data, subscriptionURL url: URL) throws -> [PluginCandidate] {
        let value = try JSONValue.decode(data)
        let entries = value.array.isEmpty ? value["plugins"].array : value.array
        guard !entries.isEmpty else { throw PluginError.message(L10n.text("Subscription.InvalidCatalog")) }
        var seen: Set<String> = []
        return try entries.map { entry in
            let manifest = entry["manifest"].isNull ? entry : entry["manifest"]
            let id = manifest["uuid"].string
            guard PluginIdentity.isValid(id) else { throw PluginError.message(L10n.text("Subscription.InvalidPluginIdentifier", defaultValue: "订阅包含无效的插件标识：\(manifest["name"].string)。")) }
            guard seen.insert(id.lowercased()).inserted else { throw PluginError.message(L10n.text("Subscription.DuplicatePluginIdentifier", defaultValue: "订阅包含重复的插件标识：\(id)。")) }
            let updateURL = manifest["updateUrl"].string
            return PluginCandidate(id: id, name: manifest["name"].string, version: manifest["version"].string,
                description: manifest["describe"].string, downloadURL: URL(string: updateURL), subscriptionURL: url.absoluteString, npmName: manifest["npmName"].string)
        }
    }
}

/// Transfers only Sendable values; no SwiftData records or UI state cross this boundary.
private actor PluginTransfer {
    static let shared = PluginTransfer()

    struct PreparedBundle: Sendable {
        let info: JSONValue
        let infoData: Data
        let destination: URL
    }

    func importScript(_ url: URL) async throws -> String {
        guard url.isFileURL else { return try await scriptFromUpdateURL(url) }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1024 * 1024 else { throw PluginError.message(L10n.text("PluginInstall.FileTooLarge")) }
        return url.pathExtension == "br" ? try await PluginRuntime.shared.decompress(data) : String(decoding: data, as: UTF8.self)
    }

    func prepare(source: String, expectedID: String?) async throws -> PreparedBundle {
        guard source.contains("getInfo"), source.utf8.count <= 16 * 1024 * 1024 else { throw PluginError.message(L10n.text("PluginInstall.InvalidPluginFile")) }
        let temporaryID = "install-" + UUID().uuidString
        let root = try PluginRuntime.storageDirectory()
        let temporary = root.appendingPathComponent(temporaryID + ".cjs")
        try Data(source.utf8).write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let info: JSONValue
        do {
            info = try await PluginRuntime.shared.call(id: temporaryID, path: temporary.path, function: "getInfo")
            try await PluginRuntime.shared.unload(id: temporaryID)
        } catch {
            try? await PluginRuntime.shared.unload(id: temporaryID)
            throw error
        }
        let id = info["uuid"].string
        guard PluginIdentity.isValid(id), !info["name"].string.isEmpty, !info["version"].string.isEmpty else { throw PluginError.message(L10n.text("PluginInstall.InvalidManifest")) }
        if let expectedID, expectedID != id { throw PluginError.message(L10n.text("PluginInstall.SubscriptionIdentifierMismatch")) }
        // Versioned files allow rollback if saving the installation fails.
        let destination = root.appendingPathComponent(id + "-" + UUID().uuidString + ".cjs")
        try Data(source.utf8).write(to: destination, options: [.atomic, .completeFileProtection])
        return PreparedBundle(info: info, infoData: try info.encoded(), destination: destination)
    }

    func removeFile(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func removeBundle(_ path: String) throws {
        guard let resolved = try? PluginRuntime.resolveBundlePath(path) else { return }
        try FileManager.default.removeItem(atPath: resolved)
    }

    func updateImageAccess(id: String, path: String, enabled: Bool) throws {
        let registry = try PluginRuntime.storageDirectory().appendingPathComponent(id + ".path")
        if enabled {
            try Data(path.utf8).write(to: registry, options: [.atomic, .completeFileProtection])
        } else if FileManager.default.fileExists(atPath: registry.path) {
            try FileManager.default.removeItem(at: registry)
        }
    }

    func fetchCatalog(_ url: URL) async throws -> [PluginCandidate] {
        let data = try await download(url, limit: 4 * 1024 * 1024)
        return try PluginService.parseCatalog(data, subscriptionURL: url)
    }

    func scriptFromUpdateURL(_ url: URL) async throws -> String {
        if ["cjs", "js", "br"].contains(url.pathExtension) { return try await downloadScript(url) }
        let release = try JSONValue.decode(try await download(url, limit: 4 * 1024 * 1024))
        let assets = release["assets"].array
        let asset = assets.first { $0["name"].string.hasSuffix(".cjs.br") } ?? assets.first { $0["name"].string.hasSuffix(".cjs") }
        guard let asset, let download = URL(string: asset["browser_download_url"].string) else { throw PluginError.message(L10n.text("PluginInstall.MissingReleaseAsset")) }
        return try await downloadScript(download)
    }
    func downloadScript(_ url: URL) async throws -> String {
        let data = try await download(url, limit: 16 * 1024 * 1024)
        if url.pathExtension == "br" { return try await PluginRuntime.shared.decompress(data) }
        guard let text = String(data: data, encoding: .utf8) else { throw PluginError.message(L10n.text("PluginInstall.InvalidEncoding")) }
        return text
    }
    private func validateRemote(_ url: URL) throws {
        guard url.scheme == "https", url.host != nil else { throw PluginError.message(L10n.text("Network.InvalidHTTPSURL")) }
    }
    private func download(_ url: URL, limit: Int) async throws -> Data {
        try validateRemote(url)
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Willow/1.0", forHTTPHeaderField: "User-Agent")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        let host = url.host ?? L10n.text("Network.DownloadServer")
        do { (bytes, response) = try await URLSession.shared.bytes(for: request) }
        catch {
            try Task.checkCancellation()
            throw PluginError.message(L10n.text("Network.ServerFailure", defaultValue: "\(host)：\(error.localizedDescription)"))
        }
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else {
            throw PluginError.message(L10n.text("Network.InvalidResponse", defaultValue: "\(host)：服务器返回无效响应。"))
        }
        guard (200..<300).contains(http.statusCode) else {
            let hint = http.statusCode == 429 || (http.statusCode == 403 && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") ? L10n.text("Network.RateLimited") : ""
            throw PluginError.message(L10n.text("Network.HTTPStatus", defaultValue: "\(host)：HTTP \(http.statusCode)\(hint)。"))
        }
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit { throw PluginError.message(L10n.text("Network.DownloadTooLarge")) }
            data.append(byte)
        }
        return data
    }
}
