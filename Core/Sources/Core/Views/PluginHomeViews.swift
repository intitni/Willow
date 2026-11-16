import BreezePlugins
import BreezeRuntime
import CoreStorage
import SwiftUI

private struct PluginCloudPagesView: View {
    let plugin: PluginRecord
    let tabs: [PluginHomeTab]
    @State private var selection: String?

    var body: some View {
        let selected = tabs.first { $0.id == selection } ?? tabs.first
        VStack(spacing: 0) {
            if !tabs.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(tabs) { tab in
                            Button(tab.title) { selection = tab.id }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.roundedRectangle(radius: 10))
                                .tint(selected?.id == tab.id ? WillowTheme.accent : .secondary)
                                .accessibilityAddTraits(selected?.id == tab.id ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let tab = selected {
                PluginHomePageView(plugin: plugin, tab: tab, embedded: true)
                    .id(tab.id)
            } else {
                ContentUnavailableView(L10n.text("PluginHome.EmptyTitle"), systemImage: "safari")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: tabs.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }
}

struct PluginHomePageView: View {
    @State private var model: PluginHomeModel
    @State private var showingFilters = false
    @Environment(\.openURL) private var openURL
    let embedded: Bool
    private let showsHeaderActions: Bool

    init(plugin: PluginRecord, tab: PluginHomeTab, embedded: Bool = false, showsHeaderActions: Bool = true) {
        _model = State(initialValue: PluginHomeModel(plugin: plugin, tab: tab))
        self.embedded = embedded
        self.showsHeaderActions = showsHeaderActions
    }

    var body: some View {
        @Bindable var state = model.viewModel
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if showsHeaderActions {
                    ForEach(model.tab.actions.indices, id: \.self) { index in
                        let item = model.tab.actions[index]
                        Button(item["title"].string.isEmpty ? L10n.text("PluginHome.PageActions") : item["title"].string) { model.route(item) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.roundedRectangle(radius: 10))
                    }
                }
                ForEach(state.blocks) { block in
                    PluginHomeBlockView(block: block, pluginID: model.plugin.uuid, action: model.route)
                }
                if !state.comics.isEmpty {
                    HomeComicGrid(comics: state.comics, pluginID: model.plugin.uuid)
                }
                if state.loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let error = state.error {
                    RetryView(title: L10n.text("PluginHome.LoadFailed"), message: error) { Task { await model.load() } }
                } else if state.hasMore {
                    PaginationTrigger(itemCount: state.comics.count) { Task { await model.loadMore() } }
                } else if state.loaded && state.comics.isEmpty && state.blocks.isEmpty {
                    ContentUnavailableView(L10n.text("PluginHome.NoContent"), systemImage: "books.vertical")
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .modifier(PluginPageTitle(title: embedded ? nil : model.tab.title))
        .toolbar {
            if !state.fields.isEmpty {
                Button(L10n.text("Text.SortAndFilter"), systemImage: "arrow.up.arrow.down") { showingFilters = true }
                    .disabled(state.loading)
            }
        }
        .sheet(isPresented: $showingFilters) {
            FavoriteFiltersSheet(fields: state.fields, values: state.values) { values in
                showingFilters = false
                Task { await model.filter(values) }
            }
            .modifier(AppLockShield())
        }
        .navigationDestination(item: $state.destination) { destination in
            switch destination {
            case .page(let tab): PluginHomePageView(plugin: model.plugin, tab: tab)
            case .comic(let comic): ComicDetailView(sourceID: model.plugin.uuid, summary: comic)
            case .favorites: PluginCloudHomeView(plugin: model.plugin)
            case .web(let url):
                Link(L10n.text("PluginHome.OpenWebpage"), destination: url)
                    .onAppear { openURL(url) }
            }
        }
        .modifier(ErrorAlert(error: $state.actionError))
        .task { if !state.loaded { await model.load() } }
        .refreshable { await model.load(reset: true) }
    }
}

private struct PluginHomeBlockView: View {
    let block: PluginHomeBlock
    let pluginID: String
    let action: (JSONValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !block.title.isEmpty {
                HStack {
                    Text(block.title).font(.title3.bold())
                    Spacer()
                    if !block.action["type"].string.isEmpty && block.action["type"].string != "none" {
                        Button(L10n.text("Text.More")) { action(block.action) }
                    }
                }
            }
            if block.kind == "comic-grid" {
                HomeComicGrid(comics: block.comics, pluginID: pluginID)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: block.kind == "chip-list" ? 100 : 120), spacing: 12)], spacing: 12) {
                    ForEach(block.links) { link in
                        Button { action(link.action) } label: {
                            VStack(spacing: 8) {
                                if block.kind == "action-grid", let cover = link.coverURL {
                                    ComicCover(url: cover, cachePolicy: link.comicID.map {
                                        .comicCover(id: ComicRecord.identifier(sourceID: pluginID, comicID: $0))
                                    } ?? .byURL)
                                }
                                Text(link.title).frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 10))
                        .modifier(DiscoverCartContextMenu(comic: cartComic(for: link), sourceID: pluginID))
                    }
                }
            }
        }
    }

    private func cartComic(for link: PluginHomeLink) -> ComicSummary? {
        let action = link.action["action"].isNull ? link.action : link.action["action"]
        let id = action["payload"]["comicId"].string
        guard action["type"].string == "openComicInfo", !id.isEmpty else { return nil }
        return ComicSummary(id: id, title: link.title, coverURL: link.coverURL, author: "", summary: "")
    }
}

