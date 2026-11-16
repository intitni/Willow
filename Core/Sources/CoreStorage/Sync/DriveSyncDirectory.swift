import CryptoKit
import Foundation

package struct DriveSyncFolder: Codable, Equatable, Sendable {
    package let id: UUID
    package let name: String
    let bookmark: Data

    static func makeBookmark(_ url: URL) throws -> Data {
        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        defer { url.stopAccessingSecurityScopedResource() }
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = .withSecurityScope
        #else
        let options: URL.BookmarkCreationOptions = .minimalBookmark
        #endif
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve() throws -> URL {
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = .withoutUI
        #endif
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw CocoaError(.fileReadNoPermission) }
        return url
    }
}

struct SyncRevision: Codable, Sendable {
    private(set) var format = 1
    let revision: String
    let key: String
    let payload: Data?
    let modifiedAt: Date
    let deleted: Bool
    let seed: Bool?

    init(revision: String = UUID().uuidString, key: String, payload: Data?, modifiedAt: Date, deleted: Bool, seed: Bool? = nil) {
        self.revision = revision
        self.key = key
        self.payload = payload
        self.modifiedAt = modifiedAt
        self.deleted = deleted
        self.seed = seed
    }

    var orderingDate: Date {
        if seed == true && !isPluginRating { return .distantPast }
        // Legacy reading files used their publication time. Recover the actual
        // reading time from the payload, while old tombstones use their saved time.
        guard !deleted, !isReadChapter, key.hasPrefix("reading/"), let payload,
              case .reading(let reading) = try? JSONDecoder().decode(PreferencePayload.self, from: payload)
        else { return modifiedAt }
        return reading.lastReadAt
    }

    var isReadChapter: Bool { key.hasPrefix(PreferencePayload.ReadChapter.keyPrefix) }
    var isPluginRating: Bool { key.hasPrefix(PreferencePayload.PluginRating.keyPrefix) }

    var isFollowedComic: Bool { key.hasPrefix(PreferencePayload.followedComicKeyPrefix) }

    // Older Drive clients only read .record files and reject unknown payloads.
    static let chapterFileExtension = "chapter"
    static let pluginRatingFileExtension = "rating"
    static let followedComicFileExtension = "follow"
    var filename: String {
        let fileExtension: String
        if isReadChapter { fileExtension = Self.chapterFileExtension }
        else if isPluginRating { fileExtension = Self.pluginRatingFileExtension }
        else if isFollowedComic { fileExtension = Self.followedComicFileExtension }
        else { fileExtension = "record" }
        return revision + "." + fileExtension
    }

    func precedes(_ other: Self) -> Bool {
        (orderingDate, revision) < (other.orderingDate, other.revision)
    }

    func validated(filename: String) throws -> Self {
        guard format == 1, let id = UUID(uuidString: revision), revision == id.uuidString,
              filename == self.filename, modifiedAt.timeIntervalSinceReferenceDate.isFinite,
              let payload, try JSONDecoder().decode(PreferencePayload.self, from: payload).key == key else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return self
    }
}

/// Each version has a unique filename, so two devices can publish while offline.
struct DriveSyncDirectory: Sendable {
    let id: UUID
    let root: URL
    let securityScoped: Bool

    init(folder: DriveSyncFolder) throws {
        id = folder.id
        root = try folder.resolve()
        securityScoped = true
    }

    init(id: UUID = UUID(), root: URL, securityScoped: Bool = false) {
        self.id = id
        self.root = root
        self.securityScoped = securityScoped
    }

    var directory: URL { root.appending(path: "Willow Sync v1", directoryHint: .isDirectory) }

