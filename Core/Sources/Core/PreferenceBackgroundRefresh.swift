import BackgroundTasks
import OSLog

@MainActor
enum PreferenceBackgroundRefresh {
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: CoreAppModel.preferenceRefreshIdentifier)
        // A lower bound for the system scheduler, not an in-process polling timer.
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch {
            Logger(subsystem: "Willow", category: "PreferenceSync")
                .debug("Background refresh unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }
}
