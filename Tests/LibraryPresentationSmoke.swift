import CoreStorage
import Foundation
import SwiftData

@main
struct LibraryPresentationSmoke {
    @MainActor
    static func main() throws {
        let storage = try WillowPersistence.make(inMemory: true)
        let items = (0..<95).map { index in
            let record = ComicRecord(sourceID: "test", comicID: String(index), title: String(format: "Comic %03d", index))
            record.lastReadAt = Date(timeIntervalSince1970: Double(index))
            return LibraryItem(record)
        }
        let model = LibraryModel(paginated: true, sort: .recentlyRead)
        model.update(context: storage.container.mainContext, items: items)
        precondition(model.viewModel.items.count == 40 && model.viewModel.items.first?.comic.id == "94")
        model.loadMore()
        precondition(model.viewModel.items.count == 80)
        model.loadMore()
        precondition(model.viewModel.items.count == 95 && !model.viewModel.hasMore)
        model.loadMore()
        precondition(model.viewModel.items.count == 95)
        model.selectSort(.oldestRead)
        precondition(model.viewModel.items.count == 40 && model.viewModel.items.first?.comic.id == "0")
        model.search("Comic 094")
        precondition(model.viewModel.items.count == 1 && !model.viewModel.hasMore)
        model.search("")
        precondition(model.viewModel.items.count == 40 && model.viewModel.hasMore)
        model.selectSort(.title)
        precondition(model.viewModel.items.first?.comic.title == "Comic 000")
        model.loadMore()
        model.update(context: storage.container.mainContext, items: Array(items.dropFirst(90)))
        precondition(model.viewModel.items.count == 5 && !model.viewModel.hasMore)
        let firstTag = try LocalTagStore.create("First", comicKey: items[90].id, context: storage.container.mainContext)
        let secondTag = try LocalTagStore.create("Second", comicKey: items[94].id, context: storage.container.mainContext)
        model.updateTags([LocalTagSnapshot(firstTag), LocalTagSnapshot(secondTag)])
        model.selectTags([firstTag.id])
        precondition(model.viewModel.items.map(\.id) == [items[90].id])
        model.selectTags([firstTag.id, secondTag.id])
        precondition(model.viewModel.items.count == 2)
        model.search("094")
        precondition(model.viewModel.items.map(\.id) == [items[94].id])
        model.search("")
        model.selectTags([])
        precondition(model.viewModel.items.count == 5)
        let downloadDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: downloadDirectory) }
        let manager = DownloadManager(context: storage.container.mainContext, directory: downloadDirectory)
        let downloads = DownloadsModel()
        let chapterA = DownloadRecord(sourceID: "test", comicID: "90", chapterID: "a", title: "A", pageURLs: [])
        let chapterB = DownloadRecord(sourceID: "test", comicID: "90", chapterID: "b", title: "B", pageURLs: [])
        let otherSource = DownloadRecord(sourceID: "other", comicID: "90", chapterID: "a", title: "Other", pageURLs: [])
        downloads.update(records: [chapterA, chapterB, otherSource], comics: [], manager: manager)
        downloads.updateTags([LocalTagSnapshot(firstTag), LocalTagSnapshot(secondTag)])
        downloads.selectTags([firstTag.id])
        precondition(downloads.viewModel.items.map(\.id) == [chapterA.id, chapterB.id])
        downloads.selectTags([secondTag.id])
        precondition(downloads.viewModel.items.isEmpty && !downloads.viewModel.isEmpty)
        downloads.selectTags([])
        precondition(downloads.viewModel.items.count == 3)
        chapterA.status = .queued
        chapterB.status = .queued
        downloads.update(records: [chapterA, chapterB, otherSource], comics: [], manager: manager)
        downloads.activate(downloads.viewModel.items[0])
        precondition(chapterA.status == .paused && chapterB.status == .queued,
                     "Pausing one chapter must not pause the rest of the comic")
        print("PASS: chapter downloads share comic tags, cross-source filtering and filtered empty state")
        print("PASS: local tag filtering, multi-selection union, search intersection and clearing filters")
        print("PASS: history pagination, stable sorting, search reset, exhausted pages and live deletions")
    }
}
