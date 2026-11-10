import Foundation

enum LedgerDestination: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case overview
    case assets
    case incomeExpense
    case investments
    case currencies
    case query
    case agent
    case imports
    case transactions
    case accounts
    case settings
    case search

    static let compactTabLimit = 3
    static let defaultCompactTabs: [LedgerDestination] = [.overview, .transactions, .accounts]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "财务概览")
        case .assets: String(localized: "资产分析")
        case .incomeExpense: String(localized: "收支分析")
        case .investments: String(localized: "投资")
        case .currencies: String(localized: "货币与汇率")
        case .query: String(localized: "查询")
        case .agent: String(localized: "账本助手")
        case .imports: String(localized: "导入")
        case .transactions: String(localized: "交易账本")
        case .accounts: String(localized: "账户")
        case .settings: String(localized: "设置")
        case .search: String(localized: "搜索")
        }
    }

    var compactTitle: String {
        switch self {
        case .overview: String(localized: "概览")
        case .assets: String(localized: "资产分析")
        case .incomeExpense: String(localized: "收支")
        case .investments: String(localized: "投资")
        case .currencies: String(localized: "货币")
        case .query: String(localized: "查询")
        case .agent: String(localized: "助手")
        case .imports: String(localized: "导入")
        case .transactions: String(localized: "交易")
        case .accounts: String(localized: "账户")
        case .settings: String(localized: "更多")
        case .search: String(localized: "搜索")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "house"
        case .assets: "building.columns"
        case .incomeExpense: "chart.bar.xaxis"
        case .investments: "chart.pie"
        case .currencies: "coloncurrencysign"
        case .query: "cylinder.split.1x2"
        case .agent: "bubble.left.and.text.bubble.right"
        case .imports: "tray.and.arrow.down"
        case .transactions: "list.bullet"
        case .accounts: "book.closed"
        case .settings: "gearshape"
        case .search: "magnifyingglass"
        }
    }

    static var compactTabCandidates: [LedgerDestination] {
        allCases.filter { $0 != .settings && $0 != .search }
    }

    static func normalizedCompactTabs(_ destinations: [LedgerDestination]) -> [LedgerDestination] {
        var seen = Set<LedgerDestination>()
        let normalized = destinations
            .filter { $0 != .settings && $0 != .search && seen.insert($0).inserted }
            .prefix(compactTabLimit)
        return normalized.isEmpty ? defaultCompactTabs : Array(normalized)
    }

    /// Search has its own trailing tab on compact layouts, so it never routes through 更多.
    func isCompactOverflow(in destinations: [LedgerDestination]) -> Bool {
        self != .settings && self != .search && !destinations.contains(self)
    }

    func compactSelection(in destinations: [LedgerDestination]) -> LedgerDestination {
        isCompactOverflow(in: destinations) ? .settings : self
    }

    static func stored(_ rawValue: String) -> LedgerDestination {
        LedgerDestination(rawValue: rawValue) ?? .overview
    }
}

enum LedgerDateRangePreset: String, CaseIterable, Equatable, Sendable {
    case month
    case quarter
    case year
    case custom

    var title: String {
        switch self {
        case .month: String(localized: "本月")
        case .quarter: String(localized: "本季度")
        case .year: String(localized: "本年")
        case .custom: String(localized: "自定义")
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

    static func quarter(year: Int, quarter: Int) -> LedgerDateRange {
        let q = max(1, min(4, quarter))
        let quarterStartMonth = (q - 1) * 3 + 1
        let start = calendar.date(from: DateComponents(year: year, month: quarterStartMonth, day: 1)) ?? Date()
        return period(starting: start, adding: .month, value: 3, preset: .quarter)
    }

    static func year(year: Int) -> LedgerDateRange {
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date()
        return period(starting: start, adding: .year, value: 1, preset: .year)
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
            return LedgerDateLabel.yearMonth(startDate)
        case .quarter:
            return String(localized: "\(year, format: .number.grouping(.never))年第\(((month - 1) / 3) + 1)季度")
        case .year:
            // A bare interpolated Int would be formatted with the locale's
            // grouping separator ("2,026年"), so the year opts out of it.
            return String(localized: "\(year, format: .number.grouping(.never))年")
        case .custom:
            return String(localized: "\(start) 至 \(end)")
        }
    }

    /// Keep the period visible in narrow navigation bars, including cross-year context.
    func toolbarTitle(relativeTo now: Date = Date()) -> String {
        let components = Self.calendar.dateComponents([.year, .month], from: startDate)
        let year = components.year ?? 0
        let month = components.month ?? 1
        let yearPrefix = year == Self.calendar.component(.year, from: now) ? "" : "\(year)/"
        switch preset {
        case .month: return yearPrefix + LedgerDateLabel.month(number: month)
        case .quarter: return "\(yearPrefix)Q\(((month - 1) / 3) + 1)"
        case .year: return String(localized: "\(year, format: .number.grouping(.never))年")
        case .custom:
            if start == end {
                return "\(yearPrefix)\(month)/\(Self.calendar.component(.day, from: startDate))"
            }
            return String(localized: "自定义")
        }
    }

    var metricScope: String {
        switch preset {
        case .month: String(localized: "月度")
        case .quarter: String(localized: "季度")
        case .year: String(localized: "年度")
        case .custom: String(localized: "范围")
        }
    }

    var startDate: Date { Self.parse(start) ?? Date() }
    var endDate: Date { Self.parse(end) ?? startDate }

    var queryEndExclusive: String {
        guard let endDate = Self.parse(end),
              let nextDay = Self.calendar.date(byAdding: .day, value: 1, to: endDate) else {
            return end
        }
        return Self.format(nextDay)
    }

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

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func parse(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }
}

struct HealthStatus: Decodable, Equatable {
    static let accountPeriodBalancesCapability = "account-period-balances-v1"

    let apiVersion: Int
    let capabilities: [String]

    var supportsAccountPeriodBalances: Bool {
        capabilities.contains(Self.accountPeriodBalancesCapability)
    }

    func validateForMobileClient() throws {
        guard apiVersion == 1 else {
            throw LedgerAPIError.incompatibleServer(String(localized: "服务器 API 版本不兼容（需要版本 1）"))
        }
        let available = Set(capabilities)
        guard available.contains("cookie-auth"), available.contains("full-backend") else {
            throw LedgerAPIError.incompatibleServer(String(localized: "服务器缺少 iOS 客户端所需的登录或账本能力"))
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
    let expiresAt: String?

    init(deviceID: String, token: String, expiresAt: String? = nil) {
        self.deviceID = deviceID
        self.token = token
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case token
        case expiresAt
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
    let token: String?

    init(deviceID: String, token: String? = nil) {
        self.deviceID = deviceID
        self.token = token
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case token
    }
}

struct APIErrorPayload: Decodable {
    let error: String?
}

struct LocalBootstrapPage: Decodable, Sendable {
    let bootstrap: LedgerBootstrap
    let transactionPage: LedgerTransactionPage
}

struct LedgerBootstrap: Decodable, Sendable {
    let start: String
    let end: String
    let summary: LedgerSummary
    let comparisons: LedgerPeriodComparisons?
    let accountBalances: [AccountBalance]
    let netWorthHistory: [LedgerNetWorthPoint]
    /// Chart-sized series across the whole ledger, independent of `start`/`end`.
    /// Empty from servers that predate it; readers fall back to
    /// `netWorthHistory`, which only covers the requested range.
    let netWorthTrend: [LedgerNetWorthPoint]
    let monthEndNetWorth: [LedgerNetWorthPoint]
    let netWorthWindows: LedgerNetWorthWindows?
    let transactions: [LedgerTransaction]
    let reconciliationRows: [LedgerReconciliationRow]
    let accounts: [LedgerAccount]
    let commodities: [String]
    let prices: [LedgerPrice]
    let valuationCurrency: String
    let accountStatuses: [LedgerAccountStatus]
    let sensitiveUnlocked: Bool

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case summary
        case comparisons
        case accountBalances
        case netWorthHistory
        case netWorthTrend
        case monthEndNetWorth
        case netWorthWindows
        case transactions
        case reconciliationRows
        case accounts
        case commodities
        case prices
        case valuationCurrency
        case accountStatuses
        case sensitiveUnlocked
    }

    init(
        start: String,
        end: String,
        summary: LedgerSummary,
        comparisons: LedgerPeriodComparisons? = nil,
        accountBalances: [AccountBalance],
        netWorthHistory: [LedgerNetWorthPoint] = [],
        netWorthTrend: [LedgerNetWorthPoint] = [],
        monthEndNetWorth: [LedgerNetWorthPoint] = [],
        netWorthWindows: LedgerNetWorthWindows? = nil,
        transactions: [LedgerTransaction],
        reconciliationRows: [LedgerReconciliationRow] = [],
        accounts: [LedgerAccount],
        commodities: [String] = [],
        prices: [LedgerPrice] = [],
        valuationCurrency: String,
        accountStatuses: [LedgerAccountStatus] = [],
        sensitiveUnlocked: Bool
    ) {
        self.start = start
        self.end = end
        self.summary = summary
        self.comparisons = comparisons
        self.accountBalances = accountBalances
        self.netWorthHistory = netWorthHistory
        self.netWorthTrend = netWorthTrend
        self.monthEndNetWorth = monthEndNetWorth
        self.netWorthWindows = netWorthWindows
        self.transactions = transactions
        self.reconciliationRows = reconciliationRows
        self.accounts = accounts
        self.commodities = commodities
        self.prices = prices
        self.valuationCurrency = valuationCurrency
        self.accountStatuses = accountStatuses
        self.sensitiveUnlocked = sensitiveUnlocked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(String.self, forKey: .start)
        end = try container.decode(String.self, forKey: .end)
        summary = try container.decode(LedgerSummary.self, forKey: .summary)
        comparisons = try container.decodeIfPresent(LedgerPeriodComparisons.self, forKey: .comparisons)
        accountBalances = try container.decode([AccountBalance].self, forKey: .accountBalances)
        netWorthHistory = try container.decodeIfPresent([LedgerNetWorthPoint].self, forKey: .netWorthHistory) ?? []
        netWorthTrend = try container.decodeIfPresent([LedgerNetWorthPoint].self, forKey: .netWorthTrend) ?? []
        monthEndNetWorth = try container.decodeIfPresent([LedgerNetWorthPoint].self, forKey: .monthEndNetWorth) ?? []
        netWorthWindows = try container.decodeIfPresent(LedgerNetWorthWindows.self, forKey: .netWorthWindows)
        transactions = try container.decode([LedgerTransaction].self, forKey: .transactions)
        reconciliationRows = try container.decodeIfPresent([LedgerReconciliationRow].self, forKey: .reconciliationRows) ?? []
        accounts = try container.decode([LedgerAccount].self, forKey: .accounts)
        commodities = try container.decodeIfPresent([String].self, forKey: .commodities) ?? []
        prices = try container.decodeIfPresent([LedgerPrice].self, forKey: .prices) ?? []
        valuationCurrency = try container.decode(String.self, forKey: .valuationCurrency)
        accountStatuses = try container.decodeIfPresent([LedgerAccountStatus].self, forKey: .accountStatuses) ?? []
        sensitiveUnlocked = try container.decode(Bool.self, forKey: .sensitiveUnlocked)
    }
}

// MARK: - Reconciliation & Balance Assertion

struct LedgerBalanceAssertion: Codable, Equatable, Sendable {
    let date: String
    let account: String
    let amount: Int
    let currency: String
}

struct LedgerAccountStatus: Codable, Equatable, Identifiable, Sendable {
    var id: String { account }
    let account: String
    let status: String // "green" | "red" | "yellow" | "grey"
    let lastEntryDate: String?
    let lastEntryType: String?
    let assertionAmount: Int?
    let computedBalance: Int?

    var isReconciled: Bool { status == "green" }
    var hasIssue: Bool { status == "red" }
    var needsReconciliation: Bool { status == "yellow" }
}

struct LedgerReconciliationRow: Codable, Equatable, Identifiable, Sendable {
    var id: String { account }
    let account: String
    let alias: String?
    let label: String
    let currency: String
    let ledgerBalance: Int
    let status: String // "pending" | "asserted"
    let lastAssertion: LedgerBalanceAssertion?
    var statusError: Bool? = nil
    var snapshotStatus: LedgerAccountStatus? = nil

    var isAsserted: Bool { status == "asserted" }
    var hasSnapshotIssue: Bool { statusError == true }

    /// One classification per row, shared by the summary band, the filter tabs
    /// and the row tag. An account asserted in range whose later transactions
    /// turned it yellow still needs reconciling, so it is pending, not 已核平.
    func reconciliationState(status: LedgerAccountStatus?) -> LedgerReconciliationState {
        if status?.hasIssue == true { return .error }
        if status?.isReconciled == true { return .asserted }
        if status?.needsReconciliation == true { return .pending }
        return isAsserted ? .asserted : .pending
    }

    /// Book minus asserted amount for a failed assertion, against the balance
    /// the assertion was checked with (before its day), not the all-time one.
    func assertionDifference(status: LedgerAccountStatus?) -> Int? {
        guard let status, status.hasIssue, let assertion = status.assertionAmount else { return nil }
        return (status.computedBalance ?? ledgerBalance) - assertion
    }
}

enum LedgerReconciliationState: Equatable, Sendable {
    case error
    case asserted
    case pending
}

/// Complete bounded native account rows, not a page of transaction history.
struct LocalReconciliationSnapshot: Decodable, Sendable {
    let revision: String
    let sensitiveUnlocked: Bool
    let start: String
    let end: String
    let monthPrefix: String
    let rows: [LedgerReconciliationRow]
}

struct LedgerReconciliationResponse: Codable, Equatable, Sendable {
    let start: String
    let end: String
    let monthPrefix: String
    let rows: [LedgerReconciliationRow]
}

struct LedgerReconcileRequest: Codable, Equatable, Sendable {
    let account: String
    let actualAmount: String
    let balanceDate: String
    let adjustmentDate: String
}

struct LedgerReconciliationResult: Codable, Equatable, Sendable {
    let ok: Bool
    let ledgerBalance: Int
    let actual: Int
    let diff: Int
    let beanText: String?
}

/// The book balance a reconciliation write on `date` diffs against. A balance
/// assertion holds at the start of its day, so it excludes transactions dated
/// on or after `date`.
struct LedgerReconciliationBalance: Codable, Equatable, Sendable {
    let account: String
    let date: String
    let currency: String
    let ledgerBalance: Int
}

struct LedgerSummary: Decodable, Equatable {
    let currency: String
    let income: Int
    let expense: Int
    let net: Int
}

struct LedgerComparisonDateRange: Decodable, Equatable, Sendable {
    let start: String
    let end: String
}

struct LedgerPeriodComparison: Decodable, Equatable, Sendable {
    let currentRange: LedgerComparisonDateRange
    let baselineRange: LedgerComparisonDateRange
    let current: Int?
    let baseline: Int?
    let delta: Int?
    let percentage: Double?
}

struct LedgerMetricPeriodComparisons: Decodable, Equatable, Sendable {
    let monthOverMonth: LedgerPeriodComparison
    let yearOverYear: LedgerPeriodComparison
}

struct LedgerPeriodComparisons: Decodable, Equatable, Sendable {
    let income: LedgerMetricPeriodComparisons
    let expense: LedgerMetricPeriodComparisons
    let totalAssets: LedgerMetricPeriodComparisons?
}

struct LedgerHomeReport: Decodable, Equatable, Sendable {
    let start: String
    let end: String
    let currency: String
    let current: LedgerHomeReportPeriod
    let previous: LedgerHomeReportPeriod
    let dailyExpenseSeries: [LedgerDailyExpense]
    let generatedAt: String
}

struct LedgerHomeReportPeriod: Decodable, Equatable, Sendable {
    let kpis: LedgerHomeReportExpenseKPI
    let categorySeries: [LedgerCategorySeries]
}

struct LedgerHomeReportExpenseKPI: Decodable, Equatable, Sendable {
    let expense: Int
    let transactionCount: Int
}

struct LedgerDailyExpense: Decodable, Equatable, Identifiable, Sendable {
    let date: String
    let weekday: String
    let amount: Int
    let txCount: Int

    var id: String { date }
}

struct LedgerImportDocumentsResponse: Decodable, Equatable, Sendable {
    let documents: [LedgerImportDocument]
}

struct LedgerImportDocument: Decodable, Equatable, Identifiable, Sendable {
    let path: String?
    let name: String?
    let year: String?
    let ext: String?
    let provider: String?
    let dateStart: String?
    let dateEnd: String?
    let size: Int?
    let modTime: String

    init(
        path: String? = nil,
        name: String? = nil,
        year: String? = nil,
        ext: String? = nil,
        provider: String?,
        dateStart: String?,
        dateEnd: String?,
        size: Int? = nil,
        modTime: String
    ) {
        self.path = path
        self.name = name
        self.year = year
        self.ext = ext
        self.provider = provider
        self.dateStart = dateStart
        self.dateEnd = dateEnd
        self.size = size
        self.modTime = modTime
    }

    var id: String {
        path ?? [provider, dateStart, dateEnd, name, modTime]
            .compactMap { $0 }
            .joined(separator: ":")
    }
}

enum LedgerMetadataValue: Codable, Equatable, Sendable {
    case null
    case string(String)
    case number(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        }
    }

    var stringValue: String? {
        if case let .string(val) = self { return val }
        return nil
    }
}

// MARK: - Dynamic Island Notice

enum LedgerIslandNoticeType: Equatable, Sendable {
    case expense
    case income
    case transfer
    /// Several entries written by one confirmation (natural language, .bean).
    case entries(count: Int)
    case batchImport(count: Int)

