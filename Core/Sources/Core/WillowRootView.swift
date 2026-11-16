import BreezePlugins
import CoreToast
import BreezeRuntime
import CoreStorage
import Observation
import SwiftData
import SwiftUI
import UIKit

@MainActor
@Observable
public final class CoreAppModel {
    fileprivate let appLock = AppLock()
    fileprivate let contentPrivacy = ContentPrivacy()
    fileprivate let discoverCart = DiscoverCartModel()
    fileprivate let updates = UpdateModel()
    fileprivate var startup: Result<AppSession, Error>
    private var followingRefresh: Task<Void, Never>?

    public init() {
        let privacy = contentPrivacy
        startup = Result { try AppSession(privacy: privacy) }
    }

    public func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .background {
            followingRefresh?.cancel()
            lockAccess()
            if case .success(let session) = startup { scheduleBackgroundRefresh(for: session) }
        }
        if phase == .active, case .success(let session) = startup {
            session.downloads.resumeForegroundDownloads()
            session.sync.events.request()
            let previous = followingRefresh
            previous?.cancel()
            followingRefresh = Task {
                await previous?.value
                await session.following.refresh()
            }
        }
    }

    fileprivate func resignActive() {
        // LocalAuthentication can temporarily make the app inactive.
        guard !appLock.isAuthenticating else { return }
        lockAccess()
    }

    fileprivate func lockAccess() {
        appLock.lock()
        contentPrivacy.lockNSFWAccess()
    }

    public static let preferenceRefreshIdentifier = "com.intii.Willow.preferences.refresh"

    public func refreshPreferencesInBackground() async {
        guard case .success(let session) = startup else { return }
        defer { scheduleBackgroundRefresh(for: session) }
        if let worker = session.sync.worker {
            try? await worker.reconcile() // Sync errors are reported through the shared ViewModel.
        }
        if await session.following.refresh(), !Task.isCancelled {
            try? await session.sync.worker?.reconcile()
        }
    }

    private func scheduleBackgroundRefresh(for session: AppSession) {
        let descriptor = FetchDescriptor<FollowedComicRecord>(predicate: #Predicate { $0.isFollowing })
        if session.sync.worker != nil || ((try? session.persistence.container.mainContext.fetchCount(descriptor)) ?? 0) > 0 {
            PreferenceBackgroundRefresh.schedule()
        }
    }

    fileprivate func retry() {
        let privacy = contentPrivacy
        startup = Result { try AppSession(privacy: privacy) }
        scenePhaseChanged(.active)
    }
}

@MainActor
public struct WillowRootView: View {
    private let model: CoreAppModel

