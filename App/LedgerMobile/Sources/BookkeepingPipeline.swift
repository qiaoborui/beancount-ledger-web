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
    static func classifyImports(_ entries: [LedgerImportEntry], accounts: [LedgerAccount], history: [LedgerTransaction] = [],
        evidence: ((LedgerImportEntry) async throws -> ImportClassificationContext.Evidence)? = nil,
        provider: any BookkeepingClassifier, canContinue: () -> Bool,
        currentEntry: (String) -> LedgerImportEntry?, isEligible: (String) -> Bool,
        unsupported: (LedgerImportEntry) -> Void,
        accept: (ImportClassificationBatch.Job, ImportClassificationSuggestion, LedgerImportEntry) -> Void) async throws {
        try await ImportClassificationBatch.run(entries, makeInput: { entry in
            let input: ImportClassificationRequest?
            if let evidence {
                input = ImportClassificationContext.request(for: entry, accounts: accounts, evidence: try await evidence(entry))
            } else {
                input = ImportClassificationContext.request(for: entry, accounts: accounts, history: history)
            }
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
    static func enrich(_ draft: BookkeepingDraft, accounts: [LedgerAccount], history: [LedgerTransaction] = [],
                       relatedHistory: (@Sendable (LedgerTransactionEntry) async throws -> [LedgerTransaction])? = nil,
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
                let evidenceHistory = try await relatedHistory?(record) ?? history
                try Task.checkCancellation()
                let related = evidenceHistory.filter { $0.date <= record.date && !record.payee.isEmpty && $0.payee == record.payee }
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
                try Task.checkCancellation()
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

enum BookkeepingAccountMatcher {
    static func match(role: String, text: String, accounts: [LedgerAccount]) -> String? {
        let lower = text.lowercased()
        switch role {
        case "expense":
            return matchExpense(text: lower, accounts: accounts)
        case "funding", "receivable":
            return matchFunding(text: lower, accounts: accounts)
        case "income":
            return matchIncome(text: lower, accounts: accounts)
        default:
            return matchExpense(text: lower, accounts: accounts) ?? matchFunding(text: lower, accounts: accounts)
        }
    }

    private static func matchExpense(text: String, accounts: [LedgerAccount]) -> String? {
        if text.contains("外卖") || text.contains("美团") || text.contains("饿了么") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["takeout", "外卖"]) { return acc }
        }
        if text.contains("咖啡") || text.contains("奶茶") || text.contains("饮品") || text.contains("星巴克") || text.contains("瑞幸") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["drink", "coffee", "beverage", "饮品", "咖啡"]) { return acc }
        }
        if text.contains("餐") || text.contains("饭") || text.contains("吃") || text.contains("麦当劳")
            || text.contains("肯德基") || text.contains("汉堡") || text.contains("火锅") || text.contains("美食")
            || text.contains("早饭") || text.contains("午餐") || text.contains("晚餐") || text.contains("夜宵") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["food", "dining", "meal", "餐饮", "正餐"]) { return acc }
        }
        if text.contains("打车") || text.contains("滴滴") || text.contains("出租") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["taxi", "打车", "出租"]) { return acc }
        }
        if text.contains("地铁") || text.contains("公交") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["subway", "bus", "transit", "地铁", "公交"]) { return acc }
        }
        if text.contains("交通") || text.contains("加油") || text.contains("停车") || text.contains("高铁") || text.contains("火车") || text.contains("机票") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["transport", "traffic", "travel", "交通"]) { return acc }
        }
        if text.contains("买菜") || text.contains("超市") || text.contains("便利店") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["groceries", "supermarket", "超市", "买菜"]) { return acc }
        }
        if text.contains("购物") || text.contains("淘宝") || text.contains("京东") || text.contains("拼多多") || text.contains("日用") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["shopping", "daily", "购物", "日用"]) { return acc }
        }
        if text.contains("书") || text.contains("学习") || text.contains("课程") || text.contains("培训") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["book", "education", "study", "书", "学习"]) { return acc }
        }
        if text.contains("电影") || text.contains("游戏") || text.contains("门票") || text.contains("旅游") || text.contains("玩") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["entertainment", "game", "movie", "娱乐", "游戏", "电影"]) { return acc }
        }
        if text.contains("房租") || text.contains("物业") || text.contains("水费") || text.contains("电费") || text.contains("燃气") || text.contains("话费") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["housing", "utilities", "rent", "居住", "房租", "水电", "话费"]) { return acc }
        }
        if text.contains("医院") || text.contains("药") || text.contains("门诊") || text.contains("体检") {
            if let acc = find(accounts, prefix: "Expenses:", keywords: ["health", "medical", "医疗", "药品"]) { return acc }
        }
        return accounts.first(where: { $0.account.hasPrefix("Expenses:") && $0.active })?.account
    }

    private static func matchFunding(text: String, accounts: [LedgerAccount]) -> String? {
        if text.contains("微信") || text.contains("wx") || text.contains("零钱") {
            if let acc = find(accounts, prefix: "Assets:", keywords: ["wechat", "weixin", "wx", "微信", "零钱"]) { return acc }
        }
        if text.contains("花呗") {
            if let acc = find(accounts, prefix: "Liabilities:", keywords: ["huabei", "花呗"]) { return acc }
        }
        if text.contains("支付宝") || text.contains("alipay") || text.contains("余额宝") {
            if let acc = find(accounts, prefix: "Assets:", keywords: ["alipay", "支付宝", "余额宝"]) { return acc }
        }
        if text.contains("招行") || text.contains("招商") || text.contains("cmb") {
            if text.contains("信用卡") {
                if let acc = find(accounts, prefix: "Liabilities:", keywords: ["cmb", "招行", "招商"]) { return acc }
            }
            if let acc = find(accounts, prefix: "Assets:", keywords: ["cmb", "招行", "招商"]) { return acc }
        }
        if text.contains("工行") || text.contains("工商") || text.contains("icbc") {
            if text.contains("信用卡") {
                if let acc = find(accounts, prefix: "Liabilities:", keywords: ["icbc", "工行", "工商"]) { return acc }
            }
            if let acc = find(accounts, prefix: "Assets:", keywords: ["icbc", "工行", "工商"]) { return acc }
        }
        if text.contains("信用卡") {
            if let acc = find(accounts, prefix: "Liabilities:", keywords: ["creditcard", "信用卡", "card"]) { return acc }
        }
        if text.contains("现金") || text.contains("cash") {
            if let acc = find(accounts, prefix: "Assets:", keywords: ["cash", "现金"]) { return acc }
        }
        for kw in ["wechat", "weixin", "alipay", "cmb", "cash", "bank"] {
            if let acc = find(accounts, prefix: "Assets:", keywords: [kw]) { return acc }
        }
        return accounts.first(where: { $0.account.hasPrefix("Assets:") && $0.active })?.account
    }

    private static func matchIncome(text: String, accounts: [LedgerAccount]) -> String? {
        if text.contains("工资") || text.contains("薪水") || text.contains("奖金") {
            if let acc = find(accounts, prefix: "Income:", keywords: ["salary", "wage", "bonus", "工资", "薪水"]) { return acc }
        }
        return accounts.first(where: { $0.account.hasPrefix("Income:") && $0.active })?.account
    }

    private static func find(_ accounts: [LedgerAccount], prefix: String, keywords: [String]) -> String? {
        let matchingPrefix = accounts.filter { $0.account.hasPrefix(prefix) && $0.active }
        for kw in keywords {
            if let match = matchingPrefix.first(where: {
                $0.account.lowercased().contains(kw) || $0.label.lowercased().contains(kw) || $0.displayLabel.lowercased().contains(kw)
            }) {
                return match.account
            }
        }
        return nil
    }

    static func categoryCandidates(selected: String, accounts: [LedgerAccount]) -> [LedgerAccount] {
        let active = accounts.filter { ($0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:")) && $0.active }
        var result: [LedgerAccount] = []
        if let current = active.first(where: { $0.account == selected }) {
            result.append(current)
            let prefixParts = selected.components(separatedBy: ":").prefix(2).joined(separator: ":")
            let siblings = active.filter { $0.account.hasPrefix(prefixParts) && $0.account != selected }
            result.append(contentsOf: siblings.prefix(3))
        }
        for acc in active where !result.contains(where: { $0.account == acc.account }) {
            result.append(acc)
            if result.count >= 5 { break }
        }
        return result
    }

    static func fundingCandidates(selected: String, accounts: [LedgerAccount]) -> [LedgerAccount] {
        let active = accounts.filter { ($0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:")) && $0.active }
        var result: [LedgerAccount] = []
        if let current = active.first(where: { $0.account == selected }) {
            result.append(current)
        }
        let priorityKeywords = ["wechat", "weixin", "alipay", "cmb", "icbc", "creditcard", "cash"]
        for kw in priorityKeywords {
            if let match = active.first(where: { acc in
                !result.contains(where: { $0.account == acc.account }) &&
                (acc.account.lowercased().contains(kw) || acc.displayLabel.lowercased().contains(kw))
            }) {
                result.append(match)
            }
            if result.count >= 5 { break }
        }
        for acc in active where !result.contains(where: { $0.account == acc.account }) {
            result.append(acc)
            if result.count >= 5 { break }
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
