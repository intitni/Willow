import CoreData
import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Owns UI lifecycle notifications only; all storage work runs on PreferenceSyncModel.
@MainActor
package final class PreferenceSyncEvents {
    private var continuation: AsyncStream<Void>.Continuation?
    private var clients: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var worker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var notificationCenter: NotificationCenter?

    package init() {}

    package func request() { continuation?.yield(()) }

    package func run(context: ModelContext, sync: PreferenceSyncModel, center: NotificationCenter = .default) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { client in
                guard !Task.isCancelled else { client.resume(); return }
                clients[id] = client
                if worker == nil { start(context: context, sync: sync, center: center) }
            }
        } onCancel: {
            Task { @MainActor in await self.removeClient(id) }
        }
    }

    private func start(context: ModelContext, sync: PreferenceSyncModel, center: NotificationCenter) {
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        // Observe the UI context, not the worker's contexts, so applying cloud
        // changes cannot trigger an endless loop of our own saves.
        notificationCenter = center
        observers = [center.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { notification in
            if Self.containsPreferenceChanges(notification) { continuation.yield(()) }
        }]
        observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: nil) { notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                  event.type == .import, event.endDate != nil else { return }
            continuation.yield(())
        })
        #if canImport(UIKit)
        observers.append(center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil) { _ in
            continuation.yield(())
        })
        #endif
        continuation.yield(()) // Startup / reattachment catches changes made without observers.
        worker = Task {
            for await _ in events {
                if Task.isCancelled { return }
                do { try await sync.reconcile() }
                catch { /* The actor publishes errors; retry on the next event. */ }
            }
        }
    }

    private func removeClient(_ id: UUID) async {
        guard let client = clients.removeValue(forKey: id) else { return }
        if clients.isEmpty {
            // Tear down this generation before awaiting, so a newly opened window
            // can start a new one without the old worker removing its observers.
            let previousWorker = worker
            worker = nil
            if let notificationCenter { observers.forEach(notificationCenter.removeObserver) }
            observers.removeAll()
            notificationCenter = nil
            continuation?.finish()
            continuation = nil
            previousWorker?.cancel()
            await previousWorker?.value
        }
        client.resume()
    }

    nonisolated private static func containsPreferenceChanges(_ notification: Notification) -> Bool {
        let names: Set<String> = ["PluginRecord", "SubscriptionRecord", "LocalTagRecord"]
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        return keys.contains { key in
            let value = notification.userInfo?[key] ?? notification.userInfo?[key.rawValue]
            let identifiers = (value as? [PersistentIdentifier]) ?? Array(value as? Set<PersistentIdentifier> ?? [])
            return identifiers.contains { names.contains($0.entityName) }
        }
    }
}
