import BreezePlugins
import CoreStorage
import SwiftData
import SwiftUI

struct LibraryView: View {
    enum Kind {
        case favorites
        case history

        var title: String {
            self == .favorites ? L10n.text("Shelf.Title") : L10n.text("History.Title")
        }
    }

    @Environment(\.modelContext) private var context
    @Query private var comics: [ComicRecord]
    @Query(sort: \LocalTagRecord.name) private var localTags: [LocalTagRecord]
    @State private var editingTags: LibraryItem?
    @State private var model: LibraryModel
    @State private var movingComic: LibraryItem?
    @State private var collectionName = ""
    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
        _model = State(initialValue: LibraryModel(paginated: kind == .history, sort: kind == .history ? .recentlyRead : .title))
        switch kind {
        case .favorites:
            _comics = Query(filter: #Predicate<ComicRecord> { $0.isFavorite }, sort: \ComicRecord.title)
        case .history:
            _comics = Query(filter: #Predicate<ComicRecord> { $0.lastReadAt != nil },
                            sort: \ComicRecord.lastReadAt, order: .reverse)
        }
    }

    var body: some View {
        @Bindable var viewModel = model.viewModel
        VStack(spacing: 0) {
            if viewModel.isEmpty {
                if kind == .favorites {
                    ContentUnavailableView(L10n.text("Shelf.EmptyTitle"), systemImage: "books.vertical",
                                           description: Text(L10n.text("Shelf.EmptyDescription")))
                } else {
                    ContentUnavailableView(L10n.text("History.EmptyTitle"), systemImage: "clock",
                                           description: Text(L10n.text("History.EmptyDescription")))
                }
            } else if viewModel.items.isEmpty {
                ContentUnavailableView(L10n.text("Library.NoMatchesTitle"), systemImage: "line.3.horizontal.decrease",
                                       description: Text(L10n.text("Library.NoMatchesDescription")))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 192), spacing: 14)], spacing: 18) {
                        ForEach(viewModel.items) { comic in
                            LibraryGridTile(comic: comic, isHistory: kind == .history,
                                editTags: { editingTags = comic },
                                move: {
                                    collectionName = comic.collectionName
                                    movingComic = comic
                                },
                                remove: { model.remove(comic, fromFavorites: kind == .favorites) })
                        }
                    }
                    .padding()
                    .frame(maxWidth: 1080)
                    .frame(maxWidth: .infinity)
                    if viewModel.hasMore {
                        PaginationTrigger(itemCount: viewModel.items.count, load: model.loadMore)
                    }
                }
                .id(viewModel.sort)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: Binding(get: { viewModel.search }, set: model.search), prompt: L10n.text("Library.SearchPrompt"))
        .navigationTitle(kind.title)
        .toolbar {
            if kind == .favorites && !viewModel.tags.isEmpty {
                LocalTagFilterMenu(tags: viewModel.tags, selected: viewModel.selectedTags, select: model.selectTags)
            }
            if kind == .history {
                Menu(L10n.text("History.Sort"), systemImage: "arrow.up.arrow.down") {
                    Picker(L10n.text("History.Sort"), selection: Binding(get: { viewModel.sort }, set: model.selectSort)) {
                        Text(L10n.text("History.SortRecentlyRead")).tag(LibrarySort.recentlyRead)
                        Text(L10n.text("History.SortOldestRead")).tag(LibrarySort.oldestRead)
                        Text(L10n.text("History.SortTitle")).tag(LibrarySort.title)
                    }
                }
            }
            if kind == .favorites && !viewModel.collections.isEmpty {
                Menu(L10n.text("Shelf.Collections"), systemImage: "folder") {
                    Picker(L10n.text("Shelf.Collections"), selection: Binding(get: { viewModel.collection }, set: model.selectCollection)) {
                        Text(L10n.text("Shelf.AllCollections")).tag(nil as String?)
                        ForEach(viewModel.collections, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                }
            }
        }
        .sheet(item: $editingTags) { comic in LocalTagEditor(comicKey: comic.id).modifier(AppLockShield()) }
        .onChange(of: localTags.map(LocalTagSnapshot.init), initial: true) { _, tags in model.updateTags(tags) }
        .onChange(of: comics.map(LibraryItem.init), initial: true) { _, items in
            model.update(context: context, items: items)
        }
        .alert(L10n.text("Shelf.MoveToCollection"), isPresented: Binding(
            get: { movingComic != nil },
            set: { if !$0 { movingComic = nil } }
        ), presenting: movingComic) { comic in
            TextField(L10n.text("Shelf.CollectionName"), text: $collectionName)
            Button(L10n.text("Shelf.MoveComic")) {
                model.move(comic, to: collectionName)
            }
            Button(L10n.text("Text.Cancel"), role: .cancel) {}
        } message: { _ in
            Text(L10n.text("Shelf.MoveToCollectionDescription"))
        }
        .modifier(ErrorAlert(error: $viewModel.error))
    }

}

private struct LibraryGridTile: View {
    let comic: LibraryItem
    let isHistory: Bool
    let editTags: () -> Void
    let move: () -> Void
    let remove: () -> Void

    var body: some View {
        NavigationLink {
            ComicDetailView(sourceID: comic.sourceID, summary: comic.comic)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                DiscoverComicTile(comic: comic.comic)
                if isHistory, let date = comic.lastReadAt {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                } else if !isHistory, !comic.collectionName.isEmpty {
                    Label(comic.collectionName, systemImage: "folder")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isHistory {
                Button(L10n.text("LocalTags.Edit"), systemImage: "tag", action: editTags)
                Button(L10n.text("Shelf.MoveToCollection"), systemImage: "folder", action: move)
            }
            Button(role: .destructive, action: remove) {
                Label(isHistory ? L10n.text("History.RemoveComic") : L10n.text("Shelf.RemoveBookmark"), systemImage: "trash")
            }
        }
    }
}
