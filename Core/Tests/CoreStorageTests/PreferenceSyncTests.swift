@testable import CoreStorage
import Foundation
import SwiftData
import Testing

@Suite("Preference sync", .serialized)
@MainActor
struct PreferenceSyncTests {
    private func copyCloud(from source: ModelContainer, to destination: ModelContainer, assets: Bool = true) throws {
        let input = ModelContext(source)
        let output = ModelContext(destination)
        let known = Set(try output.fetch(FetchDescriptor<PreferenceSyncRecord>()).map(\.revision))
        for row in try input.fetch(FetchDescriptor<PreferenceSyncRecord>()) where !known.contains(row.revision) {
            let copy = PreferenceSyncRecord(key: row.key, payload: row.payload, deleted: row.deleted, modifiedAt: row.modifiedAt)
            copy.revision = row.revision
            output.insert(copy)
        }
        if assets {
            let knownAssets = Set(try output.fetch(FetchDescriptor<PluginSyncAsset>()).map(\.digest))
            for row in try input.fetch(FetchDescriptor<PluginSyncAsset>()) where !knownAssets.contains(row.digest) {
                if let data = row.data { output.insert(PluginSyncAsset(digest: row.digest, data: data)) }
            }
        }
        try output.save()
    }

    @Test func tagsAndSubscriptionsMergeAndDeleteAcrossDevices() async throws {
        let a = try WillowPersistence.make(inMemory: true).container
        let b = try WillowPersistence.make(inMemory: true).container
        let syncA = PreferenceSyncModel(container: a)
        let syncB = PreferenceSyncModel(container: b)
        let context = ModelContext(a)
        let tag = LocalTagRecord(name: "Favorite")
        tag.comicKeys = ["comic/one"]
        context.insert(tag)
        context.insert(SubscriptionRecord(url: "https://example.com/plugins", name: "Sources"))
        try context.save()
        try await syncA.reconcile()
        try copyCloud(from: a, to: b)
        try await syncB.reconcile()
        let bc = ModelContext(b)
        let bt = try #require(bc.fetch(FetchDescriptor<LocalTagRecord>()).first)
        #expect(bt.comicKeys == ["comic/one"])
        #expect(try bc.fetchCount(FetchDescriptor<SubscriptionRecord>()) == 1)

        // Separate membership records preserve concurrent additions on two devices.
        let ac = ModelContext(a)
        let at = try #require(ac.fetch(FetchDescriptor<LocalTagRecord>()).first)
        at.comicKeys.append("comic/two")
        bt.comicKeys.append("comic/three")
        try ac.save(); try bc.save()
        try await syncA.reconcile(); try await syncB.reconcile()
        try copyCloud(from: a, to: b); try copyCloud(from: b, to: a)
        try await syncA.reconcile(); try await syncB.reconcile()
        for container in [a, b] {
            let fresh = ModelContext(container)
            #expect(Set(try #require(fresh.fetch(FetchDescriptor<LocalTagRecord>()).first).comicKeys) == ["comic/one", "comic/two", "comic/three"])
        }
        let deletion = ModelContext(a)
        deletion.delete(try #require(deletion.fetch(FetchDescriptor<LocalTagRecord>()).first))
        deletion.delete(try #require(deletion.fetch(FetchDescriptor<SubscriptionRecord>()).first))
        try deletion.save()
        try await syncA.reconcile(); try copyCloud(from: a, to: b); try await syncB.reconcile()
        try copyCloud(from: b, to: a); try await syncA.reconcile()
        for container in [a, b] {
            let fresh = ModelContext(container)
            #expect(try fresh.fetchCount(FetchDescriptor<LocalTagRecord>()) == 0)
            #expect(try fresh.fetchCount(FetchDescriptor<SubscriptionRecord>()) == 0)
        }
    }

    @Test func pluginRestoresAfterAssetArrivesAndRepairsMissingFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WillowSync-\(UUID())")
        let dirA = directory.appending(path: "a")
        let dirB = directory.appending(path: "b")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = Data("module.exports = { getInfo() { return {} } };".utf8)
        try script.write(to: dirA.appending(path: "fixture.cjs"))
        let a = try WillowPersistence.make(inMemory: true).container
        let b = try WillowPersistence.make(inMemory: true).container
        let syncA = PreferenceSyncModel(container: a, files: PluginSyncFiles(directory: dirA))
        let syncB = PreferenceSyncModel(container: b, files: PluginSyncFiles(directory: dirB))
        let context = ModelContext(a)
        context.insert(PluginRecord(uuid: "fixture", name: "Fixture", version: "1", bundlePath: "fixture.cjs"))
        try context.save()
        try await syncA.reconcile()
        try copyCloud(from: a, to: b, assets: false)
        try await syncB.reconcile()
        #expect(try ModelContext(b).fetchCount(FetchDescriptor<PluginRecord>()) == 0)
        try copyCloud(from: a, to: b)
        try await syncB.reconcile()
        let fresh = ModelContext(b)
        let plugin = try #require(fresh.fetch(FetchDescriptor<PluginRecord>()).first)
        let path = dirB.appending(path: plugin.bundlePath)
        #expect(try Data(contentsOf: path) == script)
        try FileManager.default.removeItem(at: path)
        try await syncB.reconcile()
        #expect(try Data(contentsOf: path) == script)
        // A missing local file must not prevent a remote uninstall.
        try FileManager.default.removeItem(at: path)
        let deletion = ModelContext(a)
        deletion.delete(try #require(deletion.fetch(FetchDescriptor<PluginRecord>()).first))
        try deletion.save()
        try await syncA.reconcile(); try copyCloud(from: a, to: b); try await syncB.reconcile()
        #expect(try ModelContext(b).fetchCount(FetchDescriptor<PluginRecord>()) == 0)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
    @Test func missingOldFileAppliesCompleteCloudVersion() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WillowVersion-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try WillowPersistence.make(inMemory: true).container
        let files = PluginSyncFiles(directory: directory)
        let sync = PreferenceSyncModel(container: container, files: files)
        try Data("old".utf8).write(to: directory.appending(path: "old.cjs"))
        let context = ModelContext(container)
        context.insert(PluginRecord(uuid: "fixture", name: "Old", version: "1", bundlePath: "old.cjs"))
        try context.save()
        try await sync.reconcile()
        let data = Data("new".utf8)
        try data.write(to: directory.appending(path: "new.cjs"))
        let digest = try await files.digest(path: "new.cjs")
        let payload = PreferencePayload.plugin(.init(id: "fixture", name: "New", version: "2", subscriptionURL: "https://example.com/new", enabled: false, info: Data("new info".utf8), digest: digest))
        context.insert(PluginSyncAsset(digest: digest, data: data))
        let remote = PreferenceSyncRecord(key: payload.key, payload: try payload.encoded(), modifiedAt: Date.now.addingTimeInterval(1))
        context.insert(remote)
        try context.save()
        try FileManager.default.removeItem(at: directory.appending(path: "old.cjs"))
        try await sync.reconcile()
        try await sync.reconcile()
        let fresh = ModelContext(container)
        let plugin = try #require(fresh.fetch(FetchDescriptor<PluginRecord>()).first)
        #expect(plugin.version == "2")
        #expect(plugin.name == "New")
        #expect(!plugin.enabled)
        #expect(plugin.subscriptionURL == "https://example.com/new")
        #expect(plugin.infoJSON == Data("new info".utf8))
        #expect(try Data(contentsOf: directory.appending(path: plugin.bundlePath)) == data)
        let revisions = try fresh.fetch(FetchDescriptor<PreferenceSyncRecord>())
        #expect(revisions.count == 2)
        #expect(revisions.max(by: { $0.modifiedAt < $1.modifiedAt })?.revision == remote.revision)
    }

    @Test(arguments: [false, true])
    func remoteUninstallRestoresFileOnConflictOrFailure(throwDuringUnload: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WillowConflict-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try WillowPersistence.make(inMemory: true).container
        let files = PluginSyncFiles(directory: directory)
        let data = Data("original script".utf8)
        let path = directory.appending(path: "fixture.cjs")
        try data.write(to: path)
        let context = ModelContext(container)
        context.insert(PluginRecord(uuid: "fixture", name: "Fixture", version: "1", bundlePath: "fixture.cjs"))
        try context.save()
        let sync = PreferenceSyncModel(container: container, files: files, unloadPlugin: { @MainActor _ in
            // Precisely reproduce a user toggle at the suspension point after removal.
            let editor = ModelContext(container)
            let plugin = try #require(editor.fetch(FetchDescriptor<PluginRecord>()).first)
            plugin.enabled = false
            try editor.save()
            if throwDuringUnload { throw URLError(.cancelled) }
        })
        try await sync.reconcile()
        let uploaded = try #require(context.fetch(FetchDescriptor<PreferenceSyncRecord>()).first)
        context.insert(PreferenceSyncRecord(key: uploaded.key, payload: uploaded.payload, deleted: true, modifiedAt: Date.now.addingTimeInterval(1)))
        try context.save()
        do {
            try await sync.reconcile()
            #expect(!throwDuringUnload)
        } catch {
            #expect(throwDuringUnload)
        }
        #expect(try Data(contentsOf: path) == data)
        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<PluginRecord>()) == 1)
        #expect(try #require(fresh.fetch(FetchDescriptor<PluginRecord>()).first).enabled == false)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "fixture.path").path))
        // The surviving local change can be uploaded on the next pass.
        try await sync.reconcile()
        let revisions = try ModelContext(container).fetch(FetchDescriptor<PreferenceSyncRecord>())
        #expect(revisions.max(by: { $0.modifiedAt < $1.modifiedAt })?.deleted == false)
    }

