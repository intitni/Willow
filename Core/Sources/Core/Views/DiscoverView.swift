import BreezePlugins
import BreezeRuntime
import CoreStorage
import SwiftData
import SwiftUI

struct DiscoverView: View {
    @Query(filter: #Predicate<PluginRecord> { $0.enabled }, sort: \PluginRecord.name)
    private var plugins: [PluginRecord]
    @State private var search = ""
    @State private var showingPlugins = false
    @State private var destination: Destination?

    private enum Destination: Hashable {
        case favorites(PluginRecord)
        case advancedSearch(PluginRecord, String)
        case action(PluginRecord, String, JSONValue)
    }
    @State private var model = DiscoverModel()

    private var plugin: PluginRecord? { model.activePlugin(in: plugins) }

    var body: some View {
        let state = model.viewModel
        let request = model.request(for: plugin)
        VStack(spacing: 0) {
            if let plugin, state.displayedRequest == request {
                if state.query.isEmpty && !state.loading && state.error == nil {
                    PluginHomePagesView(plugin: plugin, tabs: state.tabs)
                        .id(plugin.uuid)
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
                    Label(L10n.text("Text.NoAvailableSources"), systemImage: "puzzlepiece.extension")
                } description: {
                    Text(L10n.text("Text.InstallAndEnableAPluginToBrowseAndSearchForComics"))
                } actions: {
                    Button(L10n.text("Text.ManagePlugins")) { showingPlugins = true }
                        .buttonStyle(.glassProminent)
                            .buttonBorderShape(.roundedRectangle(radius: 10))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(plugin.map { L10n.text("NavigationTitle.Discover", defaultValue: "发现 · \($0.name)") } ?? L10n.text("Text.Discover"))
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.text("Text.SearchComics"))
        .onSubmit(of: .search) { model.submit(search) }
        .onChange(of: search) { _, value in
            if value.isEmpty { model.clearSearch() }
        }
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
                        Button(L10n.text("Text.SourceFavoritesAlternative"), systemImage: "bookmark") {
                            destination = .favorites(plugin)
                        }
                    }
                    Button(L10n.text("Text.AdvancedSearch"), systemImage: "line.3.horizontal.decrease") {
                        destination = .advancedSearch(plugin, search)
                    }
                    Button(L10n.text("Text.ManagePlugins"), systemImage: "puzzlepiece.extension") {
                        showingPlugins = true
                    }
                } label: {
                    Label(plugin.name, systemImage: "puzzlepiece.extension")
                }
                if !plugin.discoveryActions.isEmpty {
                    Menu {
                        ForEach(Array(plugin.discoveryActions.enumerated()), id: \.offset) { _, item in
                            Button(item["title"].string) {
                                destination = .action(plugin, item["title"].string, item["action"])
                            }
                        }
                    } label: {
                        Label(L10n.text("ButtonTitle.PluginFunctions"), systemImage: "square.grid.2x2")
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
                RetryView(title: L10n.text("Text.CouldnTLoadComics"), message: error, retry: load)
            } else if !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ContentUnavailableView(L10n.text("Text.NoComicsToDisplay"), systemImage: "books.vertical",
                                       description: Text(L10n.text("Text.SearchThisSourceToFindComics")))
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
                            RetryView(title: L10n.text("Text.CouldnTLoadMoreResults"), message: error, retry: load)
                        } else if hasMore {
                            Button(L10n.text("ButtonTitle.LoadMore"), action: load)
                                .buttonStyle(.glass)
                            .buttonBorderShape(.roundedRectangle(radius: 10))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 1080)
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
                    DiscoverComicTile(comic: comic)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct DiscoverComicTile: View {
    let comic: ComicSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ComicCover(url: comic.coverURL)
            Text(comic.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