    var isImport: Bool {
        if case .batchImport = self { return true }
        return false
    }

    /// The notice's single accent, drawn on the always-black island. Expense
    /// and income are the dark-mode values of `BalancedPalette.expense` and
    /// `.income`; the light values are too dark to read on black, so the island
    /// uses the dark ones in both appearances. Everything else stays white.
    var hueHex: UInt {
        switch self {
        case .expense: return 0xCF7A52
        case .income: return 0x4FBFAB
        case .transfer, .entries, .batchImport: return 0xFFFFFF
        }
    }
}

struct LedgerIslandNotice: Equatable, Identifiable, Sendable {
    let id: UUID
    let type: LedgerIslandNoticeType
    /// One line: the payee, the transfer's accounts, or the bill's name.
    let title: String
    /// A short label beside the title, shown only when the row has room.
    let subtitle: String?
    let amountText: String
    /// The compact pill's trailing text: a shortened amount or a short count.
    /// Built from numbers when the notice is made, never by re-parsing
    /// `amountText`, whose decimal separator depends on the region.
    let compactText: String
    /// The category's symbol, as the transaction list draws it. The expanded
    /// disc shows a check instead; this symbol is for the compact pill.
    let iconName: String

    init(
        id: UUID = UUID(),
        type: LedgerIslandNoticeType,
        title: String,
        subtitle: String? = nil,
        amountText: String,
        compactText: String? = nil,
        iconName: String
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.amountText = amountText
        self.compactText = compactText ?? amountText
        self.iconName = iconName
    }

    /// The symbol the compact pill's disc knocks out: the category for one
    /// entry, the tray for an import. `nil` draws the check (several entries).
    var compactSymbol: String? {
        if case .entries = type { return nil }
        return iconName
    }

    /// A count short enough for the compact pill ("128 笔", "128 txns"); the
    /// card itself spells it out with the full "%lld 笔" plural.
    static func compactCount(_ count: Int) -> String {
        String(localized: "LedgerIsland.compactCount", defaultValue: "\(count) 笔",
               comment: "Compact Dynamic Island pill beside the camera; keep the unit very short.")
    }

    /// What VoiceOver says when the notice appears; the island itself is a
    /// passthrough window that never takes focus.
    var announcement: String {
        let status = type.isImport ? String(localized: "已导入") : String(localized: "已记账")
        return [status, title, subtitle, amountText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "，")
    }

    static func from(entry: LedgerTransactionEntry, accountLabels: [String: String] = [:]) -> LedgerIslandNotice {
        let isIncome = entry.postings.contains { $0.account.hasPrefix("Income:") }
        let isTransfer = entry.postings.allSatisfy { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }

        func label(_ account: String) -> String {
            accountLabels[account] ?? (account.components(separatedBy: ":").last ?? account)
        }

        let titleText: String = {
            if !entry.payee.isEmpty { return entry.payee }
            if !entry.narration.isEmpty { return entry.narration }
            return String(localized: "日常记账")
        }()

        let mainPosting = entry.postings.first(where: {
            if isIncome { return $0.account.hasPrefix("Income:") }
            if isTransfer { return true }
            return $0.account.hasPrefix("Expenses:")
        }) ?? entry.postings.first
        let currency = mainPosting.map { $0.currency.isEmpty ? entry.currency : $0.currency } ?? entry.currency
        let magnitude = abs(mainPosting.flatMap { minorUnits($0.amount) } ?? 0)

        if isTransfer {
            let fromAccount = entry.postings.first(where: { $0.amount.hasPrefix("-") })?.account
            let toAccount = entry.postings.first(where: { !$0.amount.hasPrefix("-") })?.account
            let fromLabel = fromAccount.map(label) ?? String(localized: "转出")
            let toLabel = toAccount.map(label) ?? String(localized: "转入")
            return LedgerIslandNotice(
                type: .transfer,
                title: "\(fromLabel) → \(toLabel)",
                amountText: MoneyText.format(minorUnits: magnitude, currency: currency),
                compactText: LedgerIslandAmount.compact(minorUnits: magnitude, currency: currency),
                iconName: "arrow.left.arrow.right"
            )
        }

        let category = mainPosting?.account ?? ""
        let categoryLabel = category.isEmpty ? nil : label(category)
        let icon = LedgerCategoryIcon.name(account: category, label: categoryLabel ?? "")
        let signed = isIncome ? magnitude : -magnitude
        return LedgerIslandNotice(
            type: isIncome ? .income : .expense,
            title: titleText,
            subtitle: categoryLabel == titleText ? nil : categoryLabel,
            amountText: MoneyText.format(minorUnits: signed, currency: currency, showSign: isIncome),
            compactText: LedgerIslandAmount.compact(minorUnits: signed, currency: currency, showSign: isIncome),
            iconName: icon
        )
    }

    /// One confirmation that wrote `entries`: a single entry gets its own
    /// notice, several get a count instead of a total that could mix
    /// currencies and directions.
    static func from(entries: [LedgerTransactionEntry], accountLabels: [String: String] = [:]) -> LedgerIslandNotice {
        if entries.count == 1, let entry = entries.first {
            return from(entry: entry, accountLabels: accountLabels)
        }
        return written(count: entries.count)
    }

    /// Several entries whose contents the caller does not have (a pasted
    /// .bean file is validated as text, not parsed into entries).
    static func written(count: Int) -> LedgerIslandNotice {
        LedgerIslandNotice(
            type: .entries(count: count),
            title: String(localized: "记账完成"),
            subtitle: String(localized: "已写入账本"),
            amountText: String(localized: "\(count) 笔"),
            compactText: compactCount(count),
            iconName: "checkmark"
        )
    }

    /// `provider` is an import provider id ("alipay") or a display name; an id
    /// is shown by its short label ("支付宝账单").
    static func fromImport(count: Int, provider: String? = nil) -> LedgerIslandNotice {
        let name = LedgerImportProvider.provider(provider)?.compactLabel ?? provider.flatMap { $0.isEmpty ? nil : $0 }
        return LedgerIslandNotice(
            type: .batchImport(count: count),
            title: name.map { String(localized: "\($0)账单") } ?? String(localized: "账单"),
            subtitle: String(localized: "已导入"),
            amountText: String(localized: "\(count) 笔"),
            compactText: compactCount(count),
            iconName: "tray.and.arrow.down.fill"
        )
    }

    /// Posting amounts are Beancount decimals ("-38.00"), never localized.
    private static func minorUnits(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var scaled = value * 100, rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}

/// Where saved-entry notices go. The overlay installs `handler` when it
/// appears; until then (and in the portable package, which has no island)
/// notices are dropped, because a confirmation shown late is worse than none.
@MainActor
enum LedgerIslandNotices {
    static var handler: (@MainActor (LedgerIslandNotice) -> Void)?

