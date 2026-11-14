import BreezePlugins
import CoreStorage
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ReaderViewModel {
    let chapters: [ComicChapter]
    fileprivate(set) var chapter: ComicChapter
    fileprivate(set) var pages: [URL] = []
    fileprivate(set) var pageIndex = 0
    fileprivate(set) var loadError: String?
    var saveError: String?
    fileprivate var loadedChapterID: String?
    fileprivate var refreshID = 0

    init(chapters: [ComicChapter], initialChapter: ComicChapter) {
        self.chapters = chapters
        chapter = initialChapter
    }

    var isLoaded: Bool { loadedChapterID == chapter.id }
    var previous: ComicChapter? { adjacentChapter(offset: -1) }
    var next: ComicChapter? { adjacentChapter(offset: 1) }

    private func adjacentChapter(offset: Int) -> ComicChapter? {
        guard let index = chapters.firstIndex(where: { $0.id == chapter.id }),
              chapters.indices.contains(index + offset) else { return nil }
        return chapters[index + offset]
    }
}

@MainActor
final class ReaderModel {
    struct Request: Hashable {
        let chapterID: String
        let refreshID: Int
    }

    let viewModel: ReaderViewModel
    private let sourceID: String
    private let comicID: String
    private let comic: ComicSummary
    private let detail: ComicDetail?
    private var record: ComicRecord?

    init(sourceID: String, comicID: String, comic: ComicSummary, chapters: [ComicChapter],
         initialChapter: ComicChapter, detail: ComicDetail?) {
        self.sourceID = sourceID
        self.comicID = comicID
        self.comic = comic
        self.detail = detail
        viewModel = ReaderViewModel(chapters: chapters, initialChapter: initialChapter)
    }

    var request: Request {
        Request(chapterID: viewModel.chapter.id, refreshID: viewModel.refreshID)
    }

    func retry() {
        viewModel.refreshID += 1
    }

    func selectChapter(_ chapter: ComicChapter) {
        guard chapter.id != viewModel.chapter.id else { return }
        viewModel.refreshID += 1
        viewModel.chapter = chapter
        viewModel.loadError = nil
    }

    func selectPage(_ index: Int, request: Request, context: ModelContext) {
        guard self.request == request, viewModel.isLoaded, viewModel.pages.indices.contains(index),
              viewModel.pageIndex != index else { return }
        viewModel.pageIndex = index
        saveProgress(context: context)
    }

    func loadChapter(request: Request, plugins: [PluginRecord], context: ModelContext,
                     downloads: DownloadManager) async {
        guard self.request == request else { return }
        let chapterID = request.chapterID
        viewModel.loadedChapterID = nil
        viewModel.pages = []
        viewModel.loadError = nil
        do {
            let urls: [URL]
            if let local = downloads.localPageURLs(sourceID: sourceID, comicID: comicID, chapterID: chapterID) {
                urls = local
            } else if let plugin = plugins.first(where: \.enabled) {
                urls = try await PluginService.shared.pages(plugin: plugin, comicID: comicID, chapterID: chapterID)
            } else {
                viewModel.loadError = L10n.text("Reader.SourceAndDownloadUnavailable")
                return
            }
            guard !Task.isCancelled, self.request == request else { return }
            guard !urls.isEmpty else {
                viewModel.loadError = L10n.text("Reader.NoPages")
                return
            }
            let record = try ComicRecord.findOrCreate(in: context, sourceID: sourceID, comicID: comicID,
                                                       title: comic.title, coverURL: comic.coverURL?.absoluteString ?? "",
                                                       author: comic.author, summary: comic.summary)
            if let detail { record.detailJSON = try? JSONEncoder().encode(detail) }
            self.record = record
            viewModel.pageIndex = record.chapterID == chapterID ? min(max(0, record.pageIndex), urls.count - 1) : 0
            viewModel.pages = urls
            viewModel.loadedChapterID = chapterID
            saveProgress(context: context)
        } catch {
            if !Task.isCancelled, self.request == request { viewModel.loadError = error.localizedDescription }
        }
    }

    private func saveProgress(context: ModelContext) {
        guard viewModel.isLoaded, let record else { return }
        record.chapterID = viewModel.chapter.id
        record.pageIndex = viewModel.pageIndex
        record.lastReadAt = .now
        record.historyClearedAt = nil
        do { try context.save() }
        catch { viewModel.saveError = error.localizedDescription }
    }
}
