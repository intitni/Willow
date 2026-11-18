import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Owns UI lifecycle notifications only; all storage work runs on PreferenceSyncModel.
@MainActor
package final class PreferenceSyncEvents {
    private let observesDirectory: Bool
    private var continuation: AsyncStream<Void>.Continuation?
    private var clients: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var worker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var storageObservers: [NSObjectProtocol] = []
    private var notificationCenter: NotificationCenter?
    private var drivePresenter: DriveSyncPresenter?
    private var isSavingPageProgress = false
    private var pendingPageProgress: UUID?

    package init(observesDirectory: Bool = true) {
        self.observesDirectory = observesDirectory
    }

    package func request() { continuation?.yield(()) }

    package func savePageProgress(in context: ModelContext, update: () -> Void) throws {
        // An unrelated edit already pending in this context still needs its usual save event.
        isSavingPageProgress = !context.hasChanges
        defer { isSavingPageProgress = false }
        update()
        try context.save()
        pendingPageProgress = UUID()
    }

    package func requestPendingPageProgress() {
        guard pendingPageProgress != nil else { return }
        request()
    }

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
        observers = [center.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { [weak self] notification in
            guard Self.containsPreferenceChanges(notification) else { return }
            // This observer only receives saves from the UI's main context.
            MainActor.assumeIsolated {
                if self?.isSavingPageProgress == false { self?.request() }
            }
        }]
        storageObservers = [ReadChapterStore.didRecordOpen, FollowedComicStore.didEdit].map { name in
            NotificationCenter.default.addObserver(forName: name, object: context.container, queue: nil) { _ in
                continuation.yield(())
            }
        }
        if observesDirectory, let directory = sync.directory {
            let presenter = DriveSyncPresenter(directory: directory) { continuation.yield(()) }
            drivePresenter = presenter
            presenter.start()
            #if canImport(UIKit)
            observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { presenter.stop() }
            })
            observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { presenter.start() }
                continuation.yield(())
            })
            #endif
        }
        #if canImport(UIKit)
        observers.append(center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil) { _ in
            continuation.yield(())
        })
        #endif
        continuation.yield(()) // Startup / reattachment catches changes made without observers.
        worker = Task { [weak self] in
            for await _ in events {
                if Task.isCancelled { return }
                let pending = self?.pendingPageProgress
                do {
                    try await sync.reconcile()
                    // A failed or cancelled pass, or a newer page save during it,
                    // leaves progress eligible for the next lifecycle event.
                    if !Task.isCancelled, let pending, self?.pendingPageProgress == pending {
                        self?.pendingPageProgress = nil
                    }
                } catch { /* The actor publishes errors; retry on the next event. */ }
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
            storageObservers.forEach(NotificationCenter.default.removeObserver)
            storageObservers.removeAll()
            observers.removeAll()
            notificationCenter = nil
            drivePresenter?.stop()
            drivePresenter = nil
            continuation?.finish()
            continuation = nil
            previousWorker?.cancel()
            await previousWorker?.value
        }
        client.resume()
    }

    nonisolated private static func containsPreferenceChanges(_ notification: Notification) -> Bool {
        let names: Set<String> = ["PluginRecord", "PluginContentRating", "SubscriptionRecord", "LocalTagRecord", "ComicRecord"]
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        return keys.contains { key in
            let value = notification.userInfo?[key] ?? notification.userInfo?[key.rawValue]
            let identifiers = (value as? [PersistentIdentifier]) ?? Array(value as? Set<PersistentIdentifier> ?? [])
            return identifiers.contains { names.contains($0.entityName) }
        }
    }
}

/// Observes subitems of the selected directory, including arrival of evicted files.
@MainActor
private final class DriveSyncPresenter: NSObject, NSFilePresenter {
    nonisolated let presentedItemURL: URL?
    nonisolated let presentedItemOperationQueue = OperationQueue()
    private nonisolated let changed: @Sendable () -> Void
    private let directory: DriveSyncDirectory
    private var observing = false

    init(directory: DriveSyncDirectory, changed: @escaping @Sendable () -> Void) {
        self.directory = directory
        presentedItemURL = directory.root
        self.changed = changed
        super.init()
    }

    func start() {
        guard !observing, !directory.securityScoped || directory.root.startAccessingSecurityScopedResource() else { return }
        observing = true
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        guard observing else { return }
        observing = false
        NSFileCoordinator.removeFilePresenter(self)
        if directory.securityScoped { directory.root.stopAccessingSecurityScopedResource() }
    }

    nonisolated func presentedItemDidChange() { changed() }
    nonisolated func presentedSubitemDidAppear(at url: URL) { changed() }
    nonisolated func presentedSubitemDidChange(at url: URL) { changed() }
    nonisolated func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
}