    public init(model: CoreAppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            switch model.startup {
            case .success(let session):
                let worker = session.sync.worker
                let events = session.sync.events
                WillowTabs(updates: model.updates, discoverCart: model.discoverCart)
                    .overlay(alignment: .top) { ToastHost() }
                    .modifier(AppLockShield())
                    .modelContainer(session.persistence.container)
                    .environment(session.downloads)
                    .environment(session.sync)
                    .environment(session.following)
                    .task(id: worker.map(ObjectIdentifier.init)) {
                        guard let worker else { return }
                        await events.run(context: session.persistence.container.mainContext, sync: worker)
                    }
                    .environment(model.appLock)
                    .environment(model.contentPrivacy)
                    .tint(WillowTheme.accent)
            case .failure(let error):
                RetryView(title: L10n.text("App.StartupFailed"), message: error.localizedDescription, retry: model.retry)
                    .tint(WillowTheme.accent)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { notification in
            if let scene = notification.object as? UIWindowScene, scene.session.role == .windowApplication {
                model.resignActive()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            model.lockAccess()
        }
        .task { _ = model.updates.startInitialCheck() }
    }
}

@MainActor
private struct AppSession {
    let persistence: WillowPersistence
    let downloads: DownloadManager
    let sync: SyncSettingsModel
    let following: ComicFollowingModel

    init(privacy: ContentPrivacy) throws {
        persistence = try WillowPersistence.make()
        try ContentPrivacy.migrateSourceRatings(in: persistence.container.mainContext)
        downloads = DownloadManager(context: persistence.container.mainContext)
        let following = ComicFollowingModel(container: persistence.container, privacy: privacy)
        self.following = following
        sync = SyncSettingsModel(container: persistence.container, didImportFollowing: following.deliverNotifications)
    }
}

struct AppLockShield: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppLock.self) private var appLock
    @Environment(ContentPrivacy.self) private var privacy
    @State private var unlockTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        let protected = appLock.isLocked || privacy.requiresNSFWUnlock
            || ((appLock.isEnabled || privacy.allowsNSFW) && scenePhase != .active)
        ZStack {
            content
                .opacity(protected ? 0 : 1)
                .accessibilityHidden(protected)
                .allowsHitTesting(!protected)

            if protected {
                LockedView(appLock: appLock) {
                    unlockTask = Task {
                        let verified: Bool
                        if appLock.isLocked {
                            verified = await appLock.unlock()
                        } else if privacy.requiresNSFWUnlock {
                            verified = await appLock.verify(reason: L10n.text("Privacy.UnlockReason"))
                        } else {
                            return
                        }
                        if verified { privacy.unlockNSFWAccess() }
                    }
                }
                .disabled(scenePhase != .active)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { unlockTask?.cancel() }
        }
        .onDisappear { unlockTask?.cancel() }
    }
}

extension EnvironmentValues {
    @Entry var hiddenNSFWSources: Set<String> = []
    @Entry var unreadFollowedComics: Set<String> = []
}

private struct WillowTabs: View {
    private struct NotificationDestination: Hashable {
        let id = UUID()
        let sourceID: String
        let comic: ComicSummary
    }

    private enum TabTitle: CaseIterable, Hashable {
        case shelf, history, downloads, discover, settings

