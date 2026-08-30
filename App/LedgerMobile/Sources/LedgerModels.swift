import Foundation

enum LedgerDateRangePreset: String, CaseIterable, Equatable, Sendable {
    case month
    case quarter
    case year
    case custom

    var title: String {
        switch self {
        case .month: "本月"
        case .quarter: "本季度"
        case .year: "本年"
        case .custom: "自定义"
        }
    }
}

struct LedgerDateRange: Equatable, Sendable {
    let start: String
    let end: String
    let preset: LedgerDateRangePreset

    static func month(year: Int, month: Int) -> LedgerDateRange {
        let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        return period(starting: start, adding: .month, value: 1, preset: .month)
    }

    static func current(_ preset: LedgerDateRangePreset, now: Date = Date()) -> LedgerDateRange {
        let components = calendar.dateComponents([.year, .month], from: now)
        let year = components.year ?? 2000
        let month = components.month ?? 1

        switch preset {
        case .month:
            return Self.month(year: year, month: month)
        case .quarter:
            let quarterStartMonth = ((month - 1) / 3) * 3 + 1
            let start = calendar.date(from: DateComponents(year: year, month: quarterStartMonth, day: 1)) ?? now
            return period(starting: start, adding: .month, value: 3, preset: .quarter)
        case .year:
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
            return period(starting: start, adding: .year, value: 1, preset: .year)
        case .custom:
            return custom(start: now, end: now)
        }
    }

    static func custom(start: Date, end: Date) -> LedgerDateRange {
        let lower = min(start, end)
        let upper = max(start, end)
        return LedgerDateRange(start: format(lower), end: format(upper), preset: .custom)
    }

    func shifted(by delta: Int) -> LedgerDateRange {
        guard delta != 0, let startDate = Self.parse(start) else { return self }

        switch preset {
        case .month:
            let shifted = Self.calendar.date(byAdding: .month, value: delta, to: startDate) ?? startDate
            let components = Self.calendar.dateComponents([.year, .month], from: shifted)
            return Self.month(year: components.year ?? 2000, month: components.month ?? 1)
        case .quarter:
            let shifted = Self.calendar.date(byAdding: .month, value: delta * 3, to: startDate) ?? startDate
            return Self.quarter(containing: shifted)
        case .year:
            let shifted = Self.calendar.date(byAdding: .year, value: delta, to: startDate) ?? startDate
            return Self.year(containing: shifted)
        case .custom:
            return self
        }
    }

    var displayTitle: String {
        guard let startDate = Self.parse(start) else { return start }
        let components = Self.calendar.dateComponents([.year, .month], from: startDate)
        let year = components.year ?? 0
        let month = components.month ?? 1

        switch preset {
        case .month:
            return "\(year)年\(month)月"
        case .quarter:
            return "\(year)年第\(((month - 1) / 3) + 1)季度"
        case .year:
            return "\(year)年"
        case .custom:
            return "\(start) 至 \(end)"
        }
    }

    var metricScope: String {
        switch preset {
        case .month: "月度"
        case .quarter: "季度"
        case .year: "年度"
        case .custom: "范围"
        }
    }

    var startDate: Date { Self.parse(start) ?? Date() }
    var endDate: Date { Self.parse(end) ?? startDate }

    static func today(now: Date = Date()) -> String {
        format(now)
    }

    private static func quarter(containing date: Date) -> LedgerDateRange {
        let components = calendar.dateComponents([.year, .month], from: date)
        let month = components.month ?? 1
        let quarterStartMonth = ((month - 1) / 3) * 3 + 1
        let start = calendar.date(
            from: DateComponents(year: components.year ?? 2000, month: quarterStartMonth, day: 1)
        ) ?? date
        return period(starting: start, adding: .month, value: 3, preset: .quarter)
    }

    private static func year(containing date: Date) -> LedgerDateRange {
        let year = calendar.component(.year, from: date)
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? date
        return period(starting: start, adding: .year, value: 1, preset: .year)
    }

    private static func period(
        starting start: Date,
        adding component: Calendar.Component,
        value: Int,
        preset: LedgerDateRangePreset
    ) -> LedgerDateRange {
        let exclusiveEnd = calendar.date(byAdding: component, value: value, to: start) ?? start
        let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: exclusiveEnd) ?? exclusiveEnd
        return LedgerDateRange(start: format(start), end: format(inclusiveEnd), preset: preset)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func parse(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }
}