    static func post(_ notice: LedgerIslandNotice) { handler?(notice) }
}

/// The SF Symbol a category account is drawn with. Shared by the transaction
/// list's category chips (`TransactionVisualCategory.resolve(account:label:)`)
/// and the island, so a saved entry shows the icon the list will show.
enum LedgerCategoryIcon {
    static func name(account: String, label: String = "") -> String {
        let displayLabel = label.isEmpty ? (account.components(separatedBy: ":").last ?? account) : label
        let lower = account.lowercased()

        if lower.hasPrefix("expenses:food") || lower.hasPrefix("expenses:dining") || lower.hasPrefix("expenses:groceries") || lower.hasPrefix("expenses:meal") { return "fork.knife" }
        if lower.hasPrefix("expenses:transport") || lower.hasPrefix("expenses:travel") || lower.hasPrefix("expenses:taxi") { return "car.fill" }
        if lower.hasPrefix("expenses:book") || lower.hasPrefix("expenses:education") || lower.hasPrefix("expenses:study") { return "book.fill" }
        if lower.hasPrefix("expenses:digital") || lower.hasPrefix("expenses:communication") || lower.hasPrefix("expenses:telecom") { return "antenna.radiowaves.left.and.right" }
        if lower.hasPrefix("expenses:shopping") || lower.hasPrefix("expenses:clothing") || lower.hasPrefix("expenses:daily") { return "bag.fill" }
        if lower.hasPrefix("expenses:entertainment") || lower.hasPrefix("expenses:game") || lower.hasPrefix("expenses:movie") { return "popcorn.fill" }
        if lower.hasPrefix("expenses:housing") || lower.hasPrefix("expenses:rent") || lower.hasPrefix("expenses:utilities") { return "house.fill" }
        if lower.hasPrefix("expenses:health") || lower.hasPrefix("expenses:medical") { return "heart.fill" }
        if lower.hasPrefix("income:salary") || lower.hasPrefix("income:wage") || lower.hasPrefix("income:bonus") { return "banknote.fill" }
        if lower.contains("fund") || lower.contains("invest") || lower.contains("stock") { return "chart.line.uptrend.xyaxis" }

        // Keyword matching on displayLabel & account
        let text = "\(displayLabel) \(account)".lowercased()
        func any(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if any(["餐饮", "美食", "早餐", "午餐", "晚餐", "外卖", "美团", "咖啡", "超市", "买菜"]) { return "fork.knife" }
        if any(["交通", "出行", "打车", "滴滴", "地铁", "公交", "加油", "停车"]) { return "car.fill" }
        if any(["购物", "数码", "淘宝", "京东", "拼多多", "服饰", "衣服", "日用"]) { return "bag.fill" }
        if any(["娱乐", "游戏", "电影", "音乐", "会员"]) { return "popcorn.fill" }
        if any(["房租", "房贷", "水电", "燃气", "物业", "家居"]) { return "house.fill" }
        if any(["医疗", "健康", "医院", "药品"]) { return "heart.fill" }
        if any(["话费", "流量", "宽带", "云服务"]) { return "antenna.radiowaves.left.and.right" }
        if any(["学习", "图书", "书籍", "课程", "培训"]) { return "book.fill" }
        if any(["工资", "薪水", "奖金", "收入"]) { return "banknote.fill" }

        return account.hasPrefix("Income:") ? "arrow.down.left" : "cart.fill"
    }
}

struct LedgerTransaction: Codable, Identifiable, Equatable, Sendable {
    let date: String
    let payee: String
    let narration: String
    let metadata: [String: LedgerMetadataValue]?
    let tags: [String]?
    let postings: [LedgerPosting]
    let editableEntry: LedgerTransactionEntry?
    /// Native pending pages carry only the exact source-entry review condition.
    /// This never grants edit authority or reconstructs an editable draft.
    let pendingReviewFlag: Bool?
    let source: TransactionSource

    private enum CodingKeys: String, CodingKey {
        case date
        case payee
        case narration
        case metadata
        case tags
        case postings
        case editableEntry = "entry"
        case pendingReviewFlag
        case source
    }

    init(
        date: String,
        payee: String,
        narration: String,
        metadata: [String: LedgerMetadataValue]? = nil,
        tags: [String]? = nil,
        postings: [LedgerPosting],
        editableEntry: LedgerTransactionEntry? = nil,
        pendingReviewFlag: Bool? = nil,
        source: TransactionSource
    ) {
        self.date = date
        self.payee = payee
        self.narration = narration
        self.metadata = metadata
        self.tags = tags
        self.postings = postings
        self.editableEntry = editableEntry
        self.pendingReviewFlag = pendingReviewFlag
        self.source = source
    }

    var id: String {
        "\(source.gitSHA ?? "local"):\(source.file):\(source.line):\(source.hash ?? "")"
    }
}

struct LedgerPosting: Codable, Equatable, Identifiable, Sendable {
    let account: String
    let amount: Int
    let currency: String?

    var id: String { "\(account):\(amount):\(currency ?? "")" }
}

struct TransactionSource: Codable, Equatable, Sendable {
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

    init(file: String, line: Int, hash: String? = nil, gitSHA: String? = nil) {
        self.file = file
        self.line = line
        self.hash = hash
        self.gitSHA = gitSHA
    }
}

struct LedgerTransactionEntryPosting: Codable, Equatable, Sendable {
    let account: String
    let flag: String?
    let amount: String
    let currency: String
    let costKind: String?
    let costAmount: String?
    let costCurrency: String?
    let costSpec: String?
    let priceKind: String?
    let priceAmount: String?
    let priceCurrency: String?

    init(
        account: String,
        flag: String? = nil,
        amount: String,
        currency: String,
        costKind: String? = nil,
        costAmount: String? = nil,
        costCurrency: String? = nil,
        costSpec: String? = nil,
        priceKind: String? = nil,
        priceAmount: String? = nil,
        priceCurrency: String? = nil
    ) {
        self.account = account
        self.flag = flag
        self.amount = amount
        self.currency = currency
        self.costKind = costKind
        self.costAmount = costAmount
        self.costCurrency = costCurrency
        self.costSpec = costSpec
        self.priceKind = priceKind
        self.priceAmount = priceAmount
        self.priceCurrency = priceCurrency
    }
}

struct LedgerTransactionEntry: Codable, Equatable, Sendable {
    let kind: String
    let date: String
    let flag: String?
    let payee: String
    let narration: String
    let metadata: [String: LedgerMetadataValue]
    let tags: [String]
    let links: [String]
    let postings: [LedgerTransactionEntryPosting]
    let currency: String
    let confidence: Double
    let needsReview: Bool
    let questions: [String]

    private enum CodingKeys: String, CodingKey {
        case kind
        case date
        case flag
        case payee
        case narration
        case metadata
        case tags
        case links
        case postings
        case currency
        case confidence
        case needsReview
        case questions
    }

    init(
        date: String,
        flag: String? = nil,
        payee: String = "",
        narration: String,
        metadata: [String: LedgerMetadataValue] = [:],
        tags: [String] = [],
        links: [String] = [],
        postings: [LedgerTransactionEntryPosting]
    ) {
        kind = "transaction"
        self.date = date
        self.flag = flag
        self.payee = payee
        self.narration = narration
        self.metadata = metadata
        self.tags = tags
        self.links = links
        self.postings = postings
        currency = postings.first?.currency ?? "CNY"
        confidence = 1
        needsReview = false
        questions = []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "transaction"
        date = try container.decode(String.self, forKey: .date)
        flag = try container.decodeIfPresent(String.self, forKey: .flag)
        // A narration-only transaction has no payee key.
        payee = try container.decodeIfPresent(String.self, forKey: .payee) ?? ""
        narration = try container.decodeIfPresent(String.self, forKey: .narration) ?? ""
        metadata = try container.decodeIfPresent([String: LedgerMetadataValue].self, forKey: .metadata) ?? [:]
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        links = try container.decodeIfPresent([String].self, forKey: .links) ?? []
        postings = try container.decode([LedgerTransactionEntryPosting].self, forKey: .postings)
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? postings.first?.currency ?? "CNY"
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        needsReview = try container.decodeIfPresent(Bool.self, forKey: .needsReview) ?? false
        questions = try container.decodeIfPresent([String].self, forKey: .questions) ?? []
    }
}

struct LedgerTransactionUpdateRequest: Encodable, Equatable, Sendable {
    let source: TransactionSource
    let entry: LedgerTransactionEntry
}

struct LedgerTransactionDeleteRequest: Encodable, Equatable, Sendable {
    let source: TransactionSource
    let reason: String
}

struct LedgerTransactionTagsRequest: Encodable, Equatable, Sendable {
    let sources: [TransactionSource]
    let tags: [String]
}

enum LedgerTagValidationError: LocalizedError, Equatable {
    case empty
    case tooMany
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .empty: String(localized: "请输入至少一个标签")
        case .tooMany: String(localized: "标签总数最多 50 个")
        case let .invalid(tag): String(localized: "标签 #\(tag) 格式无效，仅支持字母、数字、下划线和连字符")
        }
    }
}

enum LedgerTagRules {
    static let maximumCount = 50
    static let maximumLength = 64