        var text: String {
            switch self {
            case .shelf: L10n.text("Shelf.Title")
            case .history: L10n.text("History.TabTitle")
            case .downloads: L10n.text("Downloads.Title")
            case .discover: L10n.text("Discover.Title")
            case .settings: L10n.text("Settings.Title")
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppLock.self) private var appLock
    @Environment(ContentPrivacy.self) private var privacy
    @Query(filter: #Predicate<PluginContentRating> { $0.isNSFW }) private var ratings: [PluginContentRating]
    @Query(filter: #Predicate<FollowedComicRecord> { $0.isFollowing && $0.hasUnreadUpdate })
    private var unreadFollows: [FollowedComicRecord]
    @Query(DownloadRecord.unfinishedDownloads) private var unfinishedDownloads: [DownloadRecord]
    @Environment(\.modelContext) private var context
    @State private var selectedTab: TabTitle = .shelf
    @State private var shelfPath: [NotificationDestination] = []
    @State private var authenticationError: String?
    @State private var authenticationTask: Task<Void, Never>?
    @State private var showingDownloadTasks = false
    let updates: UpdateModel
    let discoverCart: DiscoverCartModel

    var body: some View {
        @Bindable var notices = PluginNoticeModel.shared.viewModel
        let updateBadge = updates.isUpdateAvailable == true ? Text(verbatim: "") : nil
        let hiddenSources = privacy.hidesNSFWSources ? Set(ratings.map(\.sourceID)) : []
        let pendingDownloads = unfinishedDownloads.filter { !hiddenSources.contains($0.sourceID) }
        let pendingComic = scenePhase == .active && !appLock.isLocked && !privacy.requiresNSFWUnlock
            ? ComicUpdateNotifications.shared.pendingComicKey : nil
        let tabs = TabView(selection: $selectedTab) {
            Tab(TabTitle.shelf.text, systemImage: "books.vertical", value: .shelf) {
                NavigationStack(path: $shelfPath) {
                    LibraryView(kind: .favorites)
                        .navigationDestination(for: NotificationDestination.self) { destination in
                            ComicDetailView(sourceID: destination.sourceID, summary: destination.comic)
                        }
                }
            }
            Tab(TabTitle.history.text, systemImage: "clock", value: .history) {
                NavigationStack { LibraryView(kind: .history) }
            }
            Tab(TabTitle.downloads.text, systemImage: "arrow.down.circle", value: .downloads) {
                NavigationStack { DownloadsView { showingDownloadTasks = true } }
            }
            Tab(TabTitle.discover.text, systemImage: "safari", value: .discover) {
                NavigationStack { DiscoverView() }
                    .id(hiddenSources)
                    .environment(discoverCart)
            }
            Tab(TabTitle.settings.text, systemImage: "gearshape", value: .settings) {
                NavigationStack { SettingsView(updates: updates) }
            }
            .accessibilityIdentifier(SettingsTabLongPress.tabIdentifier)
            .badge(updateBadge)
        }
        downloadAccessory(for: tabs, count: pendingDownloads.count)
        .sheet(isPresented: $showingDownloadTasks) {
            DownloadTasksView(records: pendingDownloads)
                .modifier(AppLockShield())
        }
        .environment(\.hiddenNSFWSources, hiddenSources)
        .environment(\.unreadFollowedComics, Set(unreadFollows.lazy.filter { !hiddenSources.contains($0.sourceID) }.map(\.id)))
        .onChange(of: pendingComic, initial: true) { _, id in
            if let id { openNotification(id, hiddenSources: hiddenSources) }
        }
        .onChange(of: hiddenSources) { _, sources in
            if let pendingComic { openNotification(pendingComic, hiddenSources: sources) }
        }
        .background {
            SettingsTabLongPress(
                title: TabTitle.settings.text,
                tabTitles: Set(TabTitle.allCases.map(\.text)),
                action: verifyNSFWAccess
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { authenticationTask?.cancel() }
        }
        .onDisappear { authenticationTask?.cancel() }
        .modifier(ErrorAlert(error: $authenticationError))
        .modifier(ErrorAlert(error: $notices.message))
    }

    @ViewBuilder
    private func downloadAccessory(for tabs: some View, count: Int) -> some View {
        let button = Button {
            showingDownloadTasks = true
        } label: {
            Label(L10n.text("Downloads.TasksCount", defaultValue: "Download Tasks (\(count))"),
                  systemImage: "arrow.down.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)

        if #available(iOS 26.1, *) {
            tabs.tabViewBottomAccessory(isEnabled: count > 0) { button }
        } else {
            tabs.tabViewBottomAccessory {
                if count > 0 { button }
            }
        }
    }

    private func openNotification(_ id: String, hiddenSources: Set<String>) {
        let descriptor = FetchDescriptor<FollowedComicRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try? context.fetch(descriptor).first,
              !hiddenSources.contains(record.sourceID), ComicUpdateNotifications.shared.take(id) else { return }
        shelfPath = [NotificationDestination(sourceID: record.sourceID, comic: record.comicSummary)]
        selectedTab = .shelf
    }

    private func verifyNSFWAccess() {
        guard scenePhase == .active, !appLock.isLocked, !privacy.requiresNSFWUnlock, !appLock.isAuthenticating else { return }
        authenticationTask = Task {
            let verified = await appLock.verify(reason: L10n.text("Privacy.VerifyIdentityReason"))
            guard !Task.isCancelled else { return }
            if verified && !appLock.isLocked && !privacy.requiresNSFWUnlock {
                privacy.toggleNSFWAccess()
            } else {
                authenticationError = appLock.errorMessage
            }
        }
    }
}

private struct LockedView: View {
    let appLock: AppLock
    let unlock: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(L10n.text("AppLock.LockedTitle"), systemImage: "lock")
        } description: {
            if let error = appLock.errorMessage {
                Text(error)
            }
        } actions: {
            Button(L10n.text("AppLock.Unlock"), action: unlock)
            .buttonStyle(.glassProminent)
            .disabled(appLock.isAuthenticating)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.background).ignoresSafeArea() }
        .accessibilityAddTraits(.isModal)
    }
}
