import BreezePlugins
import BreezeRuntime
import CoreStorage
import Foundation
import Observation

@MainActor
final class PluginComicListModel {
    @MainActor @Observable
    final class ViewModel {
        var tabs: [PluginFavoriteTab] = []
        var selectedTab: Int?
        var fields: [PluginFeatureField] = []
        var values: [String: JSONValue] = [:]
        var keyword: String
        var comics: [ComicSummary] = []
        var error: String?
        var isLoading = false
        var loaded = false
        var hasMore = false
        var searched = false
        fileprivate var submittedKeyword: String?
        fileprivate var submittedValues: [String: JSONValue] = [:]

        var matchesSubmittedSearch: Bool {
            submittedKeyword == keyword.trimmingCharacters(in: .whitespacesAndNewlines) && submittedValues == values
        }

        init(keyword: String) { self.keyword = keyword }
    }

    let viewModel: ViewModel
    private let plugin: PluginRecord
    private let advanced: Bool
    private var page = 1
    private var extern: [String: JSONValue] = [:]
    private var query = ""
    private var filtersLoadedFor: Int?
    private var favoritesBundleNeedsRetry = false

    init(plugin: PluginRecord, keyword: String? = nil) {
        self.plugin = plugin
        advanced = keyword != nil
        viewModel = ViewModel(keyword: keyword ?? "")
    }

    func load() async {
        guard !viewModel.isLoading else { return }
        viewModel.isLoading = true
        viewModel.error = nil
        defer { viewModel.isLoading = false }
        do {
            if advanced {
                let (fields, values) = try await PluginService.shared.advancedSearchFields(plugin: plugin)
                viewModel.fields = fields
                viewModel.values = values
            } else {
                let tabs = try await PluginService.shared.sourceFavoriteTabs(plugin: plugin)
                viewModel.tabs = tabs
                if !tabs.contains(where: { $0.id == viewModel.selectedTab }) {
                    viewModel.selectedTab = tabs.first?.id
                }
                if tabs.isEmpty {
                    viewModel.fields = []
                    viewModel.values = [:]
                }
                filtersLoadedFor = nil
                favoritesBundleNeedsRetry = false
            }
            viewModel.loaded = true
        } catch {
            if !Task.isCancelled {
                favoritesBundleNeedsRetry = !advanced
                viewModel.error = error.localizedDescription
            }
        }
    }

    func loadFavorites() async {
        guard !viewModel.isLoading else { return }
        await load()
        if viewModel.error == nil && !Task.isCancelled {
            await fetch(reset: true)
        }
    }

    func retry() async {
        if favoritesBundleNeedsRetry {
            await loadFavorites()
        } else if viewModel.loaded {
            await fetch()
        } else if advanced {
            await load()
        } else {
            await loadFavorites()
        }
    }

    func applyFavoriteFilters(_ values: [String: JSONValue]) async {
        guard !viewModel.isLoading, values != viewModel.values else { return }
        viewModel.values = values
        await fetch(reset: true)
    }

    func selectTab(_ id: Int?) async {
        guard !viewModel.isLoading else { return }
        viewModel.selectedTab = id
        await fetch(reset: true)
    }

    func search() async {
        guard !viewModel.isLoading else { return }
        query = viewModel.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.submittedKeyword = query
        viewModel.submittedValues = viewModel.values
        extern = viewModel.values
        for field in viewModel.fields {
            let value = extern[field.id] ?? field.defaultValue
            switch (field.kind, value) {
            case ("multiChoice", .object(let map)):
                extern[field.id] = .array(field.options.map(\.id).filter { map[$0.string]?.bool == true })
            case ("multiChoice", .null): extern[field.id] = .array([])
            case ("text", .null): extern[field.id] = .string("")
            case ("switch", .null): extern[field.id] = .bool(false)
            default: extern[field.id] = value
            }
        }
        await fetch(reset: true)
    }

    func loadNextPage() async {
        guard viewModel.hasMore, viewModel.error == nil, viewModel.searched else { return }
        await fetch()
    }

