import Foundation

extension LedgerSession {
    static func appSession(processInfo: ProcessInfo = .processInfo) -> LedgerSession {
        #if DEBUG
        if processInfo.arguments.contains("--safe-preview") {
            let suiteName = "ledger-mobile-safe-preview"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.set("https://preview.ledger.invalid", forKey: "ledger.mobile.server-origin")
            return LedgerSession(api: SafePreviewLedgerAPI(), defaults: defaults)
        }
        #endif
        return LedgerSession()
    }
}

#if DEBUG
private actor SafePreviewLedgerAPI: LedgerAPI {
    func health(baseURL: URL) async throws -> HealthStatus {
        HealthStatus(apiVersion: 1, capabilities: ["full-backend", "cookie-auth"])
    }

    func authStatus(baseURL: URL) async throws -> AuthStatus {
        AuthStatus(authenticated: true, sensitiveUnlocked: true, authDisabled: false)
    }

    func passkeyStatus(baseURL: URL) async throws -> PasskeyStatus {
        PasskeyStatus(registered: false, count: 0)
    }

    func passkeyLoginOptions(baseURL: URL) async throws -> PasskeyRequestOptions {
        throw LedgerAPIError.incompatibleServer("安全预览不提供通行密钥")
    }

    func verifyPasskey(baseURL: URL, assertion: PasskeyAssertion) async throws {}
    func login(baseURL: URL, password: String) async throws {}

    func registerQuickUnlock(baseURL: URL, deviceName: String) async throws -> QuickUnlockCredential {
        QuickUnlockCredential(deviceID: "safe-preview", token: "safe-preview")
    }

    func verifyQuickUnlock(baseURL: URL, credential: QuickUnlockCredential) async throws {}
    func revokeQuickUnlock(baseURL: URL, deviceID: String) async throws {}

    func bootstrap(baseURL: URL, start: String, end: String, today: String) async throws -> LedgerBootstrap {
        SafePreviewLedgerData.bootstrap(start: start, end: end)
    }

    func accountDetail(baseURL: URL, account: String) async throws -> LedgerAccountDetail {
        SafePreviewLedgerData.accountDetail(account: account)
    }

    func lock(baseURL: URL) async throws {}
    func logout(baseURL: URL) async throws {}
}

private enum SafePreviewLedgerData {
    static let accounts = [
        LedgerAccount(account: "Assets:Bank:Daily", openDate: "2024-01-01", closeDate: nil, currency: "CNY", alias: "日常账户", label: "日常账户", group: "cash", active: true),
        LedgerAccount(account: "Assets:Bank:FamilyEducationReserve", openDate: "2024-01-01", closeDate: nil, currency: "CNY", alias: "家庭长期储备与教育基金（含海外留学与应急资金）", label: "家庭长期储备与教育基金", group: "wealth", active: true),
        LedgerAccount(account: "Assets:Investments:IndexFund", openDate: "2024-01-01", closeDate: nil, currency: "CNY", alias: "全球指数基金", label: "全球指数基金", group: "wealth", active: true),
        LedgerAccount(account: "Assets:Cash:USD", openDate: "2024-03-15", closeDate: nil, currency: "USD", alias: "美元备用金", label: "美元备用金", group: "cash", active: true),
        LedgerAccount(account: "Liabilities:CreditCard", openDate: "2024-01-01", closeDate: nil, currency: "CNY", alias: "信用卡", label: "信用卡", group: "credit", active: true),
    ]

    static let balances = [
        AccountBalance(account: "Assets:Bank:Daily", currency: "CNY", amount: 8_756_432, valuationCurrency: "CNY", valuation: 8_756_432, valuationMissing: false),
        AccountBalance(account: "Assets:Bank:FamilyEducationReserve", currency: "CNY", amount: 128_763_450, valuationCurrency: "CNY", valuation: 128_763_450, valuationMissing: false),
        AccountBalance(account: "Assets:Investments:IndexFund", currency: "CNY", amount: 12_345_678_900, valuationCurrency: "CNY", valuation: 12_345_678_900, valuationMissing: false),
        AccountBalance(account: "Assets:Cash:USD", currency: "USD", amount: 42_875, valuationCurrency: "CNY", valuation: 305_984, valuationMissing: false),
        AccountBalance(account: "Liabilities:CreditCard", currency: "CNY", amount: -289_900, valuationCurrency: "CNY", valuation: -289_900, valuationMissing: false),
    ]

