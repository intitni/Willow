import BreezeRuntime
import Foundation
import Observation
import SwiftData

@MainActor @Observable
package final class PreferenceSyncViewModel {
    package fileprivate(set) var error: String?
    package fileprivate(set) var lastReconciledAt: Date?

    fileprivate func completed(error: String?) {
        self.error = error
        if error == nil { lastReconciledAt = .now }
    }
}

package actor PreferenceSyncModel {
    package nonisolated let viewModel: PreferenceSyncViewModel
    private let container: ModelContainer
    private let files: PluginSyncFiles
    private let unloadPlugin: @Sendable (String) async throws -> Void
    private let drive: Result<DriveSyncDirectory, any Error>
    private let driveKey: (@Sendable (UUID) throws -> Data)?
    private let didImportFollowing: @Sendable () async -> Void
    private let readDriveRecord: (@Sendable (URL) throws -> Data?)?
    private(set) var isStopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var reconciling = false
    private var rerun = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    @MainActor package init(container: ModelContainer, folder: DriveSyncFolder,
                            didImportFollowing: @escaping @Sendable () async -> Void = {}) {
        self.init(container: container, drive: Result { try DriveSyncDirectory(folder: folder) },
                  didImportFollowing: didImportFollowing)
    }

    @MainActor init(container: ModelContainer, drive: Result<DriveSyncDirectory, any Error>,
                    files: PluginSyncFiles = PluginSyncFiles(),
                    driveKey: (@Sendable (UUID) throws -> Data)? = nil,
                    readDriveRecord: (@Sendable (URL) throws -> Data?)? = nil,
                    didImportFollowing: @escaping @Sendable () async -> Void = {},
                    unloadPlugin: @escaping @Sendable (String) async throws -> Void = { try await PluginRuntime.shared.unload(id: $0) }) {
        viewModel = PreferenceSyncViewModel()
        self.container = container
        self.drive = drive
        self.driveKey = driveKey
        self.readDriveRecord = readDriveRecord
        self.didImportFollowing = didImportFollowing
        self.files = files
        self.unloadPlugin = unloadPlugin
    }

    nonisolated var directory: DriveSyncDirectory? { try? drive.get() }

    package func stop() async {
        isStopped = true
        if reconciling { await withCheckedContinuation { stopWaiters.append($0) } }
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        if isStopped { throw CancellationError() }
    }

    private func finish() {
        reconciling = false
        let pending = stopWaiters
        stopWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    // Concurrent triggers share the current run and request one follow-up pass.
    // No timer or recurring task is kept alive between events.
    package func reconcile() async throws {
        try checkActive()
        if reconciling {
            rerun = true
            let id = UUID()
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                        else { waiters[id] = continuation }
                    }
                } onCancel: {
                    Task { await self.cancelWaiter(id) }
                }
            } catch is CancellationError {
                // An expired background request must not discard a live foreground trigger.
                try checkActive()
                try await reconcile()
            }
            try checkActive()
            return
        }
        reconciling = true
        defer { finish() }
        do {
            repeat {
                rerun = false
                try checkActive()
                try await reconcilePass()
                try checkActive()
                await viewModel.completed(error: nil)
            } while rerun
            let pending = Array(waiters.values)
            waiters.removeAll()
            pending.forEach { $0.resume() }
        } catch {
            if !(error is CancellationError) { await viewModel.completed(error: error.localizedDescription) }
            let pending = Array(waiters.values)
            waiters.removeAll()
            pending.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    // Contexts and all model objects are created and consumed on this actor.
    private func reconcilePass() async throws {
        let directory = try drive.get()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let encryptionKey: DriveSyncKey
        if let driveKey {
            encryptionKey = try DriveSyncKey(driveKey(directory.id))
            try directory.verify(key: encryptionKey)
        } else {
            encryptionKey = try DriveSyncKey(directory.recoveryKey())
        }
        let read = try directory.readRevisions(key: encryptionKey, readRecord: readDriveRecord)
        var firstError = read.chapterError
        let remote = Dictionary(grouping: read.revisions.filter { !$0.isFollowedComic }, by: \.key).compactMapValues { records in
            records.max { $0.precedes($1) }
        }
        let prefix = "drive/" + directory.id.uuidString + "/"
        let checkpoints = Dictionary(try context.fetch(FetchDescriptor<PreferenceSyncCheckpoint>())
            .filter { $0.key.hasPrefix(prefix) }
            .map { (String($0.key.dropFirst(prefix.count)), $0) }, uniquingKeysWith: { a, _ in a })
        do {
            try await reconcileReadChapters(remote: remote, checkpoints: checkpoints, prefix: prefix,
                                            directory: directory, encryptionKey: encryptionKey, context: context)
        } catch let error as CancellationError {
            throw error
        } catch {
            context.rollback()
            firstError = firstError ?? error
        }
        // Missing ordinary revisions may contain deletions. Chapter history
        // only adds observations and can already merge the records available.
        if !read.isComplete { throw read.error ?? DriveSyncError.waitingForFiles }
        do {
            try reconcilePluginRatings(remote: remote, checkpoints: checkpoints, prefix: prefix,
                                       directory: directory, encryptionKey: encryptionKey, context: context)
        } catch let error as CancellationError {
            throw error
        } catch {
            context.rollback()
            firstError = firstError ?? error
        }
        do {
            try await reconcileFollowing(read.revisions.filter(\.isFollowedComic), directory: directory, encryptionKey: encryptionKey)
        } catch let error as CancellationError {
            throw error
        } catch {
            firstError = firstError ?? error
        }
        let plugins = try context.fetch(FetchDescriptor<PluginRecord>())
        var local: [String: PreferencePayload] = [:]
        var pluginPaths: [String: String] = [:]
        var unavailable = Set<String>()
        var missingFiles = Set<String>()

        for plugin in plugins {
            let key = "plugin/" + plugin.uuid
            let path = plugin.bundlePath
            pluginPaths[key] = path
            do {
                let digest = try await files.digest(path: path)
                local[key] = .plugin(snapshot(plugin, digest: digest))
            } catch {
                // 换机或文件丢失时优先恢复云端副本，不把缺失文件误当成卸载。
                if let record = remote[key],
                   let data = record.payload,
                   case .plugin(let value) = try JSONDecoder().decode(PreferencePayload.self, from: data) {
                    // File recovery must apply one complete cloud version. Never publish
                    // local metadata paired with a different version's cloud script.
                    local[key] = .plugin(snapshot(plugin, digest: value.digest))
                    missingFiles.insert(key)
                } else {
                    unavailable.insert(key)
                    firstError = firstError ?? error
                }
            }
        }
        try checkActive()
        var readingEvents: [String: (payload: PreferencePayload, date: Date, deleted: Bool)] = [:]
        for record in try context.fetch(FetchDescriptor<ComicRecord>()) {
            let comic = PreferencePayload.Comic(record)
            if record.isFavorite {
                let value = PreferencePayload.favorite(comic)
                local[value.key] = value
            }
            if let date = record.lastReadingEventAt {
                let deleted = record.lastReadAt == nil || date != record.lastReadAt
                let value = PreferencePayload.reading(.init(comic: comic, lastReadAt: date,
                                                            chapterID: deleted ? nil : record.chapterID,
                                                            pageIndex: deleted ? 0 : record.pageIndex))
                if let existing = readingEvents[value.key], existing.date > date || (existing.date == date && existing.deleted) { continue }
                readingEvents[value.key] = (value, date, deleted)
            }
        }
        for subscription in try context.fetch(FetchDescriptor<SubscriptionRecord>()) {
            let value = PreferencePayload.subscription(.init(url: subscription.url, name: subscription.name))
            local[value.key] = value
        }
        for tag in try context.fetch(FetchDescriptor<LocalTagRecord>()) {
            let value = PreferencePayload.tag(.init(normalizedName: tag.normalizedName, name: tag.name))
            local[value.key] = value
            for comicKey in Set(tag.comicKeys) {
                let link = PreferencePayload.tagLink(.init(normalizedName: tag.normalizedName, comicKey: comicKey))
                local[link.key] = link
            }
        }

        try reconcileReading(readingEvents, remote: remote, checkpoints: checkpoints,
                             prefix: prefix, directory: directory, encryptionKey: encryptionKey, context: context)
        // 标签定义先于关联处理；文件操作放在最后，避免等待文件时覆盖标签编辑。
        let keys = Set(local.keys).union(remote.keys).union(checkpoints.keys).subtracting(unavailable)
            .filter { !$0.hasPrefix("reading/") && !$0.hasPrefix(PreferencePayload.PluginRating.keyPrefix) }.sorted {
            func order(_ key: String) -> Int { key.hasPrefix("tag/") ? 0 : key.hasPrefix("tag-link/") ? 1 : key.hasPrefix("plugin/") ? 3 : 2 }
            return order($0) == order($1) ? $0 < $1 : order($0) < order($1)
        }
        for key in keys {
            try checkActive()
            do {
                let value = local[key]
                let bytes = try value?.encoded()
                let checkpoint = checkpoints[key]
                let cloud = remote[key]
                let newestDate = max(cloud?.orderingDate ?? .distantPast, checkpoint?.modifiedAt ?? .distantPast)
                let changed = try (checkpoint != nil || cloud == nil) &&
                    changedLocally(value, comparedTo: checkpoint?.payload, encoded: bytes)
                if changed && !missingFiles.contains(key) {
                    var driveAsset: (digest: String, data: Data)?
                    if case .plugin(let plugin) = value {
                        guard let path = pluginPaths[key], pluginUnchanged(plugin, path: path) else { continue }
                        let data = try await files.read(path: path)
                        guard try await files.digest(path: path) == plugin.digest,
                              pluginUnchanged(plugin, path: path) else { continue }
                        try checkActive()
                        driveAsset = (plugin.digest, data)
                    }
                    let date = max(Date.now, newestDate.addingTimeInterval(0.001))
                    let record = SyncRevision(key: key, payload: bytes ?? checkpoint?.payload, modifiedAt: date,
                                              deleted: value == nil, seed: checkpoint == nil ? true : nil)
                    try directory.publish(record, asset: driveAsset, key: encryptionKey)
                    saveCheckpoint(key: prefix + key, bytes: bytes, revision: record.revision, modifiedAt: record.orderingDate, path: pluginPaths[key], existing: checkpoint, context: context)
                    try context.save()
                } else if let cloud,
                          cloud.revision != checkpoint?.revision || missingFiles.contains(key),
                          checkpoint?.modifiedAt == nil ||
                            (cloud.orderingDate, cloud.revision) >= (checkpoint?.modifiedAt ?? .distantPast, checkpoint?.revision ?? "") {
                    guard let data = cloud.payload else { continue }
                    let payload = try JSONDecoder().decode(PreferencePayload.self, from: data)
                    guard payload.key == key else { throw URLError(.cannotParseResponse) }
                    let asset: Data?
                    if !cloud.deleted, case .plugin(let plugin) = payload {
                        asset = try directory.asset(plugin.digest, key: encryptionKey)
                    } else {
                        asset = nil
                    }
                    if case .plugin(let plugin) = payload {
                        if let path = pluginPaths[key], case .plugin(let baseline) = value {
                            guard pluginUnchanged(baseline, path: path) else { continue }
                        } else {
                            let id = plugin.id
                            let latest = ModelContext(container)
                            guard try latest.fetchCount(FetchDescriptor<PluginRecord>(predicate: #Predicate { $0.uuid == id })) == 0 else { continue }
                        }
                    }
                    let applied = try await apply(payload, deleted: cloud.deleted, asset: asset, context: context)
                    guard applied else { continue } // 资源文件或标签定义可能稍后到达。
                    let path: String?
                    if case .plugin(let plugin) = payload, !cloud.deleted { path = "\(plugin.id)-\(plugin.digest).cjs" } else { path = nil }
                    saveCheckpoint(key: prefix + key, bytes: cloud.deleted ? nil : data, revision: cloud.revision, modifiedAt: cloud.orderingDate, path: path, existing: checkpoint, context: context)
                    try context.save()
                }
            } catch {
                context.rollback()
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private func reconcileFollowing(
        _ revisions: [SyncRevision], directory: DriveSyncDirectory, encryptionKey: DriveSyncKey
    ) async throws {
        var remote: [String: FollowedComicSnapshot] = [:]
        for revision in revisions {
            try checkActive()
            guard let data = revision.payload,
                  case .followedComic(let value) = try JSONDecoder().decode(PreferencePayload.self, from: data),
                  value.updatedAt == revision.modifiedAt, value.revision.uuidString == revision.revision,
                  value.followingChangedAt <= value.updatedAt, value.isFollowing != revision.deleted else {
                throw URLError(.cannotParseResponse)
            }
            if remote[value.id].map({ $0.version < value.version }) ?? true {
                remote[value.id] = value
            }
        }

        let store = FollowedComicStore.shared
        let records = try await store.records(in: container, followingOnly: false)
        let local = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let ids = Set(local.keys).union(remote.keys)
        var imports: [FollowedComicSnapshot] = []
        for id in ids.sorted() {
            try checkActive()
            if let cloud = remote[id], local[id].map({ $0.version <= cloud.version }) ?? true {
                if local[id]?.revision != cloud.revision { imports.append(cloud) }
            } else if let value = local[id] {
                let payload = PreferencePayload.followedComic(value)
                let revision = SyncRevision(revision: value.revision.uuidString, key: payload.key,
                                            payload: try payload.encoded(), modifiedAt: value.updatedAt,
                                            deleted: !value.isFollowing)
                try directory.publish(revision, asset: nil, key: encryptionKey)
            }
        }
        try checkActive()
        if !imports.isEmpty, try await store.merge(imports, in: container) {
            await didImportFollowing()
        }
    }

    private func reconcilePluginRatings(
        remote: [String: SyncRevision],
        checkpoints: [String: PreferenceSyncCheckpoint],
        prefix: String,
        directory: DriveSyncDirectory,
        encryptionKey: DriveSyncKey,
        context: ModelContext
    ) throws {
        let ratingPrefix = PreferencePayload.PluginRating.keyPrefix
        let local = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<PluginContentRating>()).map {
            (ratingPrefix + $0.sourceID, $0)
        })
        let keys = Set(local.keys).union(remote.values.lazy.filter(\.isPluginRating).map(\.key))
        for key in keys.sorted() {
            try checkActive()
            let rating = local[key]
            let editedAt = rating?.updatedAt ?? .distantPast
            let checkpoint = checkpoints[key]
            let baseline = checkpoint?.modifiedAt ?? .distantPast
            let cloud = remote[key]

            if let rating,
               (cloud == nil && checkpoint == nil) || editedAt > max(baseline, cloud?.orderingDate ?? .distantPast) {
                let payload = PreferencePayload.pluginRating(.init(sourceID: rating.sourceID, isNSFW: rating.isNSFW))
                let bytes = try payload.encoded()
                let version = SyncRevision(key: key, payload: bytes, modifiedAt: editedAt, deleted: false)
                try directory.publish(version, asset: nil, key: encryptionKey)
                saveCheckpoint(key: prefix + key, bytes: bytes, revision: version.revision, modifiedAt: editedAt,
                               path: nil, existing: checkpoint, context: context)
            } else if let cloud, let bytes = cloud.payload, cloud.orderingDate >= editedAt,
                      (cloud.orderingDate, cloud.revision) >= (baseline, checkpoint?.revision ?? "") {
                guard case .pluginRating(let value) = try JSONDecoder().decode(PreferencePayload.self, from: bytes),
                      PluginIdentity.isValid(value.sourceID) else {
                    throw URLError(.cannotParseResponse)
                }
                if cloud.deleted {
                    if let rating { context.delete(rating) }
                } else if let rating {
                    if rating.isNSFW != value.isNSFW || rating.updatedAt != cloud.orderingDate {
                        rating.isNSFW = value.isNSFW
                        rating.updatedAt = cloud.orderingDate
                    }
                } else {
                    context.insert(PluginContentRating(sourceID: value.sourceID, isNSFW: value.isNSFW,
                                                       updatedAt: cloud.orderingDate))
                }
                if cloud.revision != checkpoint?.revision {
                    saveCheckpoint(key: prefix + key, bytes: cloud.deleted ? nil : bytes, revision: cloud.revision,
                                   modifiedAt: cloud.orderingDate, path: nil, existing: checkpoint, context: context)
                }
            }
            if context.hasChanges { try context.save() }
        }
    }

    private func reconcileReading(
        _ local: [String: (payload: PreferencePayload, date: Date, deleted: Bool)],
        remote: [String: SyncRevision],
        checkpoints: [String: PreferenceSyncCheckpoint],
        prefix: String,
        directory: DriveSyncDirectory,
        encryptionKey: DriveSyncKey,
        context: ModelContext
    ) throws {
        let keys = Set(local.keys).union(remote.values.lazy.filter { !$0.isReadChapter && $0.key.hasPrefix("reading/") }.map(\.key))
        for key in keys.sorted() {
            try checkActive()
            let checkpoint = checkpoints[key]
            let cloud = remote[key]
            let event = local[key]
            let currentBytes = try event?.payload.encoded()
            // Keep the observed event watermark if a newer file temporarily
            // disappears from the listing. Legacy checkpoints used export time.
            let baseline = try readingCheckpointDate(checkpoint)
            if let event, let currentBytes, event.date > baseline,
               cloud.map({ event.date > $0.orderingDate }) ?? true {
                let version = SyncRevision(key: key, payload: currentBytes, modifiedAt: event.date, deleted: event.deleted)
                try directory.publish(version, asset: nil, key: encryptionKey)
                saveCheckpoint(key: prefix + key, bytes: event.deleted ? nil : currentBytes,
                               revision: version.revision, modifiedAt: version.orderingDate, path: nil,
                               existing: checkpoint, context: context)
                try context.save()
            } else if let cloud, let data = cloud.payload,
                      (cloud.orderingDate, cloud.revision) >= (baseline, checkpoint?.revision ?? ""),
                      case .reading(let progress) = try JSONDecoder().decode(PreferencePayload.self, from: data) {
                // Even an already applied winner must replace an older local
                // event. This occurs when the local user reads on a slower clock.
                if cloud.revision == checkpoint?.revision,
                   event?.date == cloud.orderingDate,
                   event?.deleted == cloud.deleted,
                   cloud.deleted || matchesReadingPosition(event?.payload, progress) {
                    continue
                }
                for record in try comicRecords(progress.comic, deleted: false, context: context) {
                    if cloud.deleted {
                        record.clearHistory(at: cloud.orderingDate)
                    } else {
                        record.lastReadAt = progress.lastReadAt
                        record.historyClearedAt = nil
                        record.chapterID = progress.chapterID
                        record.pageIndex = progress.pageIndex
                    }
                }
                saveCheckpoint(key: prefix + key, bytes: cloud.deleted ? nil : data,
                               revision: cloud.revision, modifiedAt: cloud.orderingDate, path: nil,
                               existing: checkpoint, context: context)
                try context.save()
            }
        }
    }

    private func reconcileReadChapters(
        remote: [String: SyncRevision],
        checkpoints: [String: PreferenceSyncCheckpoint],
        prefix: String,
        directory: DriveSyncDirectory,
        encryptionKey: DriveSyncKey,
        context: ModelContext
    ) async throws {
        let local = Dictionary(try context.fetch(FetchDescriptor<ReadChapterRecord>()).map { record in
            let payload = PreferencePayload.readChapter(.init(comicKey: record.comicKey,
                                                              chapterID: record.chapterID, readAt: record.readAt))
            return (payload.key, (payload: payload, date: record.readAt))
        }, uniquingKeysWith: { $0.date >= $1.date ? $0 : $1 })
        var imports: [PreferencePayload.ReadChapter] = []
        let keys = Set(local.keys).union(remote.values.lazy.filter(\.isReadChapter).map(\.key))
        for key in keys {
            try checkActive()
            let checkpoint = checkpoints[key]
            let baseline = checkpoint?.modifiedAt ?? .distantPast
            let cloud = remote[key]
            let current = local[key]
            if let current, current.date > max(baseline, cloud?.orderingDate ?? .distantPast) {
                let bytes = try current.payload.encoded()
                let version = SyncRevision(key: key, payload: bytes, modifiedAt: current.date, deleted: false)
                try directory.publish(version, asset: nil, key: encryptionKey)
                saveCheckpoint(key: prefix + key, bytes: bytes, revision: version.revision, modifiedAt: current.date,
                               path: nil, existing: checkpoint, context: context)
            } else if let cloud, !cloud.deleted, let data = cloud.payload, cloud.orderingDate >= baseline {
                let payload = try JSONDecoder().decode(PreferencePayload.self, from: data)
                guard case .readChapter(let chapter) = payload, payload.key == key, chapter.readAt == cloud.orderingDate else {
                    throw URLError(.cannotParseResponse)
                }
                if chapter.readAt > (current?.date ?? .distantPast) {
                    imports.append(chapter)
                }
                if cloud.revision != checkpoint?.revision {
                    saveCheckpoint(key: prefix + key, bytes: data, revision: cloud.revision, modifiedAt: chapter.readAt,
                                   path: nil, existing: checkpoint, context: context)
                }
            }
        }
        if !imports.isEmpty { try await ReadChapterStore.shared.merge(imports, in: container) }
        try checkActive()
        if context.hasChanges { try context.save() }
    }

    private func matchesReadingPosition(_ current: PreferencePayload?, _ remote: PreferencePayload.Reading) -> Bool {
        guard case .reading(let current) = current else { return false }
        return current.chapterID == remote.chapterID && current.pageIndex == remote.pageIndex
    }

    private func readingCheckpointDate(_ checkpoint: PreferenceSyncCheckpoint?) throws -> Date {
        if let data = checkpoint?.payload,
           case .reading(let progress) = try JSONDecoder().decode(PreferencePayload.self, from: data) {
            return progress.lastReadAt
        }
        return checkpoint?.modifiedAt ?? .distantPast
    }

    private func changedLocally(_ current: PreferencePayload?, comparedTo previous: Data?, encoded: Data?) throws -> Bool {
        guard let current, let previous else { return encoded != previous }
        switch current {
        case .favorite:
            // Comic metadata can change when the title is opened or synced through
            // reading progress. Only the favorite operation changes this record.
            return false
        default:
            return encoded != previous
        }
    }

    private func saveCheckpoint(key: String, bytes: Data?, revision: String, modifiedAt: Date, path: String?, existing: PreferenceSyncCheckpoint?, context: ModelContext) {
        let checkpoint = existing ?? PreferenceSyncCheckpoint(key: key, payload: bytes, revision: revision)
        if existing == nil { context.insert(checkpoint) }
        checkpoint.payload = bytes
        checkpoint.revision = revision
        checkpoint.modifiedAt = modifiedAt
        checkpoint.localBundlePath = path
    }

    private func snapshot(_ plugin: PluginRecord, digest: String) -> PreferencePayload.Plugin {
        .init(id: plugin.uuid, name: plugin.name, version: plugin.version, subscriptionURL: plugin.subscriptionURL,
              enabled: plugin.enabled, info: plugin.infoJSON, digest: digest)
    }

    private func pluginUnchanged(_ value: PreferencePayload.Plugin, path: String) -> Bool {
        let context = ModelContext(container)
        let id = value.id
        guard let current = try? context.fetch(FetchDescriptor<PluginRecord>(predicate: #Predicate { $0.uuid == id })).first else { return false }
        return current.bundlePath == path && snapshot(current, digest: value.digest) == value
    }

    private func comicRecords(_ value: PreferencePayload.Comic, deleted: Bool, context: ModelContext) throws -> [ComicRecord] {
        let id = value.id
        let existing = try context.fetch(FetchDescriptor<ComicRecord>(predicate: #Predicate { $0.id == id }))
        guard existing.isEmpty, !deleted else { return existing }
        let record = ComicRecord(sourceID: value.sourceID, comicID: value.comicID, title: value.title,
                                 coverURL: value.coverURL, author: value.author, summary: value.summary)
        context.insert(record)
        return [record]
    }

    private func restorePluginAccess(id: String, path: String, backup: Data?) async throws {
        let fresh = ModelContext(container)
        if let current = try fresh.fetch(FetchDescriptor<PluginRecord>(predicate: #Predicate { $0.uuid == id })).first {
            if current.bundlePath == path, let backup { try await files.restoreRemoved(backup, path: path) }
            try await files.setAccess(id: id, path: current.bundlePath, enabled: current.enabled)
        } else {
            try await files.setAccess(id: id, path: path, enabled: false)
        }
    }

    private func apply(_ payload: PreferencePayload, deleted: Bool, asset: Data?, context: ModelContext) async throws -> Bool {
        switch payload {
        case .favorite(let comic):
            for record in try comicRecords(comic, deleted: deleted, context: context) {
                record.isFavorite = !deleted
            }
        case .reading, .readChapter, .pluginRating, .followedComic:
            throw URLError(.cannotParseResponse)
        case .subscription(let value):
            let url = value.url
            let existing = try context.fetch(FetchDescriptor<SubscriptionRecord>(predicate: #Predicate { $0.url == url })).first
            if deleted { if let existing { context.delete(existing) } }
            else {
                let record = existing ?? SubscriptionRecord(url: url, name: value.name)
                if existing == nil { context.insert(record) }
                record.name = value.name
            }
        case .tag(let value):
            let name = value.normalizedName
            let existing = try context.fetch(FetchDescriptor<LocalTagRecord>(predicate: #Predicate { $0.normalizedName == name })).first
            if deleted { if let existing { context.delete(existing) } }
            else {
                let record = existing ?? LocalTagRecord(name: value.name)
                guard record.normalizedName == name else { throw URLError(.cannotParseResponse) }
                if existing == nil { context.insert(record) }
                record.name = value.name
            }
        case .tagLink(let value):
            let name = value.normalizedName
            guard let record = try context.fetch(FetchDescriptor<LocalTagRecord>(predicate: #Predicate { $0.normalizedName == name })).first else { return deleted }
            if deleted { record.comicKeys.removeAll { $0 == value.comicKey } }
            else if !record.comicKeys.contains(value.comicKey) { record.comicKeys.append(value.comicKey) }
        case .plugin(let value):
            let id = value.id
            guard PluginIdentity.isValid(id) else { throw URLError(.cannotParseResponse) }
            let existing = try context.fetch(FetchDescriptor<PluginRecord>(predicate: #Predicate { $0.uuid == id })).first
            let baseline = existing.map { snapshot($0, digest: value.digest) }
            let baselinePath = existing?.bundlePath
            func unchanged() throws -> Bool {
                let fresh = ModelContext(container)
                let current = try fresh.fetch(FetchDescriptor<PluginRecord>(predicate: #Predicate { $0.uuid == id })).first
                return current?.bundlePath == baselinePath && current.map { snapshot($0, digest: value.digest) } == baseline
            }
            if deleted {
                if let existing {
                    let path = existing.bundlePath
                    try await unloadPlugin(id)
                    try checkActive()
                    guard try unchanged() else { return false }
                    // Keep the script intact until deletion is durable.
                    let backup = try await files.readIfPresent(path: path)
                    try checkActive()
                    guard try unchanged() else { return false }
                    do {
                        _ = try await files.remove(id: id, path: path)
                        try checkActive()
                        guard try unchanged() else {
                            try await restorePluginAccess(id: id, path: path, backup: backup)
                            return false
                        }
                        context.delete(existing)
                        try context.save()
                    } catch {
                        try await restorePluginAccess(id: id, path: path, backup: backup)
                        throw error
                    }
                }
            } else {
                guard let data = asset else { return false }
                let path = try await files.restore(data, id: id, digest: value.digest, enabled: value.enabled)
                do {
                    try await unloadPlugin(id)
                    try checkActive()
                    guard try unchanged() else {
                        try await restorePluginAccess(id: id, path: path, backup: nil)
                        return false
                    }
                } catch {
                    try await restorePluginAccess(id: id, path: path, backup: nil)
                    throw error
                }
                let record = existing ?? PluginRecord(uuid: id, name: value.name, version: value.version, bundlePath: path)
                if existing == nil { context.insert(record) }
                record.name = value.name; record.version = value.version; record.bundlePath = path
                record.subscriptionURL = value.subscriptionURL; record.enabled = value.enabled; record.infoJSON = value.info
            }
        }
        return true
    }
}
