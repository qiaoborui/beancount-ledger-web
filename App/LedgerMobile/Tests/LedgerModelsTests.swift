import XCTest
@testable import LedgerMobile

final class LedgerModelsTests: XCTestCase {
    func testPasskeyAssertionUsesUnpaddedBase64URLWebAuthnJSON() throws {
        let assertion = PasskeyAssertion(
            credentialID: Data([0xFB, 0xFF]),
            clientDataJSON: Data([0x01, 0x02]),
            authenticatorData: Data([0x03]),
            signature: Data([0x04]),
            userHandle: Data()
        )

        let data = try JSONEncoder().encode(assertion)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, "-_8")
        XCTAssertEqual(json["rawId"] as? String, "-_8")
        XCTAssertEqual(json["type"] as? String, "public-key")
        let response = try XCTUnwrap(json["response"] as? [String: Any])
        XCTAssertEqual(response["clientDataJSON"] as? String, "AQI")
        XCTAssertEqual(response["authenticatorData"] as? String, "Aw")
        XCTAssertEqual(response["signature"] as? String, "BA")
        XCTAssertNil(response["userHandle"])
        XCTAssertEqual(Data(base64URLEncoded: "-_8"), Data([0xFB, 0xFF]))
    }

    func testNativePasskeyPreparationPinsRelyingPartyAndDecodesCredentialIDs() throws {
        let options = PasskeyRequestOptions(
            challenge: "AQID",
            relyingPartyID: "beancount.borry.org",
            allowCredentials: [
                PasskeyCredentialDescriptor(type: "public-key", id: "BAUG", transports: ["internal"]),
            ]
        )

        let prepared = try options.preparedForNativeAuthentication(relyingPartyID: "beancount.borry.org")
        XCTAssertEqual(prepared.challenge, Data([1, 2, 3]))
        XCTAssertEqual(prepared.allowedCredentialIDs, [Data([4, 5, 6])])
        XCTAssertThrowsError(try options.preparedForNativeAuthentication(relyingPartyID: "mesh.example")) { error in
            XCTAssertEqual(
                error as? PasskeyAuthenticationError,
                .relyingPartyMismatch(expected: "mesh.example", received: "beancount.borry.org")
            )
        }
    }

    func testServerOriginNormalizationAddsHTTPS() throws {
        let url = try ServerConfiguration.normalize("ledger.mesh.arpa/")
        XCTAssertEqual(url.absoluteString, "https://ledger.mesh.arpa")
    }

    func testServerOriginRejectsHTTPAndPaths() {
        XCTAssertThrowsError(try ServerConfiguration.normalize("http://ledger.example.com")) { error in
            XCTAssertEqual(error as? ServerConfigurationError, .requiresHTTPS)
        }
        XCTAssertThrowsError(try ServerConfiguration.normalize("https://ledger.example.com/private")) { error in
            XCTAssertEqual(error as? ServerConfigurationError, .originOnly)
        }
    }

    func testBootstrapDecodingBuildsBalanceSheetAndSections() throws {
        let payload = try JSONDecoder().decode(LedgerBootstrap.self, from: Data(Self.bootstrapJSON.utf8))

        XCTAssertEqual(payload.summary.net, 315_000)
        XCTAssertEqual(payload.comparisons?.income.monthOverMonth.delta, 20_000)
        XCTAssertEqual(payload.comparisons?.income.yearOverYear.percentage, 0.5)
        XCTAssertEqual(payload.comparisons?.expense.monthOverMonth.delta, -1_000)
        XCTAssertNil(payload.comparisons?.expense.yearOverYear.percentage)
        XCTAssertNil(payload.comparisons?.totalAssets)
        XCTAssertEqual(
            payload.balanceSheetTotals,
            BalanceSheetTotals(assets: 1_235_000, liabilities: 235_000, netWorth: 1_000_000)
        )
        XCTAssertEqual(payload.accountSections.map(\.title), ["现金与支付", "信用账户"])
        XCTAssertEqual(payload.accountSections.first?.rows.first?.label, "日常账户")
        XCTAssertEqual(payload.transactions.first?.source.gitSHA, "abc123")
        XCTAssertEqual(payload.commodities, ["CNY", "USD"])
        XCTAssertEqual(payload.prices.first, LedgerPrice(date: "2026-08-20", currency: "USD", amount: 713, quoteCurrency: "CNY"))
    }

    func testCurrencyAnalysisMatchesWebDirectInverseBridgeAndMissingRates() {
        let prices = [
            LedgerPrice(date: "2026-07-31", currency: "USD", amount: 720, quoteCurrency: "CNY"),
            LedgerPrice(date: "2026-08-29", currency: "USD", amount: 713, quoteCurrency: "CNY"),
            LedgerPrice(date: "2026-07-31", currency: "EUR", amount: 780, quoteCurrency: "CNY"),
            LedgerPrice(date: "2026-08-29", currency: "EUR", amount: 776, quoteCurrency: "CNY"),
            LedgerPrice(date: "2026-08-29", currency: "QQQ", amount: 41_825, quoteCurrency: "USD"),
        ]

        let direct = CurrencyAnalysis.latestRate(currency: "USD", targetCurrency: "CNY", prices: prices)
        XCTAssertEqual(direct?.source, .direct)
        XCTAssertEqual(direct?.rate ?? 0, 7.13, accuracy: 0.000_001)

        let inverse = CurrencyAnalysis.latestRate(currency: "CNY", targetCurrency: "USD", prices: prices)
        XCTAssertEqual(inverse?.source, .inverse)
        XCTAssertEqual(inverse?.rate ?? 0, 1 / 7.13, accuracy: 0.000_001)

        let bridge = CurrencyAnalysis.latestRate(currency: "EUR", targetCurrency: "USD", prices: prices)
        XCTAssertEqual(bridge?.source, .bridge)
        XCTAssertEqual(bridge?.rate ?? 0, 7.76 / 7.13, accuracy: 0.000_001)
        XCTAssertNil(CurrencyAnalysis.latestRate(currency: "GBP", targetCurrency: "USD", prices: prices))

        let history = CurrencyAnalysis.rateHistory(currency: "EUR", targetCurrency: "USD", prices: prices)
        XCTAssertEqual(history.map(\.date), ["2026-07-31", "2026-08-29"])
        XCTAssertEqual(history.last?.rate ?? 0, 7.76 / 7.13, accuracy: 0.000_001)

        let universe = CurrencyAnalysis.currencyUniverse(
            commodities: ["CNY", "USD", "EUR", "GBP", "QQQ"],
            prices: prices,
            balances: [],
            accounts: [],
            valuationCurrency: "USD"
        )
        XCTAssertEqual(universe.first, "USD")
        XCTAssertTrue(universe.contains("GBP"))
        XCTAssertFalse(universe.contains("QQQ"))
    }

    func testCurrencyHistorySamplesLedgerPriceDatesAndBoundsSeriesToNinetyPoints() {
        var prices = (1...200).map { index in
            LedgerPrice(
                date: String(format: "2026-%03d", index),
                currency: "QQQ",
                amount: 40_000 + index,
                quoteCurrency: "USD"
            )
        }
        prices.append(contentsOf: [
            LedgerPrice(date: "2025-07-31", currency: "USD", amount: 720, quoteCurrency: "CNY"),
            LedgerPrice(date: "2025-07-31", currency: "EUR", amount: 780, quoteCurrency: "CNY"),
            LedgerPrice(date: "2025-08-31", currency: "USD", amount: 713, quoteCurrency: "CNY"),
            LedgerPrice(date: "2025-08-31", currency: "EUR", amount: 776, quoteCurrency: "CNY"),
        ])

        let bridgeHistory = CurrencyAnalysis.rateHistory(
            currency: "EUR",
            targetCurrency: "USD",
            prices: prices
        )
        XCTAssertEqual(bridgeHistory.count, 90)
        XCTAssertEqual(bridgeHistory.first?.date, "2026-111")
        XCTAssertEqual(bridgeHistory.last?.date, "2026-200")
        XCTAssertEqual(bridgeHistory.first?.rate ?? 0, 7.76 / 7.13, accuracy: 0.000_001)
        XCTAssertEqual(bridgeHistory.last?.rate ?? 0, 7.76 / 7.13, accuracy: 0.000_001)

        let baseHistory = CurrencyAnalysis.rateHistory(
            currency: "USD",
            targetCurrency: "USD",
            prices: prices
        )
        XCTAssertEqual(baseHistory.count, 90)
        XCTAssertEqual(baseHistory.last?.date, "2026-200")
    }

    func testTransactionIdentityIncludesSourceLocationForDuplicateHashes() throws {
        let payload = try JSONDecoder().decode(LedgerBootstrap.self, from: Data(Self.bootstrapJSON.utf8))
        let transaction = try XCTUnwrap(payload.transactions.first)
        let duplicateAtAnotherLine = LedgerTransaction(
            date: transaction.date,
            payee: transaction.payee,
            narration: transaction.narration,
            tags: transaction.tags,
            postings: transaction.postings,
            source: TransactionSource(
                file: transaction.source.file,
                line: transaction.source.line + 10,
                hash: transaction.source.hash,
                gitSHA: transaction.source.gitSHA
            )
        )

        XCTAssertNotEqual(transaction.id, duplicateAtAnotherLine.id)
    }

    func testHealthCompatibilityRequiresExpectedVersionAndCapabilities() throws {
        XCTAssertNoThrow(
            try HealthStatus(apiVersion: 1, capabilities: ["cookie-auth", "full-backend"]).validateForMobileClient()
        )
        XCTAssertThrowsError(
            try HealthStatus(apiVersion: 2, capabilities: ["cookie-auth", "full-backend"]).validateForMobileClient()
        )
        XCTAssertThrowsError(
            try HealthStatus(apiVersion: 1, capabilities: ["cookie-auth"]).validateForMobileClient()
        )
    }

    func testTransactionPresentationClassifiesExpenseAndIncome() throws {
        let payload = try JSONDecoder().decode(LedgerBootstrap.self, from: Data(Self.bootstrapJSON.utf8))
        let expense = TransactionPresentation(transaction: payload.transactions[0])
        let income = TransactionPresentation(transaction: payload.transactions[1])

        XCTAssertEqual(expense.kind, .expense)
        XCTAssertEqual(expense.minorUnits, 8_500)
        XCTAssertEqual(expense.title, "海底捞")
        XCTAssertEqual(income.kind, .income)
        XCTAssertEqual(income.minorUnits, 400_000)
    }

    func testTransactionFilterMatchesWordsKindAccountAndTags() throws {
        let payload = try JSONDecoder().decode(LedgerBootstrap.self, from: Data(Self.bootstrapJSON.utf8))
        let expense = payload.transactions[0]
        let income = payload.transactions[1]

        XCTAssertTrue(LedgerTransactionFilter(query: "海底 晚餐").matches(expense))
        XCTAssertTrue(LedgerTransactionFilter(query: "#dining").matches(expense))
        XCTAssertFalse(LedgerTransactionFilter(query: "不存在").matches(expense))
        XCTAssertTrue(LedgerTransactionFilter(kind: .expense).matches(expense))
        XCTAssertFalse(LedgerTransactionFilter(kind: .income).matches(expense))
        XCTAssertTrue(LedgerTransactionFilter(account: "Assets:Bank:Daily").matches(income))
        XCTAssertFalse(LedgerTransactionFilter(account: "Liabilities:CreditCard:Visa").matches(income))
    }

    func testCompactMoneyUsesChineseAndInternationalUnits() {
        XCTAssertEqual(MoneyText.formatCompact(minorUnits: 999_999, currency: "CNY"), "¥9,999.99")
        XCTAssertEqual(MoneyText.formatCompact(minorUnits: 1_234_567, currency: "CNY"), "¥1.2w")
        XCTAssertEqual(MoneyText.formatCompact(minorUnits: 12_345_678_900, currency: "CNY"), "¥1.2亿")
        XCTAssertEqual(MoneyText.formatCompact(minorUnits: 1_234_567, currency: "USD"), "$12.3k")
        XCTAssertEqual(MoneyText.formatCompact(minorUnits: -1_234_567, currency: "CNY"), "-¥1.2w")
    }

    func testMonthRangeShiftKeepsInclusiveCalendarBounds() {
        let august = LedgerDateRange.month(year: 2026, month: 8)
        let july = august.shifted(by: -1)
        let september = august.shifted(by: 1)

        XCTAssertEqual(august.start, "2026-08-01")
        XCTAssertEqual(august.end, "2026-08-31")
        XCTAssertEqual(july.start, "2026-07-01")
        XCTAssertEqual(july.end, "2026-07-31")
        XCTAssertEqual(september.start, "2026-09-01")
        XCTAssertEqual(september.end, "2026-09-30")
        XCTAssertEqual(august.queryEndExclusive, "2026-09-01")
        XCTAssertEqual(july.queryEndExclusive, "2026-08-01")
    }

    func testBQLDynamicCellsDecodeAllJSONShapesAndNullCollections() throws {
        let json = #"""
        {
          "columns":null,
          "rows":[[null,true,12.5,"text",["a",2],{"tag":"food"}]],
          "query":"SELECT * FROM transactions",
          "warnings":null,
          "valuationCurrency":"CNY",
          "limit":100,
          "rowCount":1
        }
        """#
        let result = try JSONDecoder().decode(BQLResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.columns, [])
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(
            result.rows[0],
            [.null, .bool(true), .number(12.5), .string("text"), .array([.string("a"), .number(2)]), .object(["tag": .string("food")])]
        )
    }

    func testBQLStatementSplitterKeepsQuotedSemicolonsAndEscapes() {
        let raw = "SELECT payee FROM transactions WHERE narration = '午餐;咖啡'; SELECT account FROM postings WHERE account = \"Assets:\\\"Daily\";"

        XCTAssertEqual(
            BQLStatements.split(raw),
            [
                "SELECT payee FROM transactions WHERE narration = '午餐;咖啡'",
                "SELECT account FROM postings WHERE account = \"Assets:\\\"Daily\"",
            ]
        )
    }

    func testBQLHistoryMergePreservesChangesMadeWhileLoading() {
        let original = Self.bqlHistoryRecord(id: "existing", title: "旧标题", lastRunAt: "2026-08-01T00:00:00Z")
        let stale = Self.bqlHistoryRecord(id: "existing", title: "旧标题", lastRunAt: "2026-08-01T00:00:00Z")
        let renamed = Self.bqlHistoryRecord(id: "existing", title: "新标题", lastRunAt: "2026-08-01T00:00:00Z")
        let saved = Self.bqlHistoryRecord(id: "saved", title: "刚保存", lastRunAt: "2026-08-02T00:00:00Z")

        let merged = BQLHistoryMerge.reconcile(
            loaded: [
                stale,
                Self.bqlHistoryRecord(id: "existing", title: "重复旧标题", lastRunAt: "2026-08-01T00:00:00Z"),
                Self.bqlHistoryRecord(id: "deleted", title: "待删除", lastRunAt: "2026-07-31T00:00:00Z"),
            ],
            snapshot: [original, Self.bqlHistoryRecord(id: "deleted", title: "待删除", lastRunAt: "2026-07-31T00:00:00Z")],
            current: [renamed, saved]
        )

        XCTAssertEqual(Set(merged.map(\.id)), ["existing", "saved"])
        XCTAssertEqual(merged.first(where: { $0.id == "existing" })?.title, "新标题")
    }

    private static func bqlHistoryRecord(id: String, title: String, lastRunAt: String) -> BQLHistoryRecord {
        BQLHistoryRecord(
            id: id,
            query: "SELECT * FROM transactions",
            title: title,
            titleSource: "manual",
            createdAt: "2026-08-01T00:00:00Z",
            lastRunAt: lastRunAt,
            runCount: 1
        )
    }

    static let bootstrapJSON = #"""
    {
      "start": "2026-08-01",
      "end": "2026-08-31",
      "summary": { "currency": "CNY", "income": 400000, "expense": 85000, "net": 315000 },
      "comparisons": {
        "income": {
          "monthOverMonth": {
            "currentRange": { "start": "2026-08-01", "end": "2026-08-31" },
            "baselineRange": { "start": "2026-07-01", "end": "2026-07-31" },
            "current": 400000, "baseline": 380000, "delta": 20000, "percentage": 0.0526315789
          },
          "yearOverYear": {
            "currentRange": { "start": "2026-08-01", "end": "2026-08-31" },
            "baselineRange": { "start": "2025-08-01", "end": "2025-08-31" },
            "current": 400000, "baseline": 266667, "delta": 133333, "percentage": 0.5
          }
        },
        "expense": {
          "monthOverMonth": {
            "currentRange": { "start": "2026-08-01", "end": "2026-08-31" },
            "baselineRange": { "start": "2026-07-01", "end": "2026-07-31" },
            "current": 85000, "baseline": 86000, "delta": -1000, "percentage": -0.011627907
          },
          "yearOverYear": {
            "currentRange": { "start": "2026-08-01", "end": "2026-08-31" },
            "baselineRange": { "start": "2025-08-01", "end": "2025-08-31" },
            "current": 85000, "baseline": 0, "delta": 85000, "percentage": null
          }
        },
        "totalAssets": null
      },
      "accountBalances": [
        { "account": "Assets:Bank:Daily", "currency": "CNY", "amount": 1235000, "valuationCurrency": "CNY", "valuation": 1235000 },
        { "account": "Liabilities:CreditCard:Visa", "currency": "CNY", "amount": -235000, "valuationCurrency": "CNY", "valuation": -235000 }
      ],
      "transactions": [
        {
          "date": "2026-08-20", "payee": "海底捞", "narration": "晚餐", "tags": ["dining"],
          "postings": [
            { "account": "Expenses:Food:Dining", "amount": 8500, "currency": "CNY" },
            { "account": "Assets:Bank:Daily", "amount": -8500, "currency": "CNY" }
          ],
          "source": { "file": "transactions/2026/08.bean", "line": 18, "hash": "expense-hash", "gitSha": "abc123" }
        },
        {
          "date": "2026-08-10", "payee": "Huya", "narration": "工资",
          "postings": [
            { "account": "Income:Salary", "amount": -400000, "currency": "CNY" },
            { "account": "Assets:Bank:Daily", "amount": 400000, "currency": "CNY" }
          ],
          "source": { "file": "transactions/2026/08.bean", "line": 4 }
        }
      ],
      "accounts": [
        { "account": "Assets:Bank:Daily", "openDate": "2024-01-01", "closeDate": null, "currency": "CNY", "alias": "日常账户/银行卡", "label": "日常账户", "group": "cash", "active": true },
        { "account": "Liabilities:CreditCard:Visa", "openDate": "2024-01-01", "closeDate": null, "currency": "CNY", "alias": "Visa", "label": "Visa", "group": "credit", "active": true }
      ],
      "commodities": ["CNY", "USD"],
      "prices": [
        { "date": "2026-08-20", "currency": "USD", "amount": 713, "quoteCurrency": "CNY" }
      ],
      "valuationCurrency": "CNY",
      "sensitiveUnlocked": true
    }
    """#

    static let accountDetailJSON = #"""
    {
      "account": "Assets:Bank:Daily",
      "label": "日常账户",
      "alias": "日常账户/银行卡",
      "group": "cash",
      "active": true,
      "currency": "CNY",
      "currentBalance": 1235000,
      "rows": [
        {
          "date": "2026-08-20",
          "payee": "海底捞",
          "narration": "晚餐",
          "change": -8500,
          "balance": 1235000,
          "txn": {
            "date": "2026-08-20",
            "payee": "海底捞",
            "narration": "晚餐",
            "postings": [
              { "account": "Expenses:Food:Dining", "amount": 8500, "currency": "CNY" },
              { "account": "Assets:Bank:Daily", "amount": -8500, "currency": "CNY" }
            ],
            "source": { "file": "transactions/2026/08.bean", "line": 18 }
          }
        }
      ]
    }
    """#
}
