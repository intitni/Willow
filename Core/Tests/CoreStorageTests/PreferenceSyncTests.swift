@testable import CoreStorage
import Foundation
import SwiftData
import Testing

@Suite("Preference sync", .serialized)
@MainActor
struct PreferenceSyncTests {
    @Test func tagsAndSubscriptionsMergeAndDeleteAcrossDevices() async throws {
        let a = try WillowPersistence.make(inMemory: true).container
        let b = try WillowPersistence.make(inMemory: true).container
        let drive = try SyncTestFolder()
        defer { drive.remove() }
        let syncA = drive.worker(container: a)
        let syncB = drive.worker(container: b)
        let context = ModelContext(a)
        let tag = LocalTagRecord(name: "Favorite")
        tag.comicKeys = ["comic/one"]
        context.insert(tag)
        context.insert(SubscriptionRecord(url: "https://example.com/plugins", name: "Sources"))
        try context.save()
        try await syncA.reconcile()
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
        try await syncA.reconcile(); try await syncB.reconcile()
        for container in [a, b] {
            let fresh = ModelContext(container)
            #expect(Set(try #require(fresh.fetch(FetchDescriptor<LocalTagRecord>()).first).comicKeys) == ["comic/one", "comic/two", "comic/three"])
        }
        let deletion = ModelContext(a)
        deletion.delete(try #require(deletion.fetch(FetchDescriptor<LocalTagRecord>()).first))
        deletion.delete(try #require(deletion.fetch(FetchDescriptor<SubscriptionRecord>()).first))
        try deletion.save()
        try await syncA.reconcile(); try await syncB.reconcile()
        try await syncA.reconcile()
        for container in [a, b] {
            let fresh = ModelContext(container)
            #expect(try fresh.fetchCount(FetchDescriptor<LocalTagRecord>()) == 0)
            #expect(try fresh.fetchCount(FetchDescriptor<SubscriptionRecord>()) == 0)
        }
    }

    @Test func pluginRepairsMissingFileAndAppliesRemoteUninstall() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WillowSync-\(UUID())")
        let dirA = directory.appending(path: "a")
        let dirB = directory.appending(path: "b")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = Data("module.exports = { getInfo() { return {} } };".utf8)
        try script.write(to: dirA.appending(path: "fixture.cjs"))
        let a = try WillowPersistence.make(inMemory: true).container
        let b = try WillowPersistence.make(inMemory: true).container
        let drive = try SyncTestFolder()
        defer { drive.remove() }
        let syncA = drive.worker(container: a, files: PluginSyncFiles(directory: dirA))
        let syncB = drive.worker(container: b, files: PluginSyncFiles(directory: dirB))
        let context = ModelContext(a)
        context.insert(PluginRecord(uuid: "fixture", name: "Fixture", version: "1", bundlePath: "fixture.cjs"))
        try context.save()
        try await syncA.reconcile()
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
        try await syncA.reconcile(); try await syncB.reconcile()
        #expect(try ModelContext(b).fetchCount(FetchDescriptor<PluginRecord>()) == 0)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func pluginRatingSyncsWithoutAnInstalledPlugin() async throws {
        let a = try WillowPersistence.make(inMemory: true).container
        let b = try WillowPersistence.make(inMemory: true).container
        let drive = try SyncTestFolder()
        defer { drive.remove() }
        let syncA = drive.worker(container: a)
        let syncB = drive.worker(container: b)

        a.mainContext.insert(PluginContentRating(sourceID: "fixture", isNSFW: true))
        try a.mainContext.save()
        try await syncA.reconcile()
        try await syncB.reconcile()

        let editor = ModelContext(b)
        let rating = try #require(editor.fetch(FetchDescriptor<PluginContentRating>()).first)
        #expect(rating.sourceID == "fixture")
        #expect(rating.isNSFW)
        #expect(try editor.fetchCount(FetchDescriptor<PluginRecord>()) == 0)
        rating.isNSFW = false
        rating.updatedAt = try #require(rating.updatedAt).addingTimeInterval(1)
        try editor.save()

        try await syncB.reconcile()
        try await syncA.reconcile()
        try await syncA.reconcile()
        let imported = try #require(ModelContext(a).fetch(FetchDescriptor<PluginContentRating>()).first)
        #expect(!imported.isNSFW)
        let revisions = try drive.revisions()
        #expect(revisions.count == 2)
        #expect(revisions.allSatisfy { $0.filename.hasSuffix(".rating") })
    }

    @Test(arguments: [true, false])
    func firstPluginRatingSyncUsesEditTime(localIsNewer: Bool) async throws {
        let container = try WillowPersistence.make(inMemory: true).container
        let drive = try SyncTestFolder()
        defer { drive.remove() }
        let sync = drive.worker(container: container)
        let cloudDate = Date(timeIntervalSinceReferenceDate: 10_000)
        let localDate = cloudDate.addingTimeInterval(localIsNewer ? 60 : -60)
        let payload = PreferencePayload.pluginRating(.init(sourceID: "fixture", isNSFW: false))
        // Older clients published the first value as a seed with no edit time in the payload.
        let cloud = SyncRevision(key: payload.key, payload: try payload.encoded(), modifiedAt: cloudDate,
                                 deleted: false, seed: true)
        try drive.directory.publish(cloud, asset: nil, key: drive.key)
        container.mainContext.insert(PluginContentRating(sourceID: "fixture", isNSFW: true, updatedAt: localDate))
        try container.mainContext.save()

        try await sync.reconcile()
        try await sync.reconcile()

        let rating = try #require(ModelContext(container).fetch(FetchDescriptor<PluginContentRating>()).first)
        #expect(rating.isNSFW == localIsNewer)
        #expect(rating.updatedAt == max(localDate, cloudDate))
        let revisions = try drive.revisions()
        #expect(revisions.count == (localIsNewer ? 2 : 1))
        #expect(revisions.max { $0.precedes($1) }?.modifiedAt == max(localDate, cloudDate))
    }

    @Test func missingOldFileAppliesCompleteRemoteVersion() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WillowVersion-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try WillowPersistence.make(inMemory: true).container
        let files = PluginSyncFiles(directory: directory)
        let drive = try SyncTestFolder()
        defer { drive.remove() }
        let sync = drive.worker(container: container, files: files)
        try Data("old".utf8).write(to: directory.appending(path: "old.cjs"))
        let context = ModelContext(container)
        context.insert(PluginRecord(uuid: "fixture", name: "Old", version: "1", bundlePath: "old.cjs"))
        try context.save()
        try await sync.reconcile()
        let data = Data("new".utf8)
        try data.write(to: directory.appending(path: "new.cjs"))
        let digest = try await files.digest(path: "new.cjs")
        let payload = PreferencePayload.plugin(.init(id: "fixture", name: "New", version: "2", subscriptionURL: "https://example.com/new", enabled: false, info: Data("new info".utf8), digest: digest))
        let remote = SyncRevision(key: payload.key, payload: try payload.encoded(),
                                  modifiedAt: Date.now.addingTimeInterval(1), deleted: false)
        try drive.directory.publish(remote, asset: (digest, data), key: drive.key)
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
        let revisions = try drive.revisions()
        #expect(revisions.count == 2)
        #expect(revisions.max(by: { $0.precedes($1) })?.revision == remote.revision)
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
        let drive = try SyncTestFolder()
        defer { drive.remove() }
        let sync = drive.worker(container: container, files: files, unloadPlugin: { @MainActor _ in
            // Precisely reproduce a user toggle at the suspension point before deleting the script.
            let editor = ModelContext(container)
            let plugin = try #require(editor.fetch(FetchDescriptor<PluginRecord>()).first)
            plugin.enabled = false
            try editor.save()
            if throwDuringUnload { throw URLError(.cancelled) }
        })
        try await sync.reconcile()
        let uploaded = try #require(drive.revisions().first)
        let deletion = SyncRevision(key: uploaded.key, payload: uploaded.payload,
                                    modifiedAt: Date.now.addingTimeInterval(1), deleted: true)
        try drive.directory.publish(deletion, asset: nil, key: drive.key)
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
        let revisions = try drive.revisions()
        #expect(revisions.max(by: { $0.precedes($1) })?.deleted == false)
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
        let drive = try SyncTestFolder()
        defer { drive.remove() }
        let files = PluginSyncFiles(directory: directory)
        let seed = drive.worker(container: source, files: files)
        try await seed.reconcile()
        let gate = SyncGate()
        let sync = drive.worker(container: target, files: files, unloadPlugin: { _ in
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
            let rows = try drive.revisions()
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

struct SyncTestFolder {
    let directory: DriveSyncDirectory
    let key: DriveSyncKey
    private let keyData: Data

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "WillowSyncTests-\(UUID())", directoryHint: .isDirectory)
        directory = DriveSyncDirectory(root: root)
        keyData = DriveSyncKeychain.generate()
        key = try DriveSyncKey(keyData)
        try directory.create(key: key) { _ in }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory.root)
    }

    func revisions() throws -> [SyncRevision] {
        try directory.readRevisions(key: key).revisions
    }

    @MainActor
    func worker(container: ModelContainer, files: PluginSyncFiles? = nil,
                readDriveRecord: (@Sendable (URL) throws -> Data?)? = nil,
                didImportFollowing: @escaping @Sendable () async -> Void = {},
                unloadPlugin: @escaping @Sendable (String) async throws -> Void = { _ in }) -> PreferenceSyncModel {
        PreferenceSyncModel(container: container, drive: .success(directory),
                            files: files ?? PluginSyncFiles(directory: directory.root.appending(path: "plugins")),
                            driveKey: { [keyData] _ in keyData }, readDriveRecord: readDriveRecord,
                            didImportFollowing: didImportFollowing, unloadPlugin: unloadPlugin)
    }
}
