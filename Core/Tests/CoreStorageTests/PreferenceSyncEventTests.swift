import CoreStorage
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

    @Test func savesTriggerSyncAndCancellationRemovesObservers() async throws {
        let container = try WillowPersistence.make(inMemory: true).container
        let context = container.mainContext
        let sync = PreferenceSyncModel(container: container)
        let events = PreferenceSyncEvents()
        let runner = Task { await events.run(context: context, sync: sync) }
        defer { runner.cancel() }
        try await waitUntil { sync.viewModel.lastReconciledAt != nil }
        let startupDate = sync.viewModel.lastReconciledAt

        // Reading progress is already synced directly by SwiftData and should not
        // wake the plugin/tag coordinator.
        context.insert(ComicRecord(sourceID: "test", comicID: "comic", title: "Comic"))
        try context.save()
        try await Task.sleep(for: .milliseconds(80))
        #expect(sync.viewModel.lastReconciledAt == startupDate)

        let subscription = SubscriptionRecord(url: "https://example.com/catalog", name: "Initial")
        context.insert(subscription)
        try context.save()
        try await waitUntil {
            try ModelContext(container).fetchCount(FetchDescriptor<PreferenceSyncRecord>()) == 1
        }
        subscription.name = "Updated"
        try context.save()
        try await waitUntil {
            try ModelContext(container).fetchCount(FetchDescriptor<PreferenceSyncRecord>()) == 2
        }
        context.delete(subscription)
        try context.save()
        try await waitUntil {
            let rows = try ModelContext(container).fetch(FetchDescriptor<PreferenceSyncRecord>())
            return rows.count == 3 && rows.max(by: { $0.modifiedAt < $1.modifiedAt })?.deleted == true
        }
        let completed = sync.viewModel.lastReconciledAt
        try await Task.sleep(for: .milliseconds(80))
        #expect(sync.viewModel.lastReconciledAt == completed, "Worker saves must not trigger feedback loops.")

        // An explicit lifecycle event triggers reconciliation without a save.
        events.request()
        try await waitUntil { sync.viewModel.lastReconciledAt != completed }
        runner.cancel()
        await runner.value
        let stopped = sync.viewModel.lastReconciledAt
        context.insert(SubscriptionRecord(url: "https://example.com/second", name: "After stop"))
        try context.save()
        try await Task.sleep(for: .milliseconds(80))
        #expect(sync.viewModel.lastReconciledAt == stopped)
    }
    @Test func closingFirstWindowKeepsRemainingWindowSubscribed() async throws {
        let container = try WillowPersistence.make(inMemory: true).container
        let context = container.mainContext
        let sync = PreferenceSyncModel(container: container)
        let events = PreferenceSyncEvents()
        let first = Task { await events.run(context: context, sync: sync) }
        defer { first.cancel() }
        try await waitUntil { sync.viewModel.lastReconciledAt != nil }
        let second = Task { await events.run(context: context, sync: sync) }
        defer { second.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        first.cancel()
        await first.value

        context.insert(SubscriptionRecord(url: "https://example.com/remaining", name: "Remaining window"))
        try context.save()
        try await waitUntil {
            try ModelContext(container).fetchCount(FetchDescriptor<PreferenceSyncRecord>()) == 1
        }
        let completed = sync.viewModel.lastReconciledAt
        events.request()
        try await waitUntil { sync.viewModel.lastReconciledAt != completed }

        second.cancel()
        await second.value
        let stopped = sync.viewModel.lastReconciledAt
        context.insert(SubscriptionRecord(url: "https://example.com/closed", name: "All windows closed"))
        try context.save()
        events.request()
        try await Task.sleep(for: .milliseconds(80))
        #expect(sync.viewModel.lastReconciledAt == stopped)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PreferenceSyncRecord>()) == 1)

        // Reopening after all windows close starts a fresh observer and catches up.
        let reopened = Task { await events.run(context: context, sync: sync) }
        defer { reopened.cancel() }
        try await waitUntil {
            try ModelContext(container).fetchCount(FetchDescriptor<PreferenceSyncRecord>()) == 2
        }
        reopened.cancel()
        await reopened.value
    }

}
