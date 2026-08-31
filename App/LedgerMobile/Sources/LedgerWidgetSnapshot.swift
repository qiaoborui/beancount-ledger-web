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

struct LedgerWidgetSnapshotStore {
    static let appGroupIdentifier = "group.com.qiaoborui.ledger.mobile"
    static let snapshotKey = "ledger.widgets.snapshot.v1"
    static let shared = LedgerWidgetSnapshotStore()

    let suiteName: String

    init(suiteName: String = appGroupIdentifier) {
        self.suiteName = suiteName
    }

    func load() -> LedgerWidgetSnapshot? {
        guard let data = defaults?.data(forKey: Self.snapshotKey),
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
        try? save(migrated)
        return migrated
    }

    func save(_ snapshot: LedgerWidgetSnapshot) throws {
        guard let defaults else { throw LedgerWidgetSnapshotStoreError.unavailable }
        defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.snapshotKey)
    }

    func clear() {
        defaults?.removeObject(forKey: Self.snapshotKey)
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
