import Observation
import UIKit
import UserNotifications

@MainActor
@Observable
final class ComicUpdateNotifications {
    static let shared = ComicUpdateNotifications()
    nonisolated static let category = "Willow.ComicUpdate"
    nonisolated static let comicKeyField = "comicKey"

    private(set) var pendingComicKey: String?

    nonisolated static func identifier(for comicKey: String) -> String {
        category + "/" + comicKey
    }

    func enqueue(_ comicKey: String) { pendingComicKey = comicKey }

    func take(_ comicKey: String) -> Bool {
        guard comicKey == pendingComicKey else { return false }
        pendingComicKey = nil
        return true
    }
}

public final class WillowNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    public func application(_ application: UIApplication,
                            willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ComicUpdateNotifications.category, actions: [], intentIdentifiers: [])
        ])
        return true
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                    willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.content.categoryIdentifier == ComicUpdateNotifications.category ? [.banner, .list, .sound] : []
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                    didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              content.categoryIdentifier == ComicUpdateNotifications.category,
              let id = content.userInfo[ComicUpdateNotifications.comicKeyField] as? String else { return }
        await ComicUpdateNotifications.shared.enqueue(id)
    }
}