    func fetch(reset: Bool = false) async {
        guard !viewModel.isLoading, !advanced || viewModel.matchesSubmittedSearch else { return }
        viewModel.isLoading = true
        viewModel.error = nil
        defer { viewModel.isLoading = false }
        if reset {
            page = 1
            viewModel.comics = []
            viewModel.hasMore = false
            viewModel.searched = false
        }
        do {
            let response: PluginComicPage
            if advanced {
                response = try await PluginService.shared.advancedSearch(
                    plugin: plugin, keyword: query, page: page, extern: extern
                )
                try Task.checkCancellation()
                guard viewModel.matchesSubmittedSearch else { return }
                extern.merge(response.extern.object) { _, new in new }
            } else {
                guard let tab = viewModel.tabs.first(where: { $0.id == viewModel.selectedTab }) else { return }
                if filtersLoadedFor != tab.id {
                    let (fields, values) = try await PluginService.shared.sourceFavoriteFilters(plugin: plugin, tab: tab)
                    viewModel.fields = fields
                    viewModel.values = values
                    filtersLoadedFor = tab.id
                }
                response = try await PluginService.shared.sourceFavoritePage(
                    plugin: plugin, tab: tab, page: page, fields: viewModel.fields, values: viewModel.values
                )
            }
            try Task.checkCancellation()
            var seen = Set(viewModel.comics.map(\.id))
            viewModel.comics += response.comics.filter { seen.insert($0.id).inserted }
            viewModel.hasMore = response.hasMore && !response.comics.isEmpty
            viewModel.searched = true
            page += 1
        } catch {
            if !Task.isCancelled { viewModel.error = error.localizedDescription }
        }
    }
}

struct PluginFavoritePrompt: Identifiable {
    let id = UUID()
    let payload: JSONValue
    let token: String
    let folders: [JSONValue]
}

@MainActor
final class PluginComicActionsModel {
    @MainActor @Observable
    final class ViewModel {
        var state: PluginComicActionState?
        var prompt: PluginFavoritePrompt?
        var isWorking = false
        var error: String?

        init(state: PluginComicActionState?) { self.state = state }
    }

    let viewModel: ViewModel
    private let plugin: PluginRecord
    private let comicID: String
    private var favoriteStartValue = false
    private var steps = 0

    init(plugin: PluginRecord, comicID: String, state: PluginComicActionState?) {
        self.plugin = plugin
        self.comicID = comicID
        viewModel = ViewModel(state: state)
    }

    func updateSourceState(_ state: PluginComicActionState?) {
        guard let state, !viewModel.isWorking, viewModel.prompt == nil else { return }
        viewModel.state = state
    }

    func load() async {
        guard viewModel.state == nil else { return }
        await perform {
            viewModel.state = try await PluginService.shared.sourceActions(plugin: plugin, comicID: comicID)
        }
    }

    func like() async {
        guard let state = viewModel.state, state.allowLike else { return }
        await perform {
            let liked = try await PluginService.shared.toggleSourceLike(
                plugin: plugin, comicID: comicID, liked: state.liked
            )
            viewModel.state?.liked = liked
            if let count = state.totalLikes, liked != state.liked {
                viewModel.state?.totalLikes = max(0, count + (liked ? 1 : -1))
            }
        }
    }

    func favorite() async {
        guard let state = viewModel.state, state.allowCollected, viewModel.prompt == nil else { return }
        await perform {
            favoriteStartValue = state.favorited
            steps = 0
            let result = try await PluginService.shared.startSourceFavorite(
                plugin: plugin, comicID: comicID, favorited: state.favorited
            )
            try await applyFavorite(result)
        }
    }

