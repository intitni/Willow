import Core
import SwiftUI

@main
struct WillowApp: App {
    @UIApplicationDelegateAdaptor(WillowNotificationDelegate.self) private var notificationDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = CoreAppModel()

    var body: some Scene {
        WindowGroup {
            WillowRootView(model: model)
        }
        .backgroundTask(.appRefresh(CoreAppModel.preferenceRefreshIdentifier)) {
            await model.refreshPreferencesInBackground()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}