    static func normalized(_ rawValues: [String]) -> [String] {
        Array(Set(rawValues.compactMap { raw in
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while value.first == "#" {
                value.removeFirst()
            }
            return value.isEmpty ? nil : value
        }))
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func parse(_ raw: String) throws -> [String] {
        let values = normalized(raw.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，"))))
        guard !values.isEmpty else { throw LedgerTagValidationError.empty }
        guard values.count <= maximumCount else { throw LedgerTagValidationError.tooMany }
        for value in values where !isValid(value) {
            throw LedgerTagValidationError.invalid(value)
        }
        return values
    }

    static func validating(_ values: [String]) throws -> [String] {
        let normalizedValues = normalized(values)
        guard normalizedValues.count <= maximumCount else { throw LedgerTagValidationError.tooMany }
        for value in normalizedValues where !isValid(value) {
            throw LedgerTagValidationError.invalid(value)
        }
        return normalizedValues
    }

    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        return value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}

enum TransactionTagSelectionRules {
    static let maximumCount = 200

    /// Equal counts do not imply equal user intent after asynchronous hydration.
    static func canPresentPreparedBatch(captured: Set<String>, current: Set<String>, isSelecting: Bool) -> Bool {
        isSelecting && !captured.isEmpty && captured == current
    }

    static func adding(_ candidateIDs: [String], to current: Set<String>) -> Set<String> {
        var updated = current
        for id in candidateIDs where updated.count < maximumCount {
            updated.insert(id)
        }
        return updated
    }
}

struct AccountBalance: Decodable, Equatable, Sendable {
    let account: String
    let currency: String
    let amount: Int
    let valuationCurrency: String
    let valuation: Int
    let valuationMissing: Bool?
    var openingAmount: Int? = nil
    var closingAmount: Int? = nil
    var periodChange: Int? = nil
    var openingValuation: Int? = nil
    var closingValuation: Int? = nil
    var periodValuationChange: Int? = nil
    var periodValuationMissing: Bool? = nil
    var periodAvailable: Bool? = nil
}

struct LedgerAccount: Decodable, Equatable, Sendable {
    let account: String
    let openDate: String
    let closeDate: String?
    let currency: String
    let alias: String?
    let label: String
    let group: String
    let active: Bool
}

/// A partial ascending history window plus complete account balances/count.
/// Never use detail.rows alone to build a whole-period balance chart.
enum LedgerAccountPageOrder: String, Sendable { case asc, desc }

struct LedgerAccountPage: Decodable, Sendable {
    let revision: String
    let sensitiveUnlocked: Bool
    let detail: LedgerAccountDetail
    let rowCount: Int
    let nextCursor: String?
}

struct LedgerAccountDetail: Decodable, Equatable, Sendable {
    let account: String
    let label: String
    let alias: String?
    let group: String
    let active: Bool
    let currency: String
    let currentBalance: Int
    let rows: [LedgerAccountDetailRow]
    var start: String? = nil
    var end: String? = nil
    var openingBalance: Int? = nil
    var closingBalance: Int? = nil
    var periodChange: Int? = nil
}

struct LedgerAccountDetailRow: Decodable, Equatable, Identifiable, Sendable {
    let date: String
    let payee: String
    let narration: String
    let change: Int
    let balance: Int
    let transaction: LedgerTransaction

    var id: String { transaction.id }

    private enum CodingKeys: String, CodingKey {
        case date
        case payee
        case narration
        case change
        case balance
        case transaction = "txn"
    }
}

struct LedgerAccountBalanceTrendPoint: Equatable, Identifiable, Sendable {
    let date: String
    let balance: Int

    var id: String { "\(date):\(balance)" }
}

extension LedgerAccountDetail {
    func hasPeriodBalances(start: String, end: String) -> Bool {
        self.start == start && self.end == end && openingBalance != nil && closingBalance != nil && periodChange != nil
    }

    func filteredForLegacyServer(start: String, endExclusive: String) -> LedgerAccountDetail {
        let orderedRows = rows.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.date == rhs.element.date {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.date < rhs.element.date
            }
            .map { $0.element }
        let periodRows = orderedRows.filter { $0.date >= start && $0.date < endExclusive }
        let opening = orderedRows.last(where: { $0.date < start })?.balance
            ?? periodRows.first.map { $0.balance - $0.change }
            ?? (orderedRows.isEmpty ? currentBalance : 0)
        let closing = periodRows.last?.balance ?? opening

        return LedgerAccountDetail(
            account: account,
            label: label,
            alias: alias,
            group: group,
            active: active,
            currency: currency,
            currentBalance: currentBalance,
            rows: periodRows,
            start: start,
            end: endExclusive,
            openingBalance: opening,
            closingBalance: closing,
            periodChange: closing - opening
        )
    }

    var balanceTrend: [LedgerAccountBalanceTrendPoint] {
        var closingBalanceByDate: [String: Int] = [:]
        for row in rows {
            closingBalanceByDate[row.date] = row.balance
        }
        return closingBalanceByDate
            .map { LedgerAccountBalanceTrendPoint(date: $0.key, balance: $0.value) }
            .sorted { $0.date < $1.date }
    }

    func balanceTrend(maxPoints: Int) -> [LedgerAccountBalanceTrendPoint] {
        Self.downsampledBalanceTrend(balanceTrend, maxPoints: maxPoints)
    }

    func balanceTrend(in range: LedgerDateRange, maxPoints: Int) -> [LedgerAccountBalanceTrendPoint] {
        let opening = openingBalance ?? rows.first.map { $0.balance - $0.change } ?? currentBalance
        let closing = closingBalance ?? rows.last?.balance ?? opening
        var points = [LedgerAccountBalanceTrendPoint(date: range.start, balance: opening)]
        points.append(contentsOf: balanceTrend)
        let closingPoint = LedgerAccountBalanceTrendPoint(date: range.end, balance: closing)
        if points.last != closingPoint {
            points.append(closingPoint)
        }
        return Self.downsampledBalanceTrend(points, maxPoints: maxPoints)
    }

    static func downsampledBalanceTrend(
        _ points: [LedgerAccountBalanceTrendPoint],
        maxPoints: Int
    ) -> [LedgerAccountBalanceTrendPoint] {
        guard points.count > maxPoints else { return points }
        guard maxPoints >= 2, let first = points.first, let last = points.last else {
            return Array(points.prefix(max(0, maxPoints)))
        }
        if maxPoints == 2 { return [first, last] }
        if maxPoints == 3 { return [first, points[points.count / 2], last] }

        let interior = Array(points.dropFirst().dropLast())
        let bucketCount = max(1, (maxPoints - 2) / 2)
        let bucketSize = Int(ceil(Double(interior.count) / Double(bucketCount)))
        var sampled = [first]

        for lowerBound in stride(from: 0, to: interior.count, by: bucketSize) {
            let upperBound = min(lowerBound + bucketSize, interior.count)
            let bucket = interior[lowerBound..<upperBound]
            guard let minimum = bucket.min(by: { $0.balance < $1.balance }),
                  let maximum = bucket.max(by: { $0.balance < $1.balance }) else { continue }
            sampled.append(minimum)
            if maximum.id != minimum.id {
                sampled.append(maximum)
            }
        }

        sampled.append(last)
        return sampled.sorted { $0.date < $1.date }
    }
}

struct LedgerAssetsAnalysis: Equatable, Sendable {
    let accountBalances: [AccountBalance]
    let accounts: [LedgerAccount]
    let netWorthHistory: [LedgerNetWorthPoint]
    let monthEndNetWorth: [LedgerNetWorthPoint]
    let netWorthWindows: LedgerNetWorthWindows?
    let comparisons: LedgerPeriodComparisons?
    let valuationCurrency: String
}

/// Derived balances for the assets report.
///
/// The report reads the same grouped totals from `assets`, `debt`, `missing`,
/// `accountNames` and one `accountRow` per account during a single body
/// evaluation. Recomputing the filter and grouping on each access cost several
/// passes over every balance per render, and the per-account row lookup made it
/// quadratic. This computes everything once per `data`.
extension TerminalAssetsIndex {
    /// The 资产构成 band/table group for one balance. Account type decides
    /// first: every Liabilities:* balance is debt whatever its metadata group
    /// (the server files payables under 应收), and an Assets account whose group
    /// has no slot there (其他, or anything unexpected) counts as 其他资产
    /// instead of being dropped.
    static func compositionGroup(account: String, metadataGroup: String?) -> String {
        if account.hasPrefix("Liabilities:") { return "liability" }
        if let metadataGroup, ["wealth", "cash", "receivable"].contains(metadataGroup) { return metadataGroup }
        return "asset"
    }
}

struct TerminalAssetsIndex: Equatable {
    let balances: [AccountBalance]
    let valuations: [String: Int]
    let balancesByAccount: [String: [AccountBalance]]
    let accountNames: [String]
    let assets: Int
    /// Signed debt, `-Σ` of the Liabilities valuations. An overpaid card (a
    /// positive Liabilities balance) lowers it and can take it below zero.
    let debt: Int
    let missing: Bool

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (data: LedgerAssetsAnalysis, index: TerminalAssetsIndex)?

        func index(for data: LedgerAssetsAnalysis) -> TerminalAssetsIndex {
            lock.lock()
            if let cached = entry, cached.data == data {
                let index = cached.index
                lock.unlock()
                return index
            }
            lock.unlock()

            let index = TerminalAssetsIndex(data: data)

            lock.lock()
            entry = (data, index)
            lock.unlock()
            return index
        }
    }

    private static let cache = Cache()

    static func index(for data: LedgerAssetsAnalysis) -> TerminalAssetsIndex {
        cache.index(for: data)
    }

    private init(data: LedgerAssetsAnalysis) {
        let filtered = data.accountBalances.filter {
            $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:")
        }
        balances = filtered

        var grouped: [String: [AccountBalance]] = [:]
        var values: [String: Int] = [:]
        var assetTotal = 0
        var debtTotal = 0
        var hasMissing = false
        for balance in filtered {
            grouped[balance.account, default: []].append(balance)
            if balance.valuationMissing == true {
                hasMissing = true
            } else {
                values[balance.account, default: 0] += balance.valuation
            }
        }
        balancesByAccount = grouped
        valuations = values
        missing = hasMissing

        for (account, value) in values {
            if account.hasPrefix("Assets:") {
                assetTotal += value
            } else if account.hasPrefix("Liabilities:") {
                debtTotal -= value
            }
        }
        assets = assetTotal
        debt = debtTotal
        accountNames = grouped.keys.sorted()
    }
}

struct LedgerIncomeExpenseAnalysis: Equatable, Sendable {
    let dashboard: LedgerDashboard
    let statement: LedgerIncomeStatement
}

enum LedgerAnalysisResourceKind: Equatable, Sendable {
    case assets
    case incomeExpense
    case investments
}

enum LedgerAnalysisResource: Equatable, Sendable {
    case assets(LedgerAssetsAnalysis)
    case incomeExpense(LedgerIncomeExpenseAnalysis)
    case investments(LedgerInvestmentSummary)
}

struct LedgerChartAxisPoint: Equatable, Sendable {
    let label: String
    let shortLabel: String
    let position: Double
}

struct LedgerChartAxis: Equatable, Sendable {
    let points: [LedgerChartAxisPoint]
    let usesTimeScale: Bool

    init(labels: [String], referenceLabel: String? = nil) {
        let reference = referenceLabel.flatMap { Self.explicitDate(from: $0) }
        var inferredYear = reference.map { Self.calendar.component(.year, from: $0) }
        var previousMonthDay: Int?
        var parsed: [(date: Date, shortLabel: String)] = []

        for label in labels {
            guard var value = Self.parsedLabel(label, inferredYear: inferredYear) else {
                points = labels.enumerated().map {
                    LedgerChartAxisPoint(label: $0.element, shortLabel: $0.element, position: Double($0.offset))
                }
                usesTimeScale = false
                return
            }

            if !value.hasExplicitYear,
               let previousMonthDay,
               value.monthDay < previousMonthDay,
               let year = inferredYear,
               let rolled = Self.parsedLabel(label, inferredYear: year + 1) {
                inferredYear = year + 1
                value = rolled
            }
            if value.hasExplicitYear {
                inferredYear = Self.calendar.component(.year, from: value.date)
            }
            previousMonthDay = value.monthDay
            parsed.append((value.date, value.shortLabel))
        }

        points = zip(labels, parsed).map { label, value in
            LedgerChartAxisPoint(
                label: label,
                shortLabel: value.shortLabel,
                position: value.date.timeIntervalSince1970
            )
        }
        usesTimeScale = !points.isEmpty
    }

    var domain: ClosedRange<Double> {
        guard let lower = points.map(\.position).min(),
              let upper = points.map(\.position).max() else {
            return 0...1
        }
        if lower == upper {
            let padding = usesTimeScale ? 12 * 60 * 60 : 0.5
            return (lower - padding)...(upper + padding)
        }
        let padding = usesTimeScale ? max((upper - lower) * 0.05, 12 * 60 * 60) : 0.5
        return (lower - padding)...(upper + padding)
    }

    func position(at index: Int) -> Double {
        points.indices.contains(index) ? points[index].position : Double(index)
    }

    func nearestIndex(to position: Double) -> Int? {
        points.indices.min { left, right in
            abs(points[left].position - position) < abs(points[right].position - position)
        }
    }

    func shortLabel(nearestTo position: Double) -> String {
        nearestIndex(to: position).map { points[$0].shortLabel } ?? ""
    }

    func tickPositions(maxCount: Int) -> [Double] {
        guard maxCount > 0, !points.isEmpty else { return [] }
        guard points.count > maxCount, maxCount > 1 else {
            return points.prefix(maxCount).map(\.position)
        }
        let last = Double(points.count - 1)
        return (0..<maxCount).map { offset in
            let index = Int((Double(offset) * last / Double(maxCount - 1)).rounded())
            return points[index].position
        }
    }

    private struct ParsedLabel {
        let date: Date
        let shortLabel: String
        let monthDay: Int
        let hasExplicitYear: Bool
    }

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return value
    }

    private static func explicitDate(from label: String) -> Date? {
        let first = label.split(separator: "~", maxSplits: 1).first.map(String.init) ?? label
        let parts = first.split(separator: "-").map(String.init)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func parsedLabel(_ label: String, inferredYear: Int?) -> ParsedLabel? {
        let first = label.split(separator: "~", maxSplits: 1).first.map(String.init) ?? label

        if let quarterMarker = first.range(of: "-Q"),
           let year = Int(first[..<quarterMarker.lowerBound]),
           let quarter = Int(first[quarterMarker.upperBound...]),
           (1...4).contains(quarter) {
            let month = (quarter - 1) * 3 + 1
            return makeParsed(year: year, month: month, day: 1, shortLabel: "Q\(quarter)", explicitYear: true)
        }

        let parts = first.split(separator: "-").compactMap { Int($0) }
        switch parts.count {
        case 3:
            return makeParsed(
                year: parts[0],
                month: parts[1],
                day: parts[2],
                shortLabel: "\(parts[1])/\(parts[2])",
                explicitYear: true
            )
        case 2 where first.split(separator: "-").first?.count == 4:
            return makeParsed(
                year: parts[0],
                month: parts[1],
                day: 1,
                shortLabel: LedgerDateLabel.month(number: parts[1]),
                explicitYear: true
            )
        case 2:
            guard let inferredYear else { return nil }
            return makeParsed(
                year: inferredYear,
                month: parts[0],
                day: parts[1],
                shortLabel: "\(parts[0])/\(parts[1])",
                explicitYear: false
            )
        case 1:
            guard let inferredYear, (1...12).contains(parts[0]) else { return nil }
            return makeParsed(
                year: inferredYear,
                month: parts[0],
                day: 1,
                shortLabel: LedgerDateLabel.month(number: parts[0]),
                explicitYear: false
            )
        default:
            return nil
        }
    }

    private static func makeParsed(
        year: Int,
        month: Int,
        day: Int,
        shortLabel: String,
        explicitYear: Bool
    ) -> ParsedLabel? {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else {
            return nil
        }
        return ParsedLabel(
            date: date,
            shortLabel: shortLabel,
            monthDay: month * 100 + day,
            hasExplicitYear: explicitYear
        )
    }
}

struct LedgerDashboard: Decodable, Equatable, Sendable {
    let start: String
    let end: String
    let currency: String
    let kpis: LedgerDashboardKPI
    let netWorthSeries: [LedgerNetWorthPoint]
    let cashflowSeries: [LedgerCashflowPoint]
    let categorySeries: [LedgerCategorySeries]
    let topPayees: [LedgerPayeeAnalytics]
    let topPaymentAccounts: [LedgerAccountAnalytics]
    let anomalies: [LedgerDashboardAnomaly]

