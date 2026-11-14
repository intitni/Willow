import CoreToast
import BreezeRuntime
import CoreStorage
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
public final class CoreAppModel {
    fileprivate let appLock = AppLock()
    fileprivate let updates = UpdateModel()
    fileprivate var startup = Result { try AppSession() }

    public init() {}

    public func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .background {
            appLock.lock()
            PreferenceBackgroundRefresh.schedule()
        }
        if phase == .active, case .success(let session) = startup {
            session.downloads.resumeForegroundDownloads()
            session.preferenceEvents.request()
        }
    }

    public static let preferenceRefreshIdentifier = "com.intii.Willow.preferences.refresh"

    public func refreshPreferencesInBackground() async {
        defer { PreferenceBackgroundRefresh.schedule() }
        guard case .success(let session) = startup else { return }
        do { try await session.preferences.reconcile() }
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
                WillowTabs(persistence: session.persistence, updates: model.updates)
                    .overlay(alignment: .top) { ToastHost() }
                    .modifier(AppLockShield())
                    .modelContainer(session.persistence.container)
                    .environment(session.downloads)
                    .environment(session.preferences.viewModel)
                    .task {
                        await session.preferenceEvents.run(context: session.persistence.container.mainContext, sync: session.preferences)
                    }
                    .environment(model.appLock)
                    .tint(WillowTheme.accent)
            case .failure(let error):
                RetryView(title: L10n.text("App.StartupFailed"), message: error.localizedDescription, retry: model.retry)
                    .tint(WillowTheme.accent)
            }
        }
        .task { _ = model.updates.startInitialCheck() }
    }
}

@MainActor
private struct AppSession {
    let persistence: WillowPersistence
    let downloads: DownloadManager
    let preferences: PreferenceSyncModel
    let preferenceEvents = PreferenceSyncEvents()

    init() throws {
        persistence = try WillowPersistence.make()
        downloads = DownloadManager(context: persistence.container.mainContext)
        preferences = PreferenceSyncModel(container: persistence.container)
    }
}

struct AppLockShield: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppLock.self) private var appLock

    func body(content: Content) -> some View {
        let protected = appLock.isLocked || (appLock.isEnabled && scenePhase != .active)
        ZStack {
            content
                .accessibilityHidden(protected)
                .allowsHitTesting(!protected)

            if protected {
                LockedView(appLock: appLock)
            }
        }
    }
}

private struct WillowTabs: View {
    let persistence: WillowPersistence
    let updates: UpdateModel

    var body: some View {
        @Bindable var notices = PluginNoticeModel.shared.viewModel
        let updateBadge: String? = updates.isUpdateAvailable == true ? "" : nil
        TabView {
            Tab(L10n.text("Shelf.Title"), systemImage: "books.vertical") {
                NavigationStack { LibraryView(kind: .favorites) }
            }
            Tab(L10n.text("History.TabTitle"), systemImage: "clock") {
                NavigationStack { LibraryView(kind: .history) }
            }
            Tab(L10n.text("Downloads.Title"), systemImage: "arrow.down.circle") {
                NavigationStack { DownloadsView() }
            }
            Tab(L10n.text("Discover.Title"), systemImage: "safari") {
                NavigationStack { DiscoverView() }
            }
            Tab(L10n.text("Settings.Title"), systemImage: "gearshape") {
                NavigationStack { SettingsView(persistence: persistence, updates: updates) }
            }
            .badge(updateBadge)
        }
        .modifier(ErrorAlert(error: $notices.message))
    }
}

private struct LockedView: View {
    let appLock: AppLock

    var body: some View {
        ContentUnavailableView {
            Label(L10n.text("AppLock.LockedTitle"), systemImage: "lock")
        } description: {
            if let error = appLock.errorMessage {
                Text(error)
            }
        } actions: {
            Button(L10n.text("AppLock.Unlock")) {
                Task { await appLock.unlock() }
            }
            .buttonStyle(.glassProminent)
            .disabled(appLock.isAuthenticating)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.background).ignoresSafeArea() }
        .accessibilityAddTraits(.isModal)
    }
}
