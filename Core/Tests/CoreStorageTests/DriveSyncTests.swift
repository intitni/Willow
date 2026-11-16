import CryptoKit
@testable import CoreStorage
import Foundation
import SwiftData
import Testing

@Suite("Encrypted iCloud Drive sync")
@MainActor
struct DriveSyncTests {
    @Test func recoveryKeyAuthenticatesFolderAndRecords() async throws {
        let directory = DriveSyncDirectory(root: try temporaryFolder())
        defer { try? FileManager.default.removeItem(at: directory.root) }
        let recoveryKey = DriveSyncKeychain.generate()
        let key = try DriveSyncKey(recoveryKey)
        try create(directory, key: key)

        let privateTitle = "Private comic title"
        let script = Data("module.exports = 'private script'".utf8)
        let digest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        let payload = PreferencePayload.tag(.init(normalizedName: "private comic title", name: privateTitle))
        let revision = SyncRevision(key: payload.key, payload: try payload.encoded(), modifiedAt: .now, deleted: false)
        try directory.publish(revision, asset: (digest, script), key: key)

        let reopened = DriveSyncDirectory(id: directory.id, root: directory.root)
        let supplied = try #require(Data(base64Encoded: recoveryKey.base64EncodedString()))
        let reopenedKey = try DriveSyncKey(supplied)
        try reopened.verify(key: reopenedKey)
        #expect(try reopened.readRevisions(key: reopenedKey).revisions.map(\.key) == [payload.key])
        #expect(try reopened.asset(digest, key: reopenedKey) == script)
        let incorrect = try DriveSyncKey(DriveSyncKeychain.generate())
        #expect(throws: DriveSyncError.wrongKey) {
            let marker = try reopened.recoveryMarker()
            try marker.verify(incorrect)
        }
        #expect(throws: DriveSyncError.folderAlreadyExists) { try create(reopened, key: incorrect) }
        try reopened.verify(key: reopenedKey)

        for file in try FileManager.default.contentsOfDirectory(at: directory.directory, includingPropertiesForKeys: nil) {
            let stored = try Data(contentsOf: file)
            #expect(!file.lastPathComponent.contains(digest))
            #expect(stored.range(of: Data(privateTitle.utf8)) == nil)
            #expect(stored.range(of: script) == nil)
            #expect(stored.range(of: recoveryKey) == nil)
        }