    init(
        start: String,
        end: String,
        currency: String,
        kpis: LedgerDashboardKPI,
        netWorthSeries: [LedgerNetWorthPoint],
        cashflowSeries: [LedgerCashflowPoint],
        categorySeries: [LedgerCategorySeries],
        topPayees: [LedgerPayeeAnalytics],
        topPaymentAccounts: [LedgerAccountAnalytics],
        anomalies: [LedgerDashboardAnomaly]
    ) {
        self.start = start
        self.end = end
        self.currency = currency
        self.kpis = kpis
        self.netWorthSeries = netWorthSeries
        self.cashflowSeries = cashflowSeries
        self.categorySeries = categorySeries
        self.topPayees = topPayees
        self.topPaymentAccounts = topPaymentAccounts
        self.anomalies = anomalies
    }
}

struct LedgerDashboardKPI: Decodable, Equatable, Sendable {
    let assets: Int
    let liabilities: Int
    let netWorth: Int
    let income: Int
    let expense: Int
    let net: Int
    let savingsRate: Double?
}

struct LedgerNetWorthPoint: Decodable, Equatable, Identifiable, Sendable {
    let date: String
    let assets: Int
    let liabilities: Int
    let netWorth: Int
    var id: String { date }
}

struct LedgerNetWorthDelta: Decodable, Equatable, Sendable {
    let baseline: LedgerNetWorthPoint?
    let change: Int?
    let changeRatio: Double?
}

struct LedgerNetWorthWindows: Decodable, Equatable, Sendable {
    let latest: LedgerNetWorthPoint?
    let previousMonthEnd: LedgerNetWorthPoint?
    let monthChange: Int?
    let sixMonth: LedgerNetWorthDelta
    let twelveMonth: LedgerNetWorthDelta
}

/// Windows offered by the accounts net-worth chart. They cut the ledger's own
/// net-worth history rather than the page's selected period, so the curve keeps
/// a shape of its own no matter which month the header is showing.
enum NetWorthTrendRange: String, CaseIterable, Identifiable {
    case oneMonth, threeMonths, sixMonths, yearToDate, oneYear, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneMonth: String(localized: "1月")
        case .threeMonths: String(localized: "3月")
        case .sixMonths: String(localized: "6月")
        case .yearToDate: String(localized: "今年")
        case .oneYear: String(localized: "1年")
        case .all: String(localized: "全部")
        }
    }

    /// Trailing window width in months. `nil` for the windows bounded by the
    /// calendar year (`今年`) or by the ledger itself (`全部`).
    private var monthsBack: Int? {
        switch self {
        case .oneMonth: 1
        case .threeMonths: 3
        case .sixMonths: 6
        case .oneYear: 12
        case .yearToDate, .all: nil
        }
    }

    /// Points a window may draw. A one-month window is read day by day; wider
    /// windows are read as a shape, so they thin the series instead of folding
    /// it into a dense ribbon.
    var pointBudget: Int {
        switch self {
        case .oneMonth: 64
        case .threeMonths: 64
        case .sixMonths: 56
        case .yearToDate: 48
        case .oneYear: 48
        case .all: 40
        }
    }

    /// Filters a date-sorted series relative to the *last* point's date, not
    /// today, so a ledger that stops last month still draws a full window.
    /// Always returns at least two points (when available) so a line can be drawn.
    func filter(_ points: [LedgerNetWorthPoint]) -> [LedgerNetWorthPoint] {
        guard self != .all, let last = points.last else { return points }
        let cutoff: String
        if self == .yearToDate {
            cutoff = String(last.date.prefix(4)) + "-01-01"
        } else {
            guard let lastDate = LedgerDateRange.parse(last.date) else { return points }
            let start = LedgerDateRange.calendar.date(byAdding: .month, value: -(monthsBack ?? 12), to: lastDate) ?? lastDate
            cutoff = LedgerDateRange.format(start)
        }
        let filtered = points.filter { $0.date >= cutoff }
        return filtered.count >= 2 ? filtered : Array(points.suffix(2))
    }

    /// The window's points, thinned to `pointBudget` for the chart.
    func series(_ points: [LedgerNetWorthPoint]) -> [LedgerNetWorthPoint] {
        LedgerNetWorthPoint.sampled(filter(points), maxPoints: pointBudget)
    }
}

extension LedgerNetWorthPoint {
    /// Evenly thins a date-ascending series, always keeping the first and last
    /// point and never averaging: every point returned is a real ledger closing
    /// value, so the curve cannot invent a high or a low.
    static func sampled(_ points: [LedgerNetWorthPoint], maxPoints: Int) -> [LedgerNetWorthPoint] {
        guard maxPoints >= 2, points.count > maxPoints else { return points }
        let interiorCount = points.count - 2
        let slots = maxPoints - 2
        var sampled: [LedgerNetWorthPoint] = [points[0]]
        var previous = 0
        for slot in stride(from: 1, through: slots, by: 1) {
            let position = Int((Double(slot) * Double(interiorCount) / Double(slots + 1)).rounded())
            let index = min(max(1 + position, previous + 1), points.count - 2)
            guard index > previous else { continue }
            sampled.append(points[index])
            previous = index
        }
        sampled.append(points[points.count - 1])
        return sampled
    }
}

extension LedgerBootstrap {
    /// Net-worth history for the accounts chart. The whole-ledger series wins
    /// when the payload carries one; it is cut at `endExclusive` so the curve
    /// finishes on the closing figure the page shows for its period. Servers
    /// that predate the series answer with the range-scoped history, which is
    /// already cut and is used as-is.
    func netWorthTrendHistory(before endExclusive: String) -> [LedgerNetWorthPoint] {
        let sorted = (netWorthTrend.isEmpty ? netWorthHistory : netWorthTrend)
            .sorted { $0.date < $1.date }
        guard !netWorthTrend.isEmpty else { return sorted }
        let scoped = sorted.filter { $0.date < endExclusive }
        return scoped.count >= 2 ? scoped : sorted
    }
}

struct LedgerCashflowPoint: Decodable, Equatable, Identifiable, Sendable {
    let month: String
    let income: Int
    let expense: Int
    let net: Int
    var id: String { month }
}

struct LedgerSeriesPoint: Decodable, Equatable, Identifiable, Sendable {
    let month: String
    let value: Int
    var id: String { month }
}

struct LedgerCategorySeries: Decodable, Equatable, Identifiable, Sendable {
    let account: String
    let alias: String?
    let label: String
    let total: Int
    let values: [LedgerSeriesPoint]
    var id: String { account }
}

struct LedgerPayeeAnalytics: Decodable, Equatable, Identifiable, Sendable {
    let payee: String
    let amount: Int
    let txCount: Int
    var id: String { payee }
}

struct LedgerAccountAnalytics: Decodable, Equatable, Identifiable, Sendable {
    let account: String
    let alias: String?
    let label: String
    let amount: Int
    let txCount: Int
    var id: String { account }
}

struct LedgerDashboardAnomaly: Decodable, Equatable, Identifiable, Sendable {
    let date: String
    let payee: String
    let narration: String
    let account: String
    let amount: Int
    let source: String
    var id: String { "\(date):\(source):\(account)" }
}

struct LedgerIncomeStatement: Decodable, Equatable, Sendable {
    let start: String
    let end: String
    let income: [LedgerIncomeNode]
    let expense: [LedgerIncomeNode]
    let totalIncome: Int
    let totalExpense: Int
    let expenseAnalytics: [LedgerExpenseCategoryAnalytics]
    let topPayees: [LedgerPayeeAnalytics]
    let topPaymentAccounts: [LedgerAccountAnalytics]
    let netIncome: Int
    let valuationCurrency: String

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case income
        case expense
        case totalIncome
        case totalExpense
        case expenseAnalytics
        case topPayees
        case topPaymentAccounts
        case netIncome
        case valuationCurrency
    }

    init(
        start: String,
        end: String,
        income: [LedgerIncomeNode],
        expense: [LedgerIncomeNode],
        totalIncome: Int,
        totalExpense: Int,
        expenseAnalytics: [LedgerExpenseCategoryAnalytics] = [],
        topPayees: [LedgerPayeeAnalytics] = [],
        topPaymentAccounts: [LedgerAccountAnalytics] = [],
        netIncome: Int,
        valuationCurrency: String
    ) {
        self.start = start
        self.end = end
        self.income = income
        self.expense = expense
        self.totalIncome = totalIncome
        self.totalExpense = totalExpense
        self.expenseAnalytics = expenseAnalytics
        self.topPayees = topPayees
        self.topPaymentAccounts = topPaymentAccounts
        self.netIncome = netIncome
        self.valuationCurrency = valuationCurrency
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(String.self, forKey: .start)
        end = try container.decode(String.self, forKey: .end)
        income = try container.decode([LedgerIncomeNode].self, forKey: .income)
        expense = try container.decode([LedgerIncomeNode].self, forKey: .expense)
        totalIncome = try container.decode(Int.self, forKey: .totalIncome)
        totalExpense = try container.decode(Int.self, forKey: .totalExpense)
        expenseAnalytics = try container.decodeIfPresent([LedgerExpenseCategoryAnalytics].self, forKey: .expenseAnalytics) ?? []
        topPayees = try container.decodeIfPresent([LedgerPayeeAnalytics].self, forKey: .topPayees) ?? []
        topPaymentAccounts = try container.decodeIfPresent([LedgerAccountAnalytics].self, forKey: .topPaymentAccounts) ?? []
        netIncome = try container.decode(Int.self, forKey: .netIncome)
        valuationCurrency = try container.decode(String.self, forKey: .valuationCurrency)
    }
}

struct LedgerExpenseCategoryAnalytics: Decodable, Equatable, Identifiable, Sendable {
    let account: String
    let alias: String?
    let label: String
    let amount: Int
    let txCount: Int
    let share: Double?
    let previousAmount: Int
    let changeRatio: Double?
    let topPayees: [LedgerPayeeAnalytics]

    var id: String { account }
}

struct LedgerIncomeNode: Decodable, Equatable, Identifiable, Sendable {
    let account: String
    let alias: String?
    let label: String
    let amount: Int
    let children: [LedgerIncomeNode]
    let depth: Int
    let txCount: Int
    var id: String { account }
}

struct LedgerInvestmentSummary: Decodable, Equatable, Sendable {
    let totalMarketValueCny: Int
    let realizedPnlCny: Int?
    let holdings: [LedgerInvestmentHolding]
    let positions: [LedgerInvestmentPosition]
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case totalMarketValueCny
        case realizedPnlCny
        case holdings
        case positions
        case updatedAt
    }

    init(
        totalMarketValueCny: Int,
        realizedPnlCny: Int?,
        holdings: [LedgerInvestmentHolding],
        positions: [LedgerInvestmentPosition],
        updatedAt: String?
    ) {
        self.totalMarketValueCny = totalMarketValueCny
        self.realizedPnlCny = realizedPnlCny
        self.holdings = holdings
        self.positions = positions
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalMarketValueCny = try container.decode(Int.self, forKey: .totalMarketValueCny)
        realizedPnlCny = try container.decodeIfPresent(Int.self, forKey: .realizedPnlCny)
        holdings = try container.decodeIfPresent([LedgerInvestmentHolding].self, forKey: .holdings) ?? []
        positions = try container.decodeIfPresent([LedgerInvestmentPosition].self, forKey: .positions) ?? []
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

struct LedgerInvestmentHolding: Decodable, Equatable, Identifiable, Sendable {
    let commodity: String
    let commodityName: String
    let totalQuantity: Double
    let averageCost: Double?
    let totalCostValueCny: Int?
    let totalMarketValueCny: Int?
    let accountCount: Int
    let realizedPnlCny: Int?
    var id: String { commodity }
}

struct LedgerInvestmentPosition: Decodable, Equatable, Identifiable, Sendable {
    let account: String
    let accountLabel: String
    let commodity: String
    let commodityName: String
    let quantity: Double
    let costValueCny: Int?
    let marketValueCny: Int?
    let realizedPnlCny: Int?
    var id: String { "\(account):\(commodity)" }
}

enum TransactionKind: Equatable {
    case expense
    case income
    case transfer
}

enum TransactionKindFilter: String, CaseIterable, Equatable, Identifiable, Sendable {
    case all
    case expense
    case income
    case transfer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "全部")
        case .expense: String(localized: "支出")
        case .income: String(localized: "收入")
        case .transfer: String(localized: "转账")
        }
    }
}

