import Foundation
import Security

/// One device-only generic password in the keychain, such as the assistant's
/// model API keys.
struct LedgerKeychainKeyStore {
    var service: String
    var account: String
    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: account, kSecAttrSynchronizable: false]
    }
    func load() throws -> String? {
        var request = query
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { throw keychainError }
        return key
    }
    func save(_ key: String) throws {
        let attributes: [CFString: Any] = [kSecValueData: Data(key.utf8), kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw keychainError }
        } else if status != errSecSuccess { throw keychainError }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError }
    }
    private var keychainError: NSError {
        NSError(domain: "LedgerKeychainKeyStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "无法访问本机 API Key，请解锁设备后重试。")])
    }
}

/// Smart classification (Jev) and the 一句话记账 semantic parser were removed.
/// Their API keys stayed in the keychain and their switches in UserDefaults;
/// this deletes them once so no unused credential is left on the device.
enum RemovedFeatureCredentials {
    private static let doneKey = "ledger.removed-ai-credentials-purged"

    static func purgeOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        do {
            try LedgerKeychainKeyStore(service: "com.qiaoborui.ledger.typesafe", account: "api-key").remove()
            try LedgerKeychainKeyStore(service: "com.qiaoborui.ledger.semantic-parser", account: "api-key").remove()
        } catch {
            // A locked keychain: try again on the next launch.
            return
        }
        defaults.removeObject(forKey: "ledger.import-classification.enabled-ledgers")
        defaults.removeObject(forKey: "ledger.bookkeeping.semantic-configuration")
        defaults.set(true, forKey: doneKey)
    }
}
