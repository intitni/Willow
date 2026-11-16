import CoreToast
import BreezePlugins
import BreezeRuntime
import CoreStorage
import Foundation
import Observation
import SwiftData

struct ChapterDownloadPresentation: Equatable {
    let status: DownloadStatus
    let completedPages: Int
    let totalPages: Int

    init(_ record: DownloadRecord) {
        status = record.status
        completedPages = record.completedPageCount
        totalPages = record.pageURLs.count
    }

    var title: String {
        switch status {
        case .queued: L10n.text("DownloadStatus.Queued")
        case .downloading: L10n.text("DownloadStatus.InProgress")
        case .paused: L10n.text("DownloadStatus.Paused")
        case .completed: L10n.text("DownloadStatus.Completed")
        case .failed: L10n.text("DownloadStatus.Failed")
        }
    }

    var progress: String {
        L10n.text("Text.PageProgress", defaultValue: "\(completedPages) / \(totalPages)")
    }
}

@MainActor
@Observable
final class ComicDetailViewModel {
    fileprivate(set) var detail: ComicDetail?
    fileprivate(set) var loadError: String?
    var actionError: String?
    fileprivate(set) var refreshID = 0
    fileprivate(set) var coverRefreshID = 0
    fileprivate(set) var pendingDownloads = Set<String>()
    fileprivate(set) var preparingDownload = false
    fileprivate(set) var favorite = false
    fileprivate(set) var changingFollow = false
    var showsNotificationSettings = false
    fileprivate(set) var activeChapterID: String?
    fileprivate(set) var downloadStatuses: [String: DownloadStatus] = [:]
    fileprivate(set) var chapterDownloads: [String: ChapterDownloadPresentation] = [:]
    fileprivate(set) var pluginAvailable = false
    fileprivate var showsReversed = false

    let summary: ComicSummary

    init(summary: ComicSummary) {
        self.summary = summary
    }

    var comic: ComicSummary {
        guard var comic = detail?.comic else { return summary }
        comic.coverURL = comic.coverURL ?? summary.coverURL
        if comic.title.isEmpty { comic.title = summary.title }
        if comic.author.isEmpty { comic.author = summary.author }
        if comic.summary.isEmpty { comic.summary = summary.summary }
        return comic
    }
    var metadata: [ComicMetadata] {
        var groups = detail?.metadata ?? []
        if !comic.author.isEmpty && !groups.contains(where: { ["author", "authors", "artist"].contains($0.id) }) {
            groups.insert(ComicMetadata(id: "author", title: L10n.text("Text.Author"), values: [comic.author]), at: 0)
        }
        groups = groups.flatMap { group -> [ComicMetadata] in
            guard group.title == "其他信息" || group.id == "titleMeta" || group.id.hasPrefix("titleMeta_") else { return [group] }
            return group.values.enumerated().flatMap { index, value -> [ComicMetadata] in
                value.split(whereSeparator: \.isNewline).enumerated().map { lineIndex, line in
                    let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    let parts = text.split(maxSplits: 1, whereSeparator: { $0 == "：" || $0 == ":" })
                    let alreadyLabeled = !group.title.isEmpty && group.title != "其他信息"
                    let label = alreadyLabeled ? group.title : (parts.count == 2 ? String(parts[0]) : "")
                    let content = !alreadyLabeled && parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : text
                    let action = group.actions?[value]
                    return ComicMetadata(id: "\(group.id)_\(index)_\(lineIndex)", title: label, values: [content],
                        actions: action.map { [content: $0] })
                }
            }
        }
        return groups.map { group in
            var actions = group.actions ?? [:]
            let searchable = ["author", "authors", "artist", "tags", "tag", "translator", "translation", "team", "group", "categories"].contains(group.id.lowercased())
                || ["作者", "标签", L10n.text("Text.Author"), L10n.text("Text.Tags"), "漢化組", "汉化组", "分類", "分类"].contains(group.title)
            if searchable {
                for value in group.values where actions[value] == nil || actions[value]?["type"].string == "none" {
                    actions[value] = .object(["type": .string("openSearch"), "payload": .object(["keyword": .string(value)])])
                }
            }
            return ComicMetadata(id: group.id, title: group.title, values: group.values, actions: actions)
        }
    }
    var allowsDownload: Bool { pluginAvailable && detail?.sourceActions?.allowDownload != false }
    var chapters: [ComicChapter] { detail?.chapters ?? [] }
    var displayedChapters: [ComicChapter] { showsReversed ? Array(chapters.reversed()) : chapters }
    var startingChapter: ComicChapter? { chapters.first { $0.id == activeChapterID } ?? chapters.first }
}

