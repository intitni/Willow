import Core
import SwiftUI

@main
struct WillowApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = CoreAppModel()

    var body: some Scene {
        WindowGroup {
            WillowRootView(model: model)
        }
        .backgroundTask(.appRefresh(CoreAppModel.preferenceRefreshIdentifier)) {
            await model.refreshPreferencesInBackground()
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}