struct LedgerTransactionFilter: Equatable, Sendable {
    var query = ""
    var kind = TransactionKindFilter.all
    var account: String?
    var tags: Set<String> = []

    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || kind != .all
            || account != nil
            || !tags.isEmpty
    }

    func matches(_ transaction: LedgerTransaction) -> Bool {
        // `TransactionPresentation` walks every posting, so only build it when a
        // kind filter is actually active. The common `.all` case used to pay for
        // it and throw it away, on every pass over the list.
        if kind != .all {
            let presentation = TransactionPresentation(transaction: transaction)
            switch kind {
            case .all:
                break
            case .expense where presentation.kind != .expense:
                return false
            case .income where presentation.kind != .income:
                return false
            case .transfer where presentation.kind != .transfer:
                return false
            default:
                break
            }
        }

        if let account, !transaction.postings.contains(where: { $0.account == account || $0.account.hasPrefix(account + ":") }) {
            return false
        }

        if !tags.isEmpty {
            let transactionTags = Set(transaction.tags ?? [])
            guard !transactionTags.isDisjoint(with: tags) else { return false }
        }

        let words = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
        guard !words.isEmpty else { return true }

        let searchable = ([
            transaction.date,
            transaction.payee,
            transaction.narration,
        ] + transaction.postings.map(\.account) + (transaction.tags ?? []).map { "#\($0)" })
            .joined(separator: " ")
            .lowercased()
        return words.allSatisfy(searchable.contains)
    }
}

/// Display-only context derived from postings; it never changes amounts or write payloads.
/// Everything `TransactionCategoryPresentation` needs from a transaction, without
/// the transaction. Full-range scans group by this key so category totals can be
/// labelled later with the current account labels instead of retaining rows.
enum TransactionCategoryKey: Hashable, Sendable {
    case multiple
    case category(String)
    /// nil on either side means several accounts ("多个账户").
    case transfer(from: String?, to: String?)
    case equity
    case uncategorized

    init(transaction: LedgerTransaction) {
        let postings = transaction.postings.filter { $0.amount != 0 }
        let categories = Set(postings.filter {
            $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:")
        }.map(\.account))
        if categories.count > 1 {
            self = .multiple
        } else if let account = categories.first {
            self = .category(account)
        } else {
            let funding = postings.filter {
                $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:")
            }
            let outgoing = Set(funding.filter { $0.amount < 0 }.map(\.account))
            let incoming = Set(funding.filter { $0.amount > 0 }.map(\.account))
            if !outgoing.isEmpty, !incoming.isEmpty {
                self = .transfer(from: outgoing.count == 1 ? outgoing.first : nil,
                                 to: incoming.count == 1 ? incoming.first : nil)
            } else if postings.contains(where: { $0.account.hasPrefix("Equity:") }) {
                self = .equity
            } else {
                self = .uncategorized
            }
        }
    }

    /// Retained UTF-8 payload, for callers that account bounded state.
    var accounts: [String] {
        switch self {
        case .category(let account): [account]
        case .transfer(let from, let to): [from, to].compactMap { $0 }
        case .multiple, .equity, .uncategorized: []
        }
    }
}

struct TransactionCategoryPresentation: Equatable {
    let label: String

    init(transaction: LedgerTransaction, accountLabels: [String: String] = [:]) {
        self.init(key: TransactionCategoryKey(transaction: transaction), accountLabels: accountLabels)
    }

    init(key: TransactionCategoryKey, accountLabels: [String: String] = [:]) {
        func displayName(_ account: String) -> String {
            let label = accountLabels[account]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !label.isEmpty, label != account { return label }
            let path = account.split(separator: ":").dropFirst().joined(separator: " › ")
            return path.isEmpty ? account : path
        }

        switch key {
        case .multiple:
            label = String(localized: "多分类")
        case .category(let account):
            label = displayName(account)
        case .transfer(let from, let to):
            label = String(localized: "\(from.map(displayName) ?? String(localized: "多个账户")) → \(to.map(displayName) ?? String(localized: "多个账户"))")
        case .equity:
            label = String(localized: "权益调整")
        case .uncategorized:
            label = String(localized: "未分类")
        }
    }

    /// Cached because callers invoke this from view bodies — several of them
    /// inside `ForEach` closures — and a ledger can carry hundreds of accounts.
    /// Keyed by the exact `accounts` array so any content change misses.
    private static let accountLabelsCache = AccountLabelCache()

    private final class AccountLabelCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (signature: Int, labels: [String: String])?
        /// Last version handed out to callers, keyed by the exact map.
        private var versionEntry: (labels: [String: String], version: Int)?

        /// Cheap identity for an `[LedgerAccount]`. Comparing the arrays themselves
        /// is a full element-by-element `Equatable` walk of every account, which ran
        /// once per call site per body evaluation — hundreds of times per scroll
        /// pass. Hashing the fields that affect a label is O(n) over small values
        /// and gives a single `Int` to compare.
        private static func signature(_ accounts: [LedgerAccount]) -> Int {
            var hasher = Hasher()
            hasher.combine(accounts.count)
            for account in accounts {
                hasher.combine(account.account)
                hasher.combine(account.label)
                hasher.combine(account.alias)
            }
            return hasher.finalize()
        }

        /// Version for a label map. The full hash is computed once, when the map is
        /// built, and remembered; a caller holding that map gets it back in O(1).
        /// A map this cache did not build (a test fixture, say) falls back to
        /// hashing it, which is correct and only happens off the scroll path.
        func version(for labels: [String: String]) -> Int {
            lock.lock()
            defer { lock.unlock() }
            if let cached = versionEntry, cached.labels == labels { return cached.version }
            let version = Self.signature(labels)
            versionEntry = (labels, version)
            return version
        }

        private static func signature(_ labels: [String: String]) -> Int {
            var hasher = Hasher()
            hasher.combine(labels.count)
            for (key, value) in labels {
                hasher.combine(key)
                hasher.combine(value)
            }
            return hasher.finalize()
        }

        func labels(for accounts: [LedgerAccount]) -> [String: String] {
            let signature = Self.signature(accounts)
            lock.lock()
            if let cached = entry, cached.signature == signature {
                let labels = cached.labels
                lock.unlock()
                return labels
            }
            lock.unlock()

            let labels = accounts.reduce(into: [String: String]()) { result, account in
                let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
                result[account.account] = label.isEmpty || label == account.account
                    ? (account.alias ?? account.account) : label
            }

            lock.lock()
            entry = (signature, labels)
            // Seed the version so the first per-row lookup is a hit, not a re-hash.
            versionEntry = (labels, Self.signature(labels))
            lock.unlock()
            return labels
        }
    }

    /// Identity for a label map, used to key per-row presentation caches. Default
    /// dictionaries are copied on write, so the map a view holds is one of the few
    /// instances `AccountLabelCache` produced; remembering its version keeps the
    /// per-row lookup O(1) instead of walking the dictionary for every visible row.
    static func labelsVersion(_ labels: [String: String]) -> Int {
        accountLabelsCache.version(for: labels)
    }

    static func accountLabels(_ accounts: [LedgerAccount]) -> [String: String] {
        accountLabelsCache.labels(for: accounts)
    }
}

struct TransactionPresentation: Equatable {
    let kind: TransactionKind
    let title: String
    let subtitle: String
    let minorUnits: Int
    let currency: String
    let isRefund: Bool

    init(transaction: LedgerTransaction) {
        title = transaction.payee.isEmpty
            ? (transaction.narration.isEmpty ? String(localized: "未命名交易") : transaction.narration)
            : transaction.payee

        if !transaction.payee.isEmpty, !transaction.narration.isEmpty {
            subtitle = transaction.narration
        } else {
            subtitle = transaction.postings.first?.account ?? ""
        }

        // Two small passes instead of two allocating filters. The order matters:
        // expense is summed and acted on before income is touched, exactly like the
        // original `filter` + `reduce` version. Summing both up front would evaluate
        // an income total that a real ledger never needs, and `Int.max + 1` traps
        // even when the expense branch returns first.
        var expenseTotal = 0
        var expenseCurrency: String?
        var hasExpense = false
        for posting in transaction.postings where posting.amount != 0 && posting.account.hasPrefix("Expenses:") {
            if !hasExpense { hasExpense = true; expenseCurrency = posting.currency }
            expenseTotal += posting.amount
        }
        if hasExpense {
            if expenseTotal < 0 {
                kind = .income
                minorUnits = abs(expenseTotal)
                currency = expenseCurrency ?? "CNY"
                isRefund = true
                return
            } else if expenseTotal > 0 {
                kind = .expense
                minorUnits = expenseTotal
                currency = expenseCurrency ?? "CNY"
                isRefund = false
                return
            }
        }

        var incomeTotal = 0
        var incomeCurrency: String?
        var hasIncome = false
        for posting in transaction.postings where posting.amount != 0 && posting.account.hasPrefix("Income:") {
            if !hasIncome { hasIncome = true; incomeCurrency = posting.currency }
            incomeTotal += posting.amount
        }
        if hasIncome {
            if incomeTotal > 0 {
                kind = .expense
                minorUnits = incomeTotal
                currency = incomeCurrency ?? "CNY"
                isRefund = false
                return
            } else if incomeTotal < 0 {
                kind = .income
                minorUnits = abs(incomeTotal)
                currency = incomeCurrency ?? "CNY"
                let metadataType = transaction.metadata?["type"]?.stringValue ?? ""
                isRefund = transaction.narration.contains("退款")
                    || transaction.payee.contains("退款")
                    || metadataType.contains("退款")
                return
            }
        }

        let posting = transaction.postings.max { abs($0.amount) < abs($1.amount) }
        kind = .transfer
        minorUnits = abs(posting?.amount ?? 0)
        currency = posting?.currency ?? "CNY"
        isRefund = false
    }
}

struct BalanceSheetTotals: Equatable {
    let assets: Int
    let liabilities: Int
    let netWorth: Int
}

extension BalanceSheetTotals {
    /// Liabilities keep their Beancount sign: a card balance is normally
    /// negative, so debt is `-Σ` of the Liabilities valuations. An overpaid
    /// card (a positive balance) reduces debt instead of adding to it, and
    /// `netWorth` stays `assets - liabilities`.
    init(assets: Int, liabilityBalance: Int) {
        self.init(assets: assets, liabilities: -liabilityBalance, netWorth: assets + liabilityBalance)
    }

    /// Totals over account rows, classified by account prefix like
    /// `LedgerBootstrap.balanceSheetTotals` rather than by display group, so a
    /// `Liabilities:Payable` row in the 应收 group still counts as a liability
    /// and an Assets row in the 其他 group is still an asset. Uses the period
    /// closing valuation where the row has one.
    init(closingRows rows: [AccountBalanceRow]) {
        var assets = 0
        var liabilityBalance = 0
        for row in rows {
            let value = row.periodBalancesAvailable ? row.closingValuation : row.valuation
            if row.account.hasPrefix("Assets:") {
                assets += value
            } else if row.account.hasPrefix("Liabilities:") {
                liabilityBalance += value
            }
        }
        self.init(assets: assets, liabilityBalance: liabilityBalance)
    }
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
    let periodBalancesAvailable: Bool
    let openingNativeAmount: Int
    let closingNativeAmount: Int
    let periodNativeChange: Int
    let openingValuation: Int
    let closingValuation: Int
    let periodValuationChange: Int
    let periodValuationMissing: Bool

    var id: String { "\(account):\(nativeCurrency)" }
}

struct AccountBalanceSection: Identifiable, Equatable {
    let id: String
    let title: String
    let rows: [AccountBalanceRow]
}

enum AccountBalanceCategory: String, CaseIterable, Equatable, Identifiable {
    case all
    case assets
    case liabilities

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "全部")
        case .assets: String(localized: "资产")
        case .liabilities: String(localized: "负债")
        }
    }

    func includes(_ row: AccountBalanceRow) -> Bool {
        switch self {
        case .all:
            true
        case .assets:
            row.account.hasPrefix("Assets:")
        case .liabilities:
            row.account.hasPrefix("Liabilities:")
        }
    }
}

extension LedgerBootstrap {
    var periodAccountBalancesAvailable: Bool {
        !accountBalances.isEmpty && accountBalances.allSatisfy { $0.periodAvailable == true }
    }

