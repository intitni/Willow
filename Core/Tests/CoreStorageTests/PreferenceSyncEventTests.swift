@testable import CoreStorage
import Foundation
import SwiftData
import Testing

@Suite("Preference sync events", .serialized)
@MainActor
struct PreferenceSyncEventTests {
    private func waitUntil(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try !condition() {
            try #require(ContinuousClock.now < deadline, "Expected event-triggered reconciliation did not run.")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func explicitRequestTriggersSyncWithoutOtherEvents() async throws {
        let container = try WillowPersistence.make(inMemory: true).container
        let drive = try SyncTestFolder()
        defer { drive.remove() }
        let sync = drive.worker(container: container)
        let events = PreferenceSyncEvents(observesDirectory: false)
        let runner = Task {
            await events.run(context: container.mainContext, sync: sync, center: NotificationCenter())
        }
        defer { runner.cancel() }
        try await waitUntil { sync.viewModel.lastReconciledAt != nil }

        let startupCompleted = try #require(sync.viewModel.lastReconciledAt)
        events.request()
        try await waitUntil { sync.viewModel.lastReconciledAt != startupCompleted }
        runner.cancel()
        await runner.value
    }

    @Test func savesTriggerSyncAndCancellationRemovesObservers() async throws {
        let container = try WillowPersistence.make(inMemory: true).container
        let context = container.mainContext
        let drive = try SyncTestFolder()
        defer { drive.remove() }
        let sync = drive.worker(container: container)
        let events = PreferenceSyncEvents()
        let runner = Task { await events.run(context: context, sync: sync) }
        defer { runner.cancel() }
        try await waitUntil { sync.viewModel.lastReconciledAt != nil }

        let comic = ComicRecord(sourceID: "test", comicID: "comic", title: "Comic")
        comic.isFavorite = true
        context.insert(comic)
        try context.save()
        try await waitUntil { try drive.revisions().contains { $0.key.hasPrefix("favorite/") } }

        let subscription = SubscriptionRecord(url: "https://example.com/catalog", name: "Initial")
        context.insert(subscription)
        try context.save()
        try await waitUntil {
            try drive.revisions().count == 2
        }
        subscription.name = "Updated"
        try context.save()
        try await waitUntil {
            try drive.revisions().count == 3
        }
        context.delete(subscription)
        try context.save()
        try await waitUntil {
            let rows = try drive.revisions().filter { $0.key.hasPrefix("subscription/") }
            return rows.count == 3 && rows.max(by: { $0.modifiedAt < $1.modifiedAt })?.deleted == true
        }
        runner.cancel()
        await runner.value
        let stopped = sync.viewModel.lastReconciledAt
        context.insert(SubscriptionRecord(url: "https://example.com/second", name: "After stop"))
        try context.save()
        try await Task.sleep(for: .milliseconds(80))
        #expect(sync.viewModel.lastReconciledAt == stopped)
        #expect(try drive.revisions().count == 4, "Reconciliation must not publish duplicate revisions or publish after cancellation.")
    }

    @Test func pageSavesStayLocalUntilRequested() async throws {
        let container = try WillowPersistence.make(inMemory: true).container
        let context = container.mainContext
        let drive = try SyncTestFolder()
        defer { drive.remove() }
        let comic = ComicRecord(sourceID: "test", comicID: "comic", title: "Comic")
        context.insert(comic)
        try context.save()
        let sync = drive.worker(container: container)
        let events = PreferenceSyncEvents(observesDirectory: false)
        let runner = Task { await events.run(context: context, sync: sync) }
        defer { runner.cancel() }
        try await waitUntil { sync.viewModel.lastReconciledAt != nil }
        let startup = sync.viewModel.lastReconciledAt

        for index in 1...4 {
            try events.savePageProgress(in: context) {
                comic.chapterID = "chapter"
                comic.pageIndex = index
                comic.lastReadAt = .now
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(sync.viewModel.lastReconciledAt == startup)
        #expect(try drive.revisions().isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<ComicRecord>()).first?.pageIndex == 4)

        let invalidRevision = drive.directory.directory.appending(path: UUID().uuidString + ".record")
        try Data("invalid revision".utf8).write(to: invalidRevision)
        events.request()
        try await waitUntil { sync.viewModel.error != nil }
        #expect(sync.viewModel.lastReconciledAt == startup)
        try FileManager.default.removeItem(at: invalidRevision)

        // Exiting the reader must still request a pass after the first one failed.
        events.requestPendingPageProgress()
        try await waitUntil { sync.viewModel.lastReconciledAt != startup }
        let revisions = try drive.revisions()
        let revision = try #require(revisions.first)
        let payload = try JSONDecoder().decode(PreferencePayload.self, from: #require(revision.payload))
        guard case .reading(let progress) = payload else {
            Issue.record("Expected the latest reading position.")
            return
        }
        #expect(revisions.count == 1)
        #expect(progress.pageIndex == 4)
        runner.cancel()
        await runner.value
    }

    @Test func closingFirstWindowKeepsRemainingWindowSubscribed() async throws {
        let container = try WillowPersistence.make(inMemory: true).container
        let context = container.mainContext
        let drive = try SyncTestFolder()
        defer { drive.remove() }
        let sync = drive.worker(container: container)
        let events = PreferenceSyncEvents()
        let first = Task { await events.run(context: context, sync: sync) }
        defer { first.cancel() }
        try await waitUntil { sync.viewModel.lastReconciledAt != nil }
        let second = Task { await events.run(context: context, sync: sync) }
        defer { second.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        first.cancel()
        await first.value

        try await ReadChapterStore.shared.recordOpen(comicKey: "comic", chapterID: "chapter", at: .now, in: context.container)
        try await waitUntil {
            try drive.revisions().count == 1
        }
        let follow = FollowedComicSnapshot(sourceID: "test", comicID: "comic", title: "Comic",
                                           coverURL: "", author: "", summary: "")
        try await FollowedComicStore.shared.setFollowing(follow, in: container)
        try await waitUntil { try drive.revisions().contains { $0.isFollowedComic } }

        second.cancel()
        await second.value
        let stopped = sync.viewModel.lastReconciledAt
        context.insert(SubscriptionRecord(url: "https://example.com/closed", name: "All windows closed"))
        try context.save()
        events.request()
        try await Task.sleep(for: .milliseconds(80))
        #expect(sync.viewModel.lastReconciledAt == stopped)
        #expect(try drive.revisions().count == 2)

        // Reopening after all windows close starts a fresh observer and catches up.
        let reopened = Task { await events.run(context: context, sync: sync) }
        defer { reopened.cancel() }
        try await waitUntil {
            try drive.revisions().count == 3
        }
        reopened.cancel()
        await reopened.value
    }

}