@MainActor
final class ComicDetailModel {
    struct Inputs: Equatable {
        let record: ComicRecord?
        let plugin: PluginRecord?
        let favorite: Bool
        let chapterID: String?
        let cachedDetail: Data?
        let statuses: [String: DownloadStatus]
        let chapterDownloads: [String: ChapterDownloadPresentation]
        let readChapterIDs: Set<String>

        init(records: [ComicRecord], plugins: [PluginRecord], downloads: [DownloadRecord], readChapters: [ReadChapterRecord]) {
            record = records.first
            plugin = plugins.first(where: \.enabled)
            favorite = record?.isFavorite == true
            chapterID = record?.chapterID
            cachedDetail = record?.detailJSON
            statuses = downloads.reduce(into: [:]) { $0[$1.chapterID] = $1.status }
            chapterDownloads = downloads.reduce(into: [:]) { $0[$1.chapterID] = ChapterDownloadPresentation($1) }
            readChapterIDs = Set(readChapters.map(\.chapterID))
        }
    }

    struct Request: Hashable {
        let pluginID: String?
        let pluginVersion: String?
        let refreshID: Int
    }

    let sourceID: String
    let viewModel: ComicDetailViewModel
    private var operation = UUID()
    private var loadedChapterIDs: [String]?
    private var comicKey: String { ComicRecord.identifier(sourceID: sourceID, comicID: viewModel.summary.id) }

    init(sourceID: String, summary: ComicSummary) {
        self.sourceID = sourceID
        viewModel = ComicDetailViewModel(summary: summary)
    }

    static func summary(for record: ComicRecord) -> ComicSummary {
        ComicSummary(id: record.comicID, title: record.title, coverURL: URL(string: record.coverURL),
                     author: record.author, summary: record.summary)
    }

    func request(for inputs: Inputs) -> Request {
        Request(pluginID: inputs.plugin?.uuid, pluginVersion: inputs.plugin?.version, refreshID: viewModel.refreshID)
    }

    func updatePresentation(_ inputs: Inputs) {
        viewModel.favorite = inputs.favorite
        viewModel.activeChapterID = inputs.chapterID
        viewModel.downloadStatuses = inputs.statuses
        viewModel.chapterDownloads = inputs.chapterDownloads
        viewModel.pluginAvailable = inputs.plugin != nil
        if viewModel.detail == nil, let data = inputs.cachedDetail {
            viewModel.detail = try? JSONDecoder().decode(ComicDetail.self, from: data)
        }
    }

    func retry() {
        viewModel.refreshID += 1
    }

    func reverseChapters() {
        viewModel.showsReversed.toggle()
    }

    func loadDetail(inputs: Inputs, context: ModelContext, following: ComicFollowingModel, refreshing: Bool = false) async {
        let current = UUID()
        operation = current
        viewModel.loadError = nil
        updatePresentation(inputs)
        var followRevision: UUID?
        do {
            followRevision = try await following.opened(comicKey)
        } catch {
            if !Task.isCancelled { viewModel.actionError = error.localizedDescription }
        }
        guard !Task.isCancelled, operation == current else { return }
        guard let plugin = inputs.plugin else {
            viewModel.loadError = L10n.text("ComicDetail.SourceUnavailable")
            return
        }
        do {
            let detail = try await PluginService.shared.detail(plugin: plugin, comicID: viewModel.summary.id)
            guard !Task.isCancelled, operation == current else { return }
            viewModel.detail = detail
            loadedChapterIDs = detail.chapters.map(\.id)
            if refreshing { viewModel.coverRefreshID += 1 }
            if let record = inputs.record {
                update(record, from: detail)
                try context.save()
            }
            do {
                try await following.observedInDetail(detail.chapters, id: comicKey, revision: followRevision)
            } catch {
                if !Task.isCancelled, operation == current { viewModel.actionError = error.localizedDescription }
            }
        } catch {
            if !Task.isCancelled, operation == current { viewModel.loadError = error.localizedDescription }
        }
    }

