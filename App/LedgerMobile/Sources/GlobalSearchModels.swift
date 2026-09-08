import Foundation

struct LedgerGlobalTransactions: Decodable, Sendable {
    let transactions: [LedgerTransaction]
    let sensitiveUnlocked: Bool
}

struct LedgerSearchResults: Sendable {
    var transactions: [LedgerTransaction] = []
    var accounts: [LedgerAccount] = []
    var tags: [String] = []
    var documents: [LedgerImportDocument] = []
    var destinations: [LedgerDestination] = []
    var isEmpty: Bool {
        transactions.isEmpty && accounts.isEmpty && tags.isEmpty && documents.isEmpty && destinations.isEmpty
    }
}

enum LedgerGlobalSearchScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all, transactions, accounts, documents
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "全部"
        case .transactions: "流水"
        case .accounts: "账户"
        case .documents: "文件"
        }
    }
}

struct LedgerGlobalSearchFilters: Equatable, Sendable {
    var account: String? = nil
    var tag: String? = nil
    var startDate: String? = nil
    var endDate: String? = nil
    var hasDateRange: Bool { startDate != nil || endDate != nil }
    var isEmpty: Bool { account == nil && tag == nil && !hasDateRange }
    var count: Int { (account == nil ? 0 : 1) + (tag == nil ? 0 : 1) + (hasDateRange ? 1 : 0) }

    func includes(_ transaction: LedgerTransaction) -> Bool {
        if let account, !transaction.postings.contains(where: { $0.account == account }) { return false }
        if let tag, !(transaction.tags ?? []).contains(tag) { return false }
        if let startDate, transaction.date < startDate { return false }
        if let endDate, transaction.date > endDate { return false }
        return true
    }

    func includes(_ document: LedgerImportDocument) -> Bool {
        guard account == nil, tag == nil else { return false }
        guard hasDateRange else { return true }
        // A file is included when its known coverage overlaps the requested days.
        guard let first = document.dateStart ?? document.dateEnd,
              let last = document.dateEnd ?? document.dateStart else { return false }
        if let startDate, last < startDate { return false }
        if let endDate, first > endDate { return false }
        return true
    }
}

enum LedgerGlobalSearch {
    static func matches(_ text: String, query: String) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace })
        return !words.isEmpty && words.allSatisfy {
            text.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
    }

    static func search(
        _ query: String,
        transactions: [LedgerTransaction],
        accounts: [LedgerAccount],
        documents: [LedgerImportDocument],
        scope: LedgerGlobalSearchScope = .all,
        filters: LedgerGlobalSearchFilters = .init()
    ) -> LedgerSearchResults {
        let isBlank = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !isBlank || scope != .all || !filters.isEmpty else { return LedgerSearchResults() }
        if let start = filters.startDate, let end = filters.endDate, start > end { return LedgerSearchResults() }
        let matchesQuery: (String) -> Bool = { isBlank || matches($0, query: query) }
        let filteredTransactions = transactions.filter(filters.includes)
        let labels = Dictionary(accounts.map { ($0.account, $0.label + " " + ($0.alias ?? "")) }, uniquingKeysWith: { first, _ in first })
        var result = LedgerSearchResults()
        if scope == .all || scope == .transactions {
            result.transactions = filteredTransactions.filter { transaction in
                var text = [transaction.date, transaction.payee, transaction.narration, transaction.source.file]
                text += (transaction.tags ?? []).map { "#" + $0 }
                text += transaction.postings.map { posting in
                    let value = Decimal(posting.amount) / 100
                    let amount = NSDecimalNumber(decimal: value).stringValue + " " + String(format: "%.2f", NSDecimalNumber(decimal: value).doubleValue)
                    return [posting.account, labels[posting.account] ?? "", amount, posting.currency ?? ""].joined(separator: " ")
                }
                for (key, value) in transaction.metadata ?? [:] {
                    text.append(key)
                    switch value {
                    case .null: break
                    case let .string(value): text.append(value)
                    case let .number(value): text.append(String(value))
                    case let .bool(value): text.append(String(value))
                    }
                }
                return matchesQuery(text.joined(separator: " "))
            }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        }
        if (scope == .all || scope == .accounts), filters.tag == nil, !filters.hasDateRange {
            result.accounts = accounts.filter {
                (filters.account == nil || filters.account == $0.account)
                    && matchesQuery([$0.account, $0.label, $0.alias ?? "", $0.currency, $0.group].joined(separator: " "))
            }
        }
        if scope == .all {
            result.tags = Set(filteredTransactions.flatMap { $0.tags ?? [] })
                .filter { (filters.tag == nil || filters.tag == $0) && matchesQuery("#" + $0) }.sorted()
        }
        if scope == .all || scope == .documents {
            result.documents = documents.filter {
                filters.includes($0) && matchesQuery([$0.name, $0.path, $0.provider, LedgerImportProvider.provider($0.provider)?.label, $0.year, $0.dateStart, $0.dateEnd].compactMap { $0 }.joined(separator: " "))
            }
        }
        if scope == .all, filters.isEmpty {
            result.destinations = LedgerDestination.allCases.filter { destination in
                guard destination != .search else { return false }
                let keywords = destination == .settings ? "Face ID FaceID 密码 解锁 隐私 生物识别" : ""
                return matches(destination.title + " " + destination.compactTitle + " " + keywords, query: query)
            }
        }
        return result
    }
}
