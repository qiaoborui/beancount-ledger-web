import SwiftUI

/// Model choice and per-provider API keys for the on-device Agent. The choice
/// lives in `UserDefaults`; keys live in this device's Keychain only and never
/// enter the ledger repository, a backup or Git sync.
@MainActor
final class LedgerAgentSettings: ObservableObject {
    static let shared = LedgerAgentSettings()
    nonisolated static let keychainService = "com.qiaoborui.ledger.agent"
    @Published private(set) var choice: LedgerAgentModelChoice
    @Published private(set) var hasKey: Bool
    let catalog: LedgerAgentCatalog
    private let defaults: UserDefaults
    private let preferenceKey = "ledger.agent.model-choice"
    private let keyStore: (String) -> ClassificationKeyStore

    init(defaults: UserDefaults = .standard, catalog: LedgerAgentCatalog = .native,
         keyStore: @escaping (String) -> ClassificationKeyStore = { .init(service: LedgerAgentSettings.keychainService, account: $0) }) {
        self.defaults = defaults
        self.catalog = catalog
        self.keyStore = keyStore
        let stored = defaults.data(forKey: preferenceKey).flatMap { try? JSONDecoder().decode(LedgerAgentModelChoice.self, from: $0) }
        let choice = stored.flatMap { catalog.provider($0.provider) == nil ? nil : $0 } ?? Self.defaultChoice(in: catalog)
        self.choice = choice
        hasKey = (try? keyStore(choice.provider).load()) != nil
    }

    var modelTitle: String { catalog.modelTitle(choice) }
    var providerTitle: String { catalog.provider(choice.provider)?.title ?? choice.provider }

    func select(provider: String) {
        guard provider != choice.provider, let entry = catalog.provider(provider) else { return }
        store(.init(provider: provider, model: Self.preferredModel(in: entry)))
    }

    func select(model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != choice.model else { return }
        store(.init(provider: choice.provider, model: trimmed))
    }

    func saveKey(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw LedgerAgentError.failed(String(localized: "API Key 格式不正确"))
        }
        try keyStore(choice.provider).save(key)
        hasKey = true
    }

    func removeKey() throws {
        try keyStore(choice.provider).remove()
        hasKey = false
    }

    /// The key for the current provider, read at the start of each turn.
    func apiKey() throws -> String {
        guard let key = try keyStore(choice.provider).load() else { throw LedgerAgentError.notConfigured }
        return key
    }

    private func store(_ choice: LedgerAgentModelChoice) {
        self.choice = choice
        defaults.set(try? JSONEncoder().encode(choice), forKey: preferenceKey)
        hasKey = (try? keyStore(choice.provider).load()) != nil
    }

    static func defaultChoice(in catalog: LedgerAgentCatalog) -> LedgerAgentModelChoice {
        let provider = catalog.provider("anthropic") ?? catalog.providers.first
        guard let provider else { return .init(provider: "anthropic", model: "claude-sonnet-4-5") }
        return .init(provider: provider.id, model: preferredModel(in: provider))
    }

    /// Provider defaults that are good at tool use without top-tier pricing;
    /// otherwise the first model the catalog lists.
    private static let preferredModels = ["anthropic": "claude-sonnet-4-5", "openai": "gpt-5-mini", "google": "gemini-2.5-flash",
                                          "deepseek": "deepseek-flash", "moonshotai": "kimi-k2.6", "zai": "glm-5.2",
                                          "openrouter": "anthropic/claude-sonnet-4.5"]

    static func preferredModel(in provider: LedgerAgentCatalog.Provider) -> String {
        if let preferred = preferredModels[provider.id], provider.models.contains(where: { $0.id == preferred }) { return preferred }
        return provider.models.first?.id ?? ""
    }
}
