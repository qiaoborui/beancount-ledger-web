import SwiftUI
import Security

@MainActor
final class ImportClassificationSettings: ObservableObject {
    static let shared = ImportClassificationSettings()
    @Published private(set) var enabledLedgers: Set<String>
    @Published private(set) var hasKey: Bool
    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    private let preferenceKey = "ledger.import-classification.enabled-ledgers"
    private let credentials: ClassificationKeyStore

    init(defaults: UserDefaults = .standard, credentials: ClassificationKeyStore = .init()) {
        self.defaults = defaults
        self.credentials = credentials
        enabledLedgers = Set(defaults.stringArray(forKey: preferenceKey) ?? [])
        hasKey = (try? credentials.load()) != nil
    }
    func isEnabled(for ledgerID: UUID?) -> Bool {
        ledgerID.map { enabledLedgers.contains($0.uuidString) } == true && hasKey
    }
    func setEnabled(_ value: Bool, for ledgerID: UUID) {
        if value { enabledLedgers.insert(ledgerID.uuidString) }
        else { enabledLedgers.remove(ledgerID.uuidString) }
        defaults.set(Array(enabledLedgers).sorted(), forKey: preferenceKey)
        revision &+= 1
    }
    func saveKey(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw ImportClassificationError.invalidConfiguration
        }
        try credentials.save(key)
        hasKey = true
        revision &+= 1
    }
    func classifier() throws -> any BookkeepingClassifier { JevBookkeepingClassifier(apiKey: try apiKey()) }
    func apiKey() throws -> String {
        guard let key = try credentials.load() else { throw ImportClassificationError.invalidConfiguration }
        return key
    }
    func removeKey() throws {
        try credentials.remove()
        hasKey = false
        enabledLedgers = []
        defaults.removeObject(forKey: preferenceKey)
        revision &+= 1
    }
}

struct ClassificationKeyStore {
    var service = "com.qiaoborui.ledger.typesafe"
    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: "api-key", kSecAttrSynchronizable: false]
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
        NSError(domain: "LedgerClassificationKeychain", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法访问本机 API Key，请解锁设备后重试。"])
    }
}
