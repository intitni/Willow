import Foundation
import BreezeBridge
import CryptoKit

package actor PluginRuntime {
    package static let shared = PluginRuntime()
    private var configurationTask: Task<Void, Error>?
    private var loaded: [String: String] = [:]
    private var sessions: [String: UUID] = [:]
    private var loading: [String: Task<Void, Error>] = [:]
    private var loadingPaths: [String: String] = [:]

    package func load(id: String, path: String) async throws {
        let path = try Self.resolveBundlePath(path)
        if loaded[id] == path { return }
        if let task = loading[id] {
            try await task.value
            if loaded[id] == path { return }
            loading[id] = nil
        }
        let task = Task {
            try await configure()
            let source = try String(contentsOfFile: path, encoding: .utf8)
            _ = try await request(.object(["op": .string("load"), "id": .string(id), "source": .string(source)]))
            loaded[id] = path
            sessions[id] = UUID()
        }
        loading[id] = task
        loadingPaths[id] = path
        defer {
            if loadingPaths[id] == path { loading[id] = nil; loadingPaths[id] = nil }
        }
        try await task.value
    }

    package func sessionID(id: String, path: String) async throws -> UUID? {
        try await load(id: id, path: path)
        return sessions[id]
    }

    private func configure() async throws {
        if let configurationTask { return try await configurationTask.value }
        let task = Task {
            var root = try Self.storageDirectory().appendingPathComponent("Configuration", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try root.setResourceValues(resourceValues)
            let key = try PluginConfigurationKey.load(encryptedFileExists: FileManager.default.fileExists(
                atPath: root.appendingPathComponent("plugin-config.encrypted").path))
            _ = try await request(.object(["op": .string("setup"), "root": .string(root.path),
                "configKey": .string(key.base64EncodedString()), "locale": .object([
                "language": .string(Locale.current.language.languageCode?.identifier ?? "en"),
                "locale": .string(Locale.current.identifier.replacingOccurrences(of: "_", with: "-")),
                "systemLocale": .string(Locale.current.identifier),
                "timezoneOffsetMinutes": .number(Double(TimeZone.current.secondsFromGMT() / 60)),
                "timezoneName": .string(TimeZone.current.identifier), "timeZone": .string(TimeZone.current.identifier),
                "timeZoneIANA": .string(TimeZone.current.identifier)
            ])]))
        }
        configurationTask = task
        do { try await task.value } catch { configurationTask = nil; throw error }
    }

    package func call(id: String, path: String, function: String, args: JSONValue = .object([:]), binary: Bool = false) async throws -> JSONValue {
        try await load(id: id, path: path)
        try Task.checkCancellation()
        return try await request(.object(["op": .string(binary ? "bytes" : "call"), "id": .string(id), "function": .string(function), "args": args]))
    }

    package func unload(id: String) async throws {
        if let task = loading[id] { try await task.value }
        guard loaded[id] != nil else { return }
        _ = try await request(.object(["op": .string("unload"), "id": .string(id)]))
        loaded[id] = nil
        sessions[id] = nil
    }

    package func decompress(_ data: Data) async throws -> String {
        try await request(.object(["op": .string("decompress"), "data": .string(data.base64EncodedString())])).string
    }

    private func request(_ value: JSONValue) async throws -> JSONValue {
        let data = try value.encoded()
        let result = try await Task.detached(priority: .userInitiated) {
            let text = String(decoding: data, as: UTF8.self)
            let response = text.withCString { willow_request($0) }
            guard let response else { throw PluginError.message(L10n.text("PluginRuntime.NoResult")) }
            defer { willow_free(response) }
            let result = try JSONValue.decode(Data(String(cString: response).utf8))
            guard result["ok"].bool else { throw PluginError.message(result["error"].string) }
            return result
        }.value
        await PluginNoticeModel.shared.receive(result["notices"].array)
        return result["data"]
    }

    package nonisolated static func resolveBundlePath(_ storedPath: String) throws -> String {
        let name = URL(fileURLWithPath: storedPath).lastPathComponent
        guard !name.isEmpty, name.hasSuffix(".cjs") else {
            throw PluginError.message(L10n.text("PluginRuntime.InvalidFileIdentifier"))
        }
        let current = try storageDirectory().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: current.path) { return current.path }
        // Keep explicit existing file paths usable for imported development bundles.
        if storedPath.hasPrefix("/"), FileManager.default.fileExists(atPath: storedPath) { return storedPath }
        throw PluginError.message(L10n.text("PluginRuntime.MissingPluginFile"))
    }

    package nonisolated static func storageDirectory() throws -> URL {
        #if WILLOW_TESTING
        if let path = ProcessInfo.processInfo.environment["WILLOW_PLUGIN_STORAGE_DIRECTORY"] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        #endif
        let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("WillowPlugins", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

package actor PluginImageGateway {
    package static let shared = PluginImageGateway()
    struct Descriptor: Codable, Sendable {
        let sourceID: String
        let bundlePath: String
        let payload: JSONValue
    }
    package func register(sourceID: String, bundlePath: String, payload: JSONValue) throws -> URL {
        let descriptor = Descriptor(sourceID: sourceID, bundlePath: bundlePath, payload: payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(descriptor)
        // A bundle update changes its disk path, but not the image identity.
        let identity = try encoder.encode(JSONValue.object(["sourceID": .string(sourceID), "payload": payload]))
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let directory = try PluginRuntime.storageDirectory().appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(key + ".json"), options: [.atomic, .completeFileProtection])
        // Carry the descriptor so synced covers resolve after installing the same source on another device.
        var components = URLComponents()
        components.scheme = "willow-plugin"
        components.host = "image"
        components.path = "/" + key
        components.fragment = data.base64EncodedString()
        return components.url!
    }
    package func data(for url: URL) async throws -> Data {
        let key = url.lastPathComponent
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else { throw PluginError.message(L10n.text("PluginImage.InvalidImageIdentifier")) }
        let file = try PluginRuntime.storageDirectory().appendingPathComponent("Images/" + key + ".json")
        let descriptorData = try url.fragment.flatMap { Data(base64Encoded: $0) } ?? Data(contentsOf: file)
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: descriptorData)
        guard PluginIdentity.isValid(descriptor.sourceID) else { throw PluginError.message(L10n.text("PluginImage.InvalidSourceIdentifier")) }
        let registry = try PluginRuntime.storageDirectory().appendingPathComponent(descriptor.sourceID + ".path")
        guard let currentPath = try? String(contentsOf: registry, encoding: .utf8) else {
            throw PluginError.message(L10n.text("PluginImage.InstallSourceFirst"))
        }
        let result = try await PluginRuntime.shared.call(id: descriptor.sourceID, path: currentPath, function: "fetchImageBytes", args: descriptor.payload, binary: true)
        guard let data = Data(base64Encoded: result.string), !data.isEmpty else { throw PluginError.message(L10n.text("PluginImage.EmptyImage")) }
        return data
    }
}
