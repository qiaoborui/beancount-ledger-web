import Foundation
import Security

struct LocalGitCredential: Codable, Equatable, Sendable {
    let username: String
    let token: String
}

protocol LocalGitCredentialStoring: Sendable {
    func load(for id: UUID) throws -> LocalGitCredential?
    func save(_ credential: LocalGitCredential, for id: UUID) throws
    func remove(for id: UUID) throws
    func prepareForBackgroundSync(for id: UUID) throws
}

extension LocalGitCredentialStoring {
    // In-memory/test stores have no device data-protection class to migrate.
    func prepareForBackgroundSync(for id: UUID) throws {}
}

/// Git secrets stay in the main app's device-only keychain, outside the ledger,
/// App Group, exported folders, Git configuration and cloud keychain sync.
struct DeviceLocalGitCredentialStore: LocalGitCredentialStoring {
    private let service = "com.qiaoborui.ledger.local-git"

    func load(for id: UUID) throws -> LocalGitCredential? {
        var query = query(id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw credentialError() }
        return try JSONDecoder().decode(LocalGitCredential.self, from: data)
    }
    func save(_ credential: LocalGitCredential, for id: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = query(id)
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw credentialError() }
        } else if result != errSecSuccess { throw credentialError() }
    }
    func remove(for id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw credentialError() }
    }
    func prepareForBackgroundSync(for id: UUID) throws {
        // Update accessibility in place so the credential remains available if
        // migration fails. The query selects this device's unsynchronized item.
        let attributes = [kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw credentialError() }
    }
    private func query(_ id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: id.uuidString, kSecAttrSynchronizable: false]
    }
    private func credentialError() -> LocalStorageError {
        .gitFailure("无法访问本机 Git 凭据，请解锁设备并重新填写访问令牌")
    }
}
