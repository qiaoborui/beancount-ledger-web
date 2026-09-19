import Foundation
import CryptoKit

/// Portable input to the local writer. Amounts remain decimal strings all the
/// way to Beancount; model/provider types never enter the writer contract.
struct BookkeepingDraft: Codable, Equatable, Sendable {
    struct Evidence: Codable, Equatable, Sendable {
        enum Origin: String, Codable, Sendable { case manual, naturalLanguage, statement, beancount }
        let origin: Origin
        let fingerprint: String
        let locator: String
        let original: String
        static func make(_ origin: Origin, original: String, locator: String = "") -> Self {
            .init(origin: origin, fingerprint: SHA256.hash(data: Data(original.utf8)).map { String(format: "%02x", $0) }.joined(),
                  locator: locator, original: original)
        }
    }
    var id = UUID()
    var revision = UUID()
    var records: [LedgerTransactionEntry]
    var evidence: [Evidence]
    var questions: [String] = []
    var accountRoles: [[String]] = []
    var proposals: [AccountDecisionProposal] = []

    static func manual(_ entry: LedgerTransactionEntry) -> Self {
        .init(records: [entry], evidence: [.make(.manual, original: sourceJSON(entry))])
    }
    static func imported(_ entries: [LedgerImportEntry]) -> Self {
        .init(records: entries.map { entry in
            LedgerTransactionEntry(date: entry.date, flag: entry.flag, payee: entry.payee, narration: entry.narration,
                metadata: entry.metadata.mapValues(LedgerMetadataValue.string),
                tags: entry.tags ?? [], postings: entry.postings.map {
                    .init(account: $0.account, amount: $0.amount, currency: $0.currency,
                          priceKind: $0.priceKind, priceAmount: $0.priceAmount, priceCurrency: $0.priceCurrency)
                })
        }, evidence: entries.map { .make(.statement, original: sourceJSON($0), locator: $0.id) })
    }
    private static func sourceJSON<T: Encodable>(_ source: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(source)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    func validate() throws {
        guard questions.isEmpty else { throw BookkeepingError.reviewRequired(questions.joined(separator: "\n")) }
        guard !records.isEmpty, records.count <= 5000 else { throw BookkeepingError.reviewRequired("请先补充交易。") }
        for record in records {
            guard LedgerDateRange.parse(record.date) != nil, record.postings.count >= 2 else {
                throw BookkeepingError.reviewRequired("请补充日期和至少两条分录。")
            }
            for posting in record.postings {
                guard !posting.account.isEmpty, posting.amount.isEmpty || !posting.currency.isEmpty,
                      posting.amount.isEmpty || ExactBookkeepingAmount.parse(posting.amount) != nil else {
                    throw BookkeepingError.reviewRequired("请核对分录的账户、金额和币种。")
                }
            }
        }
    }
}

enum BookkeepingError: LocalizedError {
    case reviewRequired(String), expiredPreview, invalidModelResponse, configurationRequired
    var errorDescription: String? {
        switch self {
        case .reviewRequired(let message): message
        case .expiredPreview: "草稿或账本已变化，请重新生成预览。"
        case .invalidModelResponse: "解析结果无法验证，请补充描述或手动编辑。"
        case .configurationRequired: "请先配置语义解析接口、模型和 API Key。"
        }
    }
}

enum ExactBookkeepingAmount {
    static func parse(_ text: String) -> Decimal? {
        guard text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              text.filter(\.isNumber).count <= 28,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }
    static func text(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    static func sum(_ terms: [(String, Int)]) throws -> String {
        var result = Decimal.zero
        for (text, sign) in terms {
            guard var value = parse(text), [-1, 1].contains(sign) else { throw BookkeepingError.invalidModelResponse }
            if sign == -1 { value.negate() }
            var next = Decimal.zero
            guard NSDecimalAdd(&next, &result, &value, .plain) == .noError else { throw BookkeepingError.invalidModelResponse }
            result = next
        }
        return self.text(result)
    }
}

/// Domain contract shared by online and future device classifiers.
protocol BookkeepingClassifier: Sendable {
    func classify(_ input: ImportClassificationRequest) async throws -> ImportClassificationSuggestion
    func decideAccount(_ input: BookkeepingAccountQuestion) async throws -> AccountDecisionProposal
}

struct BookkeepingAccountQuestion: Codable, Sendable {
    let recordIndex: Int
    let postingIndex: Int
    let date: String
    let payee: String
    let narration: String
    let amount: String
    let currency: String
    let role: String
    let evidence: String
    let candidates: [ImportClassificationRequest.Account]
    let history: [ImportClassificationRequest.Example]
}

struct AccountDecisionProposal: Codable, Equatable, Sendable {
    let recordIndex: Int
    let postingIndex: Int
    let provider: String
    let decision: ImportClassificationSuggestion.Field
}

struct JevBookkeepingClassifier: BookkeepingClassifier {
    let apiKey: String
    let client: ImportClassificationClient
    init(apiKey: String, client: ImportClassificationClient = .init()) { self.apiKey = apiKey; self.client = client }
    func classify(_ input: ImportClassificationRequest) async throws -> ImportClassificationSuggestion {
        try await client.classify(input, apiKey: apiKey)
    }
    func decideAccount(_ input: BookkeepingAccountQuestion) async throws -> AccountDecisionProposal {
        try await client.decideAccount(input, apiKey: apiKey)
    }
}

enum BookkeepingPipeline {
    static func validProposals(_ proposals: [AccountDecisionProposal], before: [LedgerTransactionEntry],
                               after: [LedgerTransactionEntry]) -> [AccountDecisionProposal] {
        proposals.filter { proposal in
            let r = proposal.recordIndex, p = proposal.postingIndex
            guard before.indices.contains(r), after.indices.contains(r),
                  before[r].postings.indices.contains(p), after[r].postings.indices.contains(p) else { return false }
            let old = before[r], new = after[r]
            return old.date == new.date && old.payee == new.payee && old.narration == new.narration
                && old.postings[p] == new.postings[p] && new.postings[p].account.isEmpty
        }
    }
    @MainActor
    static func classifyImports(_ entries: [LedgerImportEntry], accounts: [LedgerAccount], history: [LedgerTransaction],
        provider: any BookkeepingClassifier, canContinue: () -> Bool,
        currentEntry: (String) -> LedgerImportEntry?, isEligible: (String) -> Bool,
        unsupported: (LedgerImportEntry) -> Void,
        accept: (ImportClassificationBatch.Job, ImportClassificationSuggestion, LedgerImportEntry) -> Void) async throws {
        try await ImportClassificationBatch.run(entries, makeInput: { entry in
            let input = ImportClassificationContext.request(for: entry, accounts: accounts, history: history)
            if input == nil { unsupported(entry) }
            return input
        }, classify: { input in
            try await provider.classify(input).validated(for: input)
        }, canContinue: canContinue, currentEntry: currentEntry, isEligible: isEligible, accept: { job, result in
            accept(job, result, ImportClassificationContext.autofilled(job.entry, suggestion: result, input: job.input))
        })
    }
    /// Enrich unresolved fields only. The caller checks its draft/consent
    /// revision again before presenting this immutable result.
    static func enrich(_ draft: BookkeepingDraft, accounts: [LedgerAccount], history: [LedgerTransaction],
                       provider: any BookkeepingClassifier) async throws -> BookkeepingDraft {
        var result = draft
        for (recordIndex, record) in draft.records.enumerated() {
            for (postingIndex, posting) in record.postings.enumerated() where posting.account.isEmpty {
                try Task.checkCancellation()
                let role = draft.accountRoles.indices.contains(recordIndex)
                    && draft.accountRoles[recordIndex].indices.contains(postingIndex)
                    ? draft.accountRoles[recordIndex][postingIndex] : "unknown"
                let prefixes: [String]
                switch role {
                case "funding", "receivable": prefixes = ["Assets:", "Liabilities:"]
                case "expense": prefixes = ["Expenses:"]
                case "income": prefixes = ["Income:"]
                case "counterpart": prefixes = ["Assets:", "Liabilities:", "Expenses:", "Income:"]
                default: continue // An unknown semantic role requires user input.
                }
                let candidates = accounts.filter { account in
                    prefixes.contains(where: account.account.hasPrefix) && account.openDate <= record.date
                        && (account.closeDate == nil || account.closeDate! > record.date)
                        && (account.currency.isEmpty || account.currency == posting.currency)
                }.sorted { $0.account < $1.account }
                guard !candidates.isEmpty, candidates.count <= 254 else { continue }
                let related = history.filter { $0.date <= record.date && !record.payee.isEmpty && $0.payee == record.payee }
                    .sorted { $0.date > $1.date }.prefix(5).map { transaction in
                        ImportClassificationRequest.Example(date: transaction.date, payee: transaction.payee,
                            narration: transaction.narration, method: "", cardLast4: "",
                            accounts: Array(Set(transaction.postings.map(\.account))).sorted(),
                            fundingAccount: nil, categoryAccount: nil, tags: [])
                    }
                let input = BookkeepingAccountQuestion(recordIndex: recordIndex, postingIndex: postingIndex,
                    date: record.date, payee: record.payee, narration: record.narration, amount: posting.amount,
                    currency: posting.currency, role: role, evidence: draft.evidence.map(\.original).joined(separator: "\n"),
                    candidates: candidates.map { .init(account: $0.account, label: $0.displayLabel) }, history: related)
                let proposal = try await provider.decideAccount(input)
                try proposal.decision.validate(allowed: Set(candidates.map(\.account)))
                guard proposal.recordIndex == recordIndex, proposal.postingIndex == postingIndex else {
                    throw BookkeepingError.invalidModelResponse
                }
                result.proposals.append(proposal)
                // Suggestions stay separate. Users explicitly choose them in the
                // natural-language editor, including high-scoring predictions.
            }
        }
        return result
    }

}

struct PreparedBookkeepingChange: Identifiable, Sendable {
    let id: UUID
    let ledgerID: UUID
    let draftRevision: UUID
    let files: LocalLedgerWorkspace.PreparedFiles
    let createdAt: Date
}
