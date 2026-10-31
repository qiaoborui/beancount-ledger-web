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
    /// The effort the user picked. It is kept across models; each turn uses
    /// the nearest level the current model supports.
    @Published private(set) var thinking: LedgerAgentThinking
    /// Models kept for switching from the chat page, in the order starred.
    @Published private(set) var favorites: [Favorite]
    /// The provider's own list, fetched on request and kept until relaunch;
    /// keyed by `listKey`.
    @Published private(set) var listed: [String: [LedgerAgentListedModel]] = [:]
    @Published private(set) var listing = false
    @Published private(set) var listError: String?
    let catalog: LedgerAgentCatalog
    static let favoriteLimit = 12
    private let defaults: UserDefaults
    private let preferenceKey = "ledger.agent.model-choice"
    /// The custom endpoint survives switching to a listed provider and back.
    private let customKey = "ledger.agent.custom-choice"
    private let thinkingKey = "ledger.agent.thinking"
    private let favoritesKey = "ledger.agent.favorite-models"
    private let keyStore: (String) -> ClassificationKeyStore
    private let lister: LedgerAgentModelLister

    /// A starred model. Its title and levels are kept so the chat page can
    /// show and clamp it without fetching the provider's list again.
    struct Favorite: Codable, Equatable, Identifiable, Sendable {
        var choice: LedgerAgentModelChoice
        var title: String
        var thinkingLevels: [String]? = nil
        var id: String { LedgerAgentSettings.identity(choice) }

        var thinking: [LedgerAgentThinking]? {
            let levels = (thinkingLevels ?? []).compactMap(LedgerAgentThinking.init(rawValue:))
            return levels.isEmpty ? nil : levels
        }
    }

    init(defaults: UserDefaults = .standard, catalog: LedgerAgentCatalog = .native,
         keyStore: @escaping (String) -> ClassificationKeyStore = { .init(service: LedgerAgentSettings.keychainService, account: $0) },
         lister: LedgerAgentModelLister = .native) {
        self.defaults = defaults
        self.catalog = catalog
        self.keyStore = keyStore
        self.lister = lister
        favorites = defaults.data(forKey: favoritesKey).flatMap { try? JSONDecoder().decode([Favorite].self, from: $0) }?
            .filter { catalog.provider($0.choice.provider) != nil } ?? []
        let stored = defaults.data(forKey: preferenceKey).flatMap { try? JSONDecoder().decode(LedgerAgentModelChoice.self, from: $0) }
        let choice = stored.flatMap { catalog.provider($0.provider) == nil ? nil : $0 } ?? Self.defaultChoice(in: catalog)
        self.choice = choice
        thinking = defaults.string(forKey: thinkingKey).flatMap(LedgerAgentThinking.init(rawValue:)) ?? .default
        hasKey = (try? keyStore(choice.provider).load()) != nil
    }

    /// The levels the current model accepts, least to most.
    var supportedThinking: [LedgerAgentThinking] { thinkingLevels(for: choice) }

    /// A model the built-in catalog lists says what it supports; one known
    /// only from the provider's list, or a custom endpoint, is offered the
    /// levels the native side assumes for it.
    func thinkingLevels(for choice: LedgerAgentModelChoice) -> [LedgerAgentThinking] {
        if !choice.isCustom, let model = catalog.provider(choice.provider)?.models.first(where: { $0.id == choice.model }) {
            return model.thinking
        }
        if let listed = listed[Self.listKey(choice)]?.first(where: { $0.id == choice.model }) { return listed.thinking }
        if let favorite = favorites.first(where: { $0.id == Self.identity(choice) }), let levels = favorite.thinking { return levels }
        return LedgerAgentThinking.custom
    }

    /// Whether nothing describes the current model, so its levels are a guess.
    var thinkingIsAssumed: Bool {
        if choice.isCustom { return true }
        if catalog.provider(choice.provider)?.models.contains(where: { $0.id == choice.model }) == true { return false }
        return listed[Self.listKey(choice)]?.first(where: { $0.id == choice.model })?.known != true
    }

    /// What the next turn sends.
    var effectiveThinking: LedgerAgentThinking { thinking.clamped(to: supportedThinking) }

    func select(thinking level: LedgerAgentThinking) {
        guard level != thinking else { return }
        thinking = level
        defaults.set(level.rawValue, forKey: thinkingKey)
    }

    var modelTitle: String { title(for: choice) }

    func title(for choice: LedgerAgentModelChoice) -> String {
        if choice.isCustom, choice.model.isEmpty { return String(localized: "未设置") }
        if !choice.isCustom, let model = catalog.provider(choice.provider)?.models.first(where: { $0.id == choice.model }) {
            return model.title
        }
        if let favorite = favorites.first(where: { $0.id == Self.identity(choice) }) { return favorite.title }
        if let listed = listed[Self.listKey(choice)]?.first(where: { $0.id == choice.model }) { return listed.title }
        return choice.model
    }

    func providerTitle(for provider: String) -> String { catalog.provider(provider)?.title ?? provider }

    /// Whether a key for the provider is saved on this device.
    func hasKey(for provider: String) -> Bool { (try? keyStore(provider).load()) != nil }

    // MARK: Favorites

    var currentIsFavorite: Bool { favorites.contains { $0.id == Self.identity(choice) } }

    func isFavorite(model id: String) -> Bool {
        favorites.contains { $0.id == Self.identity(.init(provider: choice.provider, model: id, custom: choice.custom)) }
    }

    /// Stars or unstars a model of the current provider.
    func toggleFavorite(model id: String, title: String? = nil, levels: [LedgerAgentThinking]? = nil) {
        let target = LedgerAgentModelChoice(provider: choice.provider, model: id, custom: choice.isCustom ? choice.custom : nil)
        guard target.isComplete else { return }
        if let index = favorites.firstIndex(where: { $0.id == Self.identity(target) }) {
            favorites.remove(at: index)
        } else {
            guard favorites.count < Self.favoriteLimit else {
                listError = String(localized: "最多收藏 \(Self.favoriteLimit) 个模型")
                return
            }
            let levels = levels ?? thinkingLevels(for: target)
            favorites.append(.init(choice: target, title: title ?? self.title(for: target), thinkingLevels: levels.map(\.rawValue)))
        }
        storeFavorites()
    }

    func toggleFavoriteForCurrent() { toggleFavorite(model: choice.model) }

    func removeFavorites(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        storeFavorites()
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        storeFavorites()
    }

    /// Switches to a starred model, provider and endpoint included.
    func select(favorite: Favorite) {
        guard favorite.choice != choice else { return }
        store(favorite.choice)
    }

    private func storeFavorites() {
        defaults.set(try? JSONEncoder().encode(favorites), forKey: favoritesKey)
    }

    // MARK: Provider model list

    /// The fetched list for the current provider and endpoint, if any.
    var listedModels: [LedgerAgentListedModel]? { listed[Self.listKey(choice)] }

    /// Asks the provider which models the saved key can call.
    func refreshModels() async {
        guard !listing else { return }
        let choice = choice
        guard !choice.isCustom || choice.custom?.isValid == true else {
            listError = String(localized: "先填好 Base URL")
            return
        }
        let key: String
        do { key = try apiKey() } catch {
            listError = String(localized: "先保存 \(providerTitle) 的 API Key")
            return
        }
        listing = true
        listError = nil
        defer { listing = false }
        do {
            let models = try await lister.models(for: choice, apiKey: key)
            listed[Self.listKey(choice)] = models
        } catch {
            listError = error.localizedDescription
        }
    }

    func clearListError() { listError = nil }

    nonisolated static func identity(_ choice: LedgerAgentModelChoice) -> String {
        [choice.provider, choice.model, choice.isCustom ? (choice.custom?.api.rawValue ?? "") : "",
         choice.isCustom ? (choice.custom?.baseURL ?? "") : ""].joined(separator: "\u{1F}")
    }

    nonisolated static func listKey(_ choice: LedgerAgentModelChoice) -> String {
        choice.isCustom ? "custom\u{1F}" + (choice.custom?.api.rawValue ?? "") + "\u{1F}" + (choice.custom?.baseURL ?? "") : choice.provider
    }

    /// A key is saved and the choice names a callable model.
    var isReady: Bool { hasKey && choice.isComplete }
    var providerTitle: String { catalog.provider(choice.provider)?.title ?? choice.provider }

    func select(provider: String) {
        guard provider != choice.provider, let entry = catalog.provider(provider) else { return }
        if provider == LedgerAgentModelChoice.customProvider {
            let saved = defaults.data(forKey: customKey).flatMap { try? JSONDecoder().decode(LedgerAgentModelChoice.self, from: $0) }
            store(saved ?? .init(provider: provider, model: "", custom: .init()))
        } else {
            store(.init(provider: provider, model: Self.preferredModel(in: entry)))
        }
    }

    func select(model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != choice.model, !trimmed.isEmpty || choice.isCustom else { return }
        store(.init(provider: choice.provider, model: trimmed, custom: choice.custom))
    }

    /// Updates the custom endpoint; only meaningful while 自定义 is selected.
    func setCustom(api: LedgerAgentModelChoice.CustomEndpoint.API? = nil, baseURL: String? = nil) {
        guard choice.isCustom else { return }
        var endpoint = choice.custom ?? .init()
        if let api { endpoint.api = api }
        if let baseURL { endpoint.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard endpoint != choice.custom else { return }
        store(.init(provider: choice.provider, model: choice.model, custom: endpoint))
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
        if choice.isCustom { defaults.set(try? JSONEncoder().encode(choice), forKey: customKey) }
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