    var balanceSheetTotals: BalanceSheetTotals {
        let valid = accountBalances.filter { !($0.valuationMissing ?? false) }
        let assets = valid
            .filter { $0.account.hasPrefix("Assets:") }
            .reduce(0) { $0 + $1.valuation }
        let liabilityBalance = valid
            .filter { $0.account.hasPrefix("Liabilities:") }
            .reduce(0) { $0 + $1.valuation }
        return BalanceSheetTotals(assets: assets, liabilityBalance: liabilityBalance)
    }

    var accountSections: [AccountBalanceSection] {
        accountSections(periodBalancesAvailable: periodAccountBalancesAvailable)
    }

    func accountSections(periodBalancesAvailable: Bool) -> [AccountBalanceSection] {
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
                valuationMissing: balance.valuationMissing ?? false,
                periodBalancesAvailable: periodBalancesAvailable,
                openingNativeAmount: periodBalancesAvailable ? (balance.openingAmount ?? balance.amount) : balance.amount,
                closingNativeAmount: periodBalancesAvailable ? (balance.closingAmount ?? balance.amount) : balance.amount,
                periodNativeChange: periodBalancesAvailable ? (balance.periodChange ?? 0) : 0,
                openingValuation: periodBalancesAvailable ? (balance.openingValuation ?? balance.valuation) : balance.valuation,
                closingValuation: periodBalancesAvailable ? (balance.closingValuation ?? balance.valuation) : balance.valuation,
                periodValuationChange: periodBalancesAvailable ? (balance.periodValuationChange ?? 0) : 0,
                periodValuationMissing: periodBalancesAvailable
                    ? (balance.periodValuationMissing ?? (balance.valuationMissing ?? false))
                    : (balance.valuationMissing ?? false)
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
        case "cash": return String(localized: "现金与支付")
        case "credit": return String(localized: "信用账户")
        case "liability": return String(localized: "负债")
        case "wealth": return String(localized: "储蓄与资产")
        case "receivable": return String(localized: "应收")
        case "asset": return String(localized: "资产")
        case "expense": return String(localized: "支出账户")
        case "income": return String(localized: "收入账户")
        case "equity": return String(localized: "权益")
        default: return String(localized: "其他")
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

enum LedgerDateText {
    static func monthTitle(start: String) -> String {
        guard let date = parse(start) else { return start }
        return date.formatted(.dateTime.year().month(.wide).locale(LedgerLocale.current))
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

// MARK: - Pending Transactions (待整理收件箱)

enum PendingTransactionReason: Hashable, Identifiable, Sendable {
    case uncategorized(account: String)
    case needsReviewFlag
    case pendingTag(String)
    case missingPayee

    var id: String {
        switch self {
        case .uncategorized(let acc): return "uncategorized:\(acc)"
        case .needsReviewFlag: return "needsReviewFlag"
        case .pendingTag(let tag): return "pendingTag:\(tag)"
        case .missingPayee: return "missingPayee"
        }
    }

    var label: String {
        switch self {
        case .uncategorized(let acc):
            let short = acc.replacingOccurrences(of: "Expenses:", with: "").replacingOccurrences(of: "Income:", with: "")
            return String(localized: "分类未明确 (\(short))")
        case .needsReviewFlag:
            return String(localized: "标记待核对 (!)")
        case .pendingTag(let tag):
            return String(localized: "带有 #\(tag) 标签")
        case .missingPayee:
            return String(localized: "缺少商户信息")
        }
    }

    var badgeText: String {
        switch self {
        case .uncategorized: return String(localized: "未分类")
        case .needsReviewFlag: return String(localized: "待核对")
        case .pendingTag: return String(localized: "待确认")
        case .missingPayee: return String(localized: "缺商户")
        }
    }
}

enum PendingTransactionClassifier {
    private static let pendingTagNames: Set<String> = [
        "待确认", "待整理", "todo", "review", "待查", "核对", "待分类"
    ]

    private static let unknownAccountPrefixes: [String] = [
        "expenses:unknown", "expenses:other", "expenses:uncategorized",
        "expenses:待分类", "expenses:未分类", "expenses:待整理",
        "income:unknown", "equity:ufo", "expenses:pending"
    ]

    private static let genericPayeePlaceholders: Set<String> = [
        "商户", "特约商户", "微信支付", "支付宝", "扫二维码付款",
        "微信支付商户", "美团平台商户", "财付通", "银行交易"
    ]

    static func evaluate(_ transaction: LedgerTransaction) -> [PendingTransactionReason] {
        var reasons: [PendingTransactionReason] = []

        // 1. Unknown / Uncategorized postings
        for posting in transaction.postings {
            let lower = posting.account.lowercased()
            if unknownAccountPrefixes.contains(where: { lower.hasPrefix($0) }) {
                reasons.append(.uncategorized(account: posting.account))
            }
        }

        // 2. Needs review flag / metadata
        let isFlagged = transaction.pendingReviewFlag == true
            || transaction.editableEntry?.flag == "!"
            || transaction.editableEntry?.needsReview == true
            || transaction.metadata?["needs_review"]?.stringValue?.lowercased() == "true"
            || transaction.metadata?["status"]?.stringValue?.lowercased() == "pending"
        if isFlagged {
            reasons.append(.needsReviewFlag)
        }

        // 3. Pending tags
        if let tags = transaction.tags {
            for tag in tags {
                if pendingTagNames.contains(tag.lowercased()) {
                    reasons.append(.pendingTag(tag))
                }
            }
        }

        // 4. Missing or generic payee. The payee is optional in quick entry,
        // so a meaningful narration (`2026-11-10 * "餐饮"`) is enough.
        let trimmedPayee = transaction.payee.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPayee.isEmpty || genericPayeePlaceholders.contains(trimmedPayee) {
            let trimmedNarration = transaction.narration.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedNarration.isEmpty || genericPayeePlaceholders.contains(trimmedNarration) {
                reasons.append(.missingPayee)
            }
        }

        return reasons
    }
}

extension LedgerTransaction {
    var pendingReasons: [PendingTransactionReason] {
        PendingTransactionClassifier.evaluate(self)
    }

    var isPendingReview: Bool {
        !pendingReasons.isEmpty
    }

    /// Generates an updated entry replacing an account (e.g. Expenses:Unknown -> Expenses:Food:Dinner).
    func entryReplacingAccount(from oldAccount: String, to newAccount: String) -> LedgerTransactionEntry {
        let baseline = editableEntry
        let date = baseline?.date ?? self.date
        let flag = baseline?.flag
        let payee = baseline?.payee ?? self.payee
        let narration = baseline?.narration ?? self.narration
        let metadata = baseline?.metadata ?? self.metadata ?? [:]
        let tags = baseline?.tags ?? self.tags ?? []
        let links = baseline?.links ?? []

        let postings: [LedgerTransactionEntryPosting]
        if let baselinePostings = baseline?.postings {
            postings = baselinePostings.map { posting in
                if posting.account == oldAccount || (oldAccount.isEmpty && posting.account.lowercased().contains("unknown")) {
                    return LedgerTransactionEntryPosting(
                        account: newAccount,
                        flag: posting.flag,
                        amount: posting.amount,
                        currency: posting.currency,
                        costKind: posting.costKind,
                        costAmount: posting.costAmount,
                        costCurrency: posting.costCurrency,
                        costSpec: posting.costSpec,
                        priceKind: posting.priceKind,
                        priceAmount: posting.priceAmount,
                        priceCurrency: posting.priceCurrency
                    )
                }
                return posting
            }
        } else {
            postings = self.postings.map { posting in
                let targetAccount = (posting.account == oldAccount || (oldAccount.isEmpty && posting.account.lowercased().contains("unknown")))
                    ? newAccount
                    : posting.account
                let amountStr = String(format: "%.2f", Double(posting.amount) / 100.0)
                return LedgerTransactionEntryPosting(
                    account: targetAccount,
                    flag: nil,
                    amount: amountStr,
                    currency: posting.currency ?? "CNY"
                )
            }
        }

        return LedgerTransactionEntry(
            date: date,
            flag: flag,
            payee: payee,
            narration: narration,
            metadata: metadata,
            tags: tags,
            links: links,
            postings: postings
        )
    }

    /// Generates an updated entry clearing the pending review flags and tags.
    func entryMarkingVerified() -> LedgerTransactionEntry {
        let baseline = editableEntry
        let date = baseline?.date ?? self.date
        let flag = (baseline?.flag == "!") ? nil : baseline?.flag
        let payee = baseline?.payee ?? self.payee
        let narration = baseline?.narration ?? self.narration
        var metadata = baseline?.metadata ?? self.metadata ?? [:]
        metadata.removeValue(forKey: "needs_review")
        metadata.removeValue(forKey: "status")

        let pendingTags: Set<String> = ["待确认", "待整理", "todo", "review", "待查", "核对", "待分类"]
        let originalTags = baseline?.tags ?? self.tags ?? []
        let cleanedTags = originalTags.filter { !pendingTags.contains($0.lowercased()) }
        let links = baseline?.links ?? []

        let postings: [LedgerTransactionEntryPosting]
        if let baselinePostings = baseline?.postings {
            postings = baselinePostings
        } else {
            postings = self.postings.map { posting in
                let amountStr = String(format: "%.2f", Double(posting.amount) / 100.0)
                return LedgerTransactionEntryPosting(
                    account: posting.account,
                    flag: nil,
                    amount: amountStr,
                    currency: posting.currency ?? "CNY"
                )
            }
        }

        return LedgerTransactionEntry(
            date: date,
            flag: flag,
            payee: payee,
            narration: narration,
            metadata: metadata,
            tags: cleanedTags,
            links: links,
            postings: postings
        )
    }

    /// Generates an updated entry with new payee and/or narration.
    func entryUpdatingPayee(_ newPayee: String, narration newNarration: String? = nil) -> LedgerTransactionEntry {
        let baseline = editableEntry
        let date = baseline?.date ?? self.date
        let flag = baseline?.flag
        let payee = newPayee.trimmingCharacters(in: .whitespacesAndNewlines)
        let narration = (newNarration ?? baseline?.narration ?? self.narration).trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = baseline?.metadata ?? self.metadata ?? [:]
        let tags = baseline?.tags ?? self.tags ?? []
        let links = baseline?.links ?? []

        let postings: [LedgerTransactionEntryPosting]
        if let baselinePostings = baseline?.postings {
            postings = baselinePostings
        } else {
            postings = self.postings.map { posting in
                let amountStr = String(format: "%.2f", Double(posting.amount) / 100.0)
                return LedgerTransactionEntryPosting(
                    account: posting.account,
                    flag: nil,
                    amount: amountStr,
                    currency: posting.currency ?? "CNY"
                )
            }
        }

        return LedgerTransactionEntry(
            date: date,
            flag: flag,
            payee: payee,
            narration: narration,
            metadata: metadata,
            tags: tags,
            links: links,
            postings: postings
        )
    }
}

// MARK: - Event & Tag Project Accounting (标签 / 事件独立核算)

struct EventTagCategoryBreakdown: Identifiable, Equatable, Sendable {
    let account: String
    let label: String
    let amount: Int // minor units (cents)
    let percentage: Double // 0.0 to 1.0
    var id: String { account }
}

struct EventTagDailyPoint: Identifiable, Equatable, Sendable {
    let date: String
    let amount: Int // net expense in cents
    var id: String { date }
}

struct EventTagSummary: Identifiable, Equatable, Sendable {
    let tag: String
    let transactionCount: Int
    let totalExpense: Int // net of refunds
    let totalIncome: Int
    let netSpend: Int
    let currency: String
    let startDate: String?
    let endDate: String?
    let daysCount: Int
    let dailyAverage: Int
    var id: String { tag }
}

struct EventTagReport: Equatable, Sendable {
    let tag: String
    let transactions: [LedgerTransaction]
    let totalExpense: Int // net of refunds
    let totalIncome: Int
    let netSpend: Int
    let currency: String
    let startDate: String?
    let endDate: String?
    let daysCount: Int
    let dailyAverage: Int
    let categoryBreakdown: [EventTagCategoryBreakdown]
    let dailySeries: [EventTagDailyPoint]
}

enum EventTagCalculator {
    static func generateReport(
        tag: String,
        from transactions: [LedgerTransaction],
        accountLabels: [String: String] = [:]
    ) -> EventTagReport {
        let matched = transactions
            .filter { ($0.tags ?? []).contains(tag) }
            .sorted { $0.date > $1.date }

        guard !matched.isEmpty else {
            return EventTagReport(
                tag: tag,
                transactions: [],
                totalExpense: 0,
                totalIncome: 0,
                netSpend: 0,
                currency: "CNY",
                startDate: nil,
                endDate: nil,
                daysCount: 0,
                dailyAverage: 0,
                categoryBreakdown: [],
                dailySeries: []
            )
        }

        var totalExpense = 0
        var totalIncome = 0
        var categoryTotals: [String: Int] = [:]
        var dailyTotals: [String: Int] = [:]
        var primaryCurrency = "CNY"

        for tx in matched {
            // Net expenses
            let expensePostings = tx.postings.filter { $0.account.hasPrefix("Expenses:") }
            let netTxExpense = expensePostings.reduce(0) { $0 + $1.amount }
            if netTxExpense > 0 {
                totalExpense += netTxExpense
            } else if netTxExpense < 0 {
                totalExpense += netTxExpense // refunds reduce expense
            }

            // Category breakdown
            for p in expensePostings {
                categoryTotals[p.account, default: 0] += p.amount
                if let curr = p.currency, !curr.isEmpty { primaryCurrency = curr }
            }

            // Income
            let incomePostings = tx.postings.filter { $0.account.hasPrefix("Income:") }
            let netTxIncome = incomePostings.reduce(0) { $0 + $1.amount }
            if netTxIncome < 0 {
                totalIncome += abs(netTxIncome)
            }

            // Daily series (signed expense)
            if netTxExpense != 0 {
                dailyTotals[tx.date, default: 0] += netTxExpense
            }
        }

        totalExpense = max(0, totalExpense)
        let netSpend = max(0, totalExpense - totalIncome)

        // Date range & days count
        let sortedDates = matched.map(\.date).sorted()
        let startDate = sortedDates.first
        let endDate = sortedDates.last

        var daysCount = 1
        if let s = startDate, let e = endDate,
           let d1 = LedgerDateRange.parse(s), let d2 = LedgerDateRange.parse(e) {
            let diff = Calendar.current.dateComponents([.day], from: d1, to: d2).day ?? 0
            daysCount = max(1, abs(diff) + 1)
        }

        let dailyAverage = daysCount > 0 ? totalExpense / daysCount : totalExpense

        // Category breakdown
        let positiveCategories = categoryTotals.filter { $0.value > 0 }
        let totalCatAmount = positiveCategories.values.reduce(0, +)
        let categoryBreakdown = positiveCategories
            .map { account, amount in
                let label = accountLabels[account] ?? account.replacingOccurrences(of: "Expenses:", with: "")
                let percentage = totalCatAmount > 0 ? Double(amount) / Double(totalCatAmount) : 0.0
                return EventTagCategoryBreakdown(
                    account: account,
                    label: label,
                    amount: amount,
                    percentage: percentage
                )
            }
            .sorted { $0.amount > $1.amount }

        // Daily series
        let dailySeries = dailyTotals
            .map { date, amount in
                EventTagDailyPoint(date: date, amount: max(0, amount))
            }
            .sorted { $0.date < $1.date }

        return EventTagReport(
            tag: tag,
            transactions: matched,
            totalExpense: totalExpense,
            totalIncome: totalIncome,
            netSpend: netSpend,
            currency: primaryCurrency,
            startDate: startDate,
            endDate: endDate,
            daysCount: daysCount,
            dailyAverage: dailyAverage,
            categoryBreakdown: categoryBreakdown,
            dailySeries: dailySeries
        )
    }

    /// Memoizes the last aggregation.
    ///
    /// `EventTagViews`, `AnalysisViews` and `TerminalAnalysisViews` all call
    /// `summarizeAllTags` from computed properties inside view bodies, so an
    /// unrelated publish recomputes the whole scan. The result depends only on
    /// the transactions and labels, so the last pair is kept.
    private final class SummaryCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (transactions: [LedgerTransaction], labels: [String: String], summaries: [EventTagSummary])?

        func summaries(for transactions: [LedgerTransaction], labels: [String: String]) -> [EventTagSummary]? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry, entry.labels == labels, entry.transactions == transactions else { return nil }
            return entry.summaries
        }

        func store(_ summaries: [EventTagSummary], for transactions: [LedgerTransaction], labels: [String: String]) {
            lock.lock()
            entry = (transactions, labels, summaries)
            lock.unlock()
        }
    }

    private static let summaryCache = SummaryCache()

    /// Aggregates every tag in a single pass over `transactions`.
    ///
    /// The previous shape called `generateReport` once per distinct tag, and each
    /// call rescanned the whole transaction array. That is O(tags × transactions)
    /// and it ran from view bodies, so it re-executed on every render. Bucketing
    /// transaction indices in one pass makes it O(transactions + tags × log).
    ///
    /// The reported currency is the last non-empty expense currency in
    /// date-descending order, which is what `generateReport` produced. It depends
    /// on iteration order, so the matched transactions are still sorted per tag
    /// before their currency is read.
    static func summarizeAllTags(
        from transactions: [LedgerTransaction],
        accountLabels: [String: String] = [:]
    ) -> [EventTagSummary] {
        if let cached = summaryCache.summaries(for: transactions, labels: accountLabels) { return cached }
        struct Accumulator {
            var transactionCount = 0
            var totalExpense = 0
            var totalIncome = 0
            var startDate: String?
            var endDate: String?
            var indices: [Int] = []
        }

        var totals: [String: Accumulator] = [:]

        for (index, tx) in transactions.enumerated() {
            guard let tags = tx.tags, !tags.isEmpty else { continue }

            // Per-transaction accounting is tag-independent: compute once, reuse
            // for every tag carried by this transaction.
            var expense = 0
            var income = 0
            for posting in tx.postings {
                if posting.account.hasPrefix("Expenses:") {
                    expense += posting.amount
                } else if posting.account.hasPrefix("Income:") {
                    income += posting.amount
                }
            }
            let countedIncome = income < 0 ? abs(income) : 0

            // A transaction may repeat a tag; the original per-tag filter counted
            // it once, so dedupe before accumulating.
            var seenTags = Set<String>()
            for tag in tags where !tag.isEmpty {
                guard seenTags.insert(tag).inserted else { continue }
                var entry = totals[tag] ?? Accumulator()
                entry.transactionCount += 1
                entry.totalExpense += expense
                entry.totalIncome += countedIncome
                entry.indices.append(index)
                if entry.startDate == nil || tx.date < entry.startDate! { entry.startDate = tx.date }
                if entry.endDate == nil || tx.date > entry.endDate! { entry.endDate = tx.date }
                totals[tag] = entry
            }
        }

        let summaries = totals.map { tag, entry -> EventTagSummary in
            let totalExpense = max(0, entry.totalExpense)
            let netSpend = max(0, totalExpense - entry.totalIncome)

            var daysCount = 1
            if let start = entry.startDate, let end = entry.endDate,
               let from = LedgerDateRange.parse(start), let to = LedgerDateRange.parse(end) {
                let difference = Calendar.current.dateComponents([.day], from: from, to: to).day ?? 0
                daysCount = max(1, abs(difference) + 1)
            }

            // Preserve `generateReport`'s date-descending scan for the currency.
            var currency = "CNY"
            let ordered = entry.indices
                .map { (date: transactions[$0].date, index: $0) }
                .sorted { $0.date > $1.date }
            for item in ordered {
                for posting in transactions[item.index].postings
                where posting.account.hasPrefix("Expenses:") {
                    if let code = posting.currency, !code.isEmpty { currency = code }
                }
            }

            return EventTagSummary(
                tag: tag,
                transactionCount: entry.transactionCount,
                totalExpense: totalExpense,
                totalIncome: entry.totalIncome,
                netSpend: netSpend,
                currency: currency,
                startDate: entry.startDate,
                endDate: entry.endDate,
                daysCount: daysCount,
                dailyAverage: daysCount > 0 ? totalExpense / daysCount : totalExpense
            )
        }

        // Tags previously came from a `Set`, so ties resolved differently on
        // every launch. Break them on the tag name to keep the list stable.
        let sorted = summaries.sorted {
            if let e1 = $0.endDate, let e2 = $1.endDate, e1 != e2 {
                return e1 > e2
            }
            if $0.totalExpense != $1.totalExpense {
                return $0.totalExpense > $1.totalExpense
            }
            return $0.tag < $1.tag
        }
        summaryCache.store(sorted, for: transactions, labels: accountLabels)
        return sorted
    }
}

/// Native-only bounded overview projection. Totals include every positive net
/// category, while only the top four carry representative transactions for icons.
/// Count and highest expense cover all rows in the range, not just categories.
struct LedgerOverviewCategories: Codable, Sendable {
    let revision: String
    let start: String
    let end: String
    let sensitiveUnlocked: Bool
    let positiveTotalMinorUnits: Int
    let transactionCount: Int
    let highestExpense: HighestExpense?
    let categories: [Category]
    /// Currency the category totals are valued in. nil from engines that summed
    /// raw posting minor units across currencies.
    let currency: String?

    struct HighestExpense: Codable, Equatable, Sendable {
        let title: String
        let minorUnits: Int
    }

    private enum CodingKeys: String, CodingKey {
        case revision, start, end, sensitiveUnlocked, positiveTotalMinorUnits
        case transactionCount, highestExpense, categories, currency
    }

    init(revision: String, start: String, end: String, sensitiveUnlocked: Bool,
         positiveTotalMinorUnits: Int, transactionCount: Int, highestExpense: HighestExpense?,
         categories: [Category], currency: String? = nil) {
        self.revision = revision
        self.start = start
        self.end = end
        self.sensitiveUnlocked = sensitiveUnlocked
        self.positiveTotalMinorUnits = positiveTotalMinorUnits
        self.transactionCount = transactionCount
        self.highestExpense = highestExpense
        self.categories = categories
        self.currency = currency
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(String.self, forKey: .revision)
        start = try values.decode(String.self, forKey: .start)
        end = try values.decode(String.self, forKey: .end)
        sensitiveUnlocked = try values.decode(Bool.self, forKey: .sensitiveUnlocked)
        positiveTotalMinorUnits = try values.decode(Int.self, forKey: .positiveTotalMinorUnits)
        transactionCount = try values.decode(Int.self, forKey: .transactionCount)
        // decodeIfPresent would incorrectly accept an old/missing contract field
        // as a successful range with no expenses. Optional.decode requires the key.
        highestExpense = try values.decode(HighestExpense?.self, forKey: .highestExpense)
        categories = try values.decode([Category].self, forKey: .categories)
        currency = try values.decodeIfPresent(String.self, forKey: .currency)
        guard transactionCount >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .transactionCount, in: values,
                debugDescription: "Overview transaction count must be nonnegative")
        }
        if let highestExpense, highestExpense.minorUnits <= 0 || transactionCount == 0 {
            throw DecodingError.dataCorruptedError(forKey: .highestExpense, in: values,
                debugDescription: "Overview highest expense requires a positive amount and nonzero count")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(revision, forKey: .revision)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        try values.encode(sensitiveUnlocked, forKey: .sensitiveUnlocked)
        try values.encode(positiveTotalMinorUnits, forKey: .positiveTotalMinorUnits)
        try values.encode(transactionCount, forKey: .transactionCount)
        // Successful absence is an explicit JSON null, never an omitted key.
        try values.encode(highestExpense, forKey: .highestExpense)
        try values.encode(categories, forKey: .categories)
        try values.encodeIfPresent(currency, forKey: .currency)
    }

    struct Category: Codable, Sendable {
        let label: String
        let totalMinorUnits: Int
        let positiveTransactionCount: Int
        let representative: LedgerTransaction
    }
}

/// Portable adapter for the existing overview count and spending-rhythm views.
/// nil means unavailable, whereas a successful nil highestExpense means no expense.
struct OverviewTransactionStats: Equatable, Sendable {
    let transactionCount: Int
    let highestExpense: LedgerOverviewCategories.HighestExpense?

    init?(isLocal: Bool, aggregate: LedgerOverviewCategories?, transactions: [LedgerTransaction]) {
        if isLocal {
            guard let aggregate else { return nil }
            transactionCount = aggregate.transactionCount
            highestExpense = aggregate.highestExpense
        } else {
            transactionCount = transactions.count
            highestExpense = transactions.compactMap { transaction in
                let presentation = TransactionPresentation(transaction: transaction)
                guard presentation.kind == .expense, !presentation.isRefund,
                      presentation.minorUnits > 0 else { return nil }
                return LedgerOverviewCategories.HighestExpense(title: presentation.title,
                    minorUnits: presentation.minorUnits)
            }.max { $0.minorUnits < $1.minorUnits }
        }
    }
}
