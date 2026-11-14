import BreezeRuntime
import CoreStorage
import Foundation

package struct PluginHomeTab: Identifiable, Hashable, Sendable {
    package let id: String
    package let title: String
    package let scene: JSONValue
    package let page: JSONValue
    package let actions: [JSONValue]
    package let functionID: String?

    package init(id: String, title: String, scene: JSONValue = .null, page: JSONValue = .null,
                 actions: [JSONValue] = [], functionID: String? = nil) {
        self.id = id; self.title = title; self.scene = scene; self.page = page
        self.actions = actions; self.functionID = functionID
    }

    package var listTab: PluginFavoriteTab {
        PluginFavoriteTab(id: 0, title: title,
            request: scene["body"]["request"].isNull ? scene["list"] : scene["body"]["request"],
            filter: scene["filter"], scene: scene)
    }
}

package struct PluginHomeLink: Identifiable, Sendable {
    package let id: String
    package let title: String
    package let coverURL: URL?
    package let action: JSONValue
}

package struct PluginHomeBlock: Identifiable, Sendable {
    package let id: String
    package let title: String
    package let kind: String
    package let comics: [ComicSummary]
    package let links: [PluginHomeLink]
    package let action: JSONValue
}

extension PluginService {
    package func homeTabs(plugin: PluginRecord, cloud: Bool = false) async throws -> [PluginHomeTab] {
        let response = try await call(plugin, cloud ? "getPluginCloudFavoritePagesBundle" : "getPluginHomePagesBundle")
        let data = response["data"].isNull ? response : response["data"]
        let tabs = data["pages"].array.isEmpty ? data["tabs"].array : data["pages"].array
        var seen = Set<String>()
        return tabs.enumerated().compactMap { index, tab in
            let rawID = tab["id"].string.isEmpty ? tab["key"].string : tab["id"].string
            let id = rawID.isEmpty ? "tab_\(index)" : rawID
            guard seen.insert(id).inserted else { return nil }
            let actions = tab["header"]["actions"].isNull ? tab["actions"].array : tab["header"]["actions"].array
            return PluginHomeTab(id: id, title: tab["title"].string.isEmpty ? id : tab["title"].string,
                                 scene: tab["scene"], page: tab["page"], actions: actions)
        }
    }

    package func functionPage(plugin: PluginRecord, id: String) async throws -> JSONValue {
        try await call(plugin, "getFunctionPage", args: .object(["id": .string(id)]))
    }

    package func homeBlocks(plugin: PluginRecord, page: JSONValue) async throws -> [PluginHomeBlock] {
        let data = page["data"]
        func render(_ node: JSONValue, path: String) async throws -> [PluginHomeBlock] {
            let kind = node["type"].string
            if kind == "list" {
                var blocks: [PluginHomeBlock] = []
                for (index, child) in node["children"].array.enumerated() {
                    blocks += try await render(child, path: "\(path).\(index)")
                }
                return blocks
            }
            let items = data[node["key"].string].array
            if kind == "comic-section-list" {
                var blocks: [PluginHomeBlock] = []
                for (index, section) in items.enumerated() {
                    blocks.append(PluginHomeBlock(id: "\(path).\(index)", title: section["title"].string,
                        kind: "comic-grid", comics: try await summaries(section["items"].array, plugin: plugin),
                        links: [], action: section["action"]))
                }
                return blocks
            }
            if kind == "comic-grid" {
                return [PluginHomeBlock(id: path, title: node["title"].string, kind: kind,
                    comics: try await summaries(items, plugin: plugin), links: [], action: node["action"])]
            }
            if kind == "chip-list" || kind == "action-grid" {
                var links: [PluginHomeLink] = []
                for (index, item) in items.enumerated() {
                    let title = item["label"].string.isEmpty ? item["title"].string : item["label"].string
                    let comic = try await summary(item, plugin: plugin, fallbackID: "\(path).\(index)")
                    links.append(PluginHomeLink(id: "\(path).\(index)", title: title, coverURL: comic.coverURL, action: item["action"]))
                }
                return [PluginHomeBlock(id: path, title: node["title"].string, kind: kind, comics: [], links: links, action: node["action"])]
            }
            if kind.isEmpty { return [] }
            throw PluginError.message(L10n.text("PluginError.UnsupportedComponent", defaultValue: "暂不支持的插件页面组件：\(kind)"))
        }
        return try await render(page["scheme"]["body"], path: "body")
    }
}

extension PluginRecord {
    package var discoveryActions: [JSONValue] {
        guard let infoJSON, let info = try? JSONValue.decode(infoJSON) else { return [] }
        let functions = info["functions"].isNull ? info["function"].array : info["functions"].array
        return functions.compactMap { function in
            let id = function["id"].string
            let title = function["title"].string
            var action = function["action"]
            if action.object.isEmpty && !id.isEmpty {
                action = .object(["type": .string("openPluginFunction"),
                    "payload": .object(["id": .string(id), "title": .string(title)])])
            }
            guard !action.object.isEmpty else { return nil }
            return .object(["id": .string(id), "title": .string(title), "action": action])
        }
    }
}
