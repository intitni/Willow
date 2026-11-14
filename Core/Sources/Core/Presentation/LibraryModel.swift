import BreezePlugins
import CoreStorage
import Foundation
import Observation
import SwiftData

struct LibraryItem: Identifiable, Equatable {
    let id: String
    let sourceID: String
    let comic: ComicSummary
    let collectionName: String
    let lastReadAt: Date?

    init(_ record: ComicRecord) {
        id = record.id
        sourceID = record.sourceID
        comic = ComicSummary(id: record.comicID, title: record.title, coverURL: URL(string: record.coverURL),
                             author: record.author, summary: record.summary)
        collectionName = record.collectionName
        lastReadAt = record.lastReadAt
    }
}

enum LibrarySort: String, CaseIterable {
    case recentlyRead, oldestRead, title
}

@MainActor @Observable
final class LibraryViewModel {
    fileprivate(set) var items: [LibraryItem] = []
    fileprivate(set) var collections: [String] = []
    fileprivate(set) var isEmpty = true
    fileprivate(set) var search = ""
    fileprivate(set) var collection: String?
    fileprivate(set) var sort: LibrarySort = .recentlyRead
    fileprivate(set) var hasMore = false
    fileprivate(set) var tags: [LocalTagSnapshot] = []
    fileprivate(set) var selectedTags: Set<UUID> = []
    var error: String?
}

@MainActor
final class LibraryModel {
    let viewModel = LibraryViewModel()
    private var allItems: [LibraryItem] = []
    private var context: ModelContext?
    private let paginated: Bool
    private var visibleCount = 40
    private var filteredItems: [LibraryItem] = []

    init(paginated: Bool = false, sort: LibrarySort = .title) {
        self.paginated = paginated
        viewModel.sort = sort
    }

    func selectSort(_ value: LibrarySort) {
        viewModel.sort = value
        visibleCount = 40
        filter()
    }

    func loadMore() {
        guard viewModel.hasMore else { return }
        visibleCount += 40
        publish()
    }

    func update(context: ModelContext, items: [LibraryItem]) {
        self.context = context
        var seen: Set<String> = []
        allItems = items.filter { seen.insert($0.id).inserted }
        viewModel.isEmpty = allItems.isEmpty
        viewModel.collections = Set(allItems.map(\.collectionName).filter { !$0.isEmpty }).sorted()
        if let current = viewModel.collection, !viewModel.collections.contains(current) { viewModel.collection = nil }
        filter()
    }

    func search(_ value: String) { viewModel.search = value; visibleCount = 40; filter() }
    func selectCollection(_ value: String?) { viewModel.collection = value; visibleCount = 40; filter() }

    func updateTags(_ tags: [LocalTagSnapshot]) {
        viewModel.tags = tags
        viewModel.selectedTags.formIntersection(tags.map(\.id))
        filter()
    }

    func selectTags(_ tags: Set<UUID>) {
        viewModel.selectedTags = tags
        visibleCount = 40
        filter()
    }

    func move(_ item: LibraryItem, to name: String) {
        mutate(item) { $0.collectionName = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    func remove(_ item: LibraryItem, fromFavorites: Bool) {
        mutate(item) { record in
            if fromFavorites { record.isFavorite = false }
            else { record.lastReadAt = nil; record.chapterID = nil; record.pageIndex = 0 }
        }
    }
    private func mutate(_ item: LibraryItem, change: (ComicRecord) -> Void) {
        guard let context else { return }
        do {
            let id = item.id
            let records = try context.fetch(FetchDescriptor<ComicRecord>(predicate: #Predicate { $0.id == id }))
            for record in records { change(record) }
            try context.save()
        } catch { context.rollback(); viewModel.error = error.localizedDescription }
    }
    private func filter() {
        let collection = viewModel.collection
        let search = viewModel.search
        filteredItems = allItems.filter {
            (collection == nil || $0.collectionName == collection) && (search.isEmpty || $0.comic.title.localizedStandardContains(search))
                && LocalTagSnapshot.matches(comicKey: $0.id, selected: viewModel.selectedTags, tags: viewModel.tags)
        }
        filteredItems.sort { lhs, rhs in
            switch viewModel.sort {
            case .recentlyRead, .oldestRead:
                let left = lhs.lastReadAt ?? .distantPast
                let right = rhs.lastReadAt ?? .distantPast
                if left != right { return viewModel.sort == .recentlyRead ? left > right : left < right }
            case .title:
                let order = lhs.comic.title.localizedStandardCompare(rhs.comic.title)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return lhs.id < rhs.id
        }
        publish()
    }

    private func publish() {
        viewModel.items = paginated ? Array(filteredItems.prefix(visibleCount)) : filteredItems
        viewModel.hasMore = viewModel.items.count < filteredItems.count
    }
}
