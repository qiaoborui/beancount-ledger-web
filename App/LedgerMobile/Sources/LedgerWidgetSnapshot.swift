import Foundation

/// Shared by the app and extension. Ledger dates are civil dates, independent of time zone.
enum LedgerWidgetLink {
    static func expenseDay(_ date: String) -> URL? {
        guard isValidDay(date) else { return nil }
        return URL(string: "ledger://transactions?date=\(date)")
    }

    static func expenseDay(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "ledger", url.host == "transactions",
              url.path.isEmpty, url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, items[0].name == "date",
              let date = items[0].value, isValidDay(date) else { return nil }
        return date
    }

    static func isValidDay(_ value: String) -> Bool {
        guard value.utf8.count == 10,
              value.utf8.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 ? byte == 45 : (48...57).contains(byte)
              }) else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return false }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == parts[0] && components.month == parts[1] && components.day == parts[2]
    }
}

struct LedgerWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let updatedAt: Date
    let expense: LedgerWidgetExpenseSnapshot
    let accounts: [LedgerWidgetAccountSnapshot]
    let imports: [LedgerWidgetImportSnapshot]
    let importsUpdatedAt: Date?
    var insights: LedgerWidgetExpenseInsights? = nil

    init(
        schemaVersion: Int = currentSchemaVersion,
        updatedAt: Date,
        expense: LedgerWidgetExpenseSnapshot,
        accounts: [LedgerWidgetAccountSnapshot],
        imports: [LedgerWidgetImportSnapshot] = [],
        importsUpdatedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.expense = expense
        self.accounts = accounts
        self.imports = imports
        self.importsUpdatedAt = importsUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        expense = try container.decode(LedgerWidgetExpenseSnapshot.self, forKey: .expense)
        accounts = try container.decode([LedgerWidgetAccountSnapshot].self, forKey: .accounts)
        imports = try container.decodeIfPresent([LedgerWidgetImportSnapshot].self, forKey: .imports) ?? []
        importsUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .importsUpdatedAt)
        insights = try container.decodeIfPresent(LedgerWidgetExpenseInsights.self, forKey: .insights)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case updatedAt
        case expense
        case accounts
        case imports
        case importsUpdatedAt
        case insights
    }
}

/// Additive payload: old servers keep supporting the monthly overview.
struct LedgerWidgetExpenseInsights: Codable, Equatable, Sendable {
    let updatedAt: String
    let week: LedgerWidgetExpenseSnapshot
    let year: LedgerWidgetExpenseSnapshot
    let history: LedgerWidgetExpenseSnapshot

    var date: Date? { ISO8601DateFormatter().date(from: updatedAt) }
}

enum LedgerWidgetPeriod: String, Codable, CaseIterable, Sendable {
    case week, month, year
    var title: String {
        switch self { case .week: "本周消费"; case .month: "本月消费"; case .year: "本年消费" }
    }

    func expense(in snapshot: LedgerWidgetSnapshot) -> LedgerWidgetExpenseSnapshot? {
        switch self {
        case .week: snapshot.insights?.week
        case .month: snapshot.expense
        case .year: snapshot.insights?.year
        }
    }

    func currentExpense(in snapshot: LedgerWidgetSnapshot, now: Date) -> LedgerWidgetExpenseSnapshot? {
        guard let expense = expense(in: snapshot) else { return nil }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let today = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        guard expense.start <= today, today < expense.end else { return nil }
        return expense
    }
}

enum LedgerWidgetDates {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    static func date(_ day: String) -> Date? {
        guard LedgerWidgetLink.isValidDay(day) else { return nil }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func adding(_ days: Int, to day: String) -> String {
        guard let date = date(day), let result = calendar.date(byAdding: .day, value: days, to: date) else { return day }
        return self.day(result)
    }

    static func weekStart(_ day: String) -> String {
        guard let date = date(day) else { return day }
        return adding(-((calendar.component(.weekday, from: date) + 5) % 7), to: day)
    }

    /// Expands only the explicitly covered range, retaining source values.
    static func series(_ expense: LedgerWidgetExpenseSnapshot, start: String, end: String) -> [LedgerWidgetDailyExpense] {
        guard start >= expense.start, end <= expense.end, start < end,
              let first = date(start), let last = date(end),
              let count = calendar.dateComponents([.day], from: first, to: last).day,
              count <= 366 else { return [] }
        let amounts = Dictionary(grouping: expense.dailySeries, by: \.date).mapValues { $0.reduce(0) { $0 + $1.amount } }
        return (0..<count).map { offset in
            let value = adding(offset, to: start)
            return LedgerWidgetDailyExpense(date: value, amount: amounts[value, default: 0])
        }
    }
}

struct LedgerWidgetExpenseSnapshot: Codable, Equatable, Sendable {
    let periodTitle: String
    let start: String
    let end: String
    let currency: String
    let amount: Int
    let transactionCount: Int
    let yearOverYearPercentage: Double?
    let categories: [LedgerWidgetExpenseCategory]
    let dailySeries: [LedgerWidgetDailyExpense]
}

struct LedgerWidgetExpenseCategory: Codable, Equatable, Identifiable, Sendable {
    let account: String
    let label: String
    let amount: Int

