import CoreStorage
import SwiftData
import SwiftUI

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.hiddenNSFWSources) private var hiddenSources
    @Query(sort: \DownloadRecord.updatedAt, order: .reverse) private var records: [DownloadRecord]
    @Query private var comics: [ComicRecord]
    @Query(sort: \LocalTagRecord.name) private var localTags: [LocalTagRecord]
    @State private var editingTags: DownloadItem?
    @State private var model = DownloadsModel()

    var body: some View {
        @Bindable var viewModel = model.viewModel
        let visibleRecords = records.filter { !hiddenSources.contains($0.sourceID) }
        Group {
            if viewModel.isEmpty {
                ContentUnavailableView(L10n.text("Downloads.EmptyTitle"), systemImage: "arrow.down.circle",
                                       description: Text(L10n.text("Downloads.EmptyDescription")))
            } else if viewModel.items.isEmpty {
                ContentUnavailableView(L10n.text("Downloads.NoMatchesTitle"), systemImage: "tag", description: Text(L10n.text("Downloads.NoMatchesDescription")))
            } else {
                List(viewModel.items) { item in
                    DownloadRow(item: item) { model.activate(item) }
                        .contextMenu { Button(L10n.text("LocalTags.Edit"), systemImage: "tag") { editingTags = item } }
                        .swipeActions {
                            Button(L10n.text("Downloads.Delete"), systemImage: "trash", role: .destructive) { model.delete(item) }
                        }
                }
            }
        }
        .navigationTitle(L10n.text("Downloads.Title"))
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
        }
        .modifier(ErrorAlert(error: $viewModel.error))
        .onChange(of: records.map(\.updatedAt), initial: true) { _, _ in
            model.update(records: visibleRecords, comics: comics, manager: downloads)
        }
        .onChange(of: hiddenSources) { _, _ in
            model.update(records: visibleRecords, comics: comics, manager: downloads)
        }
        .onChange(of: comics.map(LibraryItem.init)) { _, _ in
            model.update(records: visibleRecords, comics: comics, manager: downloads)
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
                        .accessibilityLabel(L10n.text("DownloadStatus.InProgress"))
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
        case .queued: L10n.text("DownloadStatus.Queued")
        case .downloading: L10n.text("Downloads.Progress", defaultValue: "正在下载 \(item.completedPages) / \(item.totalPages)")
        case .paused: L10n.text("DownloadStatus.Paused")
        case .completed: L10n.text("DownloadStatus.Completed")
        case .failed: L10n.text("DownloadStatus.Failed")
        }
    }

    private var actionLabel: String {
        switch item.status {
        case .queued, .downloading: L10n.text("Downloads.Pause")
        case .paused: L10n.text("DownloadStatus.Resume")
        case .completed: L10n.text("Downloads.Read")
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
