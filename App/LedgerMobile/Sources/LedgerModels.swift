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
    static let accountPeriodBalancesCapability = "account-period-balances-v1"

    let apiVersion: Int
    let capabilities: [String]

    var supportsAccountPeriodBalances: Bool {
        capabilities.contains(Self.accountPeriodBalancesCapability)
    }

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
    let comparisons: LedgerPeriodComparisons?
    let accountBalances: [AccountBalance]
    let transactions: [LedgerTransaction]
    let accounts: [LedgerAccount]
    let commodities: [String]
    let prices: [LedgerPrice]
    let valuationCurrency: String
    let sensitiveUnlocked: Bool

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case summary
        case comparisons
        case accountBalances
        case transactions
        case accounts
        case commodities
        case prices
        case valuationCurrency
        case sensitiveUnlocked
    }

    init(
        start: String,
        end: String,
        summary: LedgerSummary,
        comparisons: LedgerPeriodComparisons? = nil,
        accountBalances: [AccountBalance],
        transactions: [LedgerTransaction],
        accounts: [LedgerAccount],
        commodities: [String] = [],
        prices: [LedgerPrice] = [],
        valuationCurrency: String,
        sensitiveUnlocked: Bool
    ) {
        self.start = start
        self.end = end
        self.summary = summary
        self.comparisons = comparisons
        self.accountBalances = accountBalances
        self.transactions = transactions
        self.accounts = accounts
        self.commodities = commodities
        self.prices = prices
        self.valuationCurrency = valuationCurrency
        self.sensitiveUnlocked = sensitiveUnlocked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(String.self, forKey: .start)
        end = try container.decode(String.self, forKey: .end)
        summary = try container.decode(LedgerSummary.self, forKey: .summary)
        comparisons = try container.decodeIfPresent(LedgerPeriodComparisons.self, forKey: .comparisons)
        accountBalances = try container.decode([AccountBalance].self, forKey: .accountBalances)
        transactions = try container.decode([LedgerTransaction].self, forKey: .transactions)
        accounts = try container.decode([LedgerAccount].self, forKey: .accounts)
        commodities = try container.decodeIfPresent([String].self, forKey: .commodities) ?? []
        prices = try container.decodeIfPresent([LedgerPrice].self, forKey: .prices) ?? []
        valuationCurrency = try container.decode(String.self, forKey: .valuationCurrency)
        sensitiveUnlocked = try container.decode(Bool.self, forKey: .sensitiveUnlocked)
    }
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

struct LedgerImportDocument: Decodable, Equatable, Sendable {
    let provider: String?
    let dateStart: String?
    let dateEnd: String?
    let modTime: String
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
    var openingAmount: Int? = nil
    var closingAmount: Int? = nil
    var periodChange: Int? = nil
    var openingValuation: Int? = nil
    var closingValuation: Int? = nil
    var periodValuationChange: Int? = nil
    var periodValuationMissing: Bool? = nil
    var periodAvailable: Bool? = nil
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

struct LedgerAccountDetail: Decodable, Equatable {
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

struct LedgerAccountDetailRow: Decodable, Equatable, Identifiable {
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

struct LedgerAccountBalanceTrendPoint: Equatable, Identifiable {
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
        downsampledBalanceTrend(balanceTrend, maxPoints: maxPoints)
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
        return downsampledBalanceTrend(points, maxPoints: maxPoints)
    }

    private func downsampledBalanceTrend(
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

enum LedgerAnalysisResourceKind: Equatable, Sendable {
    case dashboard
    case incomeStatement
    case investments
}

enum LedgerAnalysisResource: Equatable, Sendable {
    case dashboard(LedgerDashboard)
    case incomeStatement(LedgerIncomeStatement)
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
                shortLabel: "\(parts[1])月",
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
                shortLabel: "\(parts[0])月",
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
    let netIncome: Int
    let valuationCurrency: String
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
        case .all: "全部"
        case .expense: "支出"
        case .income: "收入"
        case .transfer: "转账"
        }
    }
}

struct LedgerTransactionFilter: Equatable, Sendable {
    var query = ""
    var kind = TransactionKindFilter.all
    var account: String?

    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || kind != .all
            || account != nil
    }

    func matches(_ transaction: LedgerTransaction) -> Bool {
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

        if let account, !transaction.postings.contains(where: { $0.account == account }) {
            return false
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
        case .all: "全部"
        case .assets: "资产"
        case .liabilities: "负债"
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
        let liabilities = valid
            .filter { $0.account.hasPrefix("Liabilities:") }
            .reduce(0) { $0 + abs($1.valuation) }
        return BalanceSheetTotals(assets: assets, liabilities: liabilities, netWorth: assets - liabilities)
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
