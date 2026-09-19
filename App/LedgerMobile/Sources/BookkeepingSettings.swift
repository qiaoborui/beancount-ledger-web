import SwiftUI

@MainActor
final class BookkeepingSettings: ObservableObject {
    static let shared = BookkeepingSettings()
    @Published private(set) var configuration: CompatibleBookkeepingParser.Configuration
    @Published private(set) var revision = 0
    @Published private(set) var hasKey: Bool
    private let defaults: UserDefaults
    private let keyStore: ClassificationKeyStore
    private let preference = "ledger.bookkeeping.semantic-configuration"
    init(defaults: UserDefaults = .standard,
         keyStore: ClassificationKeyStore = .init(service: "com.qiaoborui.ledger.semantic-parser")) {
        self.defaults = defaults
        self.keyStore = keyStore
        configuration = defaults.data(forKey: preference).flatMap {
            try? JSONDecoder().decode(CompatibleBookkeepingParser.Configuration.self, from: $0)
        } ?? .init(baseURL: "", model: "")
        hasKey = (try? keyStore.load()) != nil
    }
    func save(baseURL: String, model: String, key: String) throws {
        let next = CompatibleBookkeepingParser.Configuration(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines))
        _ = try next.endpoint()
        // Changing the endpoint requires a fresh key, preventing accidental
        // forwarding of an existing provider credential to a different host.
        if next.baseURL != configuration.baseURL && key.isEmpty { throw BookkeepingError.configurationRequired }
        if !key.isEmpty {
            let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.utf8.count <= 4096,
                  cleaned.utf8.allSatisfy({ (33...126).contains($0) }) else { throw BookkeepingError.configurationRequired }
            try keyStore.save(cleaned)
        }
        guard (try keyStore.load()) != nil else { throw BookkeepingError.configurationRequired }
        defaults.set(try JSONEncoder().encode(next), forKey: preference)
        configuration = next
        hasKey = true
        revision &+= 1
    }
    func parser() throws -> any BookkeepingSemanticParser {
        #if DEBUG
        if usesSyntheticParser { return SyntheticBookkeepingParser() }
        #endif
        guard let key = try keyStore.load() else { throw BookkeepingError.configurationRequired }
        return CompatibleBookkeepingParser(configuration: configuration, apiKey: key)
    }
    var canParse: Bool {
        #if DEBUG
        if usesSyntheticParser { return true }
        #endif
        return hasKey
    }
    #if DEBUG
    private var usesSyntheticParser: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--local-ui-testing") && arguments.contains("--safe-bookkeeping-parser")
    }
    #endif
    func removeKey() throws { try keyStore.remove(); hasKey = false; revision &+= 1 }
}

#if DEBUG
/// Explicit isolated simulator UI fixture; uses the production source checks,
/// draft editor, engine and canonical validator, with zero network traffic.
private struct SyntheticBookkeepingParser: BookkeepingSemanticParser {
    func parse(_ input: BookkeepingParseInput) async throws -> BookkeepingDraft {
        let record = SemanticBookkeepingResponse.Record(date: input.referenceDate, payee: "Synthetic split",
            narration: "餐饮和交通", postings: [
                .init(account: "Expenses:Food", role: "expense", currency: "CNY",
                      terms: [.init(value: "128", sign: 1), .init(value: "48", sign: -1)], evidence: input.text),
                .init(account: "Expenses:Transport", role: "expense", currency: "CNY",
                      terms: [.init(value: "48", sign: 1)], evidence: input.text),
                .init(account: "Assets:Cash", role: "funding", currency: "CNY",
                      terms: [.init(value: "128", sign: -1)], evidence: input.text)])
        return try SemanticBookkeepingResponse(records: [record], questions: []).draft(for: input)
    }
}
#endif
