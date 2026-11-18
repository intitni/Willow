import BreezePlugins
import CorePresentation
import CoreStorage
import SwiftData
import SwiftUI

enum ReaderMode: String, CaseIterable, Identifiable {
    case vertical, leftToRight, rightToLeft

    var id: Self { self }
    var label: String {
        switch self {
        case .vertical: L10n.text("ReadingDirection.VerticalScrolling")
        case .leftToRight: L10n.text("ReadingDirection.LeftToRight")
        case .rightToLeft: L10n.text("ReadingDirection.RightToLeft")
        }
    }
}

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var context
    @Environment(DownloadManager.self) private var downloads
    @Environment(SyncSettingsModel.self) private var sync
    @Environment(\.hiddenNSFWSources) private var hiddenSources
    @Query private var plugins: [PluginRecord]
    @AppStorage("reader.mode") private var mode = ReaderMode.vertical
    @AppStorage("reader.spreads") private var spreads = true
    @State private var pairsFromSecondPage = false
    @State private var model: ReaderModel
    @State private var showsControls = true
    @State private var showsChapters = false
    private let sourceID: String

    init(sourceID: String, comicID: String, comic: ComicSummary, chapters: [ComicChapter], initialChapter: ComicChapter,
         detail: ComicDetail?) {
        self.sourceID = sourceID
        _model = State(initialValue: ReaderModel(sourceID: sourceID, comicID: comicID, comic: comic,
                                                chapters: chapters, initialChapter: initialChapter, detail: detail))
        _plugins = Query(filter: #Predicate<PluginRecord> { $0.uuid == sourceID })
    }

    var body: some View {
        let hidden = hiddenSources.contains(sourceID)
        Group {
            if !hidden { reader }
        }
        .modifier(AppLockShield())
        .onChange(of: hidden, initial: true) { _, hidden in
            if hidden { dismiss() }
        }
        .onDisappear { sync.events.requestPendingPageProgress() }
    }

    @ViewBuilder private var reader: some View {
        @Bindable var state = model.viewModel
        let request = model.request
        let pageIndex = Binding(
            get: { state.pageIndex },
            set: { model.selectPage($0, request: request, context: context, syncEvents: sync.events) }
        )
        NavigationStack {
            GeometryReader { geometry in
                let layout = ReaderLayout(
                    viewport: geometry.size, horizontalReading: mode != .vertical,
                    spreadsEnabled: spreads, regularWidth: horizontalSizeClass == .regular,
                    pairsFromSecondPage: pairsFromSecondPage
                )
                ZStack {
                    Color.black
                    if let loadError = state.loadError {
                        RetryView(title: L10n.text("Reader.OpenChapterFailed"), message: loadError) { model.retry() }
                            .padding(.horizontal, 24)
                    } else if !state.isLoaded || state.pages.isEmpty {
                        ProgressView(L10n.text("Reader.LoadingChapter"))
                    } else {
                        ReaderPages(urls: state.pages, mode: mode, layout: layout,
                                    pageIndex: pageIndex, toggleControls: toggleControls)
                            .id(request)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .ignoresSafeArea()
            .navigationTitle(state.chapter.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.text("Reader.Close"), systemImage: "xmark") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(L10n.text("Reader.ChooseChapter"), systemImage: "list.bullet") { showsChapters = true }
                    Menu(L10n.text("Reader.Settings"), systemImage: "slider.horizontal.3") {
                        Picker(L10n.text("ReadingDirection.Title"), selection: $mode) {
                            ForEach(ReaderMode.allCases) { value in Text(value.label).tag(value) }
                        }
                        Toggle(L10n.text("Reader.TwoPagesInWideWindows"), isOn: $spreads)
                        Toggle(L10n.text("Reader.PairFromSecondPage"), isOn: $pairsFromSecondPage)
                            .disabled(mode == .vertical || !spreads)
                    }
                }
                if state.isLoaded && !state.pages.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        ReaderPageBar(pageIndex: pageIndex, pageCount: state.pages.count,
                                      previous: state.previous, next: state.next,
                                      select: { model.selectChapter($0) })
                    }
                }
            }
            .toolbar(showsControls || !state.isLoaded ? .visible : .hidden, for: .navigationBar, .bottomBar)
            .toolbarBackground(.hidden, for: .navigationBar, .bottomBar)
        }
        .environment(\.colorScheme, .dark)
        .persistentSystemOverlays(showsControls ? .visible : .hidden)
        .statusBarHidden(!showsControls)
        .task(id: request) {
            await model.loadChapter(request: request, plugins: plugins, context: context, downloads: downloads)
        }
        .sheet(isPresented: $showsChapters) {
            NavigationStack {
                List(state.chapters, id: \.id) { candidate in
                    Button {
                        model.selectChapter(candidate)
                        showsChapters = false
                    } label: {
                        HStack {
                            Text(candidate.title)
                            Spacer()
                            if candidate.id == state.chapter.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                .navigationTitle(L10n.text("Text.Chapters"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.text("Text.Done")) { showsChapters = false }
                    }
                }
            }
            .modifier(AppLockShield())
        }
        .modifier(ErrorAlert(error: $state.saveError))
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.18)) { showsControls.toggle() }
    }
}

