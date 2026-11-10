import XCTest
@testable import LedgerMobile

final class CookieFastTransactionEditorTests: XCTestCase {

    func testCalculatorBasicOperations() {
        var calc = CookieKeypadCalculator()
        calc.appendDigit("1")
        calc.appendDigit("2")
        calc.appendDigit(".")
        calc.appendDigit("5")
        XCTAssertEqual(calc.displayText, "12.5")
        XCTAssertEqual(calc.evaluatedResult, Decimal(string: "12.5"))

        calc.appendOperator("+")
        calc.appendDigit("7")
        calc.appendDigit(".")
        calc.appendDigit("5")
        XCTAssertEqual(calc.displayText, "12.5+7.5")
        XCTAssertEqual(calc.evaluatedResult, Decimal(20))

        calc.evaluateToResult()
        XCTAssertEqual(calc.displayText, "20")
    }

    func testCalculatorDeleteAndClear() {
        var calc = CookieKeypadCalculator()
        calc.appendDigit("5")
        calc.appendDigit("0")
        calc.deleteLast()
        XCTAssertEqual(calc.displayText, "5")

        calc.clear()
        XCTAssertEqual(calc.displayText, "0")
    }

    func testCurrencySymbols() {
        XCTAssertEqual(CookieFastTransactionEditorBody.currencySymbol(for: "CNY"), "¥")
        XCTAssertEqual(CookieFastTransactionEditorBody.currencySymbol(for: "USD"), "$")
        XCTAssertEqual(CookieFastTransactionEditorBody.currencySymbol(for: "EUR"), "€")
        XCTAssertEqual(CookieFastTransactionEditorBody.currencySymbol(for: "GBP"), "£")
        XCTAssertEqual(CookieFastTransactionEditorBody.currencySymbol(for: "HKD"), "HK$")
        XCTAssertEqual(CookieFastTransactionEditorBody.currencySymbol(for: "JPY"), "¥")
        XCTAssertEqual(CookieFastTransactionEditorBody.currencySymbol(for: "CAD"), "CAD")
    }

    func testDefaultCategories() {
        let expenses = CookieCategoryItem.expenseCategories
        XCTAssertFalse(expenses.isEmpty)
        XCTAssertTrue(expenses.contains(where: { $0.id == "food" }))
        XCTAssertTrue(expenses.contains(where: { $0.id == "transport" }))

        let incomes = CookieCategoryItem.incomeCategories
        XCTAssertFalse(incomes.isEmpty)
        XCTAssertTrue(incomes.contains(where: { $0.id == "salary" }))
        XCTAssertTrue(incomes.contains(where: { $0.id == "bonus" }))
    }

    func testCategoryNamesDoNotOverlapWithValidMerchants() {
        let expenseNames = Set(CookieCategoryItem.expenseCategories.map(\.name))
        let incomeNames = Set(CookieCategoryItem.incomeCategories.map(\.name))

        XCTAssertTrue(expenseNames.contains("餐饮"))
        XCTAssertTrue(expenseNames.contains("交通"))
        XCTAssertTrue(incomeNames.contains("工资薪水"))

        // Verify that standard category names are identified as categories so they won't be confused with merchants
        let sampleCategoryPayee = "餐饮"
        let isKnownCategory = expenseNames.contains(sampleCategoryPayee) || incomeNames.contains(sampleCategoryPayee)
        XCTAssertTrue(isKnownCategory)

        let realMerchant = "麦当劳"
        let isRealMerchantCategory = expenseNames.contains(realMerchant) || incomeNames.contains(realMerchant)
        XCTAssertFalse(isRealMerchantCategory)
    }

