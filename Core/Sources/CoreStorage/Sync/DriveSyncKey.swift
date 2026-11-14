import CryptoKit
import Foundation
import Security

struct DriveSyncKey: Sendable {
    private let encryption: SymmetricKey
    private let addressing: SymmetricKey

    init(_ bytes: Data) throws {
        guard bytes.count == 32 else { throw DriveSyncError.invalidKey }
        let master = SymmetricKey(data: bytes)
        encryption = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("Willow Drive v1/AEAD".utf8), outputByteCount: 32)
        addressing = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("Willow Drive v1/addressing".utf8), outputByteCount: 32)
    }

    func seal(_ data: Data, name: String) throws -> Data {
        guard let result = try AES.GCM.seal(data, using: encryption, authenticating: Data(name.utf8)).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        return result
    }

    func open(_ data: Data, name: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: encryption, authenticating: Data(name.utf8))
    }

    func assetName(_ digest: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(digest.utf8), using: addressing)
            .map { String(format: "%02x", $0) }.joined() + ".asset"
    }
}

package enum DriveSyncError: LocalizedError, Equatable {
    case invalidKey, wrongKey, missingDirectory, directoryChanged, folderAlreadyExists, waitingForFiles, keychain(OSStatus)

    package var errorDescription: String? {
        switch self {
        case .invalidKey: L10n.text("DriveSync.InvalidKey")
        case .wrongKey: L10n.text("DriveSync.WrongKey")
        case .missingDirectory: L10n.text("DriveSync.MissingDirectory")
        case .directoryChanged: L10n.text("DriveSync.DirectoryChanged")
        case .folderAlreadyExists: L10n.text("DriveSync.FolderAlreadyExists")
        case .waitingForFiles: L10n.text("DriveSync.WaitingForFiles")
        case .keychain(let status): SecCopyErrorMessageString(status, nil) as String? ?? L10n.text("DriveSync.KeychainError")
        }
    }
}

enum DriveSyncKeychain {
    static func generate() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    private static func query(_ id: UUID, synchronizable: Bool = false) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Willow.DriveSync.v1",
            kSecAttrAccount as String: id.uuidString,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: synchronizable,
        ]
    }

    private static func read(_ id: UUID, synchronizable: Bool = false) throws -> Data {
        var request = query(id, synchronizable: synchronizable)
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess else { throw DriveSyncError.keychain(status) }
        guard let bytes = result as? Data else { throw DriveSyncError.invalidKey }
        return bytes
    }

    static func save(_ bytes: Data, id: UUID) throws {
        var item = query(id)
        item[kSecValueData as String] = bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributes = [
                kSecValueData as String: bytes,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as [String: Any]
            let updated = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
            guard updated == errSecSuccess else { throw DriveSyncError.keychain(updated) }
        } else if status != errSecSuccess {
            throw DriveSyncError.keychain(status)
        }
    }

    static func readVerified(_ id: UUID, verify: (DriveSyncKey) throws -> Void) throws -> Data {
        do {
            let bytes = try read(id)
            try verify(DriveSyncKey(bytes))
            try deleteLegacy(id)
            return bytes
        } catch DriveSyncError.keychain(errSecItemNotFound) {
            // A previous build may only have stored the synchronizable item.
        } catch DriveSyncError.wrongKey {
            // Verify the legacy value against the directory before replacing it.
        } catch DriveSyncError.invalidKey {
            // A malformed local item can also be repaired by a verified legacy key.
        }
        let legacy = try read(id, synchronizable: true)
        try saveVerified(legacy, id: id, verify: verify)
        return legacy
    }

    static func saveVerified(_ bytes: Data, id: UUID, verify: (DriveSyncKey) throws -> Void) throws {
        try verify(DriveSyncKey(bytes))
        try save(bytes, id: id)
        let persisted = try read(id)
        guard persisted == bytes else { throw DriveSyncError.invalidKey }
        try verify(DriveSyncKey(persisted))
        try deleteLegacy(id)
    }

    private static func deleteLegacy(_ id: UUID) throws {
        // Apple propagates deletion of this legacy item to other devices.
        // Callers must first have a verified, device-only copy.
        let status = SecItemDelete(query(id, synchronizable: true) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DriveSyncError.keychain(status) }
    }

}

/// Keychain and file-provider coordination stay off the main actor.
package actor DriveSyncSetup {
    package init() {}

    package enum FolderStatus: Sendable {
        case connected(DriveSyncFolder)
        case needsKey
        case empty
    }

    package func inspect(_ url: URL) throws -> FolderStatus {
        let directory = DriveSyncDirectory(root: url, securityScoped: true)
        guard let marker = try directory.marker() else { return .empty }
        do {
            _ = try DriveSyncKeychain.readVerified(marker.id, verify: marker.verify)
        } catch DriveSyncError.keychain(errSecItemNotFound) {
            return .needsKey
        } catch DriveSyncError.wrongKey {
            return .needsKey
        } catch DriveSyncError.invalidKey {
            return .needsKey
        }
        return .connected(DriveSyncFolder(id: marker.id, name: url.lastPathComponent, bookmark: try DriveSyncFolder.makeBookmark(url)))
    }

    package func connect(to url: URL, recoveryKey: String?) throws -> DriveSyncFolder {
        let bookmark = try DriveSyncFolder.makeBookmark(url)
        let directory = DriveSyncDirectory(root: url, securityScoped: true)
        let id: UUID
        if let recoveryKey {
            guard let bytes = Data(base64Encoded: recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)),
                  bytes.count == 32 else { throw DriveSyncError.invalidKey }
            guard let marker = try directory.marker() else { throw DriveSyncError.missingDirectory }
            try DriveSyncKeychain.saveVerified(bytes, id: marker.id, verify: marker.verify)
            id = marker.id
        } else {
            let bytes = DriveSyncKeychain.generate()
            try directory.create(key: DriveSyncKey(bytes)) { id in
                try DriveSyncKeychain.save(bytes, id: id)
            }
            id = directory.id
        }
        return DriveSyncFolder(id: id, name: url.lastPathComponent, bookmark: bookmark)
    }

    package func recoveryKey(for folder: DriveSyncFolder) throws -> String {
        let directory = try DriveSyncDirectory(folder: folder)
        return try directory.recoveryKey().base64EncodedString()
    }
}
