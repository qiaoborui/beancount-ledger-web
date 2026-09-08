import Foundation

enum LedgerExternalRoute: Equatable, Sendable {
    case page(LedgerDestination)
    case account(String, String)
    case transactions(String)
    case search(String)

    var destination: LedgerDestination {
        switch self {
        case let .page(destination): destination
        case .account: .accounts
        case .transactions: .transactions
        case .search: .search
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
        case "overview", "imports":
            guard query.isEmpty else { return nil }
            return .page(host == "overview" ? .overview : .imports)
        case "accounts":
            guard !query.isEmpty else { return .page(.accounts) }
            guard Set(query.keys).isSubset(of: ["account", "currency"]),
                  let account = query["account"], !account.isEmpty, account.count <= 512,
                  account.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            let currency = query["currency"] ?? ""
            guard currency.count <= 32, currency.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return .account(account, currency)
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

struct LedgerExternalRouteRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let route: LedgerExternalRoute
}

struct LedgerExternalAccount: Identifiable, Hashable, Sendable {
    let id = UUID()
    let account: String
    let currency: String
}

