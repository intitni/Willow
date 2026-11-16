import BreezeRuntime
import CryptoKit
import Foundation
import ImageIO
import Observation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
package final class DownloadManager {
    private static let maximumConcurrentChapters = 3

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let imageCache: ImageCache
    @ObservationIgnored private var workers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let files = DownloadFileStore()
    @ObservationIgnored private var fileOperations = Set<String>()

    @ObservationIgnored private var backgroundExpired = false
    #if canImport(UIKit)
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    package func resumeForegroundDownloads() {
        backgroundExpired = false
        startQueue()
    }

    private func beginBackgroundDownload() {
        #if canImport(UIKit)
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Willow Downloads") { [weak self] in
            guard let self else { return }
            backgroundExpired = true
            let downloading = DownloadStatus.downloading.rawValue
            let descriptor = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.rawStatus == downloading })
            for record in (try? context.fetch(descriptor)) ?? [] where workers[record.id] != nil {
                try? changeStatus(of: record, to: .queued)
            }
            for worker in workers.values { worker.cancel() }
            endBackgroundDownload()
        }
        #endif
    }

    private func endBackgroundDownload() {
        #if canImport(UIKit)
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        #endif
    }

    package private(set) var errorMessage: String?

    package init(context: ModelContext, directory: URL? = nil, imageCache: ImageCache = .shared) {
        self.context = context
        self.imageCache = imageCache
        self.directory = directory ?? URL.applicationSupportDirectory
            .appending(path: "Willow/Downloads", directoryHint: .isDirectory)

        do {
            try LocalImageStorage.prepare(self.directory)
            let interruptedStatus = DownloadStatus.downloading.rawValue
            let interrupted = try context.fetch(FetchDescriptor<DownloadRecord>(
                predicate: #Predicate { $0.rawStatus == interruptedStatus }
            ))
            for record in interrupted {
                record.status = .queued
            }
            if !interrupted.isEmpty { try context.save() }
            startQueue()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    package func enqueue(
        sourceID: String,
        comicID: String,
        chapterID: String,
        title: String,
        pageURLs: [URL],
        requestHeaders: [[String: String]]? = nil
    ) async throws -> DownloadRecord {
        guard !pageURLs.isEmpty else { throw DownloadError.emptyChapter }
        let id = DownloadRecord.identifier(sourceID: sourceID, comicID: comicID, chapterID: chapterID)
        guard fileOperations.insert(id).inserted else { throw DownloadError.operationInProgress }
        defer {
            fileOperations.remove(id)
            startQueue()
        }
        if let existing = try record(sourceID: sourceID, comicID: comicID, chapterID: chapterID) {
            if existing.status == .failed || existing.status == .paused {
                if existing.pageURLs != pageURLs {
                    await workers[id]?.value
                    try await files.remove(folder(for: existing))
                    existing.pageURLs = pageURLs
                    existing.completedPageCount = 0
                }
                existing.requestHeaders = requestHeaders
                try changeStatus(of: existing, to: .queued)
            } else if existing.status == .completed && localPageURLs(for: existing).count != existing.pageURLs.count {
                try changeStatus(of: existing, to: .queued)
            }
            return existing
        }

        let record = DownloadRecord(
            sourceID: sourceID, comicID: comicID, chapterID: chapterID,
            title: title, pageURLs: pageURLs, requestHeaders: requestHeaders
        )
        context.insert(record)
        do {
            try context.save()
        } catch {
            context.delete(record)
            throw error
        }
        return record
    }

    package func pause(_ record: DownloadRecord) {
        guard !fileOperations.contains(record.id), [.queued, .downloading].contains(record.status) else { return }
        do {
            try changeStatus(of: record, to: .paused)
            workers[record.id]?.cancel()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    package func resume(_ record: DownloadRecord) {
        guard !fileOperations.contains(record.id), [.paused, .failed].contains(record.status) else { return }
        do {
            try changeStatus(of: record, to: .queued)
            errorMessage = nil
            startQueue()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    package func delete(_ record: DownloadRecord) async throws {
        let id = record.id
        guard fileOperations.insert(id).inserted else { throw DownloadError.operationInProgress }
        defer {
            fileOperations.remove(id)
            startQueue()
        }
        let folder = folder(for: record)
        let staging = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let shouldResume = record.status == .queued || record.status == .downloading
        if shouldResume {
            try changeStatus(of: record, to: .paused)
            workers[id]?.cancel()
        }
        await workers[id]?.value
        do {
            let hasFiles = try await files.stage(folder, at: staging)
            context.delete(record)
            do { try context.save() }
            catch {
                context.insert(record)
                if hasFiles { try await files.restore(staging, to: folder) }
                throw error
            }
            if hasFiles { try await files.remove(staging) }
        } catch {
            fileOperations.remove(id)
            if shouldResume, record.modelContext != nil { resume(record) }
            throw error
        }
    }

    package func localPageURLs(for record: DownloadRecord) -> [URL] {
        guard record.status == .completed else { return [] }
        let folder = folder(for: record)
        let pages = record.pageURLs.indices.map { pageURL(in: folder, index: $0) }
        return pages.allSatisfy(fileExists) ? pages : []
    }

    package func localPageURLs(sourceID: String, comicID: String, chapterID: String) -> [URL]? {
        guard let record = try? record(sourceID: sourceID, comicID: comicID, chapterID: chapterID) else {
            return nil
        }
        let pages = localPageURLs(for: record)
        return pages.isEmpty ? nil : pages
    }

    private func record(sourceID: String, comicID: String, chapterID: String) throws -> DownloadRecord? {
        let id = DownloadRecord.identifier(sourceID: sourceID, comicID: comicID, chapterID: chapterID)
        var descriptor = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func changeStatus(
        of record: DownloadRecord,
        to status: DownloadStatus,
        errorMessage: String? = nil
    ) throws {
        let previousStatus = record.status
        let previousDate = record.updatedAt
        let previousError = record.errorMessage
        record.status = status
        record.updatedAt = .now
        record.errorMessage = errorMessage
        do {
            try context.save()
        } catch {
            record.status = previousStatus
            record.updatedAt = previousDate
            record.errorMessage = previousError
            throw error
        }
    }

    private func startQueue() {
        guard !backgroundExpired, workers.count < Self.maximumConcurrentChapters else { return }
        do {
            let queued = DownloadStatus.queued.rawValue
            let descriptor = FetchDescriptor<DownloadRecord>(
                predicate: #Predicate { $0.rawStatus == queued },
                sortBy: [SortDescriptor(\.createdAt)]
            )
            for record in try context.fetch(descriptor) {
                guard workers.count < Self.maximumConcurrentChapters else { break }
                let id = record.id
                guard workers[id] == nil, !fileOperations.contains(id) else { continue }
                try changeStatus(of: record, to: .downloading)
                beginBackgroundDownload()
                workers[id] = Task {
                    do {
                        try await download(record)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    workers[id] = nil
                    startQueue()
                    if workers.isEmpty { endBackgroundDownload() }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func download(_ record: DownloadRecord) async throws {
        let folder = folder(for: record)
        let pages = record.pageURLs
        let headers = record.requestHeaders ?? []
        do {
            try Task.checkCancellation()
            try await files.prepare(folder)
            for (index, url) in pages.enumerated() {
                try Task.checkCancellation()
                let file = pageURL(in: folder, index: index)
                if !(await files.contains(file)) {
                    let requestHeaders = headers.indices.contains(index) ? headers[index] : [:]
                    let data = try await imageCache.data(for: url, headers: requestHeaders, priority: .download)
                    try Task.checkCancellation()
                    try await files.write(data, to: file)
                }
                try Task.checkCancellation()
                record.completedPageCount = index + 1
                record.updatedAt = .now
                try context.save()
            }
            try changeStatus(of: record, to: .completed)
        } catch {
            if Task.isCancelled { return }
            try changeStatus(of: record, to: .failed, errorMessage: error.localizedDescription)
        }
    }

    private func folder(for record: DownloadRecord) -> URL {
        directory.appending(path: ImageCache.fileKey(for: record.id), directoryHint: .isDirectory)
    }

    private func pageURL(in folder: URL, index: Int) -> URL {
        folder.appending(path: "\(index).image")
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}

private enum DownloadError: LocalizedError {
    case emptyChapter
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .emptyChapter: L10n.text("Downloads.EmptyChapter")
        case .operationInProgress: L10n.text("Downloads.FileOperationInProgress")
        }
    }
}

package actor ImageCache {
    package static let shared = ImageCache()

    private let directory: URL
    private let byteLimit: Int
    private let transport: (@Sendable (URL) async throws -> Data)?
    private static let coverLifetime: TimeInterval = 30 * 24 * 60 * 60
    package enum Priority: Int, Sendable { case download, thumbnail, prefetch, reading }
    package enum Policy: Hashable, Sendable {
        case byURL
        case comicCover(id: String)

        fileprivate var coverID: String? {
            guard case .comicCover(let id) = self else { return nil }
            return id
        }
    }
    private struct Consumer {
        let priority: Priority
        let continuation: CheckedContinuation<Data, Error>
    }
    private struct Request {
        let id = UUID()
        let url: URL
        let headers: [String: String]
        let file: URL
        let validatesThumbnail: Bool
        var consumers: [UUID: Consumer]
        var continuesWithoutView = false
        var task: Task<Void, Never>?

        var priority: Int { consumers.values.map(\.priority.rawValue).max() ?? -1 }
    }
    private var requests: [String: Request] = [:]
    private var pending: [String] = []
    private var activeRequests = 0
    private var activePrefetches = 0
    private var activeThumbnails = 0

    package init(directory: URL? = nil, byteLimit: Int = 256 * 1024 * 1024,
                 transport: (@Sendable (URL) async throws -> Data)? = nil) {
        self.directory = directory ?? URL.cachesDirectory
            .appending(path: "Willow/Images", directoryHint: .isDirectory)
        self.byteLimit = byteLimit
        self.transport = transport
    }

    #if WILLOW_TESTING
    package var queuedRequestCount: Int { pending.count }
    #endif

    private func fallbackCover(for url: URL?, coverID: String) -> URL? {
        let file = directory.appending(path: Self.coverKey(coverID))
        if url == nil || Self.freshCoverDate(at: file) == nil,
           FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        guard let url, !url.isFileURL, !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            return nil
        }
        let legacyFile = directory.appending(path: Self.urlKey(for: url, headers: [:]))
        return Self.freshCoverDate(at: legacyFile) == nil ? legacyFile : nil
    }

    package func load<Value: Sendable>(for url: URL?, priority: Priority, policy: Policy,
                                       decode: @Sendable (Data) async -> Value?,
                                       showFallback: @Sendable (Value) async -> Void) async throws -> Value? {
        try Task.checkCancellation()
        if let coverID = policy.coverID, let file = fallbackCover(for: url, coverID: coverID),
           let (_, value) = try await cachedValue(at: file, decode: decode) {
            await showFallback(value)
        }
        guard let url else { return nil }
        return try await loadValue(for: url, headers: [:], priority: priority, policy: policy, decode: decode)
    }

    package func data(for url: URL, headers: [String: String] = [:], priority: Priority = .thumbnail,
                      policy: Policy = .byURL) async throws -> Data {
        let validatesThumbnail = policy.coverID != nil || priority == .thumbnail
        return try await loadValue(for: url, headers: headers, priority: priority, policy: policy) { data in
            if validatesThumbnail, !url.isFileURL, !(await Self.isDecodableThumbnail(data)) { return nil }
            return data
        }
    }

    private func loadValue<Value: Sendable>(for url: URL, headers: [String: String], priority: Priority,
                                            policy: Policy, decode: @Sendable (Data) async -> Value?) async throws -> Value {
        try Task.checkCancellation()
        if url.isFileURL {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let value = await decode(data) else { throw URLError(.cannotDecodeContentData) }
            return value
        }

        try LocalImageStorage.prepare(directory)
        let coverID = policy.coverID
        let urlKey = Self.urlKey(for: url, headers: headers)
        let key = coverID.map(Self.coverKey) ?? urlKey
        let file = directory.appending(path: key)
        if (coverID == nil || Self.freshCoverDate(at: file) != nil),
           let (_, value) = try await cachedValue(at: file, decode: decode) { return value }
        let legacyFile = directory.appending(path: urlKey)
        if coverID != nil, !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)),
           let fetchedAt = Self.freshCoverDate(at: legacyFile),
           let (data, value) = try await cachedValue(at: legacyFile, decode: decode) {
            if requests[key] == nil, !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                try? store(data, at: file, fetchedAt: fetchedAt)
            }
            return value
        }
        let data = try await fetchData(for: url, headers: headers, priority: priority, key: key, file: file,
                                       validatesThumbnail: coverID != nil || priority == .thumbnail)
        try Task.checkCancellation()
        guard let value = await decode(data) else { throw URLError(.cannotDecodeContentData) }
        return value
    }

    private func fetchData(for url: URL, headers: [String: String], priority: Priority, key: String, file: URL,
                           validatesThumbnail: Bool) async throws -> Data {
        let consumer = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let subscriber = Consumer(priority: priority, continuation: continuation)
                if requests[key] != nil {
                    requests[key]?.consumers[consumer] = subscriber
                } else {
                    requests[key] = Request(url: url, headers: headers, file: file, validatesThumbnail: validatesThumbnail,
                                            consumers: [consumer: subscriber])
                    pending.append(key)
                }
                if priority == .reading { requests[key]?.continuesWithoutView = true }
                startRequests()
            }
        } onCancel: {
            Task { await self.cancel(key: key, consumer: consumer) }
        }
    }

    private func cancel(key: String, consumer: UUID) {
        guard let subscriber = requests[key]?.consumers.removeValue(forKey: consumer) else { return }
        subscriber.continuation.resume(throwing: CancellationError())
        if requests[key]?.consumers.isEmpty == true {
            // 阅读页离屏后继续写入缓存，等待中的请求自然降为后台优先级。
            if requests[key]?.continuesWithoutView == true { return }
            // Another screen can attach to a cover fetch that has already started.
            if subscriber.priority == .thumbnail, requests[key]?.task != nil { return }
            requests[key]?.task?.cancel()
            requests[key] = nil
            pending.removeAll { $0 == key }
        }
    }

    private func startRequests() {
        while activeRequests < 6 {
            var selected: (index: Int, priority: Int)?
            // Keep FIFO ordering for equal priorities among requests that can start now.
            for index in pending.indices {
                guard let priority = requests[pending[index]]?.priority,
                      priority > (selected?.priority ?? Int.min),
                      priority != Priority.prefetch.rawValue || activePrefetches < 2,
                      priority != Priority.thumbnail.rawValue || activeThumbnails < 2 else { continue }
                selected = (index, priority)
            }
            guard let (index, priority) = selected else { return }
            let key = pending.remove(at: index)
            guard let request = requests[key] else { continue }
            let startedPriority = Priority(rawValue: priority)
            if startedPriority == .prefetch { activePrefetches += 1 }
            if startedPriority == .thumbnail { activeThumbnails += 1 }
            activeRequests += 1
            requests[key]?.task = Task {
                let result: Result<Data, Error>
                do { result = .success(try await fetch(request)) }
                catch { result = .failure(error) }
                finish(key: key, id: request.id, startedPriority: startedPriority, result: result)
            }
        }
    }

    private func finish(key: String, id: UUID, startedPriority: Priority?, result: Result<Data, Error>) {
        let request = requests[key]?.id == id ? requests.removeValue(forKey: key) : nil
        // A cancelled plugin call can keep running until the Rust bridge returns.
        if startedPriority == .prefetch { activePrefetches -= 1 }
        if startedPriority == .thumbnail { activeThumbnails -= 1 }
        activeRequests -= 1
        for consumer in request?.consumers.values ?? Dictionary<UUID, Consumer>().values {
            consumer.continuation.resume(with: result)
        }
        startRequests()
    }

    private func fetch(_ request: Request) async throws -> Data {
        let url = request.url
        let data: Data
        if let transport {
            data = try await transport(url)
        } else {
        switch url.scheme?.lowercased() {
        case "willow-plugin":
            data = try await PluginImageGateway.shared.data(for: url)
        case "https", "http":
            var urlRequest = URLRequest(url: url)
            for (name, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
            let (body, response) = try await URLSession.shared.data(for: urlRequest)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            data = body
        default:
            throw URLError(.unsupportedURL)
        }
        }
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0 else {
            throw URLError(.cannotDecodeContentData)
        }
        if request.validatesThumbnail, !(await Self.isDecodableThumbnail(data)) {
            throw URLError(.cannotDecodeContentData)
        }

        try Task.checkCancellation()
        if data.count <= byteLimit {
            try? store(data, at: request.file)
        }
        return data
    }

    nonisolated static func fileKey(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func coverKey(_ coverID: String) -> String {
        fileKey(for: "Willow cover\n\(coverID)")
    }

    private static func urlKey(for url: URL, headers: [String: String]) -> String {
        let headerKey = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        let identity = url.scheme == "willow-plugin" ? "willow-plugin/" + url.lastPathComponent : url.absoluteString
        return fileKey(for: "\(identity)\n\(headerKey)")
    }

    private func cachedValue<Value: Sendable>(at file: URL, decode: @Sendable (Data) async -> Value?) async throws -> (Data, Value)? {
        while let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
            let value = await decode(data)
            try Task.checkCancellation()
            if let value {
                try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path(percentEncoded: false))
                return (data, value)
            }
            // Another request may have replaced the file while decoding.
            guard let current = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
            if current == data {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
        }
        return nil
    }

    @concurrent
    package static func decodeThumbnail(_ data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    private static func isDecodableThumbnail(_ data: Data) async -> Bool {
        await decodeThumbnail(data) != nil
    }

    private static func freshCoverDate(at file: URL) -> Date? {
        // Modification time tracks cache use for eviction. Creation time tracks freshness.
        guard let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
              Date.now.timeIntervalSince(created) < coverLifetime else { return nil }
        return created
    }

    private func store(_ data: Data, at file: URL, fetchedAt: Date = .now) throws {
        let manager = FileManager.default
        try LocalImageStorage.prepare(directory)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? manager.setAttributes([.creationDate: fetchedAt], ofItemAtPath: file.path(percentEncoded: false))

        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        let entries = files.compactMap { file -> (url: URL, size: Int, date: Date)? in
            guard let values = try? file.resourceValues(forKeys: keys), let size = values.fileSize else { return nil }
            return (file, size, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        if total <= byteLimit { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try manager.removeItem(at: entry.url)
            total -= entry.size
            if total <= byteLimit { break }
        }
    }
}

/// Serializes disk operations off MainActor, including deletion versus an in-flight page write.
private actor DownloadFileStore {
    func prepare(_ directory: URL) throws { try LocalImageStorage.prepare(directory) }
    func contains(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func write(_ data: Data, to url: URL) throws {
        try Task.checkCancellation()
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func stage(_ source: URL, at destination: URL) throws -> Bool {
        guard contains(source) else { return false }
        try FileManager.default.moveItem(at: source, to: destination)
        return true
    }
    func restore(_ source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }
    func remove(_ url: URL) throws {
        if contains(url) { try FileManager.default.removeItem(at: url) }
    }
}