    func testFundingMemoryRestoresOnlyAccountsStillInTheLedger() throws {
        let suite = "CookieFundingMemoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(CookieFundingMemory.load(validAccounts: ["Assets:Alipay"], defaults: defaults))

        CookieFundingMemory.save("Liabilities:CreditCard:CMB", defaults: defaults)
        XCTAssertEqual(
            CookieFundingMemory.load(validAccounts: ["Assets:Alipay", "Liabilities:CreditCard:CMB"], defaults: defaults),
            "Liabilities:CreditCard:CMB"
        )
        // A closed or renamed account falls back to the editor's own default.
        XCTAssertNil(CookieFundingMemory.load(validAccounts: ["Assets:Alipay"], defaults: defaults))

        CookieFundingMemory.save("", defaults: defaults)
        XCTAssertEqual(
            CookieFundingMemory.load(validAccounts: ["Liabilities:CreditCard:CMB"], defaults: defaults),
            "Liabilities:CreditCard:CMB"
        )
    }

    func testDefaultCurrencyNeverPicksASortedTicker() {
        let commodities = ["AAPL", "CNY", "TSLA", "USD"]
        XCTAssertEqual(TransactionEditorView.defaultCurrency(valuation: "USD", commodities: commodities), "USD")
        XCTAssertEqual(TransactionEditorView.defaultCurrency(valuation: nil, commodities: commodities), "CNY")
        XCTAssertEqual(TransactionEditorView.defaultCurrency(valuation: "", commodities: ["AAPL", "HKD"]), "HKD")
        XCTAssertEqual(TransactionEditorView.defaultCurrency(valuation: nil, commodities: ["AAPL"]), "CNY")
    }

    func testPendingExpressionIsEvaluatedBeforeLeavingTheKeypad() {
        var calc = CookieKeypadCalculator()
        for key in ["5", "0"] { calc.appendDigit(key) }
        calc.appendOperator("-")
        for key in ["2", "0"] { calc.appendDigit(key) }
        // The expression is still pending; stripping "-" would give 5020.
        XCTAssertEqual(calc.displayText, "50-20")
        XCTAssertEqual(calc.committedMagnitudeText, "30")

        calc.appendOperator("+")
        XCTAssertEqual(calc.committedMagnitudeText, "30")

        var plain = CookieKeypadCalculator()
        for key in ["1", "2", ".", "5", "0"] { plain.appendDigit(key) }
        XCTAssertEqual(plain.committedMagnitudeText, "12.50")
    }

    func testFastEditorDeclinesEntriesItWouldRewrite() {
        func posting(_ account: String, _ amount: String, _ currency: String = "CNY") -> EditableTransactionPosting {
            EditableTransactionPosting(account: account, amount: amount, currency: currency)
        }
        // Ordinary expense, income and transfer, including an elided amount.
        XCTAssertTrue(TransactionEditorView.fastEditorRepresents([posting("Expenses:Food", "30"), posting("Assets:Alipay", "-30")]))
        XCTAssertTrue(TransactionEditorView.fastEditorRepresents([posting("Assets:Alipay", "-30"), posting("Expenses:Food", "", "")]))
        XCTAssertTrue(TransactionEditorView.fastEditorRepresents([posting("Income:Salary", "-100"), posting("Assets:Bank", "100")]))
        XCTAssertTrue(TransactionEditorView.fastEditorRepresents([posting("Assets:Bank", "-5"), posting("Assets:Alipay", "5")]))
        XCTAssertTrue(TransactionEditorView.fastEditorRepresents([posting("Expenses:Food", "12.500"), posting("Assets:Alipay", "-12.500")]))
        XCTAssertTrue(TransactionEditorView.fastEditorRepresents([]))

        // A refund and a reversed income would flip direction on save.
        XCTAssertFalse(TransactionEditorView.fastEditorRepresents([posting("Expenses:Food", "-30"), posting("Assets:Alipay", "30")]))
        XCTAssertFalse(TransactionEditorView.fastEditorRepresents([posting("Assets:Alipay", "30"), posting("Expenses:Food", "", "")]))
        XCTAssertFalse(TransactionEditorView.fastEditorRepresents([posting("Income:Salary", "100"), posting("Assets:Bank", "-100")]))
        // The keypad keeps two decimals and one currency.
        XCTAssertFalse(TransactionEditorView.fastEditorRepresents([posting("Expenses:Food", "1.234"), posting("Assets:Alipay", "-1.234")]))
        XCTAssertFalse(TransactionEditorView.fastEditorRepresents([posting("Assets:Broker", "0.5", "BTC"), posting("Assets:Bank", "-30000")]))
        XCTAssertFalse(TransactionEditorView.fastEditorRepresents([
            posting("Expenses:Food", "10"), posting("Expenses:Fun", "20"), posting("Assets:Bank", "", "")
        ]))
        XCTAssertFalse(TransactionEditorView.fastEditorRepresents([
            EditableTransactionPosting(account: "Assets:Broker", amount: "2", currency: "AAPL",
                                       costKind: "per", costAmount: "150", costCurrency: "USD"),
            posting("Assets:Bank", "-300", "USD")
        ]))
    }

