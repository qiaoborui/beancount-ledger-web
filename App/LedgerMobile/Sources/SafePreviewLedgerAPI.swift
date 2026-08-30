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

    func dashboard(baseURL: URL, start: String, end: String) async throws -> LedgerDashboard {
        SafePreviewLedgerData.dashboard(start: start, end: end)
    }

    func incomeStatement(baseURL: URL, start: String, end: String) async throws -> LedgerIncomeStatement {
        SafePreviewLedgerData.incomeStatement(start: start, end: end)
    }

    func investments(baseURL: URL) async throws -> LedgerInvestmentSummary {
        SafePreviewLedgerData.investments
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

    static func dashboard(start: String, end: String) -> LedgerDashboard {
        LedgerDashboard(
            start: start,
            end: end,
            currency: "CNY",
            kpis: LedgerDashboardKPI(
                assets: 1_415_200_366,
                liabilities: 289_900,
                netWorth: 1_414_910_466,
                income: 5_050_000,
                expense: 555_180,
                net: 4_494_820,
                savingsRate: 0.8901
            ),
            netWorthSeries: [
                LedgerNetWorthPoint(date: "2026-03", assets: 1_218_400_000, liabilities: 342_800, netWorth: 1_218_057_200),
                LedgerNetWorthPoint(date: "2026-04", assets: 1_267_900_000, liabilities: 318_600, netWorth: 1_267_581_400),
                LedgerNetWorthPoint(date: "2026-05", assets: 1_301_500_000, liabilities: 301_200, netWorth: 1_301_198_800),
                LedgerNetWorthPoint(date: "2026-06", assets: 1_344_700_000, liabilities: 295_700, netWorth: 1_344_404_300),
                LedgerNetWorthPoint(date: "2026-07", assets: 1_376_800_000, liabilities: 310_400, netWorth: 1_376_489_600),
                LedgerNetWorthPoint(date: "2026-08", assets: 1_415_200_366, liabilities: 289_900, netWorth: 1_414_910_466),
            ],
            cashflowSeries: [
                LedgerCashflowPoint(month: "03", income: 4_820_000, expense: 1_138_000, net: 3_682_000),
                LedgerCashflowPoint(month: "04", income: 5_080_000, expense: 1_246_000, net: 3_834_000),
                LedgerCashflowPoint(month: "05", income: 4_960_000, expense: 932_000, net: 4_028_000),
                LedgerCashflowPoint(month: "06", income: 5_160_000, expense: 1_328_000, net: 3_832_000),
                LedgerCashflowPoint(month: "08", income: 5_050_000, expense: 555_180, net: 4_494_820),
            ],
            categorySeries: [
                LedgerCategorySeries(account: "Expenses:Housing", alias: "居住", label: "居住", total: 380_000, values: []),
                LedgerCategorySeries(account: "Expenses:Education", alias: "教育", label: "教育", total: 32_800, values: []),
                LedgerCategorySeries(account: "Expenses:Food", alias: "餐饮", label: "餐饮", total: 84_780, values: []),
                LedgerCategorySeries(account: "Expenses:Travel", alias: "出行", label: "出行", total: 57_600, values: []),
            ],
            topPayees: [
                LedgerPayeeAnalytics(payee: "房屋租金", amount: 380_000, txCount: 1),
                LedgerPayeeAnalytics(payee: "云端出行", amount: 57_600, txCount: 1),
            ],
            topPaymentAccounts: [
                LedgerAccountAnalytics(account: "Assets:Bank:Daily", alias: "日常账户", label: "日常账户", amount: 445_780, txCount: 5),
            ],
            anomalies: [
                LedgerDashboardAnomaly(date: "2026-08-28", payee: "城市书房", narration: "年度阅读计划", account: "Expenses:Education:Books", amount: 32_800, source: "transactions/2026/08.bean:88"),
            ]
        )
    }

    static func incomeStatement(start: String, end: String) -> LedgerIncomeStatement {
        LedgerIncomeStatement(
            start: start,
            end: end,
            income: [
                LedgerIncomeNode(account: "Income:Salary", alias: "工资", label: "工资", amount: 4_800_000, children: [], depth: 0, txCount: 1),
                LedgerIncomeNode(account: "Income:Reimbursement", alias: "报销", label: "报销", amount: 250_000, children: [], depth: 0, txCount: 1),
            ],
            expense: [
                LedgerIncomeNode(account: "Expenses:Housing", alias: "居住", label: "居住", amount: 380_000, children: [], depth: 0, txCount: 1),
                LedgerIncomeNode(account: "Expenses:Food", alias: "餐饮", label: "餐饮", amount: 84_780, children: [], depth: 0, txCount: 3),
                LedgerIncomeNode(account: "Expenses:Travel", alias: "出行", label: "出行", amount: 57_600, children: [], depth: 0, txCount: 1),
                LedgerIncomeNode(account: "Expenses:Education", alias: "教育", label: "教育", amount: 32_800, children: [], depth: 0, txCount: 1),
            ],
            totalIncome: 5_050_000,
            totalExpense: 555_180,
            netIncome: 4_494_820,
            valuationCurrency: "CNY"
        )
    }

    static let investments = LedgerInvestmentSummary(
        totalMarketValueCny: 123_456_789,
        realizedPnlCny: 286_400,
        holdings: [
            LedgerInvestmentHolding(commodity: "VT", commodityName: "全球股票指数", totalQuantity: 823.47, averageCost: 108.34, totalCostValueCny: 58_270_000, totalMarketValueCny: 67_850_000, accountCount: 2, realizedPnlCny: 186_400),
            LedgerInvestmentHolding(commodity: "BND", commodityName: "全球债券指数", totalQuantity: 695.18, averageCost: 71.42, totalCostValueCny: 35_480_000, totalMarketValueCny: 38_760_000, accountCount: 1, realizedPnlCny: 100_000),
            LedgerInvestmentHolding(commodity: "GLD", commodityName: "黄金", totalQuantity: 12.36, averageCost: 181.20, totalCostValueCny: 15_920_000, totalMarketValueCny: 16_846_789, accountCount: 1, realizedPnlCny: nil),
        ],
        positions: [],
        updatedAt: "2026-08-30T16:00:00Z"
    )

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
