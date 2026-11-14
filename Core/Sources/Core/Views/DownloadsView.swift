import CoreStorage
import SwiftData
import SwiftUI

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Query(sort: \DownloadRecord.updatedAt, order: .reverse) private var records: [DownloadRecord]
    @Query private var comics: [ComicRecord]
    @Query(sort: \LocalTagRecord.name) private var localTags: [LocalTagRecord]
    @State private var editingTags: DownloadItem?
    @State private var model = DownloadsModel()

    var body: some View {
        @Bindable var viewModel = model.viewModel
        Group {
            if viewModel.isEmpty {
                ContentUnavailableView(L10n.text("Text.NoDownloads"), systemImage: "arrow.down.circle",
                                       description: Text(L10n.text("Message.DownloadChaptersForOfflineReading")))
            } else if viewModel.items.isEmpty {
                ContentUnavailableView(L10n.text("Text.NoMatchingDownloads"), systemImage: "tag", description: Text(L10n.text("Text.TryOtherTagsOrClearTheTagFilter")))
            } else {
                List(viewModel.items) { item in
                    DownloadRow(item: item) { model.activate(item) }
                        .contextMenu { Button(L10n.text("Text.EditLocalTags"), systemImage: "tag") { editingTags = item } }
                        .swipeActions {
                            Button(L10n.text("Text.DeleteDownload"), systemImage: "trash", role: .destructive) { model.delete(item) }
                        }
                }
            }
        }
        .navigationTitle(L10n.text("Text.Downloads"))
        .toolbar {
            if !viewModel.tags.isEmpty {
                LocalTagFilterMenu(tags: viewModel.tags, selected: viewModel.selectedTags, select: model.selectTags)
            }
        }
        .sheet(item: $editingTags) { item in LocalTagEditor(comicKey: item.comicKey).modifier(AppLockShield()) }
        .onChange(of: localTags.map(LocalTagSnapshot.init), initial: true) { _, tags in model.updateTags(tags) }
        .fullScreenCover(item: $viewModel.opened) { offline in
            ReaderView(sourceID: offline.sourceID, comicID: offline.comic.id, comic: offline.comic, chapters: offline.chapters,
                       initialChapter: offline.chapter, detail: offline.detail)
                .modifier(AppLockShield())
        }
        .modifier(ErrorAlert(error: $viewModel.error))
        .onChange(of: records.map(\.updatedAt), initial: true) { _, _ in
            model.update(records: records, comics: comics, manager: downloads)
        }
        .onChange(of: comics.map(LibraryItem.init)) { _, _ in
            model.update(records: records, comics: comics, manager: downloads)
        }
    }

}

private struct DownloadRow: View {
    let item: DownloadItem
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.headline)
                if let comicTitle = item.comicTitle {
                    Text(comicTitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if item.status == .downloading {
                    ProgressView(value: Double(item.completedPages),
                                 total: Double(max(1, item.totalPages)))
                        .accessibilityLabel(L10n.text("Text.DownloadProgress"))
                }
                Text(statusLabel).font(.caption).foregroundStyle(.secondary)
                if let message = item.error, item.status == .failed {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(actionLabel, systemImage: actionIcon, action: action)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    private var statusLabel: String {
        switch item.status {
        case .queued: L10n.text("Text.Queued")
        case .downloading: L10n.text("Text.DownloadingProgress", defaultValue: "正在下载 \(item.completedPages) / \(item.totalPages)")
        case .paused: L10n.text("Text.Paused")
        case .completed: L10n.text("Text.Downloaded")
        case .failed: L10n.text("Text.DownloadFailed")
        }
    }

    private var actionLabel: String {
        switch item.status {
        case .queued, .downloading: L10n.text("Text.Pause")
        case .paused: L10n.text("Text.ResumeDownload")
        case .completed: L10n.text("Text.Reading")
        case .failed: L10n.text("Text.Retry")
        }
    }

    private var actionIcon: String {
        switch item.status {
        case .queued, .downloading: "pause.circle"
        case .paused: "play.circle"
        case .completed: "book"
        case .failed: "arrow.clockwise.circle"
        }
    }
}
