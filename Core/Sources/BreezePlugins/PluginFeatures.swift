import BreezeRuntime
import CoreStorage
import Foundation

package struct PluginComicActionState: Codable, Hashable, Sendable {
    package let allowComments: Bool
    package let allowLike: Bool
    package let allowCollected: Bool
    package let allowDownload: Bool
    package var liked: Bool
    package var favorited: Bool
    package var totalLikes: Int?
    package var totalComments: Int?

    package init(normal: JSONValue) {
        allowComments = normal["allowComments"].bool
        allowLike = normal["allowLike"].bool
        allowCollected = normal["allowCollected"].bool
        allowDownload = normal["allowDownload"] != .bool(false)
        liked = normal["isLiked"].bool
        favorited = normal["isFavourite"].bool
        totalLikes = normal["totalLikes"].isNull ? nil : max(0, normal["totalLikes"].int)
        totalComments = normal["totalComments"].isNull ? nil : max(0, normal["totalComments"].int)
    }
}

package struct PluginChoice: Identifiable {
    package let id: JSONValue
    package let label: String
    package let result: JSONValue

    package init(_ value: JSONValue) {
        id = value["value"].isNull ? value["id"] : value["value"]
        let label = value["label"].string.isEmpty ? value["name"].string : value["label"].string
        self.label = label.isEmpty ? id.string : label
        result = value["result"]
    }
}

package struct PluginFeatureField: Identifiable {
    package let id: String
    package let label: String
    package let kind: String
    package let options: [PluginChoice]
    package let required: Bool
    package let defaultValue: JSONValue

    package init(_ field: JSONValue, kindKey: String = "kind") {
        id = field["key"].string
        label = field["label"].string.isEmpty ? id : field["label"].string
        let kind = field[kindKey].string
        self.kind = kind.isEmpty ? (kindKey == "type" ? "text" : "choice") : kind
        options = field["options"].array.map(PluginChoice.init).filter { !$0.id.isNull }
        required = field["required"].bool
        defaultValue = field["defaultValue"]
    }

    package init(id: String, label: String, kind: String, options: [PluginChoice], required: Bool) {
        self.id = id
        self.label = label
        self.kind = kind
        self.options = options
        self.required = required
        defaultValue = .null
    }
}

package struct PluginComment: Identifiable {
    package let id: String
    package let author: String
    package let content: String
    package let createdAt: String
    package let replyCount: Int
    package let replies: [PluginComment]
    package let extern: JSONValue

    package init(_ item: JSONValue) {
        id = item["id"].string
        author = item["author"]["name"].string
        content = item["content"].string
        createdAt = item["createdAt"].string
        replyCount = item["replyCount"].int
        replies = item["replies"].array.map(PluginComment.init)
        extern = item["extern"]
    }
}

package struct PluginCommentPage {
    package let comments: [PluginComment]
    package let hasMore: Bool
    package let canPost: Bool
    package let canReply: Bool
    package let embedsReplies: Bool

    package init(comments: [PluginComment], hasMore: Bool, canPost: Bool, canReply: Bool, embedsReplies: Bool) {
        self.comments = comments
        self.hasMore = hasMore
        self.canPost = canPost
        self.canReply = canReply
        self.embedsReplies = embedsReplies
    }
}

package struct PluginFavoriteTab: Identifiable {
    package let id: Int
    package let title: String
    package let request: JSONValue
    package let filter: JSONValue
    package let scene: JSONValue

    package init(id: Int, title: String, request: JSONValue, filter: JSONValue, scene: JSONValue) {
        self.id = id
        self.title = title
        self.request = request
        self.filter = filter
        self.scene = scene
    }
}

package struct PluginComicPage {
    package let comics: [ComicSummary]
    package let hasMore: Bool
    package let extern: JSONValue

    package init(comics: [ComicSummary], hasMore: Bool, extern: JSONValue) {
        self.comics = comics
        self.hasMore = hasMore
        self.extern = extern
    }
}

extension PluginRecord {
    package var supportsCloudFavorites: Bool {
        guard let infoJSON, let info = try? JSONValue.decode(infoJSON) else { return false }
        return info["haveCloudFavorite"].bool
    }
}