struct HealthStatus: Decodable, Equatable {
    let apiVersion: Int
    let capabilities: [String]

    func validateForMobileClient() throws {
        guard apiVersion == 1 else {
            throw LedgerAPIError.incompatibleServer("服务器 API 版本不兼容（需要版本 1）")
        }
        let available = Set(capabilities)
        guard available.contains("cookie-auth"), available.contains("full-backend") else {
            throw LedgerAPIError.incompatibleServer("服务器缺少 iOS 客户端所需的登录或账本能力")
        }
    }
}

struct AuthStatus: Decodable, Equatable {
    let authenticated: Bool
    let sensitiveUnlocked: Bool
    let authDisabled: Bool
}

struct LoginRequest: Encodable {
    let password: String
}

struct PasskeyStatus: Decodable, Equatable, Sendable {
    let registered: Bool
    let count: Int
}

struct PasskeyRequestOptions: Decodable, Equatable, Sendable {
    let challenge: String
    let timeout: Int?
    let relyingPartyID: String?
    let allowCredentials: [PasskeyCredentialDescriptor]
    let userVerification: String?

    private enum CodingKeys: String, CodingKey {
        case challenge
        case timeout
        case relyingPartyID = "rpId"
        case allowCredentials
        case userVerification
    }

    init(
        challenge: String,
        timeout: Int? = nil,
        relyingPartyID: String? = nil,
        allowCredentials: [PasskeyCredentialDescriptor] = [],
        userVerification: String? = nil
    ) {
        self.challenge = challenge
        self.timeout = timeout
        self.relyingPartyID = relyingPartyID
        self.allowCredentials = allowCredentials
        self.userVerification = userVerification
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        challenge = try container.decode(String.self, forKey: .challenge)
        timeout = try container.decodeIfPresent(Int.self, forKey: .timeout)
        relyingPartyID = try container.decodeIfPresent(String.self, forKey: .relyingPartyID)
        allowCredentials = try container.decodeIfPresent([PasskeyCredentialDescriptor].self, forKey: .allowCredentials) ?? []
        userVerification = try container.decodeIfPresent(String.self, forKey: .userVerification)
    }
}

struct PasskeyCredentialDescriptor: Decodable, Equatable, Sendable {
    let type: String
    let id: String
    let transports: [String]?
}

struct PasskeyAssertion: Encodable, Equatable, Sendable {
    let id: String
    let rawID: String
    let type: String
    let response: PasskeyAssertionResponse

    private enum CodingKeys: String, CodingKey {
        case id
        case rawID = "rawId"
        case type
        case response
    }

    init(
        credentialID: Data,
        clientDataJSON: Data,
        authenticatorData: Data,
        signature: Data,
        userHandle: Data
    ) {
        let encodedCredentialID = credentialID.base64URLEncodedString()
        id = encodedCredentialID
        rawID = encodedCredentialID
        type = "public-key"
        response = PasskeyAssertionResponse(
            clientDataJSON: clientDataJSON.base64URLEncodedString(),
            authenticatorData: authenticatorData.base64URLEncodedString(),
            signature: signature.base64URLEncodedString(),
            userHandle: userHandle.isEmpty ? nil : userHandle.base64URLEncodedString()
        )
    }
}

struct PasskeyAssertionResponse: Encodable, Equatable, Sendable {
    let clientDataJSON: String
    let authenticatorData: String
    let signature: String
    let userHandle: String?
}

extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct QuickUnlockRegisterRequest: Encodable {
    let mode: String
    let name: String
}

struct QuickUnlockCredential: Codable, Equatable, Sendable {
    let deviceID: String
    let token: String

    private enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case token
    }
}

struct QuickUnlockVerifyRequest: Encodable {
    let deviceID: String
    let token: String

    private enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case token
    }
}

struct QuickUnlockRevokeRequest: Encodable {
    let deviceID: String

    private enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
    }
}

struct APIErrorPayload: Decodable {
    let error: String?
}

struct LedgerBootstrap: Decodable {
    let start: String
    let end: String
    let summary: LedgerSummary
    let accountBalances: [AccountBalance]
    let transactions: [LedgerTransaction]
    let accounts: [LedgerAccount]
    let valuationCurrency: String
    let sensitiveUnlocked: Bool
}

struct LedgerSummary: Decodable, Equatable {
    let currency: String
    let income: Int
    let expense: Int
    let net: Int
}

