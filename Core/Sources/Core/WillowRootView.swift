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
    fileprivate let updates = UpdateModel()
    fileprivate var startup = Result { try AppSession() }

    public init() {}

    public func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .background {
            lockAccess()
            if case .success(let session) = startup, session.sync.worker != nil {
                PreferenceBackgroundRefresh.schedule()
            }
        }
        if phase == .active, case .success(let session) = startup {
            session.downloads.resumeForegroundDownloads()
            session.sync.events.request()
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
        guard case .success(let session) = startup, let worker = session.sync.worker else { return }
        defer { if session.sync.worker != nil { PreferenceBackgroundRefresh.schedule() } }
        do { try await worker.reconcile() }
        catch { /* Sync errors are reported through the shared ViewModel. */ }
    }

    fileprivate func retry() {
        startup = Result { try AppSession() }
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
                WillowTabs(updates: model.updates)
                    .overlay(alignment: .top) { ToastHost() }
                    .modifier(AppLockShield())
                    .modelContainer(session.persistence.container)
                    .environment(session.downloads)
                    .environment(session.sync)
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

    init() throws {
        persistence = try WillowPersistence.make()
        try ContentPrivacy.migrateSourceRatings(in: persistence.container.mainContext)
        downloads = DownloadManager(context: persistence.container.mainContext)
        sync = SyncSettingsModel(container: persistence.container)
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
}

private struct WillowTabs: View {
    private enum TabTitle: CaseIterable {
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
    @State private var authenticationError: String?
    @State private var authenticationTask: Task<Void, Never>?
    let updates: UpdateModel

    var body: some View {
        @Bindable var notices = PluginNoticeModel.shared.viewModel
        let updateBadge = updates.isUpdateAvailable == true ? Text(verbatim: "") : nil
        let hiddenSources = privacy.hidesNSFWSources ? Set(ratings.map(\.sourceID)) : []
        TabView {
            Tab(TabTitle.shelf.text, systemImage: "books.vertical") {
                NavigationStack { LibraryView(kind: .favorites) }
            }
            Tab(TabTitle.history.text, systemImage: "clock") {
                NavigationStack { LibraryView(kind: .history) }
            }
            Tab(TabTitle.downloads.text, systemImage: "arrow.down.circle") {
                NavigationStack { DownloadsView() }
            }
            Tab(TabTitle.discover.text, systemImage: "safari") {
                NavigationStack { DiscoverView() }
                    .id(hiddenSources)
            }
            Tab(TabTitle.settings.text, systemImage: "gearshape") {
                NavigationStack { SettingsView(updates: updates) }
            }
            .accessibilityIdentifier(SettingsTabLongPress.tabIdentifier)
            .badge(updateBadge)
        }
        .environment(\.hiddenNSFWSources, hiddenSources)
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