extension PluginService {
    package func sourceActions(plugin: PluginRecord, comicID: String) async throws -> PluginComicActionState {
        let data = try await call(plugin, "getComicDetail", args: .object(["comicId": .string(comicID)])).pluginData
        return PluginComicActionState(normal: data["normal"].isNull ? data : data["normal"])
    }

    package func toggleSourceLike(plugin: PluginRecord, comicID: String, liked: Bool) async throws -> Bool {
        let data = try await call(plugin, "toggleLike", args: .object([
            "comicId": .string(comicID), "currentLiked": .bool(liked)
        ])).pluginData
        guard case .bool(let next) = data["liked"] else {
            throw PluginError.message(L10n.text("ComicActions.MissingLikeStatus"))
        }
        return next
    }

    package func startSourceFavorite(plugin: PluginRecord, comicID: String, favorited: Bool) async throws -> JSONValue {
        let args: [String: JSONValue] = ["comicId": .string(comicID), "currentFavorite": .bool(favorited)]
        do {
            return try await call(plugin, "startFavoriteAction", args: .object(
                args.merging(["action": .string(favorited ? "removeAll" : "add")]) { _, new in new }
            )).pluginData
        } catch {
            let message = error.localizedDescription.lowercased()
            guard message.contains("startfavoriteaction"),
                  ["not a function", "target is not function", "function path not found", "missing function", "undefined"]
                    .contains(where: message.contains) else { throw error }
            return try await call(plugin, "toggleFavorite", args: .object(args)).pluginData
        }
    }

    package func continueSourceFavorite(
        plugin: PluginRecord, comicID: String, favorited: Bool, token: String, input: JSONValue
    ) async throws -> JSONValue {
        try await call(plugin, "continueFavoriteAction", args: .object([
            "comicId": .string(comicID), "action": .string(favorited ? "removeAll" : "add"),
            "continuationToken": .string(token), "input": input
        ])).pluginData
    }

    package func sourceFavoriteFolders(plugin: PluginRecord) async throws -> [JSONValue] {
        try await call(plugin, "listFavoriteFolders").pluginData["items"].array
    }

    package func moveSourceFavorite(plugin: PluginRecord, comicID: String, folder: JSONValue) async throws {
        _ = try await call(plugin, "moveFavoriteToFolder", args: .object([
            "comicId": .string(comicID), "folderId": folder["id"], "folderName": folder["name"]
        ]))
    }

    package func sourceComments(
        plugin: PluginRecord, comicID: String, page: Int, parent: PluginComment?
    ) async throws -> PluginCommentPage {
        var args: [String: JSONValue] = ["comicId": .string(comicID), "page": .number(Double(page))]
        if let parent {
            args["commentId"] = .string(parent.id)
            args["extern"] = parent.extern
        }
        let data = try await call(plugin, parent == nil ? "getCommentFeed" : "loadCommentReplies", args: .object(args)).pluginData
        let items = data["items"].array
        let top = parent == nil && page == 1 ? data["topItems"].array : []
        return PluginCommentPage(
            comments: (top + items).map(PluginComment.init).filter { !$0.id.isEmpty },
            hasMore: !items.isEmpty && !data["paging"]["hasReachedMax"].bool,
            canPost: data["canComment"]["comic"].bool,
            canReply: data["canComment"]["reply"].bool,
            embedsReplies: data["replyMode"].string == "embedded"
        )
    }

    package func postSourceComment(plugin: PluginRecord, comicID: String, content: String, parent: PluginComment?) async throws {
        var args: [String: JSONValue] = ["comicId": .string(comicID), "content": .string(content)]
        if let parent {
            args["commentId"] = .string(parent.id)
            args["extern"] = parent.extern
        }
        _ = try await call(plugin, parent == nil ? "postComment" : "postCommentReply", args: .object(args))
    }

