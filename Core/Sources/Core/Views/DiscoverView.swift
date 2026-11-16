import BreezePlugins
import BreezeRuntime
import CoreStorage
import SwiftData
import SwiftUI

struct DiscoverView: View {
    @Environment(\.hiddenNSFWSources) private var hiddenSources
    @Query(filter: #Predicate<PluginRecord> { $0.enabled }, sort: \PluginRecord.name)
    private var installedPlugins: [PluginRecord]
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var selectedHomeTabID: String?
    @State private var showingPlugins = false
    @State private var destination: Destination?

    private enum Destination: Hashable {
        case favorites(PluginRecord)
        case advancedSearch(PluginRecord, String)
        case action(PluginRecord, String, JSONValue)
    }
    @State private var model = DiscoverModel()

    private var plugins: [PluginRecord] {
        installedPlugins.filter { !hiddenSources.contains($0.uuid) }
    }

    private var plugin: PluginRecord? { model.activePlugin(in: plugins) }

    var body: some View {
        let state = model.viewModel
        let request = model.request(for: plugin)
        let homeTabs = state.displayedRequest == request && state.query.isEmpty ? state.tabs : []
        let homeTab = homeTabs.first { $0.id == selectedHomeTabID } ?? homeTabs.first
        VStack(spacing: 0) {
            if let plugin, state.displayedRequest == request {
                if state.query.isEmpty && !state.loading && state.error == nil {
                    if let homeTab {
                        PluginHomePageView(plugin: plugin, tab: homeTab, embedded: true, showsHeaderActions: false)
                            .id(homeTab.id)
                    } else {
                        ContentUnavailableView(L10n.text("PluginHome.EmptyTitle"), systemImage: "safari")
                    }
                } else {
                    DiscoverResults(
                        plugin: plugin, query: state.query, sections: state.sections, results: state.results,
                        loading: state.loading, error: state.error, hasMore: state.hasMore
                    ) {
                        model.loadMoreOrRetry(plugin: plugin, request: request)
                    }
                }
            } else if plugin != nil {
                ProgressView(L10n.text("Text.Loading"))
            } else {
                ContentUnavailableView {
                    Label(L10n.text("Discover.NoSourcesTitle"), systemImage: "puzzlepiece.extension")
                } description: {
                    Text(L10n.text("Discover.NoSourcesDescription"))
                } actions: {
                    Button(L10n.text("Discover.ManagePlugins")) { showingPlugins = true }
                        .buttonStyle(.glassProminent)
                            .buttonBorderShape(.roundedRectangle(radius: 10))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .searchFocused($searchFocused)
        .searchable(text: $search, prompt: L10n.text("Discover.SearchPrompt"))
        .onSubmit(of: .search) {
            searchFocused = false
            model.submit(search)
        }
        .navigationTitle(plugin.map { L10n.text("Discover.TitleWithSource", defaultValue: "发现 · \($0.name)") } ?? L10n.text("Discover.Title"))
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: search) { _, value in
            if value.isEmpty { model.clearSearch() }
        }
        .onChange(of: plugin?.uuid) { selectedHomeTabID = nil }
        .toolbar {
            if let plugin {
                Menu {
                    Picker(L10n.text("Text.Sources"), selection: Binding(
                        get: { self.plugin?.uuid ?? "" },
                        set: model.selectPlugin
                    )) {
                        ForEach(plugins, id: \.uuid) { Text($0.name).tag($0.uuid) }
                    }
                    if plugin.supportsCloudFavorites {
                        Button(L10n.text("CloudFavorites.OpenSourceFavorites"), systemImage: "bookmark") {
                            destination = .favorites(plugin)
                        }
                    }
                    Button(L10n.text("AdvancedSearch.Title"), systemImage: "line.3.horizontal.decrease") {
                        destination = .advancedSearch(plugin, search)
                    }
                    Button(L10n.text("Discover.ManagePlugins"), systemImage: "puzzlepiece.extension") {
                        showingPlugins = true
                    }
                } label: {
                    Label(plugin.name, systemImage: "puzzlepiece.extension")
                }
                let actions = toolbarActions(plugin: plugin, homeTab: homeTab)
                let canSwitchPages = homeTabs.count > 1
                if !actions.isEmpty || canSwitchPages {
                    Menu {
                        if canSwitchPages, let homeTab {
                            Picker(L10n.text("Discover.PluginPages"), selection: Binding(
                                get: { homeTab.id },
                                set: { selectedHomeTabID = $0 }
                            )) {
                                ForEach(homeTabs) { Text($0.title).tag($0.id) }
                            }
                            .pickerStyle(.menu)
                        }
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, item in
                            Button(item.title) {
                                destination = .action(plugin, item.title, item.action)
                            }
                        }
                    } label: {
                        Label(L10n.text("Discover.PluginFunctions"), systemImage: "square.grid.2x2")
                    }
                }
            }
        }
        .navigationDestination(item: $destination) { destination in
            switch destination {
            case .favorites(let plugin):
                PluginCloudHomeView(plugin: plugin)
            case .advancedSearch(let plugin, let keyword):
                PluginAdvancedSearchView(plugin: plugin, keyword: keyword)
            case .action(let plugin, let title, let action):
                PluginActionDestinationView(plugin: plugin, title: title, action: action)
            }
        }
        .sheet(isPresented: $showingPlugins) {
            NavigationStack {
                PluginManagementView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.text("Text.Done")) { showingPlugins = false }
                        }
                    }
            }
            .modifier(AppLockShield())
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)) { _ in
            model.reloadSelection()
        }
        .task(id: request) { await model.loadInitial(plugin: plugin, request: request) }
        .refreshable { await model.loadInitial(plugin: plugin, request: request) }
    }

    private func toolbarActions(plugin: PluginRecord, homeTab: PluginHomeTab?) -> [(title: String, action: JSONValue)] {
        var actions = plugin.discoveryActions.map { (title: $0["title"].string, action: $0["action"]) }
        var seen = Set(actions.map(\.action))
        for item in homeTab?.actions ?? [] {
            let action = item["action"].isNull ? item : item["action"]
            let type = action["type"].string
            guard !type.isEmpty, type != "none" else { continue }
            if type == "openCloudFavorite", plugin.supportsCloudFavorites { continue }
            guard seen.insert(action).inserted else { continue }
            let title = item["title"].string.isEmpty ? action["payload"]["title"].string : item["title"].string
            actions.append((title.isEmpty ? L10n.text("PluginHome.PageActions") : title, action))
        }
        return actions
    }
}