    func setFollowing(_ enabled: Bool, following: ComicFollowingModel) {
        guard !viewModel.changingFollow else { return }
        viewModel.changingFollow = true
        Task {
            defer { viewModel.changingFollow = false }
            do {
                let authorized = try await following.setFollowing(enabled, sourceID: sourceID, comicID: viewModel.summary.id,
                                                                   comic: viewModel.comic, chapterIDs: loadedChapterIDs)
                viewModel.showsNotificationSettings = !authorized
            } catch {
                viewModel.actionError = error.localizedDescription
            }
        }
    }

    func toggleFavorite(context: ModelContext) {
        do {
            let record = try findRecord(context: context)
            if let detail = viewModel.detail { update(record, from: detail) }
            record.isFavorite.toggle()
            try context.save()
            viewModel.favorite = record.isFavorite
        } catch {
            viewModel.actionError = error.localizedDescription
        }
    }

    func enqueueComic(plugin: PluginRecord?, context: ModelContext, downloads: DownloadManager) {
        guard viewModel.allowsDownload, let plugin, !viewModel.preparingDownload, !viewModel.chapters.isEmpty else { return }
        enqueue(viewModel.chapters, plugin: plugin, context: context, downloads: downloads)
    }

    func enqueueChapter(_ chapter: ComicChapter, plugin: PluginRecord?, context: ModelContext, downloads: DownloadManager) {
        guard viewModel.allowsDownload, let plugin, !viewModel.preparingDownload else { return }
        enqueue([chapter], plugin: plugin, context: context, downloads: downloads)
    }

    private func enqueue(_ chapters: [ComicChapter], plugin: PluginRecord, context: ModelContext, downloads: DownloadManager) {
        viewModel.preparingDownload = true
        // 独立任务持有 Model，离开详情不会取消页面解析和入队。
        Task {
            defer { viewModel.preparingDownload = false; viewModel.pendingDownloads = [] }
            do {
                let comicID = viewModel.summary.id
                // Resolve every chapter first: a page-list failure must not silently create a partial book.
                var prepared: [(ComicChapter, [URL])] = []
                for chapter in chapters where viewModel.downloadStatuses[chapter.id] != .completed {
                    viewModel.pendingDownloads.insert(chapter.id)
                    let urls = try await PluginService.shared.pages(plugin: plugin, comicID: comicID, chapterID: chapter.id)
                    guard !urls.isEmpty else { throw PluginError.message(L10n.text("ComicDetail.EmptyChapter", defaultValue: "章节“\(chapter.title)”没有可下载的页面。")) }
                    prepared.append((chapter, urls))
                }
                let record = try findRecord(context: context)
                if let detail = viewModel.detail { update(record, from: detail) }
                try context.save()
                for (chapter, urls) in prepared {
                    try await downloads.enqueue(sourceID: sourceID, comicID: comicID, chapterID: chapter.id,
                        title: chapter.title, pageURLs: urls)
                }
                Toast.info(L10n.text("DownloadStatus.AddedToQueue"))
            } catch { Toast.error(error.localizedDescription) }
        }
    }

    private func findRecord(context: ModelContext) throws -> ComicRecord {
        let comic = viewModel.comic
        return try ComicRecord.findOrCreate(in: context, sourceID: sourceID, comicID: viewModel.summary.id,
                                            title: comic.title, coverURL: comic.coverURL?.absoluteString ?? "",
                                            author: comic.author, summary: comic.summary)
    }

    private func update(_ record: ComicRecord, from detail: ComicDetail) {
        var resolved = detail
        resolved.comic = viewModel.comic
        record.title = resolved.comic.title
        record.coverURL = resolved.comic.coverURL?.absoluteString ?? ""
        record.author = resolved.comic.author
        record.summary = resolved.comic.summary
        record.detailJSON = try? JSONEncoder().encode(resolved)
    }
}
