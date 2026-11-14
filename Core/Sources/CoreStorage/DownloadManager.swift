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
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var activeID: String?
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
            if let activeID, let record = try? context.fetch(FetchDescriptor<DownloadRecord>()).first(where: { $0.id == activeID }) {
                try? changeStatus(of: record, to: .queued)
            }
            worker?.cancel()
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

    package init(context: ModelContext, directory: URL? = nil) {
        self.context = context
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
        defer { fileOperations.remove(id) }
        if let existing = try record(sourceID: sourceID, comicID: comicID, chapterID: chapterID) {
            if existing.status == .failed || existing.status == .paused {
                if existing.pageURLs != pageURLs {
                    try await files.remove(folder(for: existing))
                    existing.pageURLs = pageURLs
                    existing.completedPageCount = 0
                }
                existing.requestHeaders = requestHeaders
                try changeStatus(of: existing, to: .queued)
                startQueue()
            } else if existing.status == .completed && localPageURLs(for: existing).count != existing.pageURLs.count {
                try changeStatus(of: existing, to: .queued)
                startQueue()
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
        startQueue()
        return record
    }

    package func pause(_ record: DownloadRecord) {
        guard [.queued, .downloading].contains(record.status) else { return }
        do {
            try changeStatus(of: record, to: .paused)
            if activeID == record.id { worker?.cancel() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    package func resume(_ record: DownloadRecord) {
        guard !fileOperations.contains(record.id), [.paused, .failed].contains(record.status) else { return }
        do {
            try changeStatus(of: record, to: .queued)
            startQueue()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    package func delete(_ record: DownloadRecord) async throws {
        let id = record.id
        guard fileOperations.insert(id).inserted else { throw DownloadError.operationInProgress }
        defer { fileOperations.remove(id) }
        let folder = folder(for: record)
        let staging = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let shouldResume = record.status == .queued || record.status == .downloading
        if shouldResume { pause(record) }
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
        guard worker == nil, !backgroundExpired else { return }
        beginBackgroundDownload()
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                activeID = nil
                worker = nil
                endBackgroundDownload()
                if Task.isCancelled { startQueue() }
            }
            do {
                let queued = DownloadStatus.queued.rawValue
                var descriptor = FetchDescriptor<DownloadRecord>(
                    predicate: #Predicate { $0.rawStatus == queued },
                    sortBy: [SortDescriptor(\.createdAt)]
                )
                descriptor.fetchLimit = 1
                while !Task.isCancelled, let record = try context.fetch(descriptor).first {
                    activeID = record.id
                    try await download(record)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func download(_ record: DownloadRecord) async throws {
        try changeStatus(of: record, to: .downloading)
        let folder = folder(for: record)
        let pages = record.pageURLs
        let headers = record.requestHeaders ?? []
        do {
            try await files.prepare(folder)
            for (index, url) in pages.enumerated() {
                try Task.checkCancellation()
                let file = pageURL(in: folder, index: index)
                if !(await files.contains(file)) {
                    let requestHeaders = headers.indices.contains(index) ? headers[index] : [:]
                    let data = try await ImageCache.shared.data(for: url, headers: requestHeaders, priority: .download)
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
    package enum Priority: Int, Sendable { case download, thumbnail, prefetch, reading }
    private struct Consumer {
        let priority: Priority
        let continuation: CheckedContinuation<Data, Error>
    }
    private struct Request {
        let id = UUID()
        let url: URL
        let headers: [String: String]
        let file: URL
        var consumers: [UUID: Consumer]
        var continuesWithoutView = false
        var task: Task<Void, Never>?

        var priority: Int { consumers.values.map(\.priority.rawValue).max() ?? -1 }
    }
    private var requests: [String: Request] = [:]
    private var pending: [String] = []
    private var activeRequests = 0
    private var activePrefetches = 0

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

    package func data(for url: URL, headers: [String: String] = [:], priority: Priority = .thumbnail) async throws -> Data {
        try Task.checkCancellation()
        if url.isFileURL {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }

        try LocalImageStorage.prepare(directory)
        let headerKey = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        let identity = url.scheme == "willow-plugin" ? "willow-plugin/" + url.lastPathComponent : url.absoluteString
        let key = Self.fileKey(for: "\(identity)\n\(headerKey)")
        let file = directory.appending(path: key)
        if let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path(percentEncoded: false))
            return data
        }

        let consumer = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let subscriber = Consumer(priority: priority, continuation: continuation)
                if requests[key] != nil {
                    requests[key]?.consumers[consumer] = subscriber
                } else {
                    requests[key] = Request(url: url, headers: headers, file: file,
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
            requests[key]?.task?.cancel()
            requests[key] = nil
            pending.removeAll { $0 == key }
        }
    }

    private func startRequests() {
        while activeRequests < 6 {
            let prefetchLimitReached = activePrefetches >= 2
            var selected: (index: Int, priority: Int)?
            // Keep FIFO ordering for equal priorities among requests that can start now.
            for index in pending.indices {
                guard let priority = requests[pending[index]]?.priority,
                      priority > (selected?.priority ?? Int.min),
                      !prefetchLimitReached || priority != Priority.prefetch.rawValue else { continue }
                selected = (index, priority)
            }
            guard let (index, priority) = selected else { return }
            let key = pending.remove(at: index)
            guard let request = requests[key] else { continue }
            let startedAsPrefetch = priority == Priority.prefetch.rawValue
            if startedAsPrefetch { activePrefetches += 1 }
            activeRequests += 1
            requests[key]?.task = Task {
                let result: Result<Data, Error>
                do { result = .success(try await fetch(request.url, headers: request.headers, file: request.file)) }
                catch { result = .failure(error) }
                finish(key: key, id: request.id, startedAsPrefetch: startedAsPrefetch, result: result)
            }
        }
    }

    private func finish(key: String, id: UUID, startedAsPrefetch: Bool, result: Result<Data, Error>) {
        let request = requests[key]?.id == id ? requests.removeValue(forKey: key) : nil
        // A cancelled plugin call can keep running until the Rust bridge returns.
        if startedAsPrefetch { activePrefetches -= 1 }
        activeRequests -= 1
        for consumer in request?.consumers.values ?? Dictionary<UUID, Consumer>().values {
            consumer.continuation.resume(with: result)
        }
        startRequests()
    }

    private func fetch(_ url: URL, headers: [String: String], file: URL) async throws -> Data {
        let data: Data
        if let transport {
            data = try await transport(url)
        } else {
        switch url.scheme?.lowercased() {
        case "willow-plugin":
            data = try await PluginImageGateway.shared.data(for: url)
        case "https", "http":
            var request = URLRequest(url: url)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (body, response) = try await URLSession.shared.data(for: request)
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

        if data.count <= byteLimit {
            try? store(data, at: file)
        }
        return data
    }

    nonisolated static func fileKey(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func store(_ data: Data, at file: URL) throws {
        let manager = FileManager.default
        try LocalImageStorage.prepare(directory)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])

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