    @Test func eventsDuringSyncAreRetained() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WillowEvents-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try WillowPersistence.make(inMemory: true).container
        let target = try WillowPersistence.make(inMemory: true).container
        try Data("module.exports = {};".utf8).write(to: directory.appending(path: "fixture.cjs"))
        source.mainContext.insert(PluginRecord(uuid: "fixture", name: "Fixture", version: "1", bundlePath: "fixture.cjs"))
        try source.mainContext.save()
        let seed = PreferenceSyncModel(container: source, files: PluginSyncFiles(directory: directory))
        try await seed.reconcile()
        try copyCloud(from: source, to: target)
        let gate = SyncGate()
        let sync = PreferenceSyncModel(container: target, files: PluginSyncFiles(directory: directory), unloadPlugin: { _ in
            await gate.pause()
        })
        let events = PreferenceSyncEvents()
        let runner = Task { await events.run(context: target.mainContext, sync: sync) }
        defer { runner.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.isWaiting) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        // Expiring a queued background request must not wait for or cancel the
        // foreground run that is currently paused in the runtime.
        let queued = Task { try await sync.reconcile() }
        try await Task.sleep(for: .milliseconds(10))
        queued.cancel()
        switch await queued.result {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("A cancelled refresh must report cancellation.")
        }
        // This change happens after the running pass has already read local tags.
        let tag = LocalTagRecord(name: "During sync")
        tag.comicKeys = ["fixture/comic"]
        target.mainContext.insert(tag)
        try target.mainContext.save()
        events.request()
        await gate.resume()
        while true {
            let rows = try ModelContext(target).fetch(FetchDescriptor<PreferenceSyncRecord>())
            if rows.contains(where: { $0.key == "tag/during sync" }) && rows.contains(where: { $0.key.hasPrefix("tag-link/") }) { break }
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        runner.cancel()
        await runner.value
    }

    private actor SyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { continuation != nil }
        func pause() async { await withCheckedContinuation { continuation = $0 } }
        func resume() { continuation?.resume(); continuation = nil }
    }

}