struct LedgerTransaction: Decodable, Identifiable, Equatable {
    let date: String
    let payee: String
    let narration: String
    let tags: [String]?
    let postings: [LedgerPosting]
    let source: TransactionSource

    var id: String {
        "\(source.gitSHA ?? "local"):\(source.file):\(source.line):\(source.hash ?? "")"
    }
}

struct LedgerPosting: Decodable, Equatable, Identifiable {
    let account: String
    let amount: Int
    let currency: String?

    var id: String { "\(account):\(amount):\(currency ?? "")" }
}

struct TransactionSource: Decodable, Equatable {
    let file: String
    let line: Int
    let hash: String?
    let gitSHA: String?

    private enum CodingKeys: String, CodingKey {
        case file
        case line
        case hash
        case gitSHA = "gitSha"
    }
}

struct AccountBalance: Decodable, Equatable {
    let account: String
    let currency: String
    let amount: Int
    let valuationCurrency: String
    let valuation: Int
    let valuationMissing: Bool?
}

struct LedgerAccount: Decodable, Equatable {
    let account: String
    let openDate: String
    let closeDate: String?
    let currency: String
    let alias: String?
    let label: String
    let group: String
    let active: Bool
}

enum TransactionKind: Equatable {
    case expense
    case income
    case transfer
}

struct TransactionPresentation: Equatable {
    let kind: TransactionKind
    let title: String
    let subtitle: String
    let minorUnits: Int
    let currency: String

    init(transaction: LedgerTransaction) {
        title = transaction.payee.isEmpty
            ? (transaction.narration.isEmpty ? "未命名交易" : transaction.narration)
            : transaction.payee

        if !transaction.payee.isEmpty, !transaction.narration.isEmpty {
            subtitle = transaction.narration
        } else {
            subtitle = transaction.postings.first?.account ?? ""
        }

        if let posting = transaction.postings.first(where: { $0.account.hasPrefix("Expenses:") && $0.amount != 0 }) {
            kind = .expense
            minorUnits = abs(posting.amount)
            currency = posting.currency ?? "CNY"
            return
        }

        if let posting = transaction.postings.first(where: { $0.account.hasPrefix("Income:") && $0.amount != 0 }) {
            kind = .income
            minorUnits = abs(posting.amount)
            currency = posting.currency ?? "CNY"
            return
        }

        let posting = transaction.postings.max { abs($0.amount) < abs($1.amount) }
        kind = .transfer
        minorUnits = abs(posting?.amount ?? 0)
        currency = posting?.currency ?? "CNY"
    }
}

struct BalanceSheetTotals: Equatable {
    let assets: Int
    let liabilities: Int
    let netWorth: Int
}

struct AccountBalanceRow: Identifiable, Equatable {
    let account: String
    let label: String
    let group: String
    let nativeCurrency: String
    let nativeAmount: Int
    let valuationCurrency: String
    let valuation: Int
    let valuationMissing: Bool

    var id: String { "\(account):\(nativeCurrency)" }
}

struct AccountBalanceSection: Identifiable, Equatable {
    let id: String
    let title: String
    let rows: [AccountBalanceRow]
}

extension LedgerBootstrap {
    var balanceSheetTotals: BalanceSheetTotals {
        let valid = accountBalances.filter { !($0.valuationMissing ?? false) }
        let assets = valid
            .filter { $0.account.hasPrefix("Assets:") }
            .reduce(0) { $0 + $1.valuation }
        let liabilities = valid
            .filter { $0.account.hasPrefix("Liabilities:") }
            .reduce(0) { $0 + abs($1.valuation) }
        return BalanceSheetTotals(assets: assets, liabilities: liabilities, netWorth: assets - liabilities)
    }

    var accountSections: [AccountBalanceSection] {
        let accountIndex = accounts.reduce(into: [String: LedgerAccount]()) { index, account in
            index[account.account] = account
        }
        let rows = accountBalances.map { balance -> AccountBalanceRow in
            let account = accountIndex[balance.account]
            return AccountBalanceRow(
                account: balance.account,
                label: account?.displayLabel ?? balance.account.split(separator: ":").last.map(String.init) ?? balance.account,
                group: account?.group.isEmpty == false ? account!.group : Self.fallbackGroup(for: balance.account),
                nativeCurrency: balance.currency,
                nativeAmount: balance.amount,
                valuationCurrency: balance.valuationCurrency,
                valuation: balance.valuation,
                valuationMissing: balance.valuationMissing ?? false
            )
        }

        let grouped = Dictionary(grouping: rows, by: \.group)
        return grouped
            .map { key, rows in
                AccountBalanceSection(
                    id: key,
                    title: Self.groupTitle(key),
                    rows: rows.sorted {
                        $0.label.localizedStandardCompare($1.label) == .orderedAscending
                    }
                )
            }
            .sorted { Self.groupRank($0.id) < Self.groupRank($1.id) }
    }

