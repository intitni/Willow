import BreezePlugins
import CoreStorage
import Foundation
import Observation
import OSLog
import SwiftData
import UserNotifications

@MainActor
@Observable
final class ComicFollowingModel {
    private let container: ModelContainer
    private let privacy: ContentPrivacy
    private let store = FollowedComicStore.shared
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "Willow", category: "ComicFollowing")
    private var lastAttempted: [String: Date] = [:]
    private var isRefreshing = false
    private var deliveringNotifications = false
    private var needsNotificationPass = false

    init(container: ModelContainer, privacy: ContentPrivacy) {
        self.container = container
        self.privacy = privacy
    }

    func setFollowing(_ isFollowing: Bool, sourceID: String, comicID: String, comic: ComicSummary,
                      chapterIDs: [String]?) async throws -> Bool {
        let snapshot = FollowedComicSnapshot(sourceID: sourceID, comicID: comicID, title: comic.title,
                                             coverURL: comic.coverURL?.absoluteString ?? "", author: comic.author,
                                             summary: comic.summary, isFollowing: isFollowing,
                                             knownChapterIDs: isFollowing ? chapterIDs : nil)
        try await store.setFollowing(snapshot, in: container)
        lastAttempted.removeValue(forKey: snapshot.id)
        guard isFollowing else {
            clearNotification(for: snapshot.id)
            return true
        }

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined, .provisional:
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            if granted { await deliverNotifications() }
            return granted
        case .denied:
            return false
        case .authorized, .ephemeral:
            await deliverNotifications()
            return settings.alertSetting == .enabled || settings.notificationCenterSetting == .enabled
        @unknown default:
            return false
        }
    }

    func opened(_ id: String) async throws -> UUID? {
        let revision = try await store.markOpened(id, in: container)
        if revision != nil { clearNotification(for: id) }
        return revision
    }

    func observedInDetail(_ chapters: [ComicChapter], id: String, revision: UUID?) async throws {
        try await store.observe(chapters.map { .init(id: $0.id, title: $0.title) }, for: id,
                                expectedRevision: revision, opened: true, in: container)
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !isRefreshing, !Task.isCancelled else { return false }
        isRefreshing = true
        defer { isRefreshing = false }
        var changed = false
        await deliverNotifications()

        do {
            let records = try await store.records(in: container)
            let currentIDs = Set(records.map(\.id))
            lastAttempted = lastAttempted.filter { currentIDs.contains($0.key) }
            let ordered = records.sorted {
                (lastAttempted[$0.id] ?? .distantPast, $0.id) < (lastAttempted[$1.id] ?? .distantPast, $1.id)
            }
            for record in ordered {
                try Task.checkCancellation()
                if let last = lastAttempted[record.id], Date.now.timeIntervalSince(last) < 15 * 60 { continue }
                if privacy.hidesNSFWSources || privacy.requiresNSFWUnlock {
                    if try hiddenSourceIDs().contains(record.sourceID) { continue }
                }
                let context = ModelContext(container)
                let sourceID = record.sourceID
                let descriptor = FetchDescriptor<PluginRecord>(predicate: #Predicate { $0.uuid == sourceID && $0.enabled })
                guard let plugin = try context.fetch(descriptor).first else { continue }
                let pluginVersion = plugin.bundlePath
                lastAttempted[record.id] = .now
                do {
                    let detail = try await PluginService.shared.detail(plugin: plugin, comicID: record.comicID)
                    try Task.checkCancellation()
                    let current = try ModelContext(container).fetch(descriptor).first
                    guard current?.bundlePath == pluginVersion else { continue }
                    let chapters = detail.chapters.map { FollowedComicSnapshot.Chapter(id: $0.id, title: $0.title) }
                    if try await store.observe(chapters, for: record.id, expectedRevision: record.revision, in: container) {
                        changed = true
                        await deliverNotifications()
                    }
                } catch is CancellationError {
                    if Task.isCancelled { break }
                } catch {
                    logger.debug("Could not check a followed comic for updates")
                }
            }
        } catch is CancellationError {
            return changed
        } catch {
            logger.error("Could not load followed comics")
        }

        return changed
    }

    func deliverNotifications() async {
        guard !Task.isCancelled else { return }
        if deliveringNotifications {
            needsNotificationPass = true
            return
        }
        deliveringNotifications = true
        defer { deliveringNotifications = false }
        repeat {
            needsNotificationPass = false
            do {
                try await deliverPendingNotifications()
            } catch is CancellationError {
                return
            } catch {
                logger.error("Could not deliver followed comic updates")
            }
        } while needsNotificationPass
    }

    private func deliverPendingNotifications() async throws {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else { return }
        guard settings.alertSetting == .enabled || settings.notificationCenterSetting == .enabled else { return }
        let pending = try await store.pendingNotifications(in: container)
        let hiddenSources = try hiddenSourceIDs()
        for record in pending where !hiddenSources.contains(record.sourceID) {
            try Task.checkCancellation()
            guard let chapter = record.updateChapter else { continue }
            let content = UNMutableNotificationContent()
            content.title = record.title.isEmpty ? record.comicID : record.title
            content.body = chapter.title.isEmpty
                ? L10n.text("Following.Notification.NewChapter")
                : L10n.text("Following.Notification.Chapter", defaultValue: "Updated to \(chapter.title)")
            content.sound = .default
            content.categoryIdentifier = ComicUpdateNotifications.category
            content.userInfo = [ComicUpdateNotifications.comicKeyField: record.id]
            let request = UNNotificationRequest(identifier: ComicUpdateNotifications.identifier(for: record.id),
                                                content: content, trigger: nil)
            do {
                try await center.add(request)
                if try await !store.noteNotification(for: record.id, chapterID: chapter.id, in: container) {
                    clearNotification(for: record.id)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error("Could not schedule a followed comic update")
            }
        }
    }

    private func clearNotification(for id: String) {
        let identifier = ComicUpdateNotifications.identifier(for: id)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func hiddenSourceIDs() throws -> Set<String> {
        guard privacy.greenTravelEnabled else { return [] }
        let descriptor = FetchDescriptor<PluginContentRating>(predicate: #Predicate { $0.isNSFW })
        return Set(try ModelContext(container).fetch(descriptor).map(\.sourceID))
    }
}
