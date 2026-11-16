@testable import CoreStorage
import Foundation
import SwiftData
import Testing

@MainActor
struct FollowedComicTests {
    private let store = FollowedComicStore.shared
    private let comic = FollowedComicSnapshot(sourceID: "fixture", comicID: "series", title: "Series",
                                              coverURL: "", author: "", summary: "")
    private let first = FollowedComicSnapshot.Chapter(id: "one", title: "Chapter 1")
    private let second = FollowedComicSnapshot.Chapter(id: "two", title: "Chapter 2")
    private let third = FollowedComicSnapshot.Chapter(id: "three", title: "Chapter 3")

    @Test func firstCheckSetsBaselineAndOnlyNewChaptersCreateUnreadUpdates() async throws {
        let device = try WillowPersistence.make(inMemory: true).container
        try await store.setFollowing(comic, in: device)
        let followed = try await current(in: device)
        try await store.observe([first], for: comic.id, expectedRevision: followed.revision, in: device)
        let baseline = try await current(in: device)
        #expect(baseline.knownChapterIDs == [first.id])
        #expect(!baseline.hasUnreadUpdate)

        try await store.observe([first, second, third], for: comic.id, expectedRevision: baseline.revision, in: device)
        let updated = try await current(in: device)
        #expect(updated.hasUnreadUpdate)
        #expect(updated.updateChapter == third)
        #expect(try await store.pendingNotifications(in: device) == [updated])

        try await store.markOpened(comic.id, in: device)
        let opened = try await current(in: device)
        #expect(!opened.hasUnreadUpdate)
        #expect(opened.updatedAt > updated.updatedAt)
        #expect(try await store.pendingNotifications(in: device).isEmpty)

        // A temporary disappearance and reappearance is not a new release.
        #expect(try await !store.observe([first], for: comic.id, expectedRevision: opened.revision, in: device))
        #expect(try await !store.observe([first, second, third], for: comic.id,
                                        expectedRevision: opened.revision, in: device))
    }

    @Test func syncImportsUnreadAndDeduplicatesNotificationsPerDevice() async throws {
        let a = try WillowPersistence.make(inMemory: true).container
        let b = try WillowPersistence.make(inMemory: true).container
        let drive = try SyncTestFolder()
        defer { drive.remove() }
        let syncA = drive.worker(container: a)
        let imports = ImportCounter()
        let syncB = drive.worker(container: b, didImportFollowing: { await imports.increment() })

        var initial = comic
        initial.knownChapterIDs = [first.id]
        try await store.setFollowing(initial, in: a)
        let followed = try await current(in: a)
        try await store.observe([first, second], for: comic.id, expectedRevision: followed.revision, in: a)
        let updated = try await current(in: a)
        #expect(try await store.noteNotification(for: comic.id, chapterID: second.id, in: a))
        #expect(try await store.pendingNotifications(in: a).isEmpty)
        try await syncA.reconcile()
        try await syncB.reconcile()
        #expect(try await current(in: b) == updated)
        #expect(try await store.pendingNotifications(in: b) == [updated])
        #expect(await imports.count == 1)
        #expect(try drive.revisions().allSatisfy { $0.filename.hasSuffix(".follow") })

        #expect(try await store.noteNotification(for: comic.id, chapterID: second.id, in: b))
        try await syncB.reconcile()
        #expect(try await store.pendingNotifications(in: b).isEmpty)
        #expect(await imports.count == 1)
        #expect(try drive.revisions().count == 1)

        try await store.markOpened(comic.id, in: b)
        try await syncB.reconcile()
        try await syncA.reconcile()
        #expect(try await !current(in: a).hasUnreadUpdate)
        #expect(try await store.pendingNotifications(in: a).isEmpty)
    }

    @Test func unfollowWinsAgainstALaterOfflineCheckAndLateResults() async throws {
        let a = try WillowPersistence.make(inMemory: true).container
        let b = try WillowPersistence.make(inMemory: true).container
        let drive = try SyncTestFolder()
        defer { drive.remove() }
        let syncA = drive.worker(container: a)
        let syncB = drive.worker(container: b)

        var initial = comic
        initial.knownChapterIDs = [first.id]
        try await store.setFollowing(initial, in: a)
        try await syncA.reconcile()
        try await syncB.reconcile()
        let followed = try await current(in: b)
        var unfollowed = comic
        unfollowed.isFollowing = false
        try await store.setFollowing(unfollowed, in: a)
        let tombstone = try await current(in: a)
        #expect(try await !store.observe([first, second], for: comic.id,
                                        expectedRevision: followed.revision, in: a))

        // Model a newer background edit made on B before it saw the unfollow.
        var offlineUpdate = followed
        offlineUpdate.updateChapter = second
        offlineUpdate.hasUnreadUpdate = true
        offlineUpdate.knownChapterIDs = [first.id, second.id]
        offlineUpdate.advance(after: tombstone.updatedAt)
        #expect(try await store.merge([offlineUpdate], in: b))
        try await syncB.reconcile()
        try await syncA.reconcile()
        try await syncB.reconcile()
        #expect(try await current(in: a) == tombstone)
        #expect(try await current(in: b) == tombstone)
        #expect(try await store.pendingNotifications(in: b).isEmpty)
        #expect(try drive.revisions().contains(where: \.deleted))
    }

    @Test func aDelayedOrCancelledSyncDoesNotPublishAnOlderFollow() async throws {
        let a = try WillowPersistence.make(inMemory: true).container
        let b = try WillowPersistence.make(inMemory: true).container
        let drive = try SyncTestFolder()
        defer { drive.remove() }
        let syncA = drive.worker(container: a)
        try await store.setFollowing(comic, in: a)
        try await syncA.reconcile()
        var unfollowed = comic
        unfollowed.isFollowing = false
        try await store.setFollowing(unfollowed, in: a)
        try await syncA.reconcile()
        let revisions = try drive.revisions()
        let missing = try #require(revisions.first { $0.deleted }).filename

        let incomplete = drive.worker(container: b, readDriveRecord: { url in
            url.lastPathComponent == missing ? nil : try Data(contentsOf: url)
        })
        await #expect(throws: DriveSyncError.waitingForFiles) { try await incomplete.reconcile() }
        #expect(try await store.records(in: b, followingOnly: false).isEmpty)

        let syncB = drive.worker(container: b)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await syncB.reconcile()
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await store.records(in: b, followingOnly: false).isEmpty)

        try await syncB.reconcile()
        #expect(try await !current(in: b).isFollowing)
    }

    @Test func existingDeviceStoreKeepsDataWhenFollowingIsAdded() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "WillowDevice.store")
        let existingModels: [any PersistentModel.Type] = [
            PluginRecord.self, PluginContentRating.self, SubscriptionRecord.self, DownloadRecord.self,
            LocalTagRecord.self, PreferenceSyncCheckpoint.self, ReadChapterRecord.self,
        ]

        func open(_ models: [any PersistentModel.Type]) throws -> ModelContainer {
            let schema = Schema(models)
            let configuration = ModelConfiguration("WillowDevice", schema: schema, url: url, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: configuration)
        }

        do {
            let device = try open(existingModels)
            try LocalTagStore.create("Favorites", comicKey: comic.id, context: device.mainContext)
        }

        let upgradedModels = existingModels + [FollowedComicRecord.self]
        do {
            let upgraded = try open(upgradedModels)
            try await store.setFollowing(comic, in: upgraded)
        }
        let reopened = try open(upgradedModels)
        let tags = try reopened.mainContext.fetch(FetchDescriptor<LocalTagRecord>())
        #expect(tags.first?.comicKeys == [comic.id])
        #expect(try await current(in: reopened).isFollowing)
    }

    private func current(in device: ModelContainer) async throws -> FollowedComicSnapshot {
        let records = try await store.records(in: device, followingOnly: false)
        return try #require(records.first)
    }
}

private actor ImportCounter {
    private(set) var count = 0

    func increment() { count += 1 }
}