    func answer(_ prompt: PluginFavoritePrompt, input: JSONValue) async {
        guard viewModel.prompt?.id == prompt.id else { return }
        viewModel.prompt = nil
        await perform {
            if !prompt.folders.isEmpty {
                if let folder = prompt.folders.first(where: { $0["id"] == input["value"] }) {
                    try await PluginService.shared.moveSourceFavorite(plugin: plugin, comicID: comicID, folder: folder)
                }
            } else {
                let result = try await PluginService.shared.continueSourceFavorite(
                    plugin: plugin, comicID: comicID, favorited: favoriteStartValue, token: prompt.token, input: input
                )
                try await applyFavorite(result)
            }
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !viewModel.isWorking else { return }
        viewModel.error = nil
        viewModel.isWorking = true
        defer { viewModel.isWorking = false }
        do { try await action() }
        catch { if !Task.isCancelled { viewModel.error = error.localizedDescription } }
    }

    private func applyFavorite(_ result: JSONValue) async throws {
        steps += 1
        guard steps <= 16 else { throw PluginError.message(L10n.text("Text.TheSourceRequestedTooManyStepsToManageThisFavorite")) }
        if case .bool(let value) = result["favorited"] {
            viewModel.state?.favorited = value
        }
        switch result["status"].string {
        case "completed", "cancelled": return
        case "awaitingInput":
            let token = result["continuationToken"].string
            let payload = result["input"]
            guard !token.isEmpty, ["select", "text", "confirm", "form"].contains(payload["type"].string) else {
                throw PluginError.message(L10n.text("Text.TheSourceRequestedAnUnsupportedFavoritesOption"))
            }
            viewModel.prompt = PluginFavoritePrompt(payload: payload, token: token, folders: [])
        case "" where !result["favorited"].isNull:
            guard result["nextStep"].string == "selectFolder", result["favorited"].bool else { return }
            let folders = try await PluginService.shared.sourceFavoriteFolders(plugin: plugin)
                .filter { !$0["id"].string.isEmpty }
            if !folders.isEmpty {
                let options = folders.map { folder in
                    JSONValue.object(["id": folder["id"], "label": folder["name"]])
                }
                let payload: JSONValue = .object([
                    "type": .string("select"), "title": .string(L10n.text("Text.ChooseASourceFavoritesFolder")), "options": .array(options)
                ])
                viewModel.prompt = PluginFavoritePrompt(payload: payload, token: "", folders: folders)
            }
        default:
            let message = result["message"].string
            throw PluginError.message(message.isEmpty ? L10n.text("Text.TheSourceCouldnTUpdateThisFavorite") : message)
        }
    }
}

@MainActor
final class PluginCommentsModel {
    @MainActor @Observable
    final class ViewModel {
        var items: [PluginComment] = []
        var error: String?
        var isLoading = false
        var hasMore = false
        var canPost = false
        var canReply = false
        var embedsReplies = false
        var isPosting = false
        var draft = ""

        var canSend: Bool {
            !isPosting && !isLoading && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    let viewModel = ViewModel()
    let plugin: PluginRecord
    let comicID: String
    let parent: PluginComment?
    private let embedded: Bool
    private var page = 1

    init(plugin: PluginRecord, comicID: String, parent: PluginComment?, embedded: Bool, canReply: Bool) {
        self.plugin = plugin
        self.comicID = comicID
        self.parent = parent
        self.embedded = embedded
        viewModel.canPost = parent != nil && canReply
    }

    func fetch(reset: Bool = false, afterPosting: Bool = false) async {
        guard !viewModel.isLoading else { return }
        if let parent, embedded, !afterPosting, page == 1 {
            viewModel.items = parent.replies
            page += 1
            return
        }
        viewModel.isLoading = true
        viewModel.error = nil
        defer { viewModel.isLoading = false }
        let requestedPage = reset ? 1 : page
        do {
            var response = try await PluginService.shared.sourceComments(
                plugin: plugin, comicID: comicID, page: embedded ? 1 : requestedPage,
                parent: embedded ? nil : parent
            )
            try Task.checkCancellation()
            if let parent, embedded {
                response = PluginCommentPage(
                    comments: response.comments.first(where: { $0.id == parent.id })?.replies ?? viewModel.items,
                    hasMore: false, canPost: viewModel.canPost, canReply: false, embedsReplies: false
                )
            }
            if reset { viewModel.items = [] }
            var seen = Set(viewModel.items.map(\.id))
            viewModel.items += response.comments.filter { seen.insert($0.id).inserted }
            viewModel.hasMore = response.hasMore
            if parent == nil {
                viewModel.canPost = response.canPost
                viewModel.canReply = response.canReply
                viewModel.embedsReplies = response.embedsReplies
            }
            page = requestedPage + 1
        } catch {
            if !Task.isCancelled { viewModel.error = error.localizedDescription }
        }
    }

    func post() async {
        guard viewModel.canPost, viewModel.canSend, !viewModel.isLoading else { return }
        viewModel.isPosting = true
        viewModel.error = nil
        defer { viewModel.isPosting = false }
        do {
            try await PluginService.shared.postSourceComment(
                plugin: plugin, comicID: comicID,
                content: viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines), parent: parent
            )
            viewModel.draft = ""
            await fetch(reset: true, afterPosting: true)
        } catch {
            if !Task.isCancelled { viewModel.error = error.localizedDescription }
        }
    }
}