    func withAccess<T>(_ body: () throws -> T) throws -> T {
        let accessing = securityScoped && root.startAccessingSecurityScopedResource()
        guard !securityScoped || accessing else { throw CocoaError(.fileReadNoPermission) }
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private let markerName = "key.v1"

    private func markerHeader(_ id: UUID) -> String { "Willow Drive v1/" + id.uuidString }

    func create(key: DriveSyncKey, saveKey: (UUID) throws -> Void) throws {
        try withAccess {
            try coordinateWrite(directory) { url in
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            try coordinateWrite(directory.appending(path: markerName)) { url in
                let entries = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
                guard entries.isEmpty else { throw DriveSyncError.folderAlreadyExists }
                let header = markerHeader(id)
                let sealed = try key.seal(Data(), name: header)
                try saveKey(id)
                try (Data(header.utf8) + sealed).write(to: url, options: .atomic)
            }
        }
    }

    func marker() throws -> (id: UUID, verify: (DriveSyncKey) throws -> Void)? {
        try withAccess {
            let url = directory.appending(path: markerName)
            guard let bytes = try read(url, limit: 256, waitForDownload: true) else { return nil }
            let headerLength = markerHeader(id).utf8.count
            guard let header = String(data: bytes.prefix(headerLength), encoding: .utf8),
                  let id = UUID(uuidString: String(header.suffix(36))), header == markerHeader(id),
                  bytes.count == headerLength + 28 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (id, { key in
                guard (try? key.open(Data(bytes.dropFirst(headerLength)), name: header)) == Data() else {
                    throw DriveSyncError.wrongKey
                }
            })
        }
    }

    func recoveryKey() throws -> Data {
        guard let marker = try marker() else { throw DriveSyncError.missingDirectory }
        guard marker.id == id else { throw DriveSyncError.directoryChanged }
        return try DriveSyncKeychain.readVerified(id, verify: marker.verify)
    }

    func verify(key: DriveSyncKey) throws {
        guard let marker = try marker() else { throw DriveSyncError.missingDirectory }
        guard marker.id == id else { throw DriveSyncError.directoryChanged }
        try marker.verify(key)
    }

    func readRevisions(
        key: DriveSyncKey,
        readRecord: ((URL) throws -> Data?)? = nil
    ) throws -> (revisions: [SyncRevision], isComplete: Bool, error: Error?, chapterError: Error?) {
        try withAccess {
            let entries = try coordinateRead(directory) { url in
                try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            }
            var revisions: [SyncRevision] = []
            var firstError: Error?
            var chapterError: Error?
            var isComplete = true
            for url in entries {
                try Task.checkCancellation()
                let isChapterFile = url.pathExtension == SyncRevision.chapterFileExtension
                guard url.pathExtension == "record" || isChapterFile
                        || url.pathExtension == SyncRevision.pluginRatingFileExtension
                        || url.pathExtension == SyncRevision.followedComicFileExtension,
                      UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
                do {
                    let bytes = if let readRecord {
                        try readRecord(url)
                    } else {
                        try read(url, limit: 4 * 1024 * 1024 + 28)
                    }
                    guard let data = bytes else {
                        // Chapter records only add information. An unavailable
                        // chapter cannot invalidate other records in the listing.
                        if !isChapterFile { isComplete = false }
                        continue
                    }
                    let cleartext = try key.open(data, name: url.lastPathComponent)
                    let revision = try JSONDecoder().decode(SyncRevision.self, from: cleartext).validated(filename: url.lastPathComponent)
                    revisions.append(revision)
                } catch {
                    if isChapterFile {
                        chapterError = chapterError ?? error
                    } else {
                        firstError = firstError ?? error
                        isComplete = false
                    }
                }
            }
            return (revisions, isComplete, firstError, chapterError)
        }
    }

    func asset(_ digest: String, key: DriveSyncKey) throws -> Data? {
        guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try withAccess {
            let name = key.assetName(digest)
            guard let data = try read(directory.appending(path: name), limit: 16 * 1024 * 1024 + 28) else { return nil }
            return try key.open(data, name: name)
        }
    }

    func publish(_ revision: SyncRevision, asset: (digest: String, data: Data)?, key: DriveSyncKey) throws {
        try withAccess {
            if let asset {
                guard asset.data.count <= 16 * 1024 * 1024, SHA256.hash(data: asset.data).hex == asset.digest else { throw CocoaError(.fileWriteUnknown) }
                let name = key.assetName(asset.digest)
                let url = directory.appending(path: name)
                try coordinateWrite(url) { destination in
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try key.seal(asset.data, name: name).write(to: destination, options: .atomic)
                    }
                }
            }
            try Task.checkCancellation()
            let data = try JSONEncoder().encode(revision)
            guard data.count <= 4 * 1024 * 1024 else { throw CocoaError(.fileWriteUnknown) }
            let name = revision.filename
            try coordinateWrite(directory.appending(path: name)) {
                try key.seal(data, name: name).write(to: $0, options: .atomic)
            }
        }
    }

    private func read(_ url: URL, limit: Int, waitForDownload: Bool = false) throws -> Data? {
        do {
            return try coordinateRead(url) { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                               .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    if waitForDownload { throw DriveSyncError.waitingForFiles }
                    return nil
                }
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size <= limit else { throw CocoaError(.fileReadCorruptFile) }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: limit + 1) ?? Data()
                guard data.count <= limit else { throw CocoaError(.fileReadCorruptFile) }
                return data
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    private func coordinateRead<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var error: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
            result = Result { try body(url) }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private func coordinateWrite(_ url: URL, _ body: (URL) throws -> Void) throws {
        var error: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error) { url in
            result = Result { try body(url) }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }
}

private extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
