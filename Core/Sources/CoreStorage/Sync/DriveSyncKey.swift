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

    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Willow.DriveSync.v1",
            kSecAttrAccount as String: id.uuidString,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: true,
        ]
    }

    static func read(_ id: UUID) throws -> Data {
        var request = query(id)
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let bytes = result as? Data else { throw DriveSyncError.keychain(status) }
        return bytes
    }

    static func save(_ bytes: Data, id: UUID) throws {
        var item = query(id)
        item[kSecValueData as String] = bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updated = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
            guard updated == errSecSuccess else { throw DriveSyncError.keychain(updated) }
        } else if status != errSecSuccess {
            throw DriveSyncError.keychain(status)
        }
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
            let bytes = try DriveSyncKeychain.read(marker.id)
            try marker.verify(DriveSyncKey(bytes))
        } catch DriveSyncError.keychain(errSecItemNotFound) {
            return .needsKey
        } catch DriveSyncError.wrongKey {
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
            try marker.verify(DriveSyncKey(bytes))
            try DriveSyncKeychain.save(bytes, id: marker.id)
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
        try DriveSyncKeychain.read(folder.id).base64EncodedString()
    }
}
