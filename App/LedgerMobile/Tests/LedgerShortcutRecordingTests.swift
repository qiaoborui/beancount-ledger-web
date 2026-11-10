import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerShortcutRecordingTests: XCTestCase {
    private typealias Builder = LedgerShortcutEntryBuilder
    private static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    /// 2026-11-10 12:00 in Shanghai.
    private static let day = ISO8601DateFormatter().date(from: "2026-11-10T04:00:00Z")!

    private static func account(_ path: String, _ label: String, currency: String = "", active: Bool = true,
                                open: String = "2024-01-01") -> LedgerAccount {
        LedgerAccount(account: path, openDate: open, closeDate: active ? nil : "2025-01-01", currency: currency,
            alias: nil, label: label, group: "", active: active)
    }

    private static let accounts: [LedgerAccount] = [
        account("Expenses:Food:Coffee", "咖啡"),
        account("Expenses:Transport", "交通"),
        account("Income:Salary", "工资"),
        account("Assets:WeChat", "微信", currency: "CNY"),
        account("Assets:Bank:CMB", "招行储蓄卡", currency: "CNY"),
        account("Liabilities:CreditCard:CMB", "招行信用卡", currency: "CNY"),
        account("Assets:Old", "旧账户", active: false),
    ]

    private static func context(accounts: [LedgerAccount] = accounts, valuation: String = "CNY",
                                history: [LedgerTransaction] = [], remembered: String? = nil,
                                commodities: [String] = ["CNY", "USD"]) -> Builder.Context {
        .init(accounts: accounts, commodities: commodities, valuationCurrency: valuation, history: history,
              rememberedFunding: remembered, timeZone: shanghai)
    }

    private static func request(_ amount: Decimal = Decimal(string: "35.8")!, payee: String? = "星巴克",
                                narration: String? = nil, category: String? = nil, funding: String? = nil,
                                currency: String? = nil, tags: [String] = [], key: String? = nil) -> LedgerShortcutRecordRequest {
        .init(amount: amount, payee: payee, narration: narration, categoryAccount: category, fundingAccount: funding,
              date: day, currency: currency, tags: tags, idempotencyKey: key)
    }

    private func assertError(_ expected: LedgerShortcutRecordingError, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? LedgerShortcutRecordingError, expected, file: file, line: line)
        }
    }

    // MARK: Builder

    func testExpenseEntryIsFlaggedWithSourceMetadataPostingsAndDate() throws {
        let built = try Builder.build(Self.request(category: "Expenses:Food:Coffee", funding: "Assets:WeChat", key: "wallet-1"),
            context: Self.context())
        XCTAssertEqual(built.entry.flag, "!")
        XCTAssertEqual(built.entry.date, "2026-11-10")
        XCTAssertEqual(built.entry.payee, "星巴克")
        XCTAssertEqual(built.entry.narration, "")
        XCTAssertEqual(built.entry.metadata, ["source": .string("shortcuts"), "shortcut_id": .string("wallet-1")])
        XCTAssertEqual(built.entry.postings, [
            .init(account: "Expenses:Food:Coffee", amount: "35.8", currency: "CNY"),
            .init(account: "Assets:WeChat", amount: "-35.8", currency: "CNY"),
        ])
        XCTAssertFalse(built.isIncome)
        XCTAssertTrue(built.openingAccounts.isEmpty)
        XCTAssertEqual(Builder.dialogSummary(built, amount: "35.8", timeZone: Self.shanghai), "11/10 星巴克 · 咖啡 ¥35.80 ← 微信")
        XCTAssertEqual(Builder.fallbackBeanText(built), """
            2026-11-10 ! "星巴克" ""
              shortcut_id: "wallet-1"
              source: "shortcuts"
              Expenses:Food:Coffee 35.8 CNY
              Assets:WeChat -35.8 CNY
            """)
    }

    func testIncomeCategoryFlipsSigns() throws {
        let built = try Builder.build(Self.request(Decimal(12000), payee: "公司", category: "Income:Salary",
            funding: "Assets:Bank:CMB"), context: Self.context())
        XCTAssertTrue(built.isIncome)
        XCTAssertEqual(built.entry.postings, [
            .init(account: "Assets:Bank:CMB", amount: "12000", currency: "CNY"),
            .init(account: "Income:Salary", amount: "-12000", currency: "CNY"),
        ])
        XCTAssertEqual(Builder.dialogSummary(built, amount: "12000", timeZone: Self.shanghai), "11/10 公司 · 工资 ¥12000.00 → 招行储蓄卡")
    }

    func testCategoryComesFromHistoryThenKeywordThenPlaceholder() throws {
        let history = [LedgerTransaction(date: "2026-10-01", payee: "星巴克", narration: "",
            postings: [.init(account: "Expenses:Transport", amount: 100, currency: "CNY"),
                       .init(account: "Assets:WeChat", amount: -100, currency: "CNY")],
            source: .init(file: "main.bean", line: 1))]
        let fromHistory = try Builder.build(Self.request(), context: Self.context(history: history))
        XCTAssertEqual(fromHistory.categoryAccount, "Expenses:Transport", "Payee history wins over keywords")

        let fromKeyword = try Builder.build(Self.request(), context: Self.context())
        XCTAssertEqual(fromKeyword.categoryAccount, "Expenses:Food:Coffee")

        let placeholder = try Builder.build(Self.request(payee: "Zqx"), context: Self.context())
        XCTAssertEqual(placeholder.categoryAccount, "Expenses:Uncategorized")
        XCTAssertEqual(placeholder.categoryLabel, "待分类")
        XCTAssertEqual(placeholder.openingAccounts, [LedgerAccountInput(date: "2024-01-01",
            account: "Expenses:Uncategorized", alias: "待分类", currency: "")])
    }

    func testExistingPlaceholderIsReusedWithoutOpeningAnother() throws {
        let built = try Builder.build(Self.request(payee: "Zqx"),
            context: Self.context(accounts: Self.accounts + [Self.account("Expenses:待分类", "待分类")]))
        XCTAssertEqual(built.categoryAccount, "Expenses:待分类")
        XCTAssertTrue(built.openingAccounts.isEmpty)
    }

    func testClosedUncategorizedAccountIsNotReopened() {
        let accounts = Self.accounts + [Self.account("Expenses:Uncategorized", "待分类", active: false)]
        assertError(.closedPlaceholder("Expenses:Uncategorized")) {
            _ = try Builder.build(Self.request(payee: "Zqx"), context: Self.context(accounts: accounts))
        }
    }

    func testFundingComesFromExplicitThenRememberedThenMatcher() throws {
        let explicit = try Builder.build(Self.request(funding: "Assets:Bank:CMB"),
            context: Self.context(remembered: "Liabilities:CreditCard:CMB"))
        XCTAssertEqual(explicit.fundingAccount, "Assets:Bank:CMB")
        let remembered = try Builder.build(Self.request(), context: Self.context(remembered: "Liabilities:CreditCard:CMB"))
        XCTAssertEqual(remembered.fundingAccount, "Liabilities:CreditCard:CMB")
        XCTAssertEqual(remembered.fundingLabel, "招行信用卡")
        let staleMemory = try Builder.build(Self.request(), context: Self.context(remembered: "Assets:Old"))
        XCTAssertEqual(staleMemory.fundingAccount, "Assets:WeChat", "A closed remembered account falls back to the matcher")
        let matched = try Builder.build(Self.request(narration: "招行信用卡"), context: Self.context())
        XCTAssertEqual(matched.fundingAccount, "Liabilities:CreditCard:CMB")
        let categoriesOnly = Self.accounts.filter { $0.account.hasPrefix("Expenses:") }
        assertError(.fundingRequired) { _ = try Builder.build(Self.request(), context: Self.context(accounts: categoriesOnly)) }
    }

    func testRejectsWrongTypesClosedAndUnknownAccounts() {
        assertError(.categoryNotCategory("Assets:WeChat")) {
            _ = try Builder.build(Self.request(category: "Assets:WeChat"), context: Self.context())
        }
        assertError(.fundingNotFunding("Expenses:Transport")) {
            _ = try Builder.build(Self.request(funding: "Expenses:Transport"), context: Self.context())
        }
        assertError(.unknownAccount("Assets:Old")) {
            _ = try Builder.build(Self.request(funding: "Assets:Old"), context: Self.context())
        }
        assertError(.unknownAccount("Expenses:Nope")) {
            _ = try Builder.build(Self.request(category: "Expenses:Nope"), context: Self.context())
        }
    }

    func testAmountValidation() throws {
        for invalid in [Decimal(0), Decimal(-1), Builder.maxAmount + 1, Decimal.nan] {
            assertError(.invalidAmount) { _ = try Builder.normalizedAmount(invalid) }
        }
        XCTAssertEqual(try Builder.normalizedAmount(Decimal(string: "35.8")!), "35.8")
        XCTAssertEqual(try Builder.normalizedAmount(Builder.maxAmount), "1000000000")
        XCTAssertEqual(Builder.amount(fromShortcutValue: 35.8), Decimal(string: "35.8"))
        XCTAssertEqual(Builder.amount(fromShortcutValue: 0.1 + 0.2), Decimal(string: "0.30000000000000004"))
        XCTAssertNil(Builder.amount(fromShortcutValue: .nan))
        XCTAssertNil(Builder.amount(fromShortcutValue: .infinity))
    }

    func testCurrencyOrder() throws {
        func currency(_ request: LedgerShortcutRecordRequest, _ context: Builder.Context) throws -> String {
            try Builder.build(request, context: context).currency
        }
        XCTAssertEqual(try currency(Self.request(currency: " usd "), Self.context()), "USD")
        XCTAssertEqual(try currency(Self.request(funding: "Assets:WeChat"), Self.context()), "CNY")
        let unconstrained = [Self.account("Expenses:Food:Coffee", "咖啡"), Self.account("Assets:Cash", "现金")]
        XCTAssertEqual(try currency(Self.request(), Self.context(accounts: unconstrained, valuation: "USD")), "USD")
        XCTAssertEqual(try currency(Self.request(funding: "Assets:WeChat"), Self.context(valuation: "USD")), "USD",
            "The engine reports only the first open currency, so the validator, not the builder, rejects USD")
        // `open Assets:HK HKD,USD` reaches the app as its first currency only.
        let multi = [Self.account("Expenses:Food:Coffee", "咖啡"), Self.account("Assets:HK", "香港", currency: "HKD")]
        XCTAssertEqual(try currency(Self.request(), Self.context(accounts: multi, valuation: "USD")), "USD",
            "A valuation currency that is the account's second open currency is kept")
        XCTAssertEqual(try currency(Self.request(), Self.context(accounts: multi, valuation: "")), "HKD")
        XCTAssertEqual(try currency(Self.request(), Self.context(accounts: unconstrained, valuation: "", commodities: ["AAPL", "USD"])), "USD")
        assertError(.invalidCurrency("1x")) { _ = try Builder.build(Self.request(currency: "1x"), context: Self.context()) }
    }

    func testTextNormalizationAndDefaultNarration() throws {
        XCTAssertEqual(Builder.normalizedText("  星巴克\n咖啡\t \u{0007} 大杯  "), "星巴克 咖啡 大杯")
        let long = Builder.normalizedText(String(repeating: "长", count: 300))
        XCTAssertEqual(long.count, 200)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(Builder.normalizedText(String(repeating: "短", count: 200)).count, 200)
        XCTAssertNil(Builder.normalizedKey("   "))
        XCTAssertEqual(Builder.normalizedKey(" " + String(repeating: "k", count: 200))?.count, 128)
        let built = try Builder.build(Self.request(payee: "  ", narration: "\n", funding: "Assets:WeChat"), context: Self.context())
        XCTAssertEqual(built.entry.payee, "")
        XCTAssertEqual(built.entry.narration, Builder.defaultNarration)
    }

    func testTagsGoThroughLedgerTagRules() throws {
        let built = try Builder.build(Self.request(funding: "Assets:WeChat", tags: ["#trip", "trip", "food"]), context: Self.context())
        XCTAssertEqual(built.entry.tags, ["food", "trip"])
        assertError(.invalidTags(LedgerTagValidationError.invalid("bad tag").localizedDescription)) {
            _ = try Builder.build(Self.request(tags: ["bad tag"]), context: Self.context())
        }
    }

    func testBuiltEntryLandsInNeedsReview() throws {
        let built = try Builder.build(Self.request(category: "Expenses:Food:Coffee", funding: "Assets:WeChat"),
            context: Self.context())
        let transaction = LedgerTransaction(date: built.entry.date, payee: built.entry.payee, narration: built.entry.narration,
            postings: [], editableEntry: built.entry, source: .init(file: "transactions/2026/11.bean", line: 1))
        XCTAssertTrue(PendingTransactionClassifier.evaluate(transaction).contains(.needsReviewFlag))
        let verified = transaction.entryMarkingVerified()
        XCTAssertNil(verified.flag)
        XCTAssertEqual(verified.metadata["source"], .string("shortcuts"), "Marking reviewed keeps the source")
    }

    func testDefaultCurrencyKeepsEditorBehaviour() {
        XCTAssertEqual(Builder.defaultCurrency(valuation: "JPY", commodities: ["CNY"]), "JPY")
        XCTAssertEqual(Builder.defaultCurrency(valuation: "", commodities: ["AAPL", "EUR", "USD"]), "USD")
        XCTAssertEqual(Builder.defaultCurrency(valuation: nil, commodities: ["AAPL"]), "CNY")
    }

    func testPermissionErrorsAreRecognised() {
        XCTAssertTrue(LedgerShortcutRecordingError.isPermissionDenied(POSIXError(.EPERM)))
        XCTAssertTrue(LedgerShortcutRecordingError.isPermissionDenied(NSError(domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError)))
        XCTAssertTrue(LedgerShortcutRecordingError.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: 1,
            userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES)])))
        XCTAssertFalse(LedgerShortcutRecordingError.isPermissionDenied(POSIXError(.ENOENT)))
    }

    // MARK: Idempotency store

    func testStorePrunesByAgeAndCountAndHashesKeys() throws {
        let directory = try temporaryDirectory()
        final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let store = LedgerShortcutIdempotencyStore.forLedger(root: directory, now: { clock.date })
        XCTAssertEqual(store.fileURL.lastPathComponent, ".shortcut-records.json")
        func result(_ text: String) -> LedgerShortcutRecordResult {
            .init(ledgerID: UUID(), revisionID: UUID(), beanText: text, dialogSummary: text)
        }
        try store.remember(result("old"), key: "secret-old-key")
        XCTAssertEqual(try store.lookup(key: "secret-old-key")?.beanText, "old")
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("secret-old-key"))
        XCTAssertTrue(raw.contains(LedgerShortcutIdempotencyStore.hash("secret-old-key")))

        clock.date.addTimeInterval(31 * 24 * 60 * 60)
        XCTAssertNil(try store.lookup(key: "secret-old-key"), "Expired records no longer suppress a write")
        for index in 0..<201 {
            clock.date.addTimeInterval(1)
            try store.remember(result("r\(index)"), key: "k\(index)")
        }
        XCTAssertNil(try store.lookup(key: "k0"), "Only the newest 200 are kept")
        XCTAssertEqual(try store.lookup(key: "k200")?.beanText, "r200")
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        XCTAssertEqual((decoded?["records"] as? [Any])?.count, 200)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertNil(try store.lookup(key: "k200"), "A corrupt file reads as empty")
        try store.remember(result("fresh"), key: "k200")
        XCTAssertEqual(try store.lookup(key: "k200")?.beanText, "fresh")
    }

    // MARK: Recorder

    private actor Engine: LocalLedgerEngine {
        private let accounts: [[String: Any]] = [
            ["account": "Expenses:Food:Coffee", "openDate": "2024-01-01", "currency": "", "label": "咖啡", "group": "", "active": true],
            ["account": "Expenses:Transport", "openDate": "2024-01-01", "currency": "", "label": "交通", "group": "", "active": true],
            ["account": "Income:Salary", "openDate": "2024-01-01", "currency": "", "label": "工资", "group": "", "active": true],
            ["account": "Assets:WeChat", "openDate": "2024-01-01", "currency": "CNY", "label": "微信", "group": "cash", "active": true],
            ["account": "Assets:Bank:CMB", "openDate": "2024-01-01", "currency": "CNY", "label": "招行储蓄卡", "group": "cash", "active": true],
            ["account": "Liabilities:CreditCard:CMB", "openDate": "2024-01-01", "currency": "CNY", "label": "招行信用卡", "group": "credit", "active": true],
            ["account": "Assets:Old", "openDate": "2024-01-01", "closeDate": "2025-01-01", "currency": "CNY", "label": "旧账户", "group": "cash", "active": false],
        ]
        private(set) var paths: [String] = []
        private(set) var appends: [LedgerTransactionEntry] = []
        private(set) var openings: [LedgerAccountInput] = []
        private(set) var stageRoots: [String] = []
        var omitBeanText = false
        private var onBootstrap: (@Sendable () async throws -> Void)?

        func configure(omitBeanText: Bool = false, onBootstrap: (@Sendable () async throws -> Void)? = nil) {
            self.omitBeanText = omitBeanText
            self.onBootstrap = onBootstrap
        }

        var ledgerRequests: [String] { paths.filter { $0 != "/api/ledger/version" } }

        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            paths.append(request.path)
            switch request.path {
            case "/api/ledger/version":
                return Data("{}".utf8)
            case "/api/ledger/bootstrap/page":
                let hook = onBootstrap
                onBootstrap = nil
                try await hook?()
                var bootstrap = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(LedgerModelsTests.bootstrapJSON.utf8)) as? [String: Any])
                bootstrap["start"] = request.query["start"]
                bootstrap["end"] = request.query["end"]
                bootstrap["transactions"] = []
                bootstrap["accounts"] = accounts
                return try JSONSerialization.data(withJSONObject: ["bootstrap": bootstrap,
                    "transactionPage": ["revision": "fixture", "transactions": [], "sensitiveUnlocked": true]])
            case "/api/ledger/transactions/history-page":
                let row = LedgerTransaction(date: "2026-10-01", payee: "星巴克", narration: "",
                    postings: [.init(account: "Expenses:Food:Coffee", amount: 3000, currency: "CNY"),
                               .init(account: "Assets:WeChat", amount: -3000, currency: "CNY")],
                    source: .init(file: "main.bean", line: 1))
                let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode([row]))
                return try JSONSerialization.data(withJSONObject: ["revision": "fixture", "transactions": rows,
                    "sensitiveUnlocked": true])
            case "/api/ledger/accounts":
                XCTAssertTrue(request.staging)
                openings.append(try JSONDecoder().decode(LedgerAccountInput.self, from: JSONEncoder().encode(request.body)))
                stageRoots.append(request.workspaceRoot)
                return Data(#"{"ok":true}"#.utf8)
            case "/api/ledger/append":
                XCTAssertTrue(request.staging)
                let entry = try JSONDecoder().decode(LedgerTransactionEntry.self, from: JSONEncoder().encode(request.body))
                appends.append(entry)
                stageRoots.append(request.workspaceRoot)
                let text = "\(entry.date) ! \"\(entry.payee)\" \"\(entry.narration)\"\n"
                let directory = URL(fileURLWithPath: request.workspaceRoot).appendingPathComponent("transactions")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("fixture.bean")
                let previous = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                try (previous + text).write(to: file, atomically: true, encoding: .utf8)
                if omitBeanText { return Data(#"{"ok":true}"#.utf8) }
                return try JSONSerialization.data(withJSONObject: ["ok": true, "beanText": text])
            default:
                throw LocalLedgerError.operationFailed("unexpected fixture request \(request.path)")
            }
        }
    }

    private struct Fixture {
        let catalog: LocalLedgerCatalog
        let descriptor: LocalLedgerDescriptor
        let engine: Engine
        let recorder: LedgerShortcutRecorder
        var target: LedgerShortcutTarget { .local(id: descriptor.id, valuationCurrency: "CNY") }
        var root: URL { catalog.rootDirectory.appendingPathComponent(descriptor.id.uuidString) }
        func revision() async throws -> UUID? { try await catalog.workspace(for: descriptor).currentRevision()?.id }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShortcutRecording-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func fixture(retryDelays: [Duration] = [.milliseconds(1), .milliseconds(1), .milliseconds(1)]) async throws -> Fixture {
        let engine = Engine()
        // A stage whose fixture file names INVALID fails validation, as a
        // rejected Beancount entry would.
        let catalog = LocalLedgerCatalog(rootDirectory: try temporaryDirectory(), engine: engine, validator: { root, _ in
            let file = root.appendingPathComponent("transactions/fixture.bean")
            if let text = try? String(contentsOf: file, encoding: .utf8), text.contains("INVALID") {
                throw LocalLedgerError.operationFailed("synthetic validation failure")
            }
        })
        let descriptor = try await catalog.create(name: "Shortcut fixture")
        return Fixture(catalog: catalog, descriptor: descriptor, engine: engine,
            recorder: LedgerShortcutRecorder(catalog: catalog, retryDelays: retryDelays,
                now: { Self.day }, timeZone: Self.shanghai))
    }

    private func assertRecordError(_ expected: LedgerShortcutRecordingError, file: StaticString = #filePath,
                                   line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LedgerShortcutRecordingError, expected, file: file, line: line)
        }
    }

    func testTargetGatingNeverTouchesTheEngine() async throws {
        let fixture = try await fixture()
        let before = await fixture.engine.ledgerRequests
        await assertRecordError(.remoteUnsupported) {
            _ = try await fixture.recorder.record(Self.request(), target: .none(remoteMode: true), rememberedFunding: nil)
        }
        await assertRecordError(.notEnabled) {
            _ = try await fixture.recorder.record(Self.request(), target: .none(remoteMode: false), rememberedFunding: nil)
        }
        await assertRecordError(.noLedger) {
            _ = try await fixture.recorder.record(Self.request(), target: .local(id: UUID(), valuationCurrency: "CNY"),
                rememberedFunding: nil)
        }
        let after = await fixture.engine.ledgerRequests
        XCTAssertEqual(before, after)
    }

    func testOneRecordCommitsOneRevisionAndPostsSave() async throws {
        let fixture = try await fixture()
        let before = try await fixture.revision()
        let id = fixture.descriptor.id
        let saved = expectation(forNotification: LocalLedgerRepository.didSaveNotification, object: nil) {
            $0.object as? UUID == id
        }
        let result = try await fixture.recorder.record(Self.request(category: "Expenses:Food:Coffee",
            funding: "Assets:WeChat"), target: fixture.target, rememberedFunding: nil)
        await fulfillment(of: [saved], timeout: 2)
        let after = try await fixture.catalog.workspace(for: fixture.descriptor).currentRevision()
        XCTAssertEqual(after?.id, result.revisionID)
        XCTAssertEqual(after?.parentID, before, "Exactly one generation was published")
        XCTAssertEqual(result.ledgerID, fixture.descriptor.id)
        XCTAssertEqual(result.beanText, "2026-11-10 ! \"星巴克\" \"\"")
        XCTAssertEqual(result.dialogSummary, "11/10 星巴克 · 咖啡 ¥35.80 ← 微信")
        XCTAssertFalse(result.duplicate)
        let appends = await fixture.engine.appends
        XCTAssertEqual(appends.count, 1)
        XCTAssertEqual(appends.first?.flag, "!")
        XCTAssertEqual(appends.first?.metadata["source"], .string("shortcuts"))
        let paths = await fixture.engine.ledgerRequests
        XCTAssertFalse(paths.contains("/api/ledger/transactions/history-page"), "An explicit category reads no history")
    }

    func testPlaceholderOpeningAndAppendShareOneRevision() async throws {
        let fixture = try await fixture()
        let before = try await fixture.revision()
        let result = try await fixture.recorder.record(Self.request(payee: "Zqx"), target: fixture.target,
            rememberedFunding: nil)
        let after = try await fixture.catalog.workspace(for: fixture.descriptor).currentRevision()
        XCTAssertEqual(after?.parentID, before)
        XCTAssertEqual(after?.id, result.revisionID)
        let paths = await fixture.engine.ledgerRequests.filter { $0 == "/api/ledger/accounts" || $0 == "/api/ledger/append" }
        XCTAssertEqual(paths, ["/api/ledger/accounts", "/api/ledger/append"])
        let roots = await fixture.engine.stageRoots
        XCTAssertEqual(Set(roots).count, 1, "Both operations ran on the same stage")
        let openings = await fixture.engine.openings
        XCTAssertEqual(openings.map(\.account), ["Expenses:Uncategorized"])
        XCTAssertTrue(result.dialogSummary.contains("待分类"))
    }

    func testValidationFailurePublishesNothing() async throws {
        let fixture = try await fixture()
        let before = try await fixture.revision()
        await assertRecordError(.validationFailed("synthetic validation failure")) {
            _ = try await fixture.recorder.record(Self.request(payee: "INVALID", category: "Expenses:Food:Coffee"),
                target: fixture.target, rememberedFunding: nil)
        }
        let after = try await fixture.revision()
        XCTAssertEqual(after, before)
    }

    func testIdempotencyKeyReturnsDuplicateWithoutWriting() async throws {
        let fixture = try await fixture()
        let first = try await fixture.recorder.record(Self.request(key: "wallet-42"), target: fixture.target,
            rememberedFunding: nil)
        let revision = try await fixture.revision()
        let second = try await fixture.recorder.record(Self.request(key: " wallet-42 "), target: fixture.target,
            rememberedFunding: nil)
        XCTAssertTrue(second.duplicate)
        XCTAssertEqual(second.beanText, first.beanText)
        XCTAssertEqual(second.revisionID, first.revisionID)
        let after = try await fixture.revision()
        XCTAssertEqual(after, revision)
        let appendCount = await fixture.engine.appends.count
        XCTAssertEqual(appendCount, 1)
        let file = fixture.root.appendingPathComponent(".shortcut-records.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The record file lives in the ledger root")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("wallet-42"))
    }

    func testConcurrentRecordsWithSameKeyAppendOnce() async throws {
        let fixture = try await fixture()
        let recorder = fixture.recorder, target = fixture.target
        async let one = recorder.record(Self.request(key: "same"), target: target, rememberedFunding: nil)
        async let two = recorder.record(Self.request(key: "same"), target: target, rememberedFunding: nil)
        let results = try await [one, two]
        XCTAssertEqual(results.filter(\.duplicate).count, 1)
        let appendCount = await fixture.engine.appends.count
        XCTAssertEqual(appendCount, 1)
    }

    func testStaleRevisionIsRetriedFromAFreshRead() async throws {
        let fixture = try await fixture()
        let other = fixture.catalog.repository(for: fixture.descriptor)
        let draft = try await other.readFile(path: "main.bean")
        await fixture.engine.configure(onBootstrap: {
            try await other.saveFile(draft, text: draft.text + "; concurrent synthetic edit\n")
        })
        let result = try await fixture.recorder.record(Self.request(category: "Expenses:Food:Coffee"),
            target: fixture.target, rememberedFunding: nil)
        let current = try await fixture.revision()
        XCTAssertEqual(current, result.revisionID)
        let appendCount = await fixture.engine.appends.count
        XCTAssertEqual(appendCount, 1)
        let bootstraps = await fixture.engine.ledgerRequests.filter { $0 == "/api/ledger/bootstrap/page" }.count
        XCTAssertEqual(bootstraps, 2, "The retry re-read the moved ledger")
    }

    func testBusyAfterRetriesRunOut() async throws {
        let fixture = try await fixture()
        let lock = fixture.root.appendingPathComponent(".workspace.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        let before = try await fixture.revision()
        await assertRecordError(.busy) {
            _ = try await fixture.recorder.record(Self.request(category: "Expenses:Food:Coffee"),
                target: fixture.target, rememberedFunding: nil)
        }
        let after = try await fixture.revision()
        XCTAssertEqual(after, before)
        let appendCount = await fixture.engine.appends.count
        XCTAssertEqual(appendCount, 0)
    }

    func testMissingBeanTextFallsBackToBuiltText() async throws {
        let fixture = try await fixture()
        await fixture.engine.configure(omitBeanText: true)
        let result = try await fixture.recorder.record(Self.request(category: "Expenses:Food:Coffee", funding: "Assets:WeChat"),
            target: fixture.target, rememberedFunding: nil)
        XCTAssertTrue(result.beanText.hasPrefix("2026-11-10 ! \"星巴克\" \"\"\n  source: \"shortcuts\""))
    }

    /// The app-linked engine and canonical Beancount validator, end to end.
    func testEmbeddedEngineWritesFlaggedEntryAndRejectsConstrainedCurrency() async throws {
        #if os(iOS)
        let catalog = LocalLedgerCatalog(rootDirectory: try temporaryDirectory())
        let descriptor = try await catalog.createCustom(name: "Shortcut integration",
            accounts: [.init(name: "微信", account: "Assets:WeChat", currency: "CNY")],
            categories: [.init(name: "咖啡", account: "Expenses:Food:Coffee")])
        let recorder = LedgerShortcutRecorder(catalog: catalog, now: { Self.day }, timeZone: Self.shanghai)
        let target = LedgerShortcutTarget.local(id: descriptor.id, valuationCurrency: "CNY")
        let repository = catalog.repository(for: descriptor)
        let result = try await recorder.record(Self.request(category: "Expenses:Food:Coffee", funding: "Assets:WeChat",
            key: "integration-1"), target: target, rememberedFunding: nil)
        let written = try await repository.readFile(path: "transactions/2026/11.bean").text
        XCTAssertTrue(written.contains("2026-11-10 ! \"星巴克\""), written)
        XCTAssertTrue(written.contains("source: \"shortcuts\""), written)
        XCTAssertTrue(written.contains("shortcut_id: \"integration-1\""), written)
        XCTAssertTrue(result.beanText.contains("Expenses:Food:Coffee"), result.beanText)

        let before = try await repository.workspace.currentRevision()
        do {
            _ = try await recorder.record(Self.request(category: "Expenses:Food:Coffee", funding: "Assets:WeChat",
                currency: "USD"), target: target, rememberedFunding: nil)
            XCTFail("A currency the account does not accept must not be written")
        } catch let error as LedgerShortcutRecordingError {
            guard case .validationFailed = error else { return XCTFail("Unexpected \(error)") }
        }
        let after = try await repository.workspace.currentRevision()
        XCTAssertEqual(after?.id, before?.id)
        #else
        throw XCTSkip("Requires the app-linked iOS Go and canonical Beancount runtimes")
        #endif
    }

    func testAccountsQueryFiltersByRole() async throws {
        let fixture = try await fixture()
        let none = try await fixture.recorder.accounts(role: .category, target: .none(remoteMode: false))
        XCTAssertTrue(none.isEmpty)
        let categories = try await fixture.recorder.accounts(role: .category, target: fixture.target)
        // Expenses first, then Income, each sorted by label in the device locale.
        XCTAssertEqual(Set(categories.prefix(2).map(\.account)), ["Expenses:Food:Coffee", "Expenses:Transport"])
        XCTAssertEqual(categories.last?.account, "Income:Salary")
        let expenseLabels = categories.prefix(2).map(\.label)
        XCTAssertEqual(expenseLabels, expenseLabels.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        let funding = try await fixture.recorder.accounts(role: .funding, target: fixture.target)
        XCTAssertEqual(Set(funding.prefix(2).map(\.account)), ["Assets:WeChat", "Assets:Bank:CMB"])
        XCTAssertEqual(funding.last?.account, "Liabilities:CreditCard:CMB")
        XCTAssertFalse(funding.contains { $0.account == "Assets:Old" })
        let bootstraps = await fixture.engine.ledgerRequests.filter { $0 == "/api/ledger/bootstrap/page" }.count
        XCTAssertEqual(bootstraps, 1, "Both roles share one cached read of the revision")
    }
}
