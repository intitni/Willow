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
    private var reconciling = false
    private var rerun = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    @MainActor package init(container: ModelContainer, files: PluginSyncFiles = PluginSyncFiles(),
                 unloadPlugin: @escaping @Sendable (String) async throws -> Void = { try await PluginRuntime.shared.unload(id: $0) }) {
        viewModel = PreferenceSyncViewModel()
        self.container = container
        self.files = files
        self.unloadPlugin = unloadPlugin
    }

    // Concurrent triggers share the current run and request one follow-up pass.
    // No timer or recurring task is kept alive between events.
    package func reconcile() async throws {
        try Task.checkCancellation()
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
                try Task.checkCancellation()
                try await reconcile()
            }
            try Task.checkCancellation()
            return
        }
        reconciling = true
        do {
            repeat {
                rerun = false
                try Task.checkCancellation()
                try await reconcilePass()
                await viewModel.completed(error: nil)
            } while rerun
            reconciling = false
            let pending = Array(waiters.values)
            waiters.removeAll()
            pending.forEach { $0.resume() }
        } catch {
            if !(error is CancellationError) { await viewModel.completed(error: error.localizedDescription) }
            reconciling = false
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
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let allRevisions = try context.fetch(FetchDescriptor<PreferenceSyncRecord>())
        let remote = Dictionary(grouping: allRevisions, by: \.key).compactMapValues { records in
            records.max { a, b in a.modifiedAt == b.modifiedAt ? a.revision < b.revision : a.modifiedAt < b.modifiedAt }
        }
        let checkpoints = Dictionary(try context.fetch(FetchDescriptor<PreferenceSyncCheckpoint>()).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let assets = Dictionary(try context.fetch(FetchDescriptor<PluginSyncAsset>()).map { ($0.digest, $0) }, uniquingKeysWith: { a, _ in a })
        let plugins = try context.fetch(FetchDescriptor<PluginRecord>())
        var local: [String: PreferencePayload] = [:]
        var pluginPaths: [String: String] = [:]
        var unavailable = Set<String>()
        var missingFiles = Set<String>()
        var firstError: Error?

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

        // 标签定义先于关联处理；文件操作放在最后，避免等待文件时覆盖标签编辑。
        let keys = Set(local.keys).union(remote.keys).union(checkpoints.keys).subtracting(unavailable).sorted {
            func order(_ key: String) -> Int { key.hasPrefix("tag/") ? 0 : key.hasPrefix("tag-link/") ? 1 : key.hasPrefix("plugin/") ? 3 : 2 }
            return order($0) == order($1) ? $0 < $1 : order($0) < order($1)
        }
        for key in keys {
            try Task.checkCancellation()
            do {
                let value = local[key]
                let bytes = try value?.encoded()
                let checkpoint = checkpoints[key]
                let cloud = remote[key]
                if bytes != checkpoint?.payload && !missingFiles.contains(key) {
                    if case .plugin(let plugin) = value {
                        guard let path = pluginPaths[key], pluginUnchanged(plugin, path: path) else { continue }
                        if assets[plugin.digest] == nil {
                            let data = try await files.read(path: path)
                            guard pluginUnchanged(plugin, path: path), try await files.digest(path: path) == plugin.digest else { continue }
                            context.insert(PluginSyncAsset(digest: plugin.digest, data: data))
                        }
                    }
                    let date = max(Date.now, (cloud?.modifiedAt ?? .distantPast).addingTimeInterval(0.001))
                    let record = PreferenceSyncRecord(key: key, payload: bytes ?? checkpoint?.payload, deleted: value == nil, modifiedAt: date)
                    context.insert(record)
                    saveCheckpoint(key: key, bytes: bytes, revision: record.revision, path: pluginPaths[key], existing: checkpoint, context: context)
                    try context.save()
                } else if let cloud, cloud.revision != checkpoint?.revision || missingFiles.contains(key) {
                    guard let data = cloud.payload else { continue }
                    let payload = try JSONDecoder().decode(PreferencePayload.self, from: data)
                    guard payload.key == key else { throw URLError(.cannotParseResponse) }
                    let applied = try await apply(payload, deleted: cloud.deleted, assets: assets, context: context)
                    guard applied else { continue } // CloudKit 的资源文件或标签定义可能稍后到达。
                    let path: String?
                    if case .plugin(let plugin) = payload, !cloud.deleted { path = "\(plugin.id)-\(plugin.digest).cjs" } else { path = nil }
                    saveCheckpoint(key: key, bytes: cloud.deleted ? nil : data, revision: cloud.revision, path: path, existing: checkpoint, context: context)
                    try context.save()
                }
            } catch {
                context.rollback()
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private func saveCheckpoint(key: String, bytes: Data?, revision: String, path: String?, existing: PreferenceSyncCheckpoint?, context: ModelContext) {
        let checkpoint = existing ?? PreferenceSyncCheckpoint(key: key, payload: bytes, revision: revision)
        if existing == nil { context.insert(checkpoint) }
        checkpoint.payload = bytes
        checkpoint.revision = revision
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

    private func apply(_ payload: PreferencePayload, deleted: Bool, assets: [String: PluginSyncAsset], context: ModelContext) async throws -> Bool {
        switch payload {
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
                    let backup = try await files.remove(id: id, path: path)
                    func restoreAfterConflict() async throws {
                        let fresh = ModelContext(container)
                        if let current = try fresh.fetch(FetchDescriptor<PluginRecord>(predicate: #Predicate { $0.uuid == id })).first {
                            if current.bundlePath == path, let backup {
                                try await files.restoreRemoved(backup, path: path)
                            }
                            try await files.setAccess(id: id, path: current.bundlePath, enabled: current.enabled)
                        }
                    }
                    do {
                        try await unloadPlugin(id)
                        guard try unchanged() else {
                            try await restoreAfterConflict()
                            return false
                        }
                        context.delete(existing)
                        // Keep the backup until the deletion is durable as well.
                        try context.save()
                    } catch {
                        try await restoreAfterConflict()
                        throw error
                    }
                }
            } else {
                guard let data = assets[value.digest]?.data else { return false }
                let path = try await files.restore(data, id: id, digest: value.digest, enabled: value.enabled)
                try await unloadPlugin(id)
                guard try unchanged() else {
                    // A local install/toggle during the file write wins this pass.
                    let fresh = ModelContext(container)
                    if let current = try fresh.fetch(FetchDescriptor<PluginRecord>(predicate: #Predicate { $0.uuid == id })).first {
                        try await files.setAccess(id: id, path: current.bundlePath, enabled: current.enabled)
                    } else {
                        try await files.setAccess(id: id, path: path, enabled: false)
                    }
                    return false
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
