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
    /// 周报 / 月报, over the current tab: one period, or the latest when nil.
    case report(LedgerReportRouteTarget?)

    var destination: LedgerDestination {
        switch self {
        case let .page(destination): destination
        case .account: .accounts
        case .transactions: .transactions
        case .search: .search
        case .agent: .agent
        case .record, .sentence: .transactions
        case .report: .overview
        }
    }

    /// The report opens as a sheet over whichever tab is showing.
    var opensReport: Bool {
        if case .report = self { return true }
        return false
    }

    /// 账本助手 is a full-screen cover over the current tab rather than a tab of its own.
    var opensAgent: Bool {
        switch self {
        case .agent, .page(.agent): true
        default: false
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
        case "report":
            guard !query.isEmpty else { return .report(nil) }
            guard let kind = query["period"].flatMap(LedgerReportPeriodKind.init(rawValue:)),
                  let start = query["start"], let startDate = date(start) else { return nil }
            switch kind {
            case .week, .month:
                guard Set(query.keys) == ["period", "start"] else { return nil }
                return .report(LedgerReportRouteTarget(kind: kind, start: start))
            case .custom:
                // At most about ten years, so the page never walks an unbounded range.
                guard Set(query.keys) == ["period", "start", "end"], let end = query["end"],
                      let endDate = date(end), startDate <= endDate,
                      endDate.timeIntervalSince(startDate) <= 3_660 * 86_400 else { return nil }
                return .report(LedgerReportRouteTarget(kind: .custom, start: start, end: end))
            }
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

/// A request to show 周报 / 月报 over the current tab, from a notification,
/// a link or 更多. `target` is nil for the latest weekly report.
struct LedgerReportRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let target: LedgerReportRouteTarget?
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


/// What a `ledger://accounts?account=…` link names in the loaded ledger.
enum LedgerExternalAccountResolution: Equatable, Sendable {
    case resolved(LedgerExternalAccountTarget)
    /// The ledger has no such account, e.g. one the assistant made up.
    case missingAccount(String)
    /// The account exists but nothing loaded says which currency to show.
    case missingCurrency(String)
}

struct LedgerExternalAccountTarget: Equatable, Sendable {
    let account: String
    let currency: String
}

extension LedgerBootstrap {
    /// Resolves an account link to the account and currency its detail page
    /// reads. A link from the assistant often carries no `currency`, and an
    /// account opened without a constraint currency (`open Expenses:Food`)
    /// has an empty `currency`, so this falls back the way the server's
    /// account detail does: the link's currency, then the open currency, then
    /// the currencies the account holds — the same balance rows the account
    /// list opens its detail page with.
    func resolveExternalAccount(_ path: String, currency requested: String) -> LedgerExternalAccountResolution {
        let name = path.trimmingCharacters(in: .whitespacesAndNewlines)
        var match = accounts.first(where: { $0.account == path }) ?? accounts.first(where: { $0.account == name })
        if match == nil {
            // A model sometimes changes the case of a name; accept that only
            // when it names one account.
            let folded = accounts.filter { $0.account.caseInsensitiveCompare(name) == .orderedSame }
            if folded.count == 1 { match = folded[0] }
        }
        guard let account = match else { return .missingAccount(name) }
        let requested = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requested.isEmpty { return .resolved(.init(account: account.account, currency: requested)) }
        if !account.currency.isEmpty { return .resolved(.init(account: account.account, currency: account.currency)) }
        var held: [String] = []
        for balance in accountBalances where balance.account == account.account && !balance.currency.isEmpty {
            if !held.contains(balance.currency) { held.append(balance.currency) }
        }
        if held.isEmpty {
            for transaction in transactions {
                for posting in transaction.postings where posting.account == account.account {
                    if let currency = posting.currency, !currency.isEmpty, !held.contains(currency) { held.append(currency) }
                }
            }
        }
        // Several currencies: the one amounts are valued in, else the first
        // row the account list shows for this account.
        guard let currency = held.first(where: { $0 == valuationCurrency }) ?? held.first else {
            return .missingCurrency(account.account)
        }
        return .resolved(.init(account: account.account, currency: currency))
    }
}