    static let transactions = [
        transaction(date: "2026-08-28", payee: "城市书房", narration: "年度阅读计划", postings: [("Expenses:Education:Books", 32_800, "CNY"), ("Liabilities:CreditCard", -32_800, "CNY")], line: 88, tags: ["学习"]),
        transaction(date: "2026-08-26", payee: "青禾市场", narration: "周末食材", postings: [("Expenses:Food:Groceries", 18_680, "CNY"), ("Assets:Bank:Daily", -18_680, "CNY")], line: 76),
        transaction(date: "2026-08-24", payee: "全球指数基金", narration: "月度定投", postings: [("Assets:Investments:IndexFund", 1_500_000, "CNY"), ("Assets:Bank:Daily", -1_500_000, "CNY")], line: 69, tags: ["投资"]),
        transaction(date: "2026-08-21", payee: "云端出行", narration: "差旅交通", postings: [("Expenses:Travel:Transport", 57_600, "CNY"), ("Liabilities:CreditCard", -57_600, "CNY")], line: 61),
        transaction(date: "2026-08-18", payee: "工资", narration: "八月薪资", postings: [("Assets:Bank:Daily", 4_800_000, "CNY"), ("Income:Salary", -4_800_000, "CNY")], line: 52),
        transaction(date: "2026-08-15", payee: "教育储备", narration: "家庭长期计划转入", postings: [("Assets:Bank:FamilyEducationReserve", 2_000_000, "CNY"), ("Assets:Bank:Daily", -2_000_000, "CNY")], line: 44),
        transaction(date: "2026-08-12", payee: "山岚咖啡", narration: "朋友聚会", postings: [("Expenses:Food:Dining", 23_600, "CNY"), ("Assets:Bank:Daily", -23_600, "CNY")], line: 37),
        transaction(date: "2026-08-09", payee: "房屋租金", narration: "八月房租", postings: [("Expenses:Housing:Rent", 380_000, "CNY"), ("Assets:Bank:Daily", -380_000, "CNY")], line: 29),
        transaction(date: "2026-08-06", payee: "差旅报销", narration: "七月差旅", postings: [("Assets:Bank:Daily", 250_000, "CNY"), ("Income:Reimbursement", -250_000, "CNY")], line: 21, tags: ["报销"]),
        transaction(date: "2026-08-03", payee: "海岸生鲜", narration: "家庭采购", postings: [("Expenses:Food:Groceries", 42_500, "CNY"), ("Liabilities:CreditCard", -42_500, "CNY")], line: 14),
    ]

    static func bootstrap(start: String, end: String) -> LedgerBootstrap {
        let visible = transactions.filter { $0.date >= start && $0.date <= end }
        let income = visible.reduce(0) { total, transaction in
            total + transaction.postings.filter { $0.account.hasPrefix("Income:") }.reduce(0) { $0 + abs($1.amount) }
        }
        let expense = visible.reduce(0) { total, transaction in
            total + transaction.postings.filter { $0.account.hasPrefix("Expenses:") }.reduce(0) { $0 + abs($1.amount) }
        }
        return LedgerBootstrap(
            start: start,
            end: end,
            summary: LedgerSummary(currency: "CNY", income: income, expense: expense, net: income - expense),
            accountBalances: balances,
            transactions: visible,
            accounts: accounts,
            valuationCurrency: "CNY",
            sensitiveUnlocked: true
        )
    }

    static func accountDetail(account: String) -> LedgerAccountDetail {
        let metadata = accounts.first { $0.account == account }
        let balance = balances.first { $0.account == account }
        let matching = transactions
            .sorted { $0.date < $1.date }
            .compactMap { transaction -> (LedgerTransaction, Int)? in
                guard let posting = transaction.postings.first(where: { $0.account == account }) else { return nil }
                return (transaction, posting.amount)
            }
        let currentBalance = balance?.amount ?? 0
        var runningBalance = currentBalance - matching.reduce(0) { $0 + $1.1 }
        let rows = matching.map { transaction, change in
            runningBalance += change
            return LedgerAccountDetailRow(
                date: transaction.date,
                payee: transaction.payee,
                narration: transaction.narration,
                change: change,
                balance: runningBalance,
                transaction: transaction
            )
        }
        return LedgerAccountDetail(
            account: account,
            label: metadata?.label ?? account,
            alias: metadata?.alias,
            group: metadata?.group ?? "asset",
            active: metadata?.active ?? true,
            currency: balance?.currency ?? metadata?.currency ?? "CNY",
            currentBalance: currentBalance,
            rows: rows
        )
    }

    private static func transaction(
        date: String,
        payee: String,
        narration: String,
        postings: [(String, Int, String)],
        line: Int,
        tags: [String]? = nil
    ) -> LedgerTransaction {
        LedgerTransaction(
            date: date,
            payee: payee,
            narration: narration,
            tags: tags,
            postings: postings.map { LedgerPosting(account: $0.0, amount: $0.1, currency: $0.2) },
            source: TransactionSource(file: "transactions/2026/08.bean", line: line, hash: "safe-preview-\(line)", gitSHA: "preview")
        )
    }
}
#endif
