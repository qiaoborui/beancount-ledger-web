import Foundation

struct LedgerWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let updatedAt: Date
    let expense: LedgerWidgetExpenseSnapshot
    let accounts: [LedgerWidgetAccountSnapshot]
    let imports: [LedgerWidgetImportSnapshot]
    let importsUpdatedAt: Date?

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
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case updatedAt
        case expense
        case accounts
        case imports
        case importsUpdatedAt
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

    func load() -> LedgerWidgetSnapshot? { loadState().snapshot }

    func loadState() -> LedgerWidgetSnapshotState {
        (try? coordinator.withLock {
            guard let defaults else { return LedgerWidgetSnapshotState(snapshot: nil, attemptedAt: nil) }
            _ = defaults.synchronize()
            return LedgerWidgetSnapshotState(
                snapshot: load(from: defaults),
                attemptedAt: defaults.object(forKey: Self.snapshotAttemptKey) as? Date
            )
        }) ?? LedgerWidgetSnapshotState(snapshot: nil, attemptedAt: nil)
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
    func saveIfNewer(
        _ snapshot: LedgerWidgetSnapshot,
        attemptedAt: Date,
        recoveringFutureState expected: LedgerWidgetSnapshotState? = nil
    ) throws -> Bool {
        try coordinator.withLock {
            guard let defaults else { throw LedgerWidgetSnapshotStoreError.unavailable }
            _ = defaults.synchronize()
            let current = LedgerWidgetSnapshotState(
                snapshot: load(from: defaults),
                attemptedAt: defaults.object(forKey: Self.snapshotAttemptKey) as? Date
            )
            // Clock correction can put both the cached payload and its write time in the future.
            // Recover only the exact state this request observed, under the shared-store lock.
            // Server timestamps can be slightly later than the request's start time.
            let toleratedResponseTime = attemptedAt.addingTimeInterval(60)
            let recoversClockSkew = expected == current
                && current.snapshot != nil
                && current.isFuture(relativeTo: toleratedResponseTime)
                && snapshot.updatedAt <= toleratedResponseTime
            if !recoversClockSkew {
                if let currentAttempt = current.attemptedAt, currentAttempt > attemptedAt { return false }
                if let stored = current.snapshot, stored.updatedAt > snapshot.updatedAt { return false }
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

struct LedgerWidgetSnapshotState: Equatable, Sendable {
    let snapshot: LedgerWidgetSnapshot?
    let attemptedAt: Date?

    func isFuture(relativeTo date: Date) -> Bool {
        (snapshot.map { $0.updatedAt > date } ?? false) || (attemptedAt.map { $0 > date } ?? false)
    }
}
