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
    /// Whether a turn keeps the app awake in the background with silent
    /// audio, instead of relying only on the time iOS grants. On by default:
    /// without it a long turn is cut short once the phone locks.
    @Published private(set) var keepsAwake: Bool
    /// How a change that passes validation reaches the ledger. Tiered by
    /// default: written at once unless it deletes files or cuts a lot of
    /// lines. Every write is still a separate, revertible commit.
    @Published private(set) var writePolicy: LedgerAgentWritePolicy
    /// Whether turns read and keep the ledger's memory.md. On by default.
    @Published private(set) var usesMemory: Bool
    /// Whether the screen asks the model for suggestions, the next question
    /// and recaps on its own. On by default; each is a small extra request.
    @Published private(set) var assists: Bool
    /// Whether the page shows recommended questions at all: the empty
    /// state's starters, its refresh, and the suggestion the composer shows
    /// in place of the placeholder. On by default, and separate from
    /// `assists`, so recaps and naming can stay on with the suggestions off.
    @Published private(set) var suggestions: Bool
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
    private let keepsAwakeKey = "ledger.agent.keep-awake"
    private let writePolicyKey = "ledger.agent.write-policy"
    /// The on/off auto-write switch that `writePolicyKey` replaced. Read only
    /// to carry an existing install's choice over.
    private let autoWriteKey = "ledger.agent.auto-write"
    private let usesMemoryKey = "ledger.agent.memory"
    private let assistsKey = "ledger.agent.assists"
    private let suggestionsKey = "ledger.agent.suggestions"
    /// Each model's context window from the provider's list, by `identity`,
    /// so a turn after relaunch knows it without fetching the list again.
    private let contextWindowsKey = "ledger.agent.context-windows"
    private var contextWindows: [String: Int]
    /// Each model's reply limit from the provider's list, by `identity`.
    private let maxOutputTokensKey = "ledger.agent.max-output-tokens"
    private var maxOutputs: [String: Int]
    /// Lists fetched quietly this launch for a window, by `listKey`; each is
    /// tried once whatever its result, until a key is saved.
    private var quietlyListed: Set<String> = []
    /// Counts keys saved this launch, so replacing a key starts the quiet
    /// read again as well as saving the first one.
    @Published private var keyGeneration = 0
    private let keyStore: (String) -> ClassificationKeyStore
    private let lister: LedgerAgentModelLister

    /// A starred model. Its title and levels are kept so the chat page can
    /// show and clamp it without fetching the provider's list again.
    struct Favorite: Codable, Equatable, Identifiable, Sendable {
        var choice: LedgerAgentModelChoice
        var title: String
        var thinkingLevels: [String]? = nil
        var contextWindow: Int? = nil
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
        keepsAwake = defaults.object(forKey: keepsAwakeKey) as? Bool ?? true
        writePolicy = Self.writePolicy(in: defaults, key: writePolicyKey, legacyKey: autoWriteKey)
        usesMemory = defaults.object(forKey: usesMemoryKey) as? Bool ?? true
        assists = defaults.object(forKey: assistsKey) as? Bool ?? true
        suggestions = defaults.object(forKey: suggestionsKey) as? Bool ?? true
        contextWindows = defaults.dictionary(forKey: contextWindowsKey) as? [String: Int] ?? [:]
        maxOutputs = defaults.dictionary(forKey: maxOutputTokensKey) as? [String: Int] ?? [:]
        hasKey = (try? keyStore(choice.provider).load()) != nil
    }

    /// The model's context window as its provider's list gave it, nil when
    /// no list said. The native side then uses its catalog's window, or for a
    /// model it does not know a common one.
    func contextWindow(for choice: LedgerAgentModelChoice) -> Int? {
        let id = Self.identity(choice)
        if let window = listed[Self.listKey(choice)]?.first(where: { $0.id == choice.model })?.contextWindow, window > 0 {
            return window
        }
        if let window = contextWindows[id], window > 0 { return window }
        if let window = favorites.first(where: { $0.id == id })?.contextWindow, window > 0 { return window }
        return nil
    }

    /// The model's reply limit as its provider's list gave it, nil when no
    /// list said; the native side then keeps its own.
    func maxOutputTokens(for choice: LedgerAgentModelChoice) -> Int? {
        if let limit = listed[Self.listKey(choice)]?.first(where: { $0.id == choice.model })?.maxOutputTokens, limit > 0 {
            return limit
        }
        if let limit = maxOutputs[Self.identity(choice)], limit > 0 { return limit }
        return nil
    }

    /// What starts `learnContextWindow` again when it changes: the model and
    /// endpoint, and whether a key is saved, since the read needs one.
    var contextWindowTaskID: String { Self.identity(choice) + (hasKey ? "\u{1F}key\(keyGeneration)" : "") }

    /// Fetches the current provider's list once per launch, and again after
    /// a key is saved, when nothing says the current model's window yet.
    /// Failures are not shown: the turn still runs with the native side's
    /// window.
    func learnContextWindow() async {
        let choice = choice
        guard contextWindow(for: choice) == nil, choice.isComplete, !listing,
              let key = try? apiKey(), quietlyListed.insert(Self.listKey(choice)).inserted,
              let models = try? await lister.models(for: choice, apiKey: key) else { return }
        listed[Self.listKey(choice)] = models
        remember(models, for: choice)
    }

    /// Keeps the windows and reply limits of a fetched list for the next launch.
    private func remember(_ models: [LedgerAgentListedModel], for choice: LedgerAgentModelChoice) {
        var windowsChanged = false, outputsChanged = false
        for model in models {
            let id = Self.identity(.init(provider: choice.provider, model: model.id, custom: choice.isCustom ? choice.custom : nil))
            if let window = model.contextWindow, window > 0, contextWindows[id] != window {
                contextWindows[id] = window
                windowsChanged = true
            }
            if let limit = model.maxOutputTokens, limit > 0, maxOutputs[id] != limit {
                maxOutputs[id] = limit
                outputsChanged = true
            }
        }
        if windowsChanged { defaults.set(contextWindows, forKey: contextWindowsKey) }
        if outputsChanged { defaults.set(maxOutputs, forKey: maxOutputTokensKey) }
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

    func setKeepsAwake(_ on: Bool) {
        guard on != keepsAwake else { return }
        keepsAwake = on
        defaults.set(on, forKey: keepsAwakeKey)
    }

    func setWritePolicy(_ policy: LedgerAgentWritePolicy) {
        guard policy != writePolicy else { return }
        writePolicy = policy
        defaults.set(policy.rawValue, forKey: writePolicyKey)
    }

    /// The stored policy; an install from before it existed keeps what its
    /// auto-write switch said, and a new one starts tiered.
    private static func writePolicy(in defaults: UserDefaults, key: String,
                                    legacyKey: String) -> LedgerAgentWritePolicy {
        if let raw = defaults.string(forKey: key), let policy = LedgerAgentWritePolicy(rawValue: raw) { return policy }
        if let autoWrites = defaults.object(forKey: legacyKey) as? Bool { return autoWrites ? .always : .confirm }
        return .tiered
    }

    func setUsesMemory(_ on: Bool) {
        guard on != usesMemory else { return }
        usesMemory = on
        defaults.set(on, forKey: usesMemoryKey)
    }

    func setAssists(_ on: Bool) {
        guard on != assists else { return }
        assists = on
        defaults.set(on, forKey: assistsKey)
    }

    func setSuggestions(_ on: Bool) {
        guard on != suggestions else { return }
        suggestions = on
        defaults.set(on, forKey: suggestionsKey)
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
            favorites.append(.init(choice: target, title: title ?? self.title(for: target), thinkingLevels: levels.map(\.rawValue),
                                   contextWindow: contextWindow(for: target)))
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
        await refreshModels(apiKey: key)
    }

    /// Fetches the current provider's list with the given key.
    func refreshModels(apiKey key: String) async {
        guard !listing else { return }
        let choice = choice
        listing = true
        listError = nil
        defer { listing = false }
        do {
            let models = try await lister.models(for: choice, apiKey: key)
            listed[Self.listKey(choice)] = models
            remember(models, for: choice)
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
        // A list that failed with no key or an older one may answer now.
        quietlyListed.removeAll()
        keyGeneration += 1
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

/// How a change that passed validation reaches the ledger. The user picks it
/// in 助手设置 → 写入账本; it never bypasses validation, conflicts or undo.
enum LedgerAgentWritePolicy: String, CaseIterable, Identifiable, Sendable {
    /// Written at once, except the changes that are hard to notice going
    /// wrong: deleting a file, or cutting a lot of lines. The default.
    case tiered
    /// Every validated change is written at once.
    case always
    /// Nothing is written until the change card's button.
    case confirm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiered: String(localized: "自动写入")
        case .always: String(localized: "全部自动写入")
        case .confirm: String(localized: "每次确认")
        }
    }

    /// One sentence under the choice saying what it does now.
    var detail: String {
        switch self {
        case .tiered: String(localized: "校验通过就直接写入，删除文件或一次删改超过 \(Self.largeRemoval) 行时先问你。")
        case .always: String(localized: "校验通过就写入，不再询问；每次写入仍可撤销。")
        case .confirm: String(localized: "每次改动都要你点「写入账本」才写入。")
        }
    }

    /// Lines a change may cut before `tiered` asks first.
    static let largeRemoval = 20

    /// Whether a validated change is committed without the card's button.
    func writesWithoutAsking(_ review: LedgerAgentReview) -> Bool {
        switch self {
        case .always: return true
        case .confirm: return false
        case .tiered: return review.tieredHoldReason == nil
        }
    }

    /// What the card adds above the validation result when this policy holds
    /// the change back. nil when it writes the change at once, and when the
    /// user asked to confirm everything (the card already waits by itself).
    func holdReason(for review: LedgerAgentReview) -> String? {
        self == .tiered ? review.tieredHoldReason : nil
    }
}

extension LedgerAgentReview {
    /// Why a tiered write waits for the user. Appends, new files and small
    /// edits are written at once: they are the everyday kind of change, and
    /// every write can be undone from the answer.
    var tieredHoldReason: String? {
        let deleted = files.filter { $0.change == .removed }.count
        if deleted == 1 { return String(localized: "这次改动删除了 1 个文件，需要你确认。") }
        if deleted > 1 { return String(localized: "这次改动删除了 \(deleted) 个文件，需要你确认。") }
        if removed > LedgerAgentWritePolicy.largeRemoval {
            return String(localized: "这次改动删除了 \(removed) 行，需要你确认。")
        }
        return nil
    }
}
