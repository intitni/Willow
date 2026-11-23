import BreezePlugins
import CoreStorage
import Observation

struct DiscoverCartItem: Identifiable, Hashable {
    let sourceID: String
    let comic: ComicSummary

    var id: String { ComicRecord.identifier(sourceID: sourceID, comicID: comic.id) }
}

@MainActor
@Observable
final class DiscoverCartModel {
    private(set) var items: [DiscoverCartItem] = []

    func contains(_ item: DiscoverCartItem) -> Bool {
        items.contains { $0.id == item.id }
    }

    func add(_ item: DiscoverCartItem) {
        guard !contains(item) else { return }
        items.append(item)
    }

    func remove(_ item: DiscoverCartItem) {
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        items.removeAll()
    }
}