        let file = directory.directory.appending(path: revision.revision + ".record")
        var stored = try Data(contentsOf: file)
        stored[stored.startIndex] ^= 0xff
        try stored.write(to: file, options: .atomic)
        let result = try reopened.readRevisions(key: reopenedKey)
        #expect(result.revisions.isEmpty)
        #expect(result.error != nil)
    }

    @Test func recoveryRequiresTheConfiguredDirectoryMarker() throws {
        let directory = DriveSyncDirectory(root: try temporaryFolder())
        defer { try? FileManager.default.removeItem(at: directory.root) }
        #expect(throws: DriveSyncError.missingDirectory) { try directory.recoveryMarker() }

        let key = try DriveSyncKey(DriveSyncKeychain.generate())
        try create(directory, key: key)
        let replacement = DriveSyncDirectory(root: directory.root)
        #expect(throws: DriveSyncError.directoryChanged) { try replacement.recoveryMarker() }
        try directory.recoveryMarker().verify(key)
    }

    @Test func readingAndFavoritesMergeIndependentlyAndDeletionDoesNotRollBack() async throws {
        let dir = DriveSyncDirectory(root: try temporaryFolder())
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let bytes = DriveSyncKeychain.generate()
        let key = try DriveSyncKey(bytes)
        try create(dir, key: key)
        let a = try WillowPersistence.make(inMemory: true).container
        let b = try WillowPersistence.make(inMemory: true).container
        let syncA = PreferenceSyncModel(container: a, drive: .success(dir), driveKey: { _ in bytes })
        let syncB = PreferenceSyncModel(container: b, drive: .success(dir), driveKey: { _ in bytes })
        let record = ComicRecord(sourceID: "source", comicID: "comic", title: "Private comic")
        record.isFavorite = true
        record.lastReadAt = Date(timeIntervalSinceReferenceDate: 1)
        record.chapterID = "old chapter"
        a.mainContext.insert(record)
        a.mainContext.insert(LocalTagRecord(name: "Tag"))
        try a.mainContext.save()
        try await syncA.reconcile()

        let independent = ComicRecord(sourceID: "source", comicID: "comic", title: "Local title")
        independent.lastReadAt = Date(timeIntervalSinceReferenceDate: 2)
        independent.chapterID = "new chapter"
        independent.pageIndex = 13
        b.mainContext.insert(independent)
        try b.mainContext.save()
        try await syncB.reconcile()
        try await syncA.reconcile()

        let editA = ModelContext(a)
        let itemA = try #require(editA.fetch(FetchDescriptor<ComicRecord>()).first)
        #expect(itemA.isFavorite)
        #expect(itemA.pageIndex == 13)
        itemA.isFavorite = false
        try editA.save()

        let editB = ModelContext(b)
        let itemB = try #require(editB.fetch(FetchDescriptor<ComicRecord>()).first)
        itemB.lastReadAt = Date(timeIntervalSinceReferenceDate: 3)
        itemB.pageIndex = 14
        try editB.save()
        try await syncA.reconcile()
        try await syncB.reconcile()
        try await syncA.reconcile()
        for store in [a, b] {
            let item = try #require(ModelContext(store).fetch(FetchDescriptor<ComicRecord>()).first)
            #expect(!item.isFavorite)
            #expect(item.pageIndex == 14)
        }

        // Simulate an older directory listing while the deletion is unavailable.
        let revisions = try dir.readRevisions(key: key).revisions
        let deletion = try #require(revisions.first { $0.deleted && $0.key.hasPrefix("favorite/") })
        let file = dir.directory.appending(path: deletion.revision + ".record")
        let contents = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try await syncB.reconcile()
        #expect(try ModelContext(b).fetch(FetchDescriptor<ComicRecord>()).first?.isFavorite == false)
        try contents.write(to: file, options: .atomic)

        // A new worker for the original directory must use its existing baseline.
        await syncA.stop()
        let edit = ModelContext(a)
        let comic = try #require(edit.fetch(FetchDescriptor<ComicRecord>()).first)
        comic.isFavorite = true
        try edit.save()
        let reattached = PreferenceSyncModel(container: a, drive: .success(dir), driveKey: { _ in bytes })
        try await reattached.reconcile()
        try await syncB.reconcile()
        #expect(try ModelContext(b).fetch(FetchDescriptor<ComicRecord>()).first?.isFavorite == true)
    }

    @Test func chapterRecordsMergeThroughDriveWithoutChangingResumePosition() async throws {
        let dir = DriveSyncDirectory(root: try temporaryFolder())
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let bytes = DriveSyncKeychain.generate()
        let key = try DriveSyncKey(bytes)
        try create(dir, key: key)
        let a = try WillowPersistence.make(inMemory: true).container
        let b = try WillowPersistence.make(inMemory: true).container
        let syncA = PreferenceSyncModel(container: a, drive: .success(dir), driveKey: { _ in bytes })
        let syncB = PreferenceSyncModel(container: b, drive: .success(dir), driveKey: { _ in bytes })
        let comic = ComicRecord(sourceID: "source", comicID: "comic", title: "Comic")
        let comicKey = comic.id
        let first = Date(timeIntervalSinceReferenceDate: 100)
        let latest = first.addingTimeInterval(10)
        comic.chapterID = "one"
        comic.pageIndex = 4
        comic.lastReadAt = first
        a.mainContext.insert(comic)
        try await ReadChapterStore.shared.recordOpen(comicKey: comicKey, chapterID: "one", at: first, in: a)
        try await ReadChapterStore.shared.recordOpen(comicKey: comicKey, chapterID: "one", at: latest, in: b)
        try await ReadChapterStore.shared.recordOpen(comicKey: comicKey, chapterID: "two", at: latest, in: b)
        try a.mainContext.save()
        try await syncA.reconcile()
        try await syncB.reconcile()
        try await syncA.reconcile()

        for container in [a, b] {
            let context = ModelContext(container)
            let chapters = try context.fetch(FetchDescriptor<ReadChapterRecord>())
            #expect(chapters.count == 2)
            #expect(Set(chapters.map(\.chapterID)) == ["one", "two"])
            #expect(chapters.allSatisfy { $0.readAt == latest })
            let progress = try #require(context.fetch(FetchDescriptor<ComicRecord>()).first)
            #expect(progress.chapterID == "one")
            #expect(progress.pageIndex == 4)
        }
        let revisions = try dir.readRevisions(key: key).revisions
        #expect(revisions.filter(\.isReadChapter).count == 3)
        #expect(revisions.filter { $0.filename.hasSuffix(".record") }.count == 1)
        let latestRevision = try #require(revisions.first { $0.isReadChapter && $0.modifiedAt == latest })
        let file = dir.directory.appending(path: latestRevision.filename)
        let contents = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try await syncA.reconcile()
        #expect(try dir.readRevisions(key: key).revisions.count == revisions.count - 1)
        try contents.write(to: file, options: .atomic)
        try await syncA.reconcile()
        #expect(try dir.readRevisions(key: key).revisions.count == revisions.count)
    }

    @Test(arguments: [true, false])
    func availableDriveRecordsSyncWhenOtherFilesArePending(chapterPending: Bool) async throws {
        let dir = DriveSyncDirectory(root: try temporaryFolder())
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let bytes = DriveSyncKeychain.generate()
        let key = try DriveSyncKey(bytes)
        try create(dir, key: key)
        let a = try WillowPersistence.make(inMemory: true).container
        let b = try WillowPersistence.make(inMemory: true).container
        let syncA = PreferenceSyncModel(container: a, drive: .success(dir), driveKey: { _ in bytes })
        let first = Date(timeIntervalSinceReferenceDate: 100)
        try await ReadChapterStore.shared.recordOpen(comicKey: "comic", chapterID: "pending", at: first, in: a)
        try await ReadChapterStore.shared.recordOpen(comicKey: "comic", chapterID: "ready", at: .now, in: a)
        a.mainContext.insert(LocalTagRecord(name: "Tag"))
        try a.mainContext.save()
        try await syncA.reconcile()

        let revisions = try dir.readRevisions(key: key).revisions
        let pending = try #require(revisions.first {
            chapterPending ? $0.isReadChapter && $0.modifiedAt == first : $0.key.hasPrefix("tag/")
        })
        let syncB = PreferenceSyncModel(container: b, drive: .success(dir), driveKey: { _ in bytes },
                                        readDriveRecord: { url in
            if url.lastPathComponent == pending.filename { return nil }
            return try Data(contentsOf: url)
        })
        try await ReadChapterStore.shared.recordOpen(comicKey: "comic", chapterID: "local", at: .now, in: b)
        if chapterPending {
            try await syncB.reconcile()
        } else {
            await #expect(throws: DriveSyncError.waitingForFiles) { try await syncB.reconcile() }
        }
        let partial = ModelContext(b)
        #expect(try partial.fetchCount(FetchDescriptor<LocalTagRecord>()) == (chapterPending ? 1 : 0))
        let available: Set<String> = chapterPending ? ["ready", "local"] : ["pending", "ready", "local"]
        #expect(Set(try partial.fetch(FetchDescriptor<ReadChapterRecord>()).map(\.chapterID)) == available)
        try await syncA.reconcile()
        #expect(try ModelContext(a).fetchCount(FetchDescriptor<ReadChapterRecord>()) == 3)

        let afterDownload = PreferenceSyncModel(container: b, drive: .success(dir), driveKey: { _ in bytes })
        try await afterDownload.reconcile()
        let complete = ModelContext(b)
        #expect(try complete.fetchCount(FetchDescriptor<ReadChapterRecord>()) == 3)
        #expect(try complete.fetchCount(FetchDescriptor<LocalTagRecord>()) == 1)
    }

    @Test(arguments: [true, false])
    func lateFavoriteDeletionWinsOverInitialLocalFavorite(enumerated: Bool) async throws {
        let dir = DriveSyncDirectory(root: try temporaryFolder())
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let bytes = DriveSyncKeychain.generate()
        let key = try DriveSyncKey(bytes)
        try create(dir, key: key)
        let store = try WillowPersistence.make(inMemory: true).container
        let comic = ComicRecord(sourceID: "source", comicID: "comic", title: "Title")
        comic.isFavorite = true
        let payload = PreferencePayload.favorite(.init(comic))
        store.mainContext.insert(comic)
        try store.mainContext.save()

        let deletion = SyncRevision(key: payload.key, payload: try payload.encoded(), modifiedAt: .now, deleted: true)
        try dir.publish(deletion, asset: nil, key: key)
        let pendingFile = dir.directory.appending(path: deletion.revision + ".record")
        let stored = try Data(contentsOf: pendingFile)
        if !enumerated { try FileManager.default.removeItem(at: pendingFile) }

        let first = PreferenceSyncModel(container: store, drive: .success(dir), driveKey: { _ in bytes },
                                        readDriveRecord: { url in
            if enumerated, url.lastPathComponent == pendingFile.lastPathComponent { return nil }
            return try Data(contentsOf: url)
        })
        if enumerated {
            await #expect(throws: DriveSyncError.waitingForFiles) { try await first.reconcile() }
            #expect(try dir.readRevisions(key: key).revisions.count == 1)
        } else {
            try await first.reconcile()
            #expect(try dir.readRevisions(key: key).revisions.first?.seed == true)
            try stored.write(to: pendingFile, options: .atomic)
        }
        #expect(try ModelContext(store).fetch(FetchDescriptor<ComicRecord>()).first?.isFavorite == true)
        await first.stop()
        let reattached = PreferenceSyncModel(container: store, drive: .success(dir), driveKey: { _ in bytes })
        try await reattached.reconcile()
        #expect(try ModelContext(store).fetch(FetchDescriptor<ComicRecord>()).first?.isFavorite == false)

        let edit = ModelContext(store)
        try #require(try edit.fetch(FetchDescriptor<ComicRecord>()).first).isFavorite = true
        try edit.save()
        try await reattached.reconcile()
        let versions = try dir.readRevisions(key: key).revisions
        let latest = versions.max { $0.precedes($1) }
        #expect(latest?.deleted == false)
        #expect(latest?.seed != true)
    }

    @Test func lateOfflineReadDoesNotOvertakeMoreRecentReadingOrHistoryDeletion() async throws {
        let dir = DriveSyncDirectory(root: try temporaryFolder())
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let bytes = DriveSyncKeychain.generate()
        try create(dir, key: DriveSyncKey(bytes))
        let a = try WillowPersistence.make(inMemory: true).container
        let b = try WillowPersistence.make(inMemory: true).container
        let syncA = PreferenceSyncModel(container: a, drive: .success(dir), driveKey: { _ in bytes })
        let syncB = PreferenceSyncModel(container: b, drive: .success(dir), driveKey: { _ in bytes })
        let comic = ComicRecord(sourceID: "source", comicID: "comic", title: "Title")
        comic.lastReadAt = Date(timeIntervalSinceReferenceDate: 10)
        a.mainContext.insert(comic)
        try a.mainContext.save()
        try await syncA.reconcile()
        try await syncB.reconcile()

        func read(_ page: Int, at time: TimeInterval, in store: ModelContainer) throws {
            let edit = ModelContext(store)
            let comic = try #require(try edit.fetch(FetchDescriptor<ComicRecord>()).first)
            comic.lastReadAt = Date(timeIntervalSinceReferenceDate: time)
            comic.historyClearedAt = nil
            comic.pageIndex = page
            try edit.save()
        }

        try read(5, at: 20, in: a)
        try read(20, at: 30, in: b)
        try await syncB.reconcile()
        try await syncA.reconcile()
        #expect(try ModelContext(a).fetch(FetchDescriptor<ComicRecord>()).first?.pageIndex == 20)

        // An intentional later reread is allowed to move to an earlier page.
        try read(3, at: 40, in: a)
        try await syncA.reconcile()
        try await syncB.reconcile()
        #expect(try ModelContext(b).fetch(FetchDescriptor<ComicRecord>()).first?.pageIndex == 3)

        let clear = ModelContext(b)
        let clearedAt = Date(timeIntervalSinceReferenceDate: 60)
        try #require(try clear.fetch(FetchDescriptor<ComicRecord>()).first).clearHistory(at: clearedAt)
        try clear.save()
        try read(50, at: 50, in: a)
        try await syncB.reconcile()
        try await syncA.reconcile()
        let cleared = try #require(try ModelContext(a).fetch(FetchDescriptor<ComicRecord>()).first)
        #expect(cleared.lastReadAt == nil)
        #expect(cleared.historyClearedAt == clearedAt)

        try read(1, at: 70, in: a)
        try await syncA.reconcile()
        try await syncB.reconcile()
        let reopened = try #require(try ModelContext(b).fetch(FetchDescriptor<ComicRecord>()).first)
        #expect(reopened.pageIndex == 1)
        #expect(reopened.lastReadAt == Date(timeIntervalSinceReferenceDate: 70))
        #expect(reopened.historyClearedAt == nil)
    }

    @Test func encryptedPluginWaitsForItsAssetAndThenImports() async throws {
        let dir = DriveSyncDirectory(root: try temporaryFolder())
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let bytes = DriveSyncKeychain.generate()
        let key = try DriveSyncKey(bytes)
        try create(dir, key: key)
        let payloadData = Data("module.exports = 'fixture'".utf8)
        let digest = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
        let payload = PreferencePayload.plugin(.init(id: "fixture", name: "Fixture", version: "1",
                                                      subscriptionURL: nil, enabled: false, info: nil, digest: digest))
        let revision = SyncRevision(key: payload.key, payload: try payload.encoded(), modifiedAt: .now, deleted: false)
        try dir.publish(revision, asset: nil, key: key)
        let store = try WillowPersistence.make(inMemory: true).container
        let plugins = dir.root.appending(path: "test plugins")
        let sync = PreferenceSyncModel(container: store, drive: .success(dir), files: PluginSyncFiles(directory: plugins),
                                       driveKey: { _ in bytes }, unloadPlugin: { _ in })
        try await sync.reconcile()
        #expect(try ModelContext(store).fetchCount(FetchDescriptor<PluginRecord>()) == 0)
        try dir.publish(revision, asset: (digest, payloadData), key: key)
        try await sync.reconcile()
        let plugin = try #require(ModelContext(store).fetch(FetchDescriptor<PluginRecord>()).first)
        #expect(try Data(contentsOf: plugins.appending(path: plugin.bundlePath)) == payloadData)
    }

    @Test func stoppingOldWorkerDrainsInFlightPluginImport() async throws {
        let dir = DriveSyncDirectory(root: try temporaryFolder())
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let bytes = DriveSyncKeychain.generate()
        let key = try DriveSyncKey(bytes)
        try create(dir, key: key)
        let script = Data("module.exports = 'fixture'".utf8)
        let digest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        let payload = PreferencePayload.plugin(.init(id: "fixture", name: "Fixture", version: "1",
                                                      subscriptionURL: nil, enabled: true, info: nil, digest: digest))
        let revision = SyncRevision(key: payload.key, payload: try payload.encoded(), modifiedAt: .now, deleted: false)
        try dir.publish(revision, asset: (digest, script), key: key)
        let store = try WillowPersistence.make(inMemory: true).container
        let plugins = dir.root.appending(path: "test plugins")
        let gate = ImportGate()
        let sync = PreferenceSyncModel(container: store, drive: .success(dir), files: PluginSyncFiles(directory: plugins),
                                       driveKey: { _ in bytes }, unloadPlugin: { _ in await gate.pause() })
        let reconcile = Task { try await sync.reconcile() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.isPaused) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        let stop = Task { await sync.stop() }
        while !(await sync.isStopped) {
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        await gate.release()
        await stop.value
        await #expect(throws: CancellationError.self) { try await reconcile.value }
        await #expect(throws: CancellationError.self) { try await sync.reconcile() }
        #expect(try ModelContext(store).fetchCount(FetchDescriptor<PluginRecord>()) == 0)
        #expect(!FileManager.default.fileExists(atPath: plugins.appending(path: "fixture.path").path))
    }

    private actor ImportGate {
        var isPaused: Bool { continuation != nil }
        private var continuation: CheckedContinuation<Void, Never>?

        func pause() async {
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "WillowDriveTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func create(_ directory: DriveSyncDirectory, key: DriveSyncKey) throws {
        try directory.create(key: key) { id in #expect(id == directory.id) }
    }
}
