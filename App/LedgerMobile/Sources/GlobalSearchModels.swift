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

enum LedgerGlobalSearch {
    static func matches(_ text: String, query: String) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace })
        return !words.isEmpty && words.allSatisfy {
            text.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
    }

    static func search(_ query: String, transactions: [LedgerTransaction], accounts: [LedgerAccount], documents: [LedgerImportDocument]) -> LedgerSearchResults {
        let labels = Dictionary(accounts.map { ($0.account, $0.label + " " + ($0.alias ?? "")) }, uniquingKeysWith: { first, _ in first })
        var result = LedgerSearchResults()
        result.transactions = transactions.filter { transaction in
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
            return matches(text.joined(separator: " "), query: query)
        }.sorted { $0.date > $1.date }
        result.accounts = accounts.filter { matches([$0.account, $0.label, $0.alias ?? "", $0.currency, $0.group].joined(separator: " "), query: query) }
        result.tags = Set(transactions.flatMap { $0.tags ?? [] }).filter { matches("#" + $0, query: query) }.sorted()
        result.documents = documents.filter {
            matches([$0.name, $0.path, $0.provider, LedgerImportProvider.provider($0.provider)?.label, $0.year, $0.dateStart, $0.dateEnd].compactMap { $0 }.joined(separator: " "), query: query)
        }
        result.destinations = LedgerDestination.allCases.filter { destination in
            guard destination != .search else { return false }
            let keywords = destination == .settings ? "Face ID FaceID 密码 解锁 隐私 生物识别" : ""
            return matches(destination.title + " " + destination.compactTitle + " " + keywords, query: query)
        }
        return result
    }
}