    func testPostingMatchingFollowsAccountsThenTheOneLeftOver() {
        XCTAssertEqual(
            TransactionEditorView.matchedPostingIndices(
                newAccounts: ["Expenses:Food", "Assets:Alipay"], originalAccounts: ["Assets:Alipay", "Expenses:Food"]),
            [1, 0])
        // A changed category still continues the original expense posting.
        XCTAssertEqual(
            TransactionEditorView.matchedPostingIndices(
                newAccounts: ["Expenses:Transport", "Assets:Alipay"], originalAccounts: ["Expenses:Food", "Assets:Alipay"]),
            [0, 1])
        XCTAssertEqual(
            TransactionEditorView.matchedPostingIndices(
                newAccounts: ["Expenses:Transport", "Assets:Bank"], originalAccounts: ["Expenses:Food", "Assets:Alipay"]),
            [nil, nil])
        XCTAssertEqual(
            TransactionEditorView.matchedPostingIndices(newAccounts: ["Expenses:Food", "Assets:Alipay"], originalAccounts: []),
            [nil, nil])
    }

    func testDuplicateCopiesExactAmountsCostAndTagsButNotFlags() {
        let entry = LedgerTransactionEntry(
            date: "2026-11-01",
            flag: "!",
            narration: "买入",
            metadata: ["orderId": .string("A1")],
            tags: ["invest"],
            links: ["trade-1"],
            postings: [
                LedgerTransactionEntryPosting(account: "Assets:Broker", flag: "!", amount: "0.125", currency: "BTC",
                                              costKind: "per", costAmount: "40000", costCurrency: "USD"),
                LedgerTransactionEntryPosting(account: "Assets:Bank", amount: "-5000", currency: "USD")
            ]
        )
        let transaction = LedgerTransaction(
            date: "2026-11-01", payee: "", narration: "买入", tags: ["invest"],
            postings: [LedgerPosting(account: "Assets:Broker", amount: 13, currency: "BTC"),
                       LedgerPosting(account: "Assets:Bank", amount: -500000, currency: "USD")],
            editableEntry: entry,
            source: TransactionSource(file: "transactions/2026/11.bean", line: 1)
        )
        let postings = TransactionEditorView.duplicatePostings(of: transaction)
        XCTAssertEqual(postings.map(\.amount), ["0.125", "-5000"])
        XCTAssertEqual(postings.first?.costKind, "per")
        XCTAssertEqual(postings.first?.costAmount, "40000")
        XCTAssertNil(postings.first?.flag)
        XCTAssertEqual(TransactionEditorView.duplicateTags(of: transaction), ["invest"])
        XCTAssertFalse(TransactionEditorView.fastEditorRepresents(postings))

        // Without an editable entry the two-decimal projection is all there is.
        let projected = LedgerTransaction(
            date: "2026-11-01", payee: "店", narration: "午饭",
            postings: [LedgerPosting(account: "Expenses:Food", amount: 3000, currency: "CNY"),
                       LedgerPosting(account: "Assets:Alipay", amount: -3000, currency: nil)],
            source: TransactionSource(file: "transactions/2026/11.bean", line: 9)
        )
        XCTAssertEqual(TransactionEditorView.duplicatePostings(of: projected).map(\.amount), ["30.00", "-30.00"])
        XCTAssertEqual(TransactionEditorView.duplicatePostings(of: projected).map(\.currency), ["CNY", "CNY"])
        XCTAssertEqual(TransactionEditorView.duplicateTags(of: projected), [])
    }
}
