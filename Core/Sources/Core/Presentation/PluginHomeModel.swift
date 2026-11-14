import BreezePlugins
import BreezeRuntime
import CoreStorage
import Foundation
import Observation

@MainActor
final class PluginHomeModel {
    @MainActor @Observable
    final class ViewModel {
        var blocks: [PluginHomeBlock] = []
        var comics: [ComicSummary] = []
        var fields: [PluginFeatureField] = []
        var values: [String: JSONValue] = [:]
        var loading = false
        var loaded = false
        var hasMore = false
        var error: String?
        var destination: Destination?
        var actionError: String?
    }

    enum Destination: Hashable {
        case page(PluginHomeTab)
        case comic(ComicSummary)
        case favorites
        case web(URL)
    }

    let viewModel = ViewModel()
    let plugin: PluginRecord
    let tab: PluginHomeTab
    private var nextPage = 1
    private var filtersLoaded = false

    init(plugin: PluginRecord, tab: PluginHomeTab) { self.plugin = plugin; self.tab = tab }

    func load(reset: Bool = false) async {
        guard !viewModel.loading else { return }
        if !reset && viewModel.loaded && !viewModel.hasMore && viewModel.error == nil { return }
        viewModel.loading = true
        viewModel.error = nil
        defer { viewModel.loading = false }
        if reset { nextPage = 1; viewModel.comics = []; viewModel.blocks = []; viewModel.hasMore = false }
        do {
            if !tab.scene.isNull {
                if !filtersLoaded {
                    let (fields, values) = try await PluginService.shared.sourceFavoriteFilters(plugin: plugin, tab: tab.listTab)
                    try Task.checkCancellation()
                    viewModel.fields = fields; viewModel.values = values; filtersLoaded = true
                }
                let result = try await PluginService.shared.sourceFavoritePage(plugin: plugin, tab: tab.listTab,
                    page: nextPage, fields: viewModel.fields, values: viewModel.values)
                try Task.checkCancellation()
                var seen = Set(viewModel.comics.map(\.id))
                viewModel.comics += result.comics.filter { seen.insert($0.id).inserted }
                viewModel.hasMore = result.hasMore && !result.comics.isEmpty
                nextPage += 1
            } else {
                let page: JSONValue
                if let id = tab.functionID { page = try await PluginService.shared.functionPage(plugin: plugin, id: id) }
                else { page = tab.page }
                let blocks = try await PluginService.shared.homeBlocks(plugin: plugin, page: page)
                try Task.checkCancellation()
                viewModel.blocks = blocks
            }
            viewModel.loaded = true
        } catch {
            if !Task.isCancelled { viewModel.error = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard viewModel.hasMore, viewModel.error == nil else { return }
        await load()
    }

    func filter(_ values: [String: JSONValue]) async {
        guard !viewModel.loading, values != viewModel.values else { return }
        viewModel.values = values
        await load(reset: true)
    }

    func route(_ action: JSONValue) {
        let action = action["action"].isNull ? action : action["action"]
        let payload = action["payload"]
        let title = payload["title"].string
        switch action["type"].string {
        case "none", "": break
        case "openSearch":
            var extern = payload["extern"].object
            for (key, value) in payload.object where key != "source" && key != "extern" && extern[key] == nil {
                extern[key] = value
            }
            let keyword = payload["keyword"].string.isEmpty ? extern["keyword"]?.string ?? "" : payload["keyword"].string
            let scene: JSONValue = .object(["body": .object(["request": .object([
                "fnPath": .string("searchComic"), "core": .object(["keyword": .string(keyword), "isSearchAggregate": .bool(false)]),
                "extern": .object(extern)
            ])])])
            viewModel.destination = .page(PluginHomeTab(id: "search", title: keyword.isEmpty ? L10n.text("Text.SearchResults") : keyword, scene: scene))
        case "openComicList":
            viewModel.destination = .page(PluginHomeTab(id: "list", title: title.isEmpty ? payload["scene"]["title"].string : title, scene: payload["scene"]))
        case "openPluginFunction":
            guard !payload["id"].string.isEmpty else { return }
            viewModel.destination = .page(PluginHomeTab(id: payload["id"].string, title: title, functionID: payload["id"].string))
        case "openCloudFavorite": viewModel.destination = .favorites
        case "openComicInfo":
            guard !payload["comicId"].string.isEmpty else { return }
            viewModel.destination = .comic(ComicSummary(id: payload["comicId"].string, title: title, coverURL: nil, author: "", summary: ""))
        case "openWeb":
            if let url = URL(string: payload["url"].string), ["https", "http"].contains(url.scheme) {
                viewModel.destination = .web(url)
            }
        default: viewModel.actionError = L10n.text("Text.ThisPluginActionIsNotSupportedYet")
        }
    }
}

@MainActor
final class PluginCloudHomeModel {
    @MainActor @Observable
    final class ViewModel {
        var tabs: [PluginHomeTab] = []
        var loading = false
        var loaded = false
        var error: String?
    }
    let viewModel = ViewModel()

    func load(plugin: PluginRecord) async {
        guard !viewModel.loading else { return }
        viewModel.loading = true
        viewModel.error = nil
        defer { viewModel.loading = false }
        do {
            let tabs = try await PluginService.shared.homeTabs(plugin: plugin, cloud: true)
            try Task.checkCancellation()
            viewModel.tabs = tabs
            viewModel.loaded = true
        } catch {
            if !Task.isCancelled { viewModel.error = error.localizedDescription }
        }
    }
}
