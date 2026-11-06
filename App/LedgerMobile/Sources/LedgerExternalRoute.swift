import Foundation

enum LedgerExternalRoute: Equatable, Sendable {
    case page(LedgerDestination)
    case account(String, String)
    case transactions(String)
    case search(String)
    /// A question for the ledger assistant, from Siri or a shortcut.
    case agent(String)
    /// The fast editor for a new transaction, from a widget or quick action.
    case record
    /// 用一句话记账, the natural-language entry, from a widget or quick action.
    case sentence

    var destination: LedgerDestination {
        switch self {
        case let .page(destination): destination
        case .account: .accounts
        case .transactions: .transactions
        case .search: .search
        case .agent: .agent
        case .record, .sentence: .transactions
        }
    }

    static func parse(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "ledger", url.user == nil, url.password == nil,
              url.port == nil, url.path.isEmpty || url.path == "/", url.fragment == nil,
              let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else { return nil }
            query[item.name] = value
        }
        switch host {
        case "agent" where !query.isEmpty:
            guard Set(query.keys) == ["q"], let question = query["q"],
                  question.utf8.count <= 4000, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .agent(question)
        case "overview", "imports", "agent":
            guard query.isEmpty else { return nil }
            return .page(host == "overview" ? .overview : host == "imports" ? .imports : .agent)
        case "accounts":
            guard !query.isEmpty else { return .page(.accounts) }
            guard Set(query.keys).isSubset(of: ["account", "currency"]),
                  let account = query["account"], !account.isEmpty, account.count <= 512,
                  account.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            let currency = query["currency"] ?? ""
            guard currency.count <= 32, currency.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return .account(account, currency)
        case "record":
            guard !query.isEmpty else { return .record }
            guard query == ["mode": "sentence"] else { return nil }
            return .sentence
        case "page":
            // Any tab by its stored name, for the configurable 快捷入口 widget.
            guard Set(query.keys) == ["name"], let name = query["name"],
                  let destination = LedgerDestination(rawValue: name) else { return nil }
            return .page(destination)
        case "transactions":
            guard !query.isEmpty else { return .page(.transactions) }
            guard query.count == 1, let day = query["date"], date(day) != nil else { return nil }
            return .transactions(day)
        case "search":
            guard Set(query.keys).isSubset(of: ["q"]), (query["q"] ?? "").count <= 500 else { return nil }
            return .search(query["q"] ?? "")
        default: return nil
        }
    }

    static func date(_ text: String) -> Date? {
        guard text.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
}

struct LedgerAgentPendingQuestion: Identifiable, Equatable, Sendable {
    let id = UUID()
    let text: String
}

struct LedgerQuickEntryRequest: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case record, sentence }
    let id = UUID()
    let kind: Kind
}

struct LedgerExternalRouteRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let route: LedgerExternalRoute
}

struct LedgerExternalAccount: Identifiable, Hashable, Sendable {
    let id = UUID()
    let account: String
    let currency: String
}

