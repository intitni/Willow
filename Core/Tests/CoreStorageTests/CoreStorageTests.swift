@testable import CoreStorage
import Foundation
import SwiftData
import Testing

@Suite("Core storage", .serialized)
@MainActor
struct CoreStorageTests {
    @Test func `Storage localization keys resolve in English and Simplified Chinese`() throws {
        let englishURL = try #require(L10n.bundle.url(forResource: "en", withExtension: "lproj"))
        let englishBundle = try #require(Bundle(url: englishURL))
        let chineseURL = try #require(L10n.bundle.url(forResource: "zh-Hans", withExtension: "lproj"))
        let chineseBundle = try #require(Bundle(url: chineseURL))
        #expect(String(localized: "LocalTags.NameRequired", bundle: englishBundle) == "Enter a tag name.")
        #expect(String(localized: "LocalTags.NameRequired", bundle: chineseBundle) == "请输入标签名称。")
    }

    @Test func `Library merges records and protects cloud fields`() throws {
        let persistence = try WillowPersistence.make(inMemory: true)
        try #require(persistence.syncStatus == .inMemory, "The in-memory library must be offline.")
        let entity = Schema([ComicRecord.self]).entities.first!
        let attributes = entity.properties.compactMap { $0 as? Schema.Attribute }
        try #require(!attributes.isEmpty && attributes.allSatisfy { $0.options.contains(.allowsCloudEncryption) },
                   "All library and reading history fields must allow CloudKit encryption.")
        let context = persistence.container.mainContext

        let comic = try ComicRecord.findOrCreate(in: context, sourceID: "source", comicID: "comic", title: "Comic")
        comic.isFavorite = true
        comic.collectionName = "Favorites"
        comic.lastReadAt = .now
        comic.chapterID = "chapter"
        comic.pageIndex = 4

        let duplicate = ComicRecord(sourceID: "source", comicID: "comic", title: "Duplicate")
        duplicate.lastReadAt = .distantPast
        context.insert(duplicate)
        try context.save()