private struct ReaderPageBar: View {
    @Binding var pageIndex: Int
    let pageCount: Int
    let previous: ComicChapter?
    let next: ComicChapter?
    let select: (ComicChapter) -> Void

    var body: some View {
        HStack {
            Button(L10n.text("Reader.PreviousChapter"), systemImage: "backward.end") {
                if let previous { select(previous) }
            }
            .disabled(previous == nil)
            .labelStyle(.iconOnly)
            if pageCount > 1 {
                Slider(value: Binding(
                    get: { Double(pageIndex) },
                    set: { pageIndex = Int($0) }
                ), in: 0...Double(pageCount - 1), step: 1)
                .accessibilityLabel(L10n.text("Reader.PageNumber"))
                .accessibilityValue(L10n.text("Reader.PageProgressAccessibilityLabel", defaultValue: "第 \(pageIndex + 1) 页，共 \(pageCount) 页"))
            }
            Text(L10n.resource("Text.PageProgress", defaultValue: "\(pageIndex + 1) / \(pageCount)"))
                .font(.caption.monospacedDigit())
                .accessibilityLabel(L10n.text("Reader.PageProgressAccessibilityLabel", defaultValue: "第 \(pageIndex + 1) 页，共 \(pageCount) 页"))
            Button(L10n.text("Reader.NextChapter"), systemImage: "forward.end") {
                if let next { select(next) }
            }
            .disabled(next == nil)
            .labelStyle(.iconOnly)
        }
        .frame(minWidth: 240, idealWidth: 480, maxWidth: 580)
        .padding(.horizontal, 8)
    }
}

private struct ReaderPages: View {
    let urls: [URL]
    let mode: ReaderMode
    let layout: ReaderLayout
    private var viewport: CGSize { layout.viewport }
    @Binding var pageIndex: Int
    let toggleControls: () -> Void

    @State private var position: Int?
    @State private var widePages: Set<Int> = []

    init(urls: [URL], mode: ReaderMode, layout: ReaderLayout, pageIndex: Binding<Int>, toggleControls: @escaping () -> Void) {
        self.urls = urls
        self.mode = mode
        self.layout = layout
        _pageIndex = pageIndex
        self.toggleControls = toggleControls
        _position = State(initialValue: layout.pagination(pageCount: urls.count).anchor(for: pageIndex.wrappedValue))
    }

    private struct LayoutID: Hashable {
        let mode: ReaderMode
        let spread: Bool
        let spreadOffset: Bool
        let width: CGFloat
        let height: CGFloat
    }

