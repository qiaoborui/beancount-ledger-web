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
        XCTAssertEqual(
            payload.balanceSheetTotals,
            BalanceSheetTotals(assets: 1_235_000, liabilities: 235_000, netWorth: 1_000_000)
        )
        XCTAssertEqual(payload.accountSections.map(\.title), ["现金与支付", "信用账户"])
        XCTAssertEqual(payload.accountSections.first?.rows.first?.label, "日常账户")
        XCTAssertEqual(payload.transactions.first?.source.gitSHA, "abc123")
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
    }

    static let bootstrapJSON = #"""
    {
      "start": "2026-08-01",
      "end": "2026-08-31",
      "summary": { "currency": "CNY", "income": 400000, "expense": 85000, "net": 315000 },
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
      "valuationCurrency": "CNY",
      "sensitiveUnlocked": true
    }
    """#
}