private struct DiscoverResults: View {
    let plugin: PluginRecord
    let query: String
    let sections: [HomeSection]
    let results: [ComicSummary]
    let loading: Bool
    let error: String?
    let hasMore: Bool
    let load: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 192), spacing: 14)]

    var body: some View {
        if sections.allSatisfy({ $0.comics.isEmpty }) && results.isEmpty {
            if loading {
                ProgressView(L10n.text("Text.Loading"))
            } else if let error {
                RetryView(title: L10n.text("Discover.LoadFailed"), message: error, retry: load)
            } else if !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ContentUnavailableView(L10n.text("Discover.EmptyTitle"), systemImage: "books.vertical",
                                       description: Text(L10n.text("Discover.EmptyDescription")))
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if query.isEmpty {
                        ForEach(sections, id: \.id) { section in
                            if !section.comics.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    if !section.title.isEmpty {
                                        Text(section.title).font(.title2.bold())
                                    }
                                    comicGrid(section.comics)
                                }
                            }
                        }
                    } else {
                        comicGrid(results)
                        if loading {
                            ProgressView().frame(maxWidth: .infinity)
                        } else if let error {
                            RetryView(title: L10n.text("Discover.LoadMoreFailed"), message: error, retry: load)
                        } else if hasMore {
                            Button(L10n.text("Pagination.LoadMore"), action: load)
                                .buttonStyle(.glass)
                            .buttonBorderShape(.roundedRectangle(radius: 10))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func comicGrid(_ comics: [ComicSummary]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(comics, id: \.id) { comic in
                NavigationLink {
                    ComicDetailView(sourceID: plugin.uuid, summary: comic)
                } label: {
                    DiscoverComicTile(comic: comic, sourceID: plugin.uuid)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct DiscoverComicTile: View {
    @Environment(\.unreadFollowedComics) private var unreadFollowedComics
    let comic: ComicSummary
    let sourceID: String

    var body: some View {
        let comicKey = ComicRecord.identifier(sourceID: sourceID, comicID: comic.id)
        VStack(alignment: .leading, spacing: 6) {
            ComicCover(url: comic.coverURL, cachePolicy: .comicCover(id: comicKey))
                .overlay(alignment: .topTrailing) {
                    if unreadFollowedComics.contains(comicKey) {
                        UnreadComicUpdateDot().padding(6)
                    }
                }
            Text(comic.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