        let resolved = try ComicRecord.findOrCreate(in: context, sourceID: "source", comicID: "comic", title: "Updated")
        try context.save()
        let stored = try context.fetch(FetchDescriptor<ComicRecord>())
        try #require(stored.count == 1 && stored.first === resolved, "Duplicate comics must merge by source and comic ID.")
        try #require(resolved.isFavorite && resolved.collectionName == "Favorites", "Favorite and collection must survive a merge.")
        try #require(resolved.chapterID == "chapter" && resolved.pageIndex == 4, "The newest reading progress must survive a merge.")
        try #require(resolved.title == "Updated", "The comic metadata must refresh.")
    }

    @Test func `Local tags persist and isolate comic identities`() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([LocalTagRecord.self])
        let config = ModelConfiguration(schema: schema, url: directory.appending(path: "tags.store"), cloudKitDatabase: .none)
        let firstKey = ComicRecord.identifier(sourceID: "first", comicID: "same-id")
        let secondKey = ComicRecord.identifier(sourceID: "second", comicID: "same-id")
        var tagID: UUID?
        do {
            let container = try ModelContainer(for: schema, configurations: config)
            let context = container.mainContext
            let tag = try LocalTagStore.create("  Favorites  ", comicKey: firstKey, context: context)
            tagID = tag.id
            let reused = try LocalTagStore.create("favorites", comicKey: secondKey, context: context)
            try #require(reused.id == tag.id, "Trimmed case-insensitive names must reuse the same tag model.")
            try #require(tag.comicKeys.count == 2, "Different sources must have separate comic associations.")
            try LocalTagStore.assign(tag.id, to: firstKey, selected: true, context: context)
            try #require(tag.comicKeys.count == 2, "Assignments must be idempotent.")
            try LocalTagStore.assign(tag.id, to: firstKey, selected: false, context: context)
            try #require(tag.comicKeys == [secondKey], "Removing one comic must preserve other associations.")
        }
        do {
            let container = try ModelContainer(for: schema, configurations: config)
            let tags = try container.mainContext.fetch(FetchDescriptor<LocalTagRecord>()).map(LocalTagSnapshot.init)
            try #require(tags.count == 1 && tags[0].id == tagID, "Tags must persist across store reopen.")
            let selected = Set(tags.map(\.id))
            try #require(LocalTagSnapshot.matches(comicKey: secondKey, selected: selected, tags: tags), "Assigned comic must match.")
            try #require(!LocalTagSnapshot.matches(comicKey: firstKey, selected: selected, tags: tags), "Removed association must not match.")
            try #require(LocalTagSnapshot.matches(comicKey: firstKey, selected: [], tags: tags), "Empty selection must show all comics.")
        }
    }

    @Test func `App lock preference persists`() throws {
        let suite = "WillowCore-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure("Cannot open isolated defaults.") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let unprotected = AppLock(defaults: defaults)
        unprotected.lock()
        try #require(!unprotected.isEnabled && !unprotected.isLocked, "The lock must be disabled by default.")

        defaults.set(true, forKey: "willow.biometricLockEnabled")
        let protected = AppLock(defaults: defaults)
        try #require(protected.isEnabled && protected.isLocked, "An enabled lock must start locked.")
    }

    @Test func `Downloads resume across launches and remove local files`() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([DownloadRecord.self])
        let configuration = ModelConfiguration(
            schema: schema, url: directory.appending(path: "device.store"), cloudKitDatabase: .none
        )
        let files = directory.appending(path: "Downloads")
        let page = directory.appending(path: "fixture.image")
        try Data("download fixture".utf8).write(to: page)
        let headers = [["Referer": "https://example.com"]]

        func openStore() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: configuration)
        }

        do {
            let container = try openStore()
            let context = container.mainContext
            let manager = DownloadManager(context: context, directory: files)
            try #require(try files.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                       "Existing and new download directories must be excluded from backup.")
            let record = try await manager.enqueue(
                sourceID: "source", comicID: "comic", chapterID: "chapter",
                title: "Chapter", pageURLs: [page], requestHeaders: headers
            )
            let duplicate = try await manager.enqueue(
                sourceID: "source", comicID: "comic", chapterID: "chapter",
                title: "Chapter", pageURLs: [page], requestHeaders: headers
            )
            try #require(duplicate === record, "Enqueue must reuse an existing chapter download.")
            manager.pause(record)
            try #require(record.status == .paused, "A queued chapter must pause.")
            manager.resume(record)
            try await waitForCompletion(record)
            try #require(manager.localPageURLs(for: record).count == 1, "A completed chapter must expose its local page.")

            let interrupted = DownloadRecord(
                sourceID: "source", comicID: "comic", chapterID: "interrupted",
                title: "Interrupted chapter", pageURLs: [page], requestHeaders: headers
            )
            interrupted.status = .downloading
            context.insert(interrupted)
            try context.save()
        }

        do {
            let container = try openStore()
            let context = container.mainContext
            let manager = DownloadManager(context: context, directory: files)
            try #require(try files.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                       "Existing and new download directories must be excluded from backup.")
            let records = try context.fetch(FetchDescriptor<DownloadRecord>())
            guard let interrupted = records.first(where: { $0.chapterID == "interrupted" }) else {
                throw Failure("The interrupted chapter must persist across store launches.")
            }
            try #require(interrupted.pageURLs == [page] && interrupted.requestHeaders == headers, "The manifest must persist.")
            try await waitForCompletion(interrupted)
            try #require(manager.localPageURLs(sourceID: "source", comicID: "comic", chapterID: "chapter")?.count == 1,
                       "Completed chapters must open offline after a restart.")

            let downloadedPage = manager.localPageURLs(for: interrupted).first
            try await manager.delete(interrupted)
            let remaining = try context.fetch(FetchDescriptor<DownloadRecord>())
            try #require(remaining.count == 1, "Deleting a download must remove its record.")
            try #require(downloadedPage.map { !FileManager.default.fileExists(atPath: $0.path) } == true,
                       "Deleting a download must remove its files.")
        }
    }

    @Test func `Deleting an active download cannot recreate its files`() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try WillowPersistence.make(inMemory: true)
        let context = persistence.container.mainContext
        let downloadDirectory = directory.appending(path: "Downloads")
        let manager = DownloadManager(context: context, directory: downloadDirectory)
        let page = directory.appending(path: "large.image")
        try Data(repeating: 0x41, count: 4 * 1024 * 1024).write(to: page)
        let record = try await manager.enqueue(sourceID: "source", comicID: "comic", chapterID: "active",
            title: "Active", pageURLs: Array(repeating: page, count: 20))
        await Task.yield()
        try await manager.delete(record)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try context.fetchCount(FetchDescriptor<DownloadRecord>()) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloadDirectory.path).isEmpty)
    }

    #if WILLOW_TESTING
    @Test func `Visible pages outrank prefetch and stale prefetch cancels`() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ControlledImages()
        let cache = ImageCache(directory: directory) { url in await transport.load(url) }
        func request(_ name: String, priority: ImageCache.Priority) -> Task<Data, Error> {
            Task { try await cache.data(for: URL(string: "https://example.com/\(name)")!, priority: priority) }
        }
        let initial = (0..<6).map { request("initial-\($0)", priority: .download) }
        try await waitUntil { await transport.started.count == 6 }
        let download = request("download", priority: .download)
        let cover = request("cover", priority: .thumbnail)
        let prefetch = request("prefetch", priority: .prefetch)
        let reading = request("reading", priority: .reading)
        let hidden = request("hidden", priority: .prefetch)
        try await waitUntil { await cache.queuedRequestCount == 5 }
        hidden.cancel()
        try await waitUntil { await cache.queuedRequestCount == 4 }
        await transport.release("initial-0")
        try await waitUntil { await transport.started.count == 7 }
        #expect(await transport.started.last == "reading")
        await transport.release("reading")
        try await waitUntil { await transport.started.count == 8 }
        #expect(await transport.started.last == "prefetch")
        await transport.release("prefetch")
        try await waitUntil { await transport.started.count == 9 }
        #expect(await transport.started.last == "cover")
        await transport.release("cover")
        try await waitUntil { await transport.started.count == 10 }
        #expect(await transport.started.last == "download")
        #expect(await !transport.started.contains("hidden"))
        await transport.releaseAll()
        for task in initial + [download, cover, prefetch, reading] { _ = try await task.value }
        do { _ = try await hidden.value; Issue.record("A stale queued prefetch must be cancelled.") }
        catch is CancellationError { }
        // A repeat request must hit disk without invoking the transport again.
        _ = try await cache.data(for: URL(string: "https://example.com/prefetch")!, priority: .reading)
        #expect(await transport.started.count == 10)
        let offscreenPage = request("offscreen-page", priority: .reading)
        try await waitUntil { await transport.started.count == 11 }
        offscreenPage.cancel()
        do { _ = try await offscreenPage.value; Issue.record("The disappearing view must stop waiting.") }
        catch is CancellationError { }
        await transport.release("offscreen-page")
        _ = try await cache.data(for: URL(string: "https://example.com/offscreen-page")!, priority: .reading)
        #expect(await transport.started.count == 11, "A reading image continues after its view disappears.")
    }

    @Test func `Cancelled prefetch keeps its slot without blocking visible pages`() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ControlledImages()
        let cache = ImageCache(directory: directory) { url in await transport.load(url) }
        func request(_ name: String, priority: ImageCache.Priority) -> Task<Data, Error> {
            Task { try await cache.data(for: URL(string: "https://example.com/\(name)")!, priority: priority) }
        }

        let oldChapter = (0..<4).map { request("old-\($0)", priority: .prefetch) }
        try await waitUntil { await cache.queuedRequestCount == 2 }
        try await waitUntil { await transport.started.count == 2 }
        let started = await transport.started
        for task in oldChapter { task.cancel() }
        for task in oldChapter {
            do { _ = try await task.value; Issue.record("A cancelled reader must stop waiting for prefetch.") }
            catch is CancellationError { }
        }

        // The transport intentionally ignores cancellation, just as an active plugin call can.
        let nextVisiblePrefetch = request("new-first", priority: .prefetch)
        try await waitUntil { await cache.queuedRequestCount == 1 }
        let first = request("new-first", priority: .reading)
        let second = request("new-second", priority: .reading)
        try await waitUntil { await transport.started.count == 4 }
        #expect(Set(await transport.started.dropFirst(2)) == ["new-first", "new-second"])

        let upcoming = request("new-third", priority: .prefetch)
        try await waitUntil { await cache.queuedRequestCount == 1 }
        await transport.release(started[0])
        try await waitUntil { await transport.started.count == 5 }
        #expect(await transport.started.last == "new-third")
        await transport.releaseAll()
        for task in [nextVisiblePrefetch, first, second, upcoming] { _ = try await task.value }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure("The image queue did not reach the expected state.")
    }

    private actor ControlledImages {
        private(set) var started: [String] = []
        private var waiting: [String: CheckedContinuation<Data, Never>] = [:]
        private let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
        func load(_ url: URL) async -> Data {
            started.append(url.lastPathComponent)
            return await withCheckedContinuation { waiting[url.lastPathComponent] = $0 }
        }
        func release(_ name: String) { waiting.removeValue(forKey: name)?.resume(returning: image) }
        func releaseAll() {
            let continuations = waiting.values
            waiting.removeAll()
            for continuation in continuations { continuation.resume(returning: image) }
        }
    }
    #endif

    @MainActor
    private func waitForCompletion(_ record: DownloadRecord) async throws {
        for _ in 0..<100 {
            if record.status == .completed { return }
            if record.status == .failed { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure("Chapter \(record.chapterID) did not finish: \(record.errorMessage ?? record.status.rawValue)")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "WillowCore-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
