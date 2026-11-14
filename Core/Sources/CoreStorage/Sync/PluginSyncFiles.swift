import BreezeRuntime
import CryptoKit
import Foundation

package actor PluginSyncFiles {
    private struct CachedDigest {
        let size: Int
        let modified: Date
        let digest: String
    }
    private let directory: URL?
    private var digests: [String: CachedDigest] = [:]
    package init(directory: URL? = nil) { self.directory = directory }

    private func root() throws -> URL { try directory ?? PluginRuntime.storageDirectory() }
    private func file(_ path: String) throws -> URL {
        if directory != nil { return try root().appending(path: URL(fileURLWithPath: path).lastPathComponent) }
        return URL(fileURLWithPath: try PluginRuntime.resolveBundlePath(path))
    }
    package func digest(path: String) throws -> String {
        let url = try file(path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values.fileSize ?? 0
        let modified = values.contentModificationDate ?? .distantPast
        if let cached = digests[url.path], cached.size == size, cached.modified == modified { return cached.digest }
        let bytes = try read(path: path)
        let digest = Self.digest(bytes)
        digests[url.path] = CachedDigest(size: size, modified: modified, digest: digest)
        return digest
    }
    package func read(path: String) throws -> Data {
        let url = try file(path)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
    package func restore(_ data: Data, id: String, digest: String, enabled: Bool) throws -> String {
        guard PluginIdentity.isValid(id), data.count <= 16 * 1024 * 1024,
              Self.digest(data) == digest, String(data: data, encoding: .utf8) != nil else {
            throw URLError(.cannotDecodeContentData)
        }
        let root = try root()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = "\(id)-\(digest).cjs"
        let file = root.appending(path: name)
        if !FileManager.default.fileExists(atPath: file.path) {
            try data.write(to: file, options: [.atomic, .completeFileProtection])
        }
        try setAccess(id: id, path: name, enabled: enabled)
        return name
    }
    package func setAccess(id: String, path: String, enabled: Bool) throws {
        guard PluginIdentity.isValid(id) else { throw URLError(.badURL) }
        let registry = try root().appending(path: id + ".path")
        if enabled { try Data(path.utf8).write(to: registry, options: [.atomic, .completeFileProtection]) }
        else if FileManager.default.fileExists(atPath: registry.path) { try FileManager.default.removeItem(at: registry) }
    }
    package func readIfPresent(path: String) throws -> Data? {
        let url = try file(path)
        return FileManager.default.fileExists(atPath: url.path) ? try read(path: path) : nil
    }
    package func remove(id: String, path: String) throws -> Data? {
        let url = try file(path)
        let backup = FileManager.default.fileExists(atPath: url.path) ? try read(path: path) : nil
        try setAccess(id: id, path: path, enabled: false)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return backup
    }
    package func restoreRemoved(_ data: Data, path: String) throws {
        let url = try file(path)
        // A concurrently installed replacement must never be overwritten.
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        }
        digests[url.path] = nil
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