private struct HomeComicGrid: View {
    let comics: [ComicSummary]
    let pluginID: String
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 192), spacing: 14)], spacing: 18) {
            ForEach(comics) { comic in
                NavigationLink { ComicDetailView(sourceID: pluginID, summary: comic) } label: {
                    DiscoverComicTile(comic: comic, sourceID: pluginID)
                }
                .buttonStyle(.plain)
                .modifier(DiscoverCartContextMenu(comic: comic, sourceID: pluginID))
            }
        }
    }
}

struct PluginCloudHomeView: View {
    let plugin: PluginRecord
    @State private var model = PluginCloudHomeModel()

    var body: some View {
        let state = model.viewModel
        VStack {
            if state.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = state.error {
                RetryView(title: L10n.text("CloudFavorites.LoadFailed"), message: error) { Task { await model.load(plugin: plugin) } }
            } else if state.loaded {
                PluginCloudPagesView(plugin: plugin, tabs: state.tabs)
            }
        }
        .navigationTitle(L10n.text("CloudFavorites.TitleWithSource", defaultValue: "云端收藏 · \(plugin.name)"))
        .task { if !state.loaded { await model.load(plugin: plugin) } }
    }
}

struct PluginActionLink: View {
    let plugin: PluginRecord
    let title: String
    let action: JSONValue

    var body: some View {
        NavigationLink {
            PluginActionDestinationView(plugin: plugin, title: title, action: action)
        } label: { Text(title) }
    }
}

struct PluginActionDestinationView: View {
    let plugin: PluginRecord
    @State private var router: PluginHomeModel
    @Environment(\.openURL) private var openURL

    init(plugin: PluginRecord, title: String, action: JSONValue) {
        self.plugin = plugin
        let router = PluginHomeModel(plugin: plugin, tab: PluginHomeTab(id: "action", title: title))
        router.route(action)
        _router = State(initialValue: router)
    }

    var body: some View {
        switch router.viewModel.destination {
        case .page(let tab): PluginHomePageView(plugin: plugin, tab: tab)
        case .comic(let comic): ComicDetailView(sourceID: plugin.uuid, summary: comic)
        case .favorites: PluginCloudHomeView(plugin: plugin)
        case .web(let url): Link(L10n.text("PluginHome.OpenWebpage"), destination: url).onAppear { openURL(url) }
        case nil:
            ContentUnavailableView(L10n.text("PluginHome.OpenPageFailed"), systemImage: "exclamationmark.circle",
                description: Text(router.viewModel.actionError ?? L10n.text("PluginHome.ActionUnavailable")))
        }
    }
}

private struct PluginPageTitle: ViewModifier {
    let title: String?
    func body(content: Content) -> some View {
        if let title { content.navigationTitle(title) }
        else { content }
    }
}
