import Foundation
import Security

package enum PluginConfigurationKey {
    package static func load(encryptedFileExists: Bool) throws -> Data {
        #if WILLOW_TESTING
        // Isolated integration tests never read or modify the user's Keychain.
        if ProcessInfo.processInfo.environment["WILLOW_PLUGIN_STORAGE_DIRECTORY"] != nil {
            return Data(repeating: 0xA7, count: 32)
        }
        #endif
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.intitni.Willow.plugin-configuration",
            kSecAttrAccount as String: "aes-gcm-v1",
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else {
                throw PluginError.message(L10n.text("PluginConfiguration.InvalidKey"))
            }
            return data
        }
        guard status == errSecItemNotFound else {
            throw PluginError.message(L10n.text("PluginConfiguration.KeyAccessFailed", defaultValue: "无法访问插件配置密钥，请解锁设备后重试（Keychain \(status)）。"))
        }
        guard !encryptedFileExists else {
            throw PluginError.message(L10n.text("PluginConfiguration.MissingKey"))
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PluginError.message(L10n.text("PluginConfiguration.KeyGenerationFailed"))
        }
        let key = Data(bytes)
        var item = identity
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem { return try load(encryptedFileExists: encryptedFileExists) }
        guard added == errSecSuccess else {
            throw PluginError.message(L10n.text("PluginConfiguration.KeySaveFailed", defaultValue: "无法保存插件配置密钥（Keychain \(added)）。"))
        }
        return key
    }
}