    package func sourceFavoriteTabs(plugin: PluginRecord) async throws -> [PluginFavoriteTab] {
        let data = try await call(plugin, "getPluginCloudFavoritePagesBundle").pluginData
        let pages = data["pages"].array
        return (pages.isEmpty ? data["tabs"].array : pages).enumerated().map { index, tab in
            let scene = tab["scene"].isNull ? tab["page"]["data"] : tab["scene"]
            return PluginFavoriteTab(
                id: index, title: tab["title"].string.isEmpty ? plugin.name : tab["title"].string,
                request: scene["body"]["request"].isNull ? scene["list"] : scene["body"]["request"],
                filter: scene["filter"], scene: scene
            )
        }
    }

    package func sourceFavoriteFilters(
        plugin: PluginRecord, tab: PluginFavoriteTab
    ) async throws -> ([PluginFeatureField], [String: JSONValue]) {
        guard !tab.filter.requestFunction.isEmpty else { return ([], [:]) }
        var args = tab.filter["core"].object
        args["extern"] = tab.filter["extern"]
        let response = try await call(plugin, tab.filter.requestFunction, args: .object(args))
        let fields = response["scheme"]["fields"].array.map { PluginFeatureField($0) }
            .filter { !$0.id.isEmpty && $0.kind == "choice" && !$0.options.isEmpty }
        let defaults = response["data"]["values"]
        var values: [String: JSONValue] = [:]
        for field in fields {
            values[field.id] = field.options.first { $0.id == defaults[field.id] }?.id ?? field.options.first?.id
        }
        return (fields, values)
    }

    package func sourceFavoritePage(
        plugin: PluginRecord, tab: PluginFavoriteTab, page: Int,
        fields: [PluginFeatureField], values: [String: JSONValue]
    ) async throws -> PluginComicPage {
        let function = tab.request.requestFunction
        guard !function.isEmpty else {
            return PluginComicPage(
                comics: try await summaries(items(in: tab.scene), plugin: plugin), hasMore: false, extern: .null
            )
        }
        var args = tab.request["core"].object
        var extern = tab.request["extern"].object
        args["page"] = .number(Double(page))
        for field in fields {
            let option = field.options.first { $0.id == values[field.id] }
            args.merge(option?.result["core"].object ?? [:]) { _, new in new }
            extern.merge(option?.result["extern"].object ?? [:]) { _, new in new }
        }
        args["extern"] = .object(extern)
        let response = try await call(plugin, function, args: .object(args))
        return try await featureComicPage(response, plugin: plugin)
    }

    package func advancedSearchFields(plugin: PluginRecord) async throws -> ([PluginFeatureField], [String: JSONValue]) {
        let response = try await call(plugin, "getAdvancedSearchScheme")
        let fields = response["scheme"]["fields"].array.map { PluginFeatureField($0) }
            .filter { !$0.id.isEmpty && ["text", "switch", "choice", "multiChoice"].contains($0.kind) }
        return (fields, response["data"]["values"].object)
    }

    package func advancedSearch(
        plugin: PluginRecord, keyword: String, page: Int, extern: [String: JSONValue]
    ) async throws -> PluginComicPage {
        let response = try await call(plugin, "searchComic", args: .object([
            "keyword": .string(keyword), "page": .number(Double(page)), "isSearchAggregate": .bool(false),
            "extern": .object(extern)
        ]))
        return try await featureComicPage(response, plugin: plugin)
    }

    private func featureComicPage(_ response: JSONValue, plugin: PluginRecord) async throws -> PluginComicPage {
        let comics = try await summaries(items(in: response), plugin: plugin)
        let data = response.pluginData
        let paging = data["paging"]
        let hasMorePages = paging["pages"].int <= 0 || paging["page"].int < paging["pages"].int
        return PluginComicPage(
            comics: comics,
            hasMore: !comics.isEmpty && hasMorePages && !paging["hasReachedMax"].bool && !data["hasReachedMax"].bool,
            extern: response["extern"]
        )
    }
}

private extension JSONValue {
    var requestFunction: String {
        for request in [self, self["request"]] {
            for key in ["fnPath", "fn_path", "fn", "function"] {
                let value = request[key].string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return ""
    }

    var pluginData: JSONValue { self["data"].isNull ? self : self["data"] }
}