    private static func fallbackGroup(for account: String) -> String {
        if account.hasPrefix("Assets:") { return "asset" }
        if account.hasPrefix("Liabilities:") { return "liability" }
        if account.hasPrefix("Income:") { return "income" }
        if account.hasPrefix("Expenses:") { return "expense" }
        if account.hasPrefix("Equity:") { return "equity" }
        return "other"
    }

    private static func groupTitle(_ group: String) -> String {
        switch group {
        case "cash": return "现金与支付"
        case "credit": return "信用账户"
        case "liability": return "负债"
        case "wealth": return "储蓄与资产"
        case "receivable": return "应收"
        case "asset": return "资产"
        case "expense": return "支出账户"
        case "income": return "收入账户"
        case "equity": return "权益"
        default: return "其他"
        }
    }

    private static func groupRank(_ group: String) -> Int {
        let order = ["cash", "credit", "liability", "wealth", "receivable", "asset", "expense", "income", "equity", "other"]
        return order.firstIndex(of: group) ?? order.count
    }
}

extension LedgerAccount {
    var displayLabel: String {
        let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedAlias.isEmpty {
            return trimmedAlias.split(separator: "/").first.map(String.init) ?? trimmedAlias
        }
        if !label.isEmpty { return label }
        return account.split(separator: ":").last.map(String.init) ?? account
    }
}

enum MoneyText {
    enum DisplayMode {
        case full
        case adaptive
    }

    static func format(minorUnits: Int, currency: String, showSign: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.isEmpty ? "CNY" : currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.usesGroupingSeparator = true
        if showSign {
            formatter.positivePrefix = "+" + (formatter.positivePrefix ?? "")
        }
        let value = NSDecimalNumber(value: Double(minorUnits) / 100)
        return formatter.string(from: value) ?? "\(currency) \(value)"
    }

    static func formatCompact(minorUnits: Int, currency: String, showSign: Bool = false) -> String {
        let currencyCode = currency.isEmpty ? "CNY" : currency
        let value = Double(minorUnits) / 100
        let absoluteValue = abs(value)
        let unit: (divisor: Double, suffix: String)?

        if currencyCode == "CNY" {
            if absoluteValue >= 100_000_000 {
                unit = (100_000_000, "亿")
            } else if absoluteValue >= 10_000 {
                unit = (10_000, "w")
            } else {
                unit = nil
            }
        } else if absoluteValue >= 1_000_000_000 {
            unit = (1_000_000_000, "B")
        } else if absoluteValue >= 1_000_000 {
            unit = (1_000_000, "M")
        } else if absoluteValue >= 1_000 {
            unit = (1_000, "k")
        } else {
            unit = nil
        }

        guard let unit else {
            return format(minorUnits: minorUnits, currency: currencyCode, showSign: showSign)
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.roundingMode = .halfUp
        let compactValue = absoluteValue / unit.divisor
        let number = formatter.string(from: NSNumber(value: compactValue)) ?? String(format: "%.1f", compactValue)
        let sign = value < 0 ? "-" : showSign ? "+" : ""
        return "\(sign)\(currencySymbol(for: currencyCode))\(number)\(unit.suffix)"
    }

    private static func currencySymbol(for currency: String) -> String {
        let commonSymbols = [
            "CNY": "¥",
            "USD": "$",
            "EUR": "€",
            "GBP": "£",
            "JPY": "¥",
            "HKD": "HK$",
        ]
        if let symbol = commonSymbols[currency] { return symbol }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "zh_CN")
        let symbol = formatter.currencySymbol ?? currency
        return symbol == currency ? "\(currency) " : symbol
    }
}

enum LedgerDateText {
    static func monthTitle(start: String) -> String {
        guard let date = parse(start) else { return start }
        return date.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN")))
    }

    static func shortDate(_ raw: String) -> String {
        guard let date = parse(raw) else { return raw }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }

    private static func parse(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }
}