    var id: String { account }
}

struct LedgerWidgetDailyExpense: Codable, Equatable, Identifiable, Sendable {
    let date: String
    let amount: Int

    var id: String { date }
}

struct LedgerWidgetAccountSnapshot: Codable, Equatable, Identifiable, Sendable {
    let account: String
    let label: String
    let group: String
    let currency: String
    let balance: Int
    let valuationCurrency: String
    let valuation: Int?

    var id: String { account }
    var isLiability: Bool { account.hasPrefix("Liabilities:") }
}

struct LedgerWidgetImportSnapshot: Codable, Equatable, Identifiable, Sendable {
    let provider: String
    let label: String
    let coverageStart: String?
    let coverageEnd: String?

    var id: String { provider }
    var latestCoverageDate: String? { coverageEnd ?? coverageStart }
}

struct LedgerWidgetSnapshotStore: Sendable {
    static let appGroupIdentifier = "group.com.qiaoborui.ledger.mobile"
    static let snapshotKey = "ledger.widgets.snapshot.v1"
    static let snapshotAttemptKey = "ledger.widgets.snapshot-attempt.v1"
    static let shared = LedgerWidgetSnapshotStore()

    let suiteName: String

    init(suiteName: String = appGroupIdentifier) {
        self.suiteName = suiteName
    }

    func load() -> LedgerWidgetSnapshot? {
        try? coordinator.withLock {
            guard let defaults else { return nil }
            _ = defaults.synchronize()
            return load(from: defaults)
        }
    }

    func save(_ snapshot: LedgerWidgetSnapshot) throws {
        try coordinator.withLock {
            guard let defaults else { throw LedgerWidgetSnapshotStoreError.unavailable }
            defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.snapshotKey)
            defaults.removeObject(forKey: Self.snapshotAttemptKey)
            _ = defaults.synchronize()
        }
    }

    @discardableResult
    func saveIfNewer(_ snapshot: LedgerWidgetSnapshot, attemptedAt: Date) throws -> Bool {
        try coordinator.withLock {
            guard let defaults else { throw LedgerWidgetSnapshotStoreError.unavailable }
            _ = defaults.synchronize()
            if let currentAttempt = defaults.object(forKey: Self.snapshotAttemptKey) as? Date,
               currentAttempt > attemptedAt {
                return false
            }
            if let current = load(from: defaults), current.updatedAt > snapshot.updatedAt {
                return false
            }
            defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.snapshotKey)
            defaults.set(attemptedAt, forKey: Self.snapshotAttemptKey)
            _ = defaults.synchronize()
            return true
        }
    }

    func clear() {
        try? coordinator.withLock {
            defaults?.removeObject(forKey: Self.snapshotKey)
            defaults?.removeObject(forKey: Self.snapshotAttemptKey)
            _ = defaults?.synchronize()
        }
    }

    func clear(ifCurrentEquals snapshot: LedgerWidgetSnapshot, attemptedAt: Date) {
        try? coordinator.withLock {
            guard let defaults else { return }
            _ = defaults.synchronize()
            guard defaults.object(forKey: Self.snapshotAttemptKey) as? Date == attemptedAt,
                  load(from: defaults) == snapshot else { return }
            defaults.removeObject(forKey: Self.snapshotKey)
            defaults.removeObject(forKey: Self.snapshotAttemptKey)
            _ = defaults.synchronize()
        }
    }

    private var coordinator: LedgerWidgetSharedStoreCoordinator {
        LedgerWidgetSharedStoreCoordinator(suiteName: suiteName)
    }

    private func load(from defaults: UserDefaults) -> LedgerWidgetSnapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKey),
              let snapshot = try? JSONDecoder().decode(LedgerWidgetSnapshot.self, from: data),
              (1...LedgerWidgetSnapshot.currentSchemaVersion).contains(snapshot.schemaVersion) else {
            return nil
        }

        guard snapshot.schemaVersion < LedgerWidgetSnapshot.currentSchemaVersion else {
            return snapshot
        }

        let migrated = LedgerWidgetSnapshot(
            updatedAt: snapshot.updatedAt,
            expense: snapshot.expense,
            accounts: snapshot.accounts,
            imports: snapshot.imports,
            importsUpdatedAt: snapshot.importsUpdatedAt
        )
        if let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: Self.snapshotKey)
        }
        return migrated
    }

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }
}

enum LedgerWidgetSnapshotStoreError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "无法访问小组件共享空间"
    }
}
