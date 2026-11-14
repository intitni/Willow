import BreezePlugins
import BreezeRuntime
import CoreStorage
import SwiftData
import SwiftUI

struct ComicDetailView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var context
    @Environment(DownloadManager.self) private var downloads
    @Query private var records: [ComicRecord]
    @Query private var plugins: [PluginRecord]
    @Query private var downloadRecords: [DownloadRecord]
    @State private var model: ComicDetailModel
    @State private var reader: ComicChapter?
    @State private var editingLocalTags = false
    @State private var metadataDestination: MetadataDestination?

    private struct MetadataDestination: Hashable {
        let title: String
        let action: JSONValue
    }

    init(sourceID: String, summary: ComicSummary) {
        _model = State(initialValue: ComicDetailModel(sourceID: sourceID, summary: summary))
        let comicID = summary.id
        _records = Query(filter: #Predicate<ComicRecord> {
            $0.sourceID == sourceID && $0.comicID == comicID
        })
        _plugins = Query(filter: #Predicate<PluginRecord> { $0.uuid == sourceID })
        _downloadRecords = Query(filter: #Predicate<DownloadRecord> {
            $0.sourceID == sourceID && $0.comicID == comicID
        })
    }

    init(record: ComicRecord) {
        self.init(sourceID: record.sourceID, summary: ComicDetailModel.summary(for: record))
    }

    private var readingButtonPlacement: ToolbarItemPlacement {
        if #available(iOS 27, *) { .topBarPinnedTrailing }
        else { .topBarTrailing }
    }

    var body: some View {
        @Bindable var state = model.viewModel
        let inputs = ComicDetailModel.Inputs(records: records, plugins: plugins, downloads: downloadRecords)
        let request = model.request(for: inputs)
        HStack(alignment: .top, spacing: 0) {
            if horizontalSizeClass == .regular {
                ScrollView {
                    ComicDetailHeader(comic: state.comic, vertical: true)
                        .padding(24)
                }
                .frame(width: 288)
            }
            Form {
                if horizontalSizeClass != .regular {
                    Section {
                    } header: {
                        ComicDetailHeader(comic: state.comic, vertical: false)
                            .textCase(nil)
                            .padding(.vertical, 8)
                    }
                }
                ComicLocalTagsSection(sourceID: model.sourceID, comicID: state.summary.id) {
                    editingLocalTags = true
                }
                .listRowBackground(Color(uiColor: .secondarySystemBackground))

                if !state.metadata.isEmpty {
                    Section(L10n.text("ComicDetail.Information")) {
                        ForEach(state.metadata) { group in
                            if group.actions?.isEmpty != false {
                                ForEach(Array(group.values.enumerated()), id: \.offset) { _, value in
                                    if group.title.isEmpty {
                                        Text(value).textSelection(.enabled)
                                    } else {
                                        LabeledContent(group.title) {
                                            Text(value).textSelection(.enabled)
                                        }
                                    }
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 10) {
                                    if !group.title.isEmpty {
                                        Text(group.title).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    WrappingTagLayout {
                                        ForEach(group.values, id: \.self) { value in
                                            if inputs.plugin != nil, let action = group.actions?[value], !action.object.isEmpty {
                                                Button(value) { metadataDestination = MetadataDestination(title: value, action: action) }
                                                    .buttonStyle(.bordered)
                                            } else { Text(value).textSelection(.enabled) }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .listRowBackground(Color(uiColor: .secondarySystemBackground))
                }
                if state.detail == nil && state.loadError == nil {
                    Section { ProgressView(L10n.text("ComicDetail.Loading")).frame(maxWidth: .infinity) }
                        .listRowBackground(Color(uiColor: .secondarySystemBackground))
                }

                if let plugin = inputs.plugin, let actions = state.detail?.sourceActions,
                   actions.allowComments || actions.allowLike || actions.allowCollected {
                    Section(L10n.text("Text.Sources")) {
                        PluginComicActionsView(plugin: plugin, comicID: state.summary.id, state: actions)
                    }
                    .listRowBackground(Color(uiColor: .secondarySystemBackground))
                }
                if state.detail != nil {
                    ChapterList(
                        chapters: state.displayedChapters,
                        activeChapterID: state.activeChapterID,
                        pendingDownloads: state.pendingDownloads,
                        downloads: state.chapterDownloads,
                        allowsDownload: state.allowsDownload && !state.preparingDownload,
                        download: { model.enqueueChapter($0, plugin: inputs.plugin, context: context, downloads: downloads) },
                        open: { reader = $0 },
                        reverse: model.reverseChapters
                    )
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if state.loadError != nil {
                    Button(L10n.text("Text.Retry"), systemImage: "arrow.clockwise", action: model.retry)
                }
                Button {
                    model.enqueueComic(plugin: inputs.plugin, context: context, downloads: downloads)
                } label: {
                    Label(state.preparingDownload ? L10n.text("DownloadStatus.Preparing") : L10n.text("ComicDetail.DownloadComic"), systemImage: "arrow.down.circle")
                }
                .disabled(!state.allowsDownload || state.chapters.isEmpty || state.preparingDownload)

                Button {
                    model.toggleFavorite(context: context)
                } label: {
                    Label(state.favorite ? L10n.text("Text.Bookmarked") : L10n.text("Text.Bookmark"), systemImage: state.favorite ? "bookmark.fill" : "bookmark")
                }
            }
            ToolbarItem(placement: readingButtonPlacement) {
                Button {
                    reader = state.startingChapter
                } label: {
                    Label(state.activeChapterID != nil ? L10n.text("ComicDetail.ContinueReading") : L10n.text("ComicDetail.StartReading"), systemImage: "book")
                }
                .disabled(state.chapters.isEmpty)
                .buttonStyle(.glassProminent)
            }
        }
        .navigationTitle(L10n.text("ComicDetail.Title"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: inputs, initial: true) { _, inputs in model.updatePresentation(inputs) }
        .refreshable { await model.loadDetail(inputs: inputs, context: context) }
        .task(id: request) { await model.loadDetail(inputs: inputs, context: context) }
        .sheet(isPresented: $editingLocalTags) {
            LocalTagEditor(comicKey: ComicRecord.identifier(sourceID: model.sourceID, comicID: state.summary.id))
                .modifier(AppLockShield())
        }
        .fullScreenCover(item: $reader) { chapter in
            ReaderView(sourceID: model.sourceID, comicID: state.summary.id, comic: state.comic,
                       chapters: state.chapters, initialChapter: chapter, detail: state.detail)
                .modifier(AppLockShield())
        }
        .navigationDestination(item: $metadataDestination) { destination in
            if let plugin = inputs.plugin {
                PluginActionDestinationView(plugin: plugin, title: destination.title, action: destination.action)
            }
        }
        .modifier(ErrorAlert(error: $state.actionError))
        .onChange(of: state.loadError) { _, error in
            if let error { state.actionError = error }
        }
    }
}

private struct ComicDetailHeader: View {
    let comic: ComicSummary
    let vertical: Bool

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                              : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            ComicCover(url: comic.coverURL).frame(width: vertical ? 240 : 112)
            VStack(alignment: .leading, spacing: 12) {
                Text(comic.title).font(.title2.bold()).foregroundStyle(.primary)
                if !comic.summary.isEmpty {
                    Text(comic.summary).font(.body).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ChapterList: View {
    let chapters: [ComicChapter]
    let activeChapterID: String?
    let pendingDownloads: Set<String>
    let downloads: [String: ChapterDownloadPresentation]
    let allowsDownload: Bool
    let download: (ComicChapter) -> Void
    let open: (ComicChapter) -> Void
    let reverse: () -> Void

    var body: some View {
        Section {
            if chapters.isEmpty {
                Text(L10n.text("ComicDetail.NoChapters")).foregroundStyle(.secondary)
            }
            ForEach(chapters, id: \.id) { chapter in
                let downloadState = downloads[chapter.id]
                let status = downloadState?.status
                HStack(spacing: 12) {
                    Button {
                        open(chapter)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(chapter.title)
                                    .foregroundStyle(chapter.id == activeChapterID ? WillowTheme.accent : .primary)
                                if pendingDownloads.contains(chapter.id) {
                                    Text(L10n.text("DownloadStatus.Preparing"))
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if let downloadState {
                                    HStack {
                                        Text(downloadState.title)
                                        Text(downloadState.progress).monospacedDigit()
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                    if status == .downloading || status == .paused {
                                        ProgressView(value: Double(downloadState.completedPages),
                                                     total: Double(max(1, downloadState.totalPages)))
                                    }
                                }
                            }
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if pendingDownloads.contains(chapter.id) {
                        ProgressView()
                    } else if status == .queued || status == .downloading {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.text("DownloadStatus.AddedToQueue"))
                    } else if status == .completed {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.text("DownloadStatus.Completed"))
                    } else {
                        Button(status == .paused ? L10n.text("DownloadStatus.Resume") :
                               status == .failed ? L10n.text("Text.Retry") : L10n.text("ComicDetail.DownloadChapter"),
                               systemImage: status == .failed ? "arrow.clockwise" : "arrow.down.circle") { download(chapter) }
                            .labelStyle(CompactActionLabelStyle())
                            .font(.subheadline)
                            .buttonStyle(.borderless)
                            .disabled(!allowsDownload)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Color(uiColor: .secondarySystemBackground))
            }
        } header: {
            HStack {
                Text(L10n.text("Text.Chapters"))
                Spacer()
                Button(L10n.text("ComicDetail.ReverseChapterOrder"), systemImage: "arrow.up.arrow.down", action: reverse)
                    .labelStyle(.iconOnly)
            }
        }
    }
}
