import BreezePlugins
import CoreStorage
import Foundation
import Observation
import SwiftData

struct DownloadItem: Identifiable, Equatable {
    let id: String
    let comicKey: String
    let title: String
    let comicTitle: String?
    let status: DownloadStatus
    let completedPages: Int
    let totalPages: Int
    let error: String?
    var chapterCount: Int = 1
    var completedChapters: Int = 0
}

struct OfflineChapter: Identifiable {
    let id: String
    let sourceID: String
    let comic: ComicSummary
    let chapter: ComicChapter
    let chapters: [ComicChapter]
    let detail: ComicDetail?
}

@MainActor @Observable
final class DownloadsViewModel {
    fileprivate(set) var items: [DownloadItem] = []
    fileprivate(set) var tags: [LocalTagSnapshot] = []
    fileprivate(set) var selectedTags: Set<UUID> = []
    fileprivate(set) var isEmpty = true
    var opened: OfflineChapter?
    var error: String?
}

@MainActor
final class DownloadsModel {
    let viewModel = DownloadsViewModel()
    private var records: [String: DownloadRecord] = [:]
    private var comics: [String: ComicRecord] = [:]
    private var manager: DownloadManager?
    private var orderedRecords: [DownloadRecord] = []

    func update(records: [DownloadRecord], comics: [ComicRecord], manager: DownloadManager) {
        self.manager = manager
        self.records = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.comics = Dictionary(comics.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        orderedRecords = records
        viewModel.isEmpty = records.isEmpty
        filter()
    }

    func updateTags(_ tags: [LocalTagSnapshot]) {
        viewModel.tags = tags
        viewModel.selectedTags.formIntersection(tags.map(\.id))
        filter()
    }

    func selectTags(_ tags: Set<UUID>) {
        viewModel.selectedTags = tags
        filter()
    }

    private func filter() {
        viewModel.items = orderedRecords.compactMap { record in
            let key = ComicRecord.identifier(sourceID: record.sourceID, comicID: record.comicID)
            guard LocalTagSnapshot.matches(comicKey: key, selected: viewModel.selectedTags, tags: viewModel.tags) else { return nil }
            return DownloadItem(id: record.id, comicKey: key, title: record.title, comicTitle: comics[key]?.title,
                status: record.status, completedPages: record.completedPageCount,
                totalPages: record.pageURLs.count, error: record.errorMessage,
                chapterCount: 1, completedChapters: record.status == .completed ? 1 : 0)
        }
    }

    private func chapters(for item: DownloadItem) -> [DownloadRecord] {
        records[item.id].map { [$0] } ?? []
    }

    func activate(_ item: DownloadItem) {
        guard let manager else { return }
        let records = chapters(for: item)
        switch item.status {
        case .queued, .downloading: records.forEach { manager.pause($0) }
        case .paused, .failed: records.forEach { manager.resume($0) }
        case .completed:
            let comic = comics[item.comicKey]
            let detail = comic?.detailJSON.flatMap { try? JSONDecoder().decode(ComicDetail.self, from: $0) }
            let chapterID = comic?.chapterID ?? detail?.chapters.first?.id
            if let record = records.first(where: { $0.chapterID == chapterID }) ?? records.first {
                open(record, manager: manager)
            }
            return
        }
        viewModel.error = manager.errorMessage
    }
    func delete(_ item: DownloadItem) {
        guard let manager else { return }
        let records = chapters(for: item)
        Task {
            do { for record in records { try await manager.delete(record) } }
            catch { viewModel.error = error.localizedDescription }
        }
    }
    private func open(_ record: DownloadRecord, manager: DownloadManager) {
        guard manager.localPageURLs(sourceID: record.sourceID, comicID: record.comicID, chapterID: record.chapterID) != nil else {
            viewModel.error = L10n.text("Message.LocalPagesAreMissingDeleteThisDownloadAndDownloadTheComicAgain")
            return
        }
        let comic = comics[ComicRecord.identifier(sourceID: record.sourceID, comicID: record.comicID)]
        let detail = comic?.detailJSON.flatMap { try? JSONDecoder().decode(ComicDetail.self, from: $0) }
        let chapter = detail?.chapters.first { $0.id == record.chapterID } ?? ComicChapter(id: record.chapterID, title: record.title)
        let summary = ComicSummary(id: record.comicID, title: comic?.title ?? record.title,
            coverURL: comic.flatMap { URL(string: $0.coverURL) }, author: comic?.author ?? "", summary: comic?.summary ?? "")
        viewModel.opened = OfflineChapter(id: record.id, sourceID: record.sourceID, comic: summary, chapter: chapter,
                                         chapters: detail?.chapters ?? [chapter], detail: detail)
    }
}
