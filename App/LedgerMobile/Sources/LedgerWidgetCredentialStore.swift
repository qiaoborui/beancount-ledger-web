import Foundation
import Security

struct LedgerWidgetCredential: Codable, Equatable, Sendable {
    let serverOrigin: String
    let deviceID: String
    let token: String
    let valuationCurrency: String
    let enabled: Bool
    let expiresAt: String?

    init(
        serverOrigin: String,
        deviceID: String,
        token: String,
        valuationCurrency: String,
        enabled: Bool,
        expiresAt: String? = nil
    ) {
        self.serverOrigin = serverOrigin
        self.deviceID = deviceID
        self.token = token
        self.valuationCurrency = valuationCurrency
        self.enabled = enabled
        self.expiresAt = expiresAt
    }

    func updating(valuationCurrency: String? = nil, enabled: Bool? = nil) -> LedgerWidgetCredential {
        LedgerWidgetCredential(
            serverOrigin: serverOrigin,
            deviceID: deviceID,
            token: token,
            valuationCurrency: valuationCurrency ?? self.valuationCurrency,
            enabled: enabled ?? self.enabled,
            expiresAt: expiresAt
        )
    }
}

protocol LedgerWidgetCredentialStoring: Sendable {
    var isAvailable: Bool { get }
    func load() throws -> LedgerWidgetCredential?
    func save(_ credential: LedgerWidgetCredential) throws
    func suspend() throws
    func pendingRevocation() throws -> LedgerWidgetCredential?
    func completeRevocation(deviceID: String) throws
}

enum LedgerWidgetCredentialStoreError: LocalizedError {
    case unavailable
    case keychain(OSStatus)
    case invalidCredential
    case pendingRevocation

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "无法访问小组件安全凭据空间"
        case let .keychain(status):
            "无法保存小组件安全凭据（\(status)）"
        case .invalidCredential:
            "小组件安全凭据已损坏"
        case .pendingRevocation:
            "旧的小组件凭据仍在等待撤销"
        }
    }
}

final class SystemLedgerWidgetCredentialStore: LedgerWidgetCredentialStoring, @unchecked Sendable {
    static let accessGroupInfoKey = "LedgerWidgetKeychainAccessGroup"

    private let service = "com.qiaoborui.ledger.mobile.widget-access"
    private let account = "current"
    private let accessGroup: String?
    private let sharedDefaults: UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let activeCredentialKeyKey = "ledger.widgets.active-credential-key.v1"

    init(
        accessGroup: String? = SystemLedgerWidgetCredentialStore.configuredAccessGroup(),
        suiteName: String = LedgerWidgetSnapshotStore.appGroupIdentifier
    ) {
        self.accessGroup = accessGroup
        sharedDefaults = UserDefaults(suiteName: suiteName)
    }

    var isAvailable: Bool { accessGroup != nil && sharedDefaults != nil }

    func load() throws -> LedgerWidgetCredential? {
        guard let credential = try loadRaw() else { return nil }
        guard activeCredentialKey() == credential.blockKey else { return nil }
        return credential
    }

    func pendingRevocation() throws -> LedgerWidgetCredential? {
        guard let credential = try loadRaw() else { return nil }
        return activeCredentialKey() == credential.blockKey ? nil : credential
    }

    private func loadRaw() throws -> LedgerWidgetCredential? {
        guard accessGroup != nil else { throw LedgerWidgetCredentialStoreError.unavailable }
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LedgerWidgetCredentialStoreError.keychain(status) }
        guard let data = result as? Data,
              let credential = try? decoder.decode(LedgerWidgetCredential.self, from: data) else {
            throw LedgerWidgetCredentialStoreError.invalidCredential
        }
        return credential
    }

    func save(_ credential: LedgerWidgetCredential) throws {
        guard accessGroup != nil else { throw LedgerWidgetCredentialStoreError.unavailable }
        if let pending = try pendingRevocation(), pending.deviceID != credential.deviceID {
            throw LedgerWidgetCredentialStoreError.pendingRevocation
        }
        let data = try encoder.encode(credential)
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            try setActiveCredentialKey(credential.blockKey)
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw LedgerWidgetCredentialStoreError.keychain(updateStatus)
        }

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LedgerWidgetCredentialStoreError.keychain(status)
        }
        try setActiveCredentialKey(credential.blockKey)
    }

    func suspend() throws {
        try setActiveCredentialKey(nil)
    }

    func completeRevocation(deviceID: String) throws {
        guard accessGroup != nil else { throw LedgerWidgetCredentialStoreError.unavailable }
        let credential = try loadRaw()
        if credential?.deviceID == deviceID {
            let status = SecItemDelete(baseQuery() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw LedgerWidgetCredentialStoreError.keychain(status)
            }
        }
        try setActiveCredentialKey(nil)
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func activeCredentialKey() -> String? {
        sharedDefaults?.string(forKey: Self.activeCredentialKeyKey)
    }

    private func setActiveCredentialKey(_ key: String?) throws {
        guard let sharedDefaults else { throw LedgerWidgetCredentialStoreError.unavailable }
        if let key {
            sharedDefaults.set(key, forKey: Self.activeCredentialKeyKey)
        } else {
            sharedDefaults.removeObject(forKey: Self.activeCredentialKeyKey)
        }
        guard sharedDefaults.synchronize() else { throw LedgerWidgetCredentialStoreError.unavailable }
    }

    private static func configuredAccessGroup(bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: accessGroupInfoKey) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
}

private extension LedgerWidgetCredential {
    var blockKey: String { "\(serverOrigin)|\(deviceID)" }
}