    var body: some View {
        let pagination = layout.pagination(pageCount: urls.count, widePages: widePages)
        let reversed = mode == .rightToLeft
        let groups = pagination.starts(reversed: reversed)
        let layoutID = LayoutID(mode: mode, spread: layout.usesSpread, spreadOffset: layout.usesSpreadOffset,
                                width: viewport.width, height: viewport.height)
        Group {
            if mode == .vertical {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groups, id: \.self) { index in
                            ReaderPage(url: urls[index], viewport: viewport, vertical: true,
                                       toggleControls: toggleControls)
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.all, 0, for: .scrollContent)
                .scrollPosition(id: $position, anchor: .top)
                .scrollIndicators(.hidden)
                .onScrollPhaseChange { _, phase in if phase == .idle { commitPosition(in: pagination) } }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(groups, id: \.self) { start in
                            let indices = pagination.slots(start: start, reversed: reversed)
                            let slotSize = CGSize(width: viewport.width / CGFloat(indices.count), height: viewport.height)
                            let hasTwoPages = indices.count == 2 && start + 1 < urls.count
                            HStack(spacing: 0) {
                                ForEach(indices, id: \.self) { index in
                                    if urls.indices.contains(index) {
                                        let innerEdge: Alignment = index == indices.first ? .trailing : .leading
                                        ReaderPage(
                                            url: urls[index],
                                            viewport: slotSize,
                                            vertical: false,
                                            imageAlignment: hasTwoPages ? innerEdge : .center,
                                            isSpreadSlot: indices.count == 2,
                                            onWideImage: { widePages.insert(index) },
                                            toggleControls: toggleControls
                                        )
                                    } else {
                                        Color.clear
                                            .frame(width: slotSize.width, height: slotSize.height)
                                            .contentShape(.rect)
                                            .onTapGesture(perform: toggleControls)
                                    }
                                }
                            }
                            .frame(width: viewport.width, height: viewport.height)
                            .contentShape(.rect)
                            .id(start)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.all, 0, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                .scrollPosition(id: $position, anchor: .center)
                .scrollIndicators(.hidden)
                .onScrollPhaseChange { _, phase in if phase == .idle { commitPosition(in: pagination) } }
                .id(layoutID)
            }
        }
        .background {
            // Include the visible group so its in-flight requests survive the turn.
            let indices = pagination.prefetchIndices(from: position ?? pageIndex)
            ZStack {
                ForEach(indices, id: \.self) { index in
                    Color.clear.task(id: layout.usesSpread) {
                        let isWide = await ReaderModel.prefetchPage(urls[index], checkAspectRatio: layout.usesSpread)
                        if isWide && !Task.isCancelled { widePages.insert(index) }
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onChange(of: pageIndex) { _, index in position = pagination.anchor(for: index) }
        .onChange(of: layoutID) { _, _ in position = pagination.anchor(for: pageIndex) }
        .onChange(of: pagination) { previous, current in
            let visible = position ?? previous.anchor(for: pageIndex)
            let page = previous.anchor(for: pageIndex) == visible ? pageIndex : visible
            let anchor = current.anchor(for: page)
            if position != anchor { position = anchor }
        }
    }

    private func commitPosition(in pagination: ReaderLayout.Pagination) {
        guard let position, urls.indices.contains(position),
              position == pagination.anchor(for: position),
              position != pagination.anchor(for: pageIndex) else { return }
        pageIndex = position
    }
}

private struct ReaderPage: View {
    @Environment(\.displayScale) private var displayScale
    let url: URL
    let viewport: CGSize
    let vertical: Bool
    var imageAlignment: Alignment = .center
    var isSpreadSlot = false
    var onWideImage: () -> Void = {}
    let toggleControls: () -> Void
    @State private var scale: CGFloat = 1
    @State private var offset = CGSize.zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag = CGSize.zero

    var body: some View {
        // Keep the current bitmap during the gesture and request more pixels once it settles.
        let zoom: CGFloat = scale == 1 ? 1 : (scale <= 2 ? 2 : 4)
        let rendering = ReaderImage(viewport: viewport, displayScale: displayScale, zoom: zoom, vertical: vertical)
        CachedImage(url: url, readerImage: rendering) { image in
            let size = image.originalSize
            let isWide = ReaderLayout.isWideImage(size)
            let fittedImage = Image(uiImage: image.bitmap).resizable()
                .aspectRatio(size.height > 0 ? size.width / size.height : nil, contentMode: .fit)
                .frame(width: viewport.width, height: vertical ? nil : viewport.height, alignment: imageAlignment)
            Group {
                if isSpreadSlot && isWide {
                    Color.clear.frame(width: viewport.width, height: viewport.height)
                } else if imageAlignment != .center && ReaderLayout.isNarrowImage(size, in: viewport) {
                    fittedImage.allowsHitTesting(false)
                } else {
                    fittedImage
                        .scaleEffect(renderedScale)
                        .offset(clampedOffset(x: offset.width + drag.width, y: offset.height + drag.height,
                                              scale: renderedScale))
                        .clipped()
                        .overlay { pageInteraction }
                        .accessibilityAction(named: Text(L10n.text("Reader.ToggleControlsAccessibilityAction")), toggleControls)
                }
            }
            .onChange(of: isWide, initial: true) { _, isWide in
                if isWide { onWideImage() }
            }
        } placeholder: { error in
            VStack(spacing: 10) {
                if error != nil {
                    Image(systemName: "arrow.clockwise.circle").font(.title)
                    Text(L10n.text("Reader.RetryPage")).font(.footnote)
                } else {
                    ProgressView()
                }
            }
            .frame(width: viewport.width, height: vertical ? max(160, viewport.width) : viewport.height)
            .contentShape(.rect)
            .simultaneousGesture(TapGesture().onEnded {
                if error == nil { toggleControls() }
            })
        }
    }

    private var pageInteraction: some View {
        // Keep gesture input in the page's clipping frame as the image moves underneath it.
        Color.clear
            .contentShape(.rect)
            .highPriorityGesture(DragGesture(coordinateSpace: .global)
                .updating($drag) { value, state, transaction in
                    transaction.animation = nil
                    state = value.translation
                }
                .onEnded { value in
                    offset = clampedOffset(x: offset.width + value.translation.width,
                                           y: offset.height + value.translation.height, scale: scale)
                }, isEnabled: scale > 1)
            .gesture(MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in
                    scale = min(4, max(1, scale * value.magnification))
                    if scale == 1 { offset = .zero }
                })
            .onTapGesture(count: 2) {
                scale = scale > 1 ? 1 : 2
                offset = .zero
            }
            .onTapGesture(perform: toggleControls)
    }

    private var renderedScale: CGFloat { min(4, max(1, scale * pinch)) }

    private func clampedOffset(x: CGFloat, y: CGFloat, scale: CGFloat) -> CGSize {
        let limitX = viewport.width * (scale - 1) / 2
        let limitY = viewport.height * (scale - 1) / 2
        return CGSize(width: min(limitX, max(-limitX, x)), height: min(limitY, max(-limitY, y)))
    }

}
