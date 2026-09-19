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

struct ImportClassificationSettingsView: View {
    @ObservedObject private var settings = ImportClassificationSettings.shared
    let ledgerID: UUID
    @State private var key = ""
    @State private var error: String?
    @State private var consentPresented = false

    var body: some View {
        Form {
            if let error { Section { StatusBanner(message: error) { self.error = nil } } }
            Section {
                Toggle("为此账本启用智能分类", isOn: Binding(
                    get: { settings.isEnabled(for: ledgerID) },
                    set: { if $0 { consentPresented = true } else { settings.setEnabled(false, for: ledgerID) } }
                ))
                .disabled(!settings.hasKey)
                .accessibilityIdentifier("classification-enabled")
            } footer: {
                Text("导入账单时，Jev 根据支付信息和相关历史补齐分类、付款或收款账户、交易性质和已有标签。结果填入预览，经你确认后在本机校验并保存。")
            }
            Section {
                if settings.hasKey { Label("API Key 已保存在本机", systemImage: "key.fill") }
                SecureField(settings.hasKey ? "替换 TypeSafe API Key" : "TypeSafe API Key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("classification-api-key")
                Button("保存 API Key") {
                    do { try settings.saveKey(key); key = ""; error = nil }
                    catch { self.error = error.localizedDescription }
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("classification-save-key")
                if settings.hasKey {
                    Button("移除 API Key 并停用", role: .destructive) {
                        do { try settings.removeKey(); key = ""; error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                    .accessibilityIdentifier("classification-remove-key")
                }
                Link("获取 TypeSafe API Key", destination: URL(string: "https://typesafe.ai")!)
            } header: { Text("TypeSafe") } footer: {
                Text("API Key 存放在这台设备的 Keychain，随账本导出与 Git 同步的内容中均不包含它。调用费用由你的 TypeSafe 账户承担。")
            }
            Section("发送内容") {
                Text("启用后会向 TypeSafe 发送日期、商家、交易描述、金额、币种、支付方式、账单渠道、卡尾号、候选账户和标签，以及最多 5 条相关历史的日期、商家、描述、支付方式、账户和标签。")
                Text("历史检索在本机完成。原始账单、订单号、账户余额、附件和完整账本保留在本机。服务暂时不可用时，可以继续手动分类。")
                Text("日期、金额、币种和商家描述沿用账单。信息有歧义时会提示核对；复杂拆分交易保留原分录。")
            }
        }
        .font(.subheadline)
        .navigationTitle("智能分类")
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .alert("启用在线智能分类？", isPresented: $consentPresented) {
            Button("同意并启用") { settings.setEnabled(true, for: ledgerID) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此账本的导入交易、支付方式和卡尾号、候选账户及标签，以及最多 5 条相关历史片段将发送至 TypeSafe。费用使用你提供的 API Key 结算，可随时关闭。")
        }
        .onDisappear { key = "" }
    }
}
