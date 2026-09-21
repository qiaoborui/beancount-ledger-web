import Foundation
import XCTest
@testable import LedgerMobile

@MainActor
final class BoundedLedgerBrowserModelTests: XCTestCase, @unchecked Sendable {
    private final class Authentication: LocalLedgerAuthenticating {
        var isAvailable = true
        var failure = false
        var calls = 0
        var suspend = false
        var continuation: CheckedContinuation<Void, Never>?
        func authenticate() async throws {
            calls += 1
            if suspend { await withCheckedContinuation { continuation = $0 } }
            if failure { throw BoundedReadIndexError.unavailable }
        }
    }

    /// Blocking fake mimics a native query that cannot instantly be interrupted.
    /// The test never uses a real catalog, ledger, exporter, keychain or network.
    private final class Workspace: BoundedBrowserWorkspace, @unchecked Sendable {
        private let gate = NSLock()
        private var _opens = 0
        private var _closes = 0
        private var _builds = 0
        private var _locks = 0
        private var _pages: [String?] = []
        private var _details = 0
        private var _detailCursors: [String?] = []
        private var _offMain = true
        private var _accountCursors: [String?] = []
        private var _balanceAccounts: [String] = []
        private var _activityCursors: [String?] = []
        private var _currencies: [String] = []
        var activityCursors: [String?] { gate.withLock { _activityCursors } }
        var currencies: [String] { gate.withLock { _currencies } }
        var readRevision = "fixture"
        var activityFault: String?
        var summaryFault: String?
        var blockActivity = false
        var blockSummary = false
        var unicodeCurrencies = false
        var unicodeAccounts = false
        var blockAccountsNext = false
        var continuationFaultsOnly = false
        var accountsFault: String?
        var blockBalances = false
        var balancesFault: String?
        var oversizedDetail = false
        var wrongDetailRevision = false
        var malformedDetail = false
        var oversized = false // configured before handing the fake to the worker
        var blockNext = false
        var blockDetail = false
        var blockBuild = false
        let queryStarted = DispatchSemaphore(value: 0)
        let queryRelease = DispatchSemaphore(value: 0)
        let revisionID = UUID()

        var accountCursors: [String?] { gate.withLock { _accountCursors } }
        var balanceAccounts: [String] { gate.withLock { _balanceAccounts } }
        var opens: Int { gate.withLock { _opens } }
        var closes: Int { gate.withLock { _closes } }
        var builds: Int { gate.withLock { _builds } }
        var locks: Int { gate.withLock { _locks } }
        var pageCount: Int { gate.withLock { _pages.count } }
        var details: Int { gate.withLock { _details } }
        var detailCursors: [String?] { gate.withLock { _detailCursors } }
        var offMain: Bool { gate.withLock { _offMain } }

        func revision() async throws -> UUID { revisionID }
        func rebuild(revision: UUID) async throws {
            guard revision == revisionID else { throw BoundedReadIndexError.revisionMismatch }
            gate.withLock { _builds += 1; _offMain = _offMain && !Thread.isMainThread }
            if blockBuild {
                queryStarted.signal()
                guard await browserTestWait(queryRelease) else {
                    throw BoundedReadIndexError.canceled
                }
            }
        }
        func lock() { gate.withLock { _locks += 1; _offMain = _offMain && !Thread.isMainThread } }
        func read(_ body: @escaping @Sendable (BoundedBrowserLeaseInfo, BoundedBrowserQueries) async throws -> Void) async throws {
            gate.withLock { _opens += 1; _offMain = _offMain && !Thread.isMainThread }
            defer { gate.withLock { _closes += 1 } }
            try await body(.init(revision: readRevision, isStale: false), .init(page: { cursor in
                self.gate.withLock { self._pages.append(cursor); self._offMain = self._offMain && !Thread.isMainThread }
                if cursor != nil, self.blockNext {
                    self.queryStarted.signal()
                    guard self.queryRelease.wait(timeout: .now() + 5) == .success else {
                        throw BoundedReadIndexError.canceled
                    }
                }
                let ids = self.oversized ? Array(1...101) : [cursor == nil ? 1 : 2]
                let rows = ids.map { id in
                    """
                    {"id":\(id),"date":"2026-01-01","record":{"type":"directive","id":\(id),"value":{"Kind":"transaction","Date":"2026-01-01","File":"main.bean","Line":1}}}
                    """
                }.joined(separator: ",")
                return try JSONDecoder().decode(BoundedIndexPage.self, from: Data("""
                    {"revision":"fixture","transactions":[\(rows)],"next_cursor":\(cursor == nil ? "\"next\"" : "null")}
                    """.utf8))
            }, detailRecords: { id, cursor in
                self.gate.withLock { self._details += 1; self._detailCursors.append(cursor); self._offMain = self._offMain && !Thread.isMainThread }
                if self.blockDetail {
                    self.queryStarted.signal()
                    guard self.queryRelease.wait(timeout: .now() + 5) == .success else {
                        throw BoundedReadIndexError.canceled
                    }
                }
                let directive = #"{"type":"directive","id":\#(id),"value":{"Kind":"transaction","Date":"2026-01-01","File":"main.bean","Line":1}}"#
                let posting = #"{"type":"posting","entry_id":\#(id),"ordinal":0,"value":{"account":"Assets:Test","Quantity":{"Number":"1.00","Currency":"USD"}}}"#
                let rows = self.oversizedDetail ? Array(repeating: posting, count: 101) :
                    (self.malformedDetail ? [posting] : (cursor == nil ? [directive, posting] : [posting]))
                return try JSONDecoder().decode(BoundedIndexDetailPage.self, from: Data("""
                    {"revision":"\(self.wrongDetailRevision ? "wrong" : "fixture")","id":\(id),"records":[\(rows.joined(separator: ","))],"next_cursor":\(cursor == nil ? "\"detail-next\"" : "null")}
                    """.utf8))
            }, accounts: { cursor in
                let call = self.gate.withLock {
                    self._accountCursors.append(cursor)
                    return self._accountCursors.count
                }
                if self.blockAccountsNext, cursor != nil, call == 2 {
                    self.queryStarted.signal()
                    guard self.queryRelease.wait(timeout: .now() + 5) == .success else { throw BoundedReadIndexError.canceled }
                }
                let fault = self.continuationFaultsOnly && cursor == nil ? nil : self.accountsFault
                let names = self.unicodeAccounts ? ["Assets:Cafe\u{0301}", "Assets:Caf\u{00e9}"] : [cursor == nil ? "Assets:A" : "Assets:B"]
                let rows = names.enumerated().map { offset, account in
                    let id = (cursor == nil ? 7 : 8) + offset
                    let kind = fault == "record" ? "close" : "open"
                    return #"{"account":"\#(account)","open_id":\#(id),"open_date":"2026-01-01","open_record":{"type":"directive","id":\#(id),"value":{"Kind":"\#(kind)","Date":"2026-01-01","File":"main.bean","Line":1,"Account":"\#(account)"}}}"#
                }
                let revision = fault == "revision" ? "wrong" : (fault == "unicodeRevision" ? "Cafe\u{0301}" : self.readRevision)
                let next = fault == "cursor" ? "\"accounts-next\"" : (cursor == nil ? "\"accounts-next\"" : "null")
                let output = fault == "oversized" ? Array(repeating: rows[0], count: 101) : rows
                return try JSONDecoder().decode(BoundedIndexAccountsPage.self, from: Data(#"{"revision":"\#(revision)","accounts":[\#(output.joined(separator: ","))],"next_cursor":\#(next)}"#.utf8))
            }, accountBalances: { account, cursor in
                let call = self.gate.withLock {
                    self._balanceAccounts.append(account)
                    return self._balanceAccounts.count
                }
                if self.blockBalances, call == 1 {
                    self.queryStarted.signal()
                    guard self.queryRelease.wait(timeout: .now() + 5) == .success else { throw BoundedReadIndexError.canceled }
                }
                let fault = self.continuationFaultsOnly && cursor == nil ? nil : self.balancesFault
                let revision = fault == "revision" ? "wrong" : (fault == "unicodeRevision" ? "Cafe\u{0301}" : self.readRevision)
                let otherUnicode = account.utf8.elementsEqual("Assets:Caf\u{00e9}".utf8) ? "Assets:Cafe\u{0301}" : "Assets:Caf\u{00e9}"
                let account = fault == "account" ? "wrong" : (fault == "unicode" ? otherUnicode : account)
                let basis = fault == "basis" ? "valuation" : "native_nominal"
                let unit = cursor == nil ? "AAA" : "ZZZ"
                let quantity = fault == "decimal" ? "1e9" : "12345678901234567890.000000000000001"
                let row = #"{"currency":"\#(unit)","quantity":"\#(quantity)"}"#
                if self.unicodeCurrencies {
                    return try JSONDecoder().decode(BoundedIndexAccountBalancesPage.self, from: Data(#"{"revision":"fixture","account":"\#(account)","basis":"native_nominal","balances":[{"currency":"Café","quantity":"1"},{"currency":"Café","quantity":"2"}]}"#.utf8))
                }
                let count = fault == "oversized" ? 101 : 1
                let next = fault == "cursor" ? "\"balances-next\"" : (cursor == nil ? "\"balances-next\"" : "null")
                return try JSONDecoder().decode(BoundedIndexAccountBalancesPage.self, from: Data(#"{"revision":"\#(revision)","account":"\#(account)","basis":"\#(basis)","balances":[\#(Array(repeating: row, count: count).joined(separator: ","))],"next_cursor":\#(next)}"#.utf8))
            }, accountSummary: { account, currency, start, end in
                if self.blockSummary {
                    self.queryStarted.signal()
                    guard self.queryRelease.wait(timeout: .now() + 5) == .success else { throw BoundedReadIndexError.canceled }
                }
                let fault = self.summaryFault
                let revision = fault == "revision" ? "wrong" : (fault == "unicodeRevision" ? "Cafe\u{0301}" : self.readRevision)
                let account = fault == "account" ? "wrong" : account
                let currency = fault == "currency" ? "wrong" : currency
                let basis = fault == "basis" ? "valuation" : "native_nominal"
                let quantity = fault == "decimal" ? "1e9" : "12345678901234567890.000000000000001"
                let range = fault == "range" ? #", "start":"2026-01-01","end":"2026-02-01""# : ""
                return try JSONDecoder().decode(BoundedIndexAccountSummary.self, from: Data(#"{"revision":"\#(revision)","account":"\#(account)","currency":"\#(currency)","basis":"\#(basis)","current_balance":"\#(quantity)","opening_balance":"0","closing_balance":"\#(quantity)","period_change":"\#(quantity)"\#(range)}"#.utf8))
            }, accountActivity: { account, currency, start, end, cursor in
                self.gate.withLock { self._activityCursors.append(cursor); self._currencies.append(currency) }
                if self.blockActivity {
                    self.queryStarted.signal()
                    guard self.queryRelease.wait(timeout: .now() + 5) == .success else { throw BoundedReadIndexError.canceled }
                }
                let fault = self.continuationFaultsOnly && cursor == nil ? nil : self.activityFault
                let revision = fault == "revision" ? "wrong" : (fault == "unicodeRevision" ? "Cafe\u{0301}" : self.readRevision)
                let account = fault == "account" ? "wrong" : account
                let currency = fault == "currency" ? "wrong" : currency
                let basis = fault == "basis" ? "valuation" : "native_nominal"
                let ids = fault == "oversized" ? Array(1...101) : (fault == "empty" ? [] : [cursor == nil ? 21 : 22])
                let quantity = fault == "decimal" ? "1e9" : "12345678901234567890.000000000000001"
                let rows = ids.map { id in
                    #"{"id":\#(id),"date":"2026-01-01","change":"0","balance":"\#(quantity)","record":{"type":"directive","id":\#(id),"value":{"Kind":"transaction","Date":"2026-01-01","File":"main.bean","Line":1}}}"#
                }.joined(separator: ",")
                let range = fault == "range" ? #", "start":"2026-01-01","end":"2026-02-01""# : ""
                let next = fault == "cursor" ? "\"activity-next\"" : (cursor == nil && fault != "empty" ? "\"activity-next\"" : "null")
                return try JSONDecoder().decode(BoundedIndexAccountActivityPage.self, from: Data(#"{"revision":"\#(revision)","account":"\#(account)","currency":"\#(currency)","basis":"\#(basis)","rows":[\#(rows)],"next_cursor":\#(next)\#(range)}"#.utf8))
            }))
        }
    }

    private final class Counter: @unchecked Sendable {
        private let gate = NSLock()
        private var value = 0
        func increment() { gate.withLock { value += 1 } }
        var count: Int { gate.withLock { value } }
    }

    private func fixture(available: Bool = true, auth: Authentication = Authentication(),
                         workspace: Workspace = Workspace()) -> (BoundedLedgerBrowserModel, Workspace, Counter) {
        let calls = Counter()
        let descriptor = LocalLedgerDescriptor(id: UUID(), name: "Synthetic fixture", entrypoint: "main.bean", createdAt: Date())
        let dependencies = BoundedBrowserDependencies(available: available, list: {
            calls.increment()
            return .init(root: URL(fileURLWithPath: "/synthetic-unused"), descriptors: [descriptor])
        }, workspace: { _, _ in workspace })
        return (BoundedLedgerBrowserModel(authenticator: auth, dependencies: dependencies), workspace, calls)
    }

    private func eventually(_ predicate: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition did not become true", file: file, line: line)
    }

    private func select(_ model: BoundedLedgerBrowserModel) async throws {
        model.unlock()
        await eventually { !model.locked && !model.busy }
        model.select(try XCTUnwrap(model.descriptors.first))
    }

    private func openBalances(_ model: BoundedLedgerBrowserModel) async throws {
        try await select(model)
        model.setMode(.accounts)
        model.open()
        await eventually { model.accountsPage != nil && !model.busy }
        model.selectAccount(7)
        await eventually { model.balances != nil && !model.busy }
    }

    func testActivitySelectionPagingDetailAndOneRetainedScope() async throws {
        let (model, workspace, _) = fixture()
        try await openBalances(model)
        model.selectCurrency("missing")
        XCTAssertNil(model.selectedCurrency)
        model.selectCurrency("AAA")
        await eventually { model.activity != nil && !model.busy }
        XCTAssertEqual(model.selectedAccount?.openID, 7)
        XCTAssertEqual(model.selectedCurrency, "AAA")
        XCTAssertEqual(model.summary?.currentBalance, "12345678901234567890.000000000000001")
        XCTAssertEqual(model.activity?.rows.map(\.id), [21])
        model.showActivityDetail(999)
        XCTAssertNil(model.detail)
        model.showActivityDetail(21)
        await eventually { model.detail != nil && !model.busy }
        XCTAssertEqual(model.detail?.id, 21)
        model.nextActivityPage()
        XCTAssertNil(model.activity)
        XCTAssertNil(model.summary)
        XCTAssertNil(model.detail)
        // Serial admission: a concurrent selection/page request cannot overtake.
        model.selectCurrency("missing")
        model.firstActivityPage()
        await eventually { model.activity?.rows.first?.id == 22 && !model.busy }
        XCTAssertEqual(model.activity?.rows.count, 1)
        XCTAssertNil(model.activity?.nextCursor)
        XCTAssertEqual(model.activity?.rows.first?.balance, model.summary?.currentBalance)
        model.firstActivityPage()
        await eventually { model.activity?.rows.first?.id == 21 && !model.busy }
        XCTAssertEqual(workspace.activityCursors.count, 3)
        XCTAssertEqual(workspace.activityCursors.compactMap { $0 }, ["activity-next"])
        model.nextBalancesPage()
        XCTAssertNil(model.selectedCurrency)
        XCTAssertNil(model.summary)
        XCTAssertNil(model.activity)
        await eventually { model.balances != nil && !model.busy }
        model.selectCurrency("ZZZ")
        await eventually { model.activity != nil && !model.busy }
        model.nextAccountsPage()
        XCTAssertNil(model.selectedAccount)
        XCTAssertNil(model.selectedCurrency)
        XCTAssertNil(model.activity)
        await eventually { model.accountsPage != nil && !model.busy }
        model.selectAccount(8)
        await eventually { model.balances != nil && !model.busy }
        model.selectCurrency("AAA")
        await eventually { model.activity != nil && !model.busy }
        XCTAssertEqual(model.selectedAccount?.openID, 8)
        model.setMode(.transactions)
        XCTAssertNil(model.summary)
        XCTAssertNil(model.activity)
        XCTAssertNil(model.selectedCurrency)
        await eventually { model.page != nil && !model.busy }
        XCTAssertEqual(workspace.opens, 1)
        XCTAssertEqual(workspace.closes, 0)
        XCTAssertEqual(workspace.builds, 0)
        model.lock()
        await eventually { workspace.closes == 1 }
    }

    func testByteExactCurrencyAndAccountSelectionDoesNotAlias() async throws {
        let workspace = Workspace(); workspace.unicodeCurrencies = true; workspace.unicodeAccounts = true
        let (model, _, _) = fixture(workspace: workspace)
        try await openBalances(model)
        for openID: Int64 in [7, 8] {
            model.selectAccount(openID)
            XCTAssertNil(model.selectedCurrency)
            await eventually { model.balances != nil && !model.busy }
            for currency in ["Cafe\u{0301}", "Café"] {
                model.selectCurrency(currency)
                await eventually { model.activity != nil && !model.busy }
                XCTAssertTrue(model.selectedCurrency!.utf8.elementsEqual(currency.utf8))
                XCTAssertTrue(model.summary!.currency.utf8.elementsEqual(currency.utf8))
                XCTAssertEqual(model.selectedAccount?.openID, openID)
            }
        }
        XCTAssertEqual(workspace.currencies.map { Array($0.utf8) }, ["Cafe\u{0301}", "Café", "Cafe\u{0301}", "Café"].map { Array($0.utf8) })
        XCTAssertEqual(workspace.opens, 1)
        model.lock()
    }

    func testSummaryAndActivityFaultsFailClosedIncludingContinuations() async throws {
        for summary in [true, false] {
            let faults = summary ? ["revision", "account", "currency", "basis", "decimal", "range"] : ["revision", "account", "currency", "basis", "decimal", "range", "oversized", "cursor"]
            for fault in faults {
                let workspace = Workspace()
                if summary { workspace.summaryFault = fault }
                else { workspace.activityFault = fault; workspace.continuationFaultsOnly = true }
                let (model, _, _) = fixture(workspace: workspace)
                try await openBalances(model)
                model.selectCurrency("AAA")
                if !summary {
                    await eventually { model.activity != nil && !model.busy }
                    model.nextActivityPage()
                }
                await eventually { model.message != nil && !model.busy }
                XCTAssertNil(model.summary)
                XCTAssertNil(model.activity)
                XCTAssertNil(model.selectedCurrency)
                XCTAssertNil(model.selectedAccount)
                XCTAssertNil(model.lease)
                model.lock()
            }
        }
    }

    func testSummaryAndActivityRejectUnicodeEquivalentLeaseRevision() async throws {
        for summary in [true, false] {
            let workspace = Workspace(); workspace.readRevision = "Café"
            if summary { workspace.summaryFault = "unicodeRevision" }
            else { workspace.activityFault = "unicodeRevision" }
            let (model, _, _) = fixture(workspace: workspace)
            try await openBalances(model)
            model.selectCurrency("AAA")
            await eventually { model.message != nil && !model.busy }
            XCTAssertNil(model.summary)
            XCTAssertNil(model.activity)
            XCTAssertNil(model.lease)
            model.lock()
        }
    }

    func testEmptyActivityKeepsZeroOrScalarSummaryWithoutContinuation() async throws {
        let workspace = Workspace(); workspace.activityFault = "empty"
        let (model, _, _) = fixture(workspace: workspace)
        try await openBalances(model)
        model.selectCurrency("AAA")
        await eventually { model.activity != nil && !model.busy }
        XCTAssertTrue(model.activity!.rows.isEmpty)
        XCTAssertNotNil(model.summary)
        XCTAssertNil(model.activity?.nextCursor)
        model.nextActivityPage()
        XCTAssertFalse(model.busy)
        model.lock()
    }

    func testLockDuringSummaryOrActivitySuppressesLateResultsAcrossUnlock() async throws {
        for summary in [true, false] {
            let workspace = Workspace(); workspace.blockSummary = summary; workspace.blockActivity = !summary
            let (model, _, _) = fixture(workspace: workspace)
            try await openBalances(model)
            model.selectCurrency("AAA")
            let started = await browserTestWait(workspace.queryStarted)
            XCTAssertTrue(started)
            model.lock()
            XCTAssertNil(model.selectedAccount)
            XCTAssertNil(model.selectedCurrency)
            XCTAssertNil(model.summary)
            XCTAssertNil(model.activity)
            model.unlock()
            await eventually { !model.locked && !model.busy }
            workspace.queryRelease.signal()
            await eventually { workspace.closes == 1 }
            XCTAssertNil(model.lease)
            XCTAssertNil(model.activity)
            XCTAssertNil(model.summary)
            XCTAssertNil(model.message)
            XCTAssertEqual(workspace.activityCursors.count, summary ? 0 : 1)
            model.lock()
        }
    }

    func testAccountsModesReplacePagesAndKeepOneScope() async throws {
        let (model, workspace, _) = fixture()
        try await select(model)
        model.open()
        await eventually { model.page != nil && !model.busy }
        model.setMode(.accounts)
        XCTAssertNil(model.page)
        await eventually { model.accountsPage != nil && !model.busy }
        XCTAssertEqual(model.accountsPage?.accounts.map(\.account), ["Assets:A"])
        model.selectAccount(7)
        await eventually { model.balances != nil && !model.busy }
        XCTAssertEqual(model.balances?.balances.first?.quantity, "12345678901234567890.000000000000001")
        model.nextBalancesPage()
        XCTAssertNil(model.balances)
        await eventually { model.balances?.balances.first?.currency == "ZZZ" && !model.busy }
        XCTAssertEqual(model.balances?.balances.count, 1)
        model.showAccountMetadata()
        await eventually { model.detail != nil && !model.busy }
        XCTAssertEqual(model.detail?.id, 7)
        model.nextAccountsPage()
        XCTAssertNil(model.detail)
        XCTAssertNil(model.balances)
        XCTAssertNil(model.selectedAccount)
        await eventually { model.accountsPage?.accounts.first?.account == "Assets:B" && !model.busy }
        XCTAssertEqual(model.accountsPage?.accounts.count, 1)
        model.selectAccount(8)
        await eventually { model.balances?.account == "Assets:B" && !model.busy }
        model.setMode(.transactions)
        XCTAssertNil(model.accountsPage)
        XCTAssertNil(model.balances)
        XCTAssertNil(model.selectedAccount)
        await eventually { model.page != nil && !model.busy }
        XCTAssertEqual(workspace.opens, 1)
        XCTAssertEqual(workspace.closes, 0)
        model.lock()
        await eventually { workspace.closes == 1 }
        XCTAssertNil(model.page)
        XCTAssertNil(model.lease)
    }

    func testUnicodeEquivalentAccountsSelectByOpenIDAndPreserveRequestBytes() async throws {
        let workspace = Workspace(); workspace.unicodeAccounts = true
        let (model, _, _) = fixture(workspace: workspace)
        try await select(model)
        model.setMode(.accounts); model.open()
        await eventually { model.accountsPage != nil && !model.busy }
        model.selectAccount(999) // An ID outside the displayed page has no capability.
        XCTAssertNil(model.selectedAccount)
        XCTAssertTrue(workspace.balanceAccounts.isEmpty)
        for (id, name) in [(Int64(8), "Assets:Caf\u{00e9}"), (7, "Assets:Cafe\u{0301}")] {
            model.selectAccount(id)
            await eventually { model.balances != nil && !model.busy }
            XCTAssertEqual(model.selectedAccount?.openID, id)
            XCTAssertTrue(try XCTUnwrap(model.selectedAccount?.account).utf8.elementsEqual(name.utf8))
            XCTAssertTrue(try XCTUnwrap(model.balances?.account).utf8.elementsEqual(name.utf8))
            XCTAssertTrue(try XCTUnwrap(workspace.balanceAccounts.last).utf8.elementsEqual(name.utf8))
        }
        model.lock()
        await eventually { workspace.closes == 1 }
    }

    func testUnicodeEquivalentWrongAccountResponseFailsClosed() async throws {
        for id in [Int64(7), 8] {
            let workspace = Workspace(); workspace.unicodeAccounts = true; workspace.balancesFault = "unicode"
            let (model, _, _) = fixture(workspace: workspace)
            try await select(model)
            model.setMode(.accounts); model.open()
            await eventually { model.accountsPage != nil && !model.busy }
            model.selectAccount(id)
            await eventually { model.message != nil && !model.busy }
            XCTAssertNil(model.balances)
            XCTAssertNil(model.selectedAccount)
            XCTAssertNil(model.lease)
            await eventually { workspace.closes == 1 }
            model.lock()
        }
    }

    func testAccountsAndBalancesContinuationMismatchesFailClosed() async throws {
        for accounts in [true, false] {
            let faults = accounts ? ["revision", "record", "cursor"] : ["revision", "account", "basis", "decimal", "cursor", "unicode"]
            for fault in faults {
                let workspace = Workspace(); workspace.continuationFaultsOnly = true
                workspace.unicodeAccounts = fault == "unicode"
                if accounts { workspace.accountsFault = fault } else { workspace.balancesFault = fault }
                let (model, _, _) = fixture(workspace: workspace)
                try await select(model)
                model.setMode(.accounts); model.open()
                await eventually { model.accountsPage != nil && !model.busy }
                if accounts { model.nextAccountsPage() }
                else {
                    model.selectAccount(7)
                    await eventually { model.balances != nil && !model.busy }
                    model.nextBalancesPage()
                }
                await eventually { model.message != nil && !model.busy }
                XCTAssertNil(model.accountsPage)
                XCTAssertNil(model.selectedAccount)
                XCTAssertNil(model.balances)
                XCTAssertNil(model.lease)
                await eventually { workspace.closes == 1 }
                model.lock()
            }
        }
    }

    func testDelayedAccountsAndBalancesStaySerialAndCannotReplaceNewSelection() async throws {
        for accounts in [true, false] {
            for lockAndUnlock in [true, false] {
                let workspace = Workspace()
                workspace.blockAccountsNext = accounts; workspace.blockBalances = !accounts
                let (model, _, _) = fixture(workspace: workspace)
                try await select(model)
                model.setMode(.accounts); model.open()
                await eventually { model.accountsPage != nil && !model.busy }
                if accounts { model.nextAccountsPage() } else { model.selectAccount(7) }
                let started = await browserTestWait(workspace.queryStarted)
                XCTAssertTrue(started)
                // Neither endpoint, selection nor a mode change may bypass the busy gate.
                model.firstAccountsPage(); model.nextAccountsPage()
                model.selectAccount(8); model.firstBalancesPage(); model.nextBalancesPage()
                model.setMode(.transactions)
                let descriptor = try XCTUnwrap(model.selected)
                model.select(try XCTUnwrap(model.descriptors.first))
                XCTAssertEqual(model.selected, descriptor)
                XCTAssertTrue(model.busy)
                XCTAssertEqual(model.mode, .accounts)
                XCTAssertEqual(workspace.accountCursors.count, accounts ? 2 : 1)
                XCTAssertEqual(workspace.balanceAccounts.count, accounts ? 0 : 1)
                if lockAndUnlock {
                    model.lock()
                    XCTAssertNil(model.accountsPage); XCTAssertNil(model.balances); XCTAssertNil(model.selectedAccount)
                    model.unlock()
                    await eventually { !model.locked && !model.busy }
                } else {
                    // Selection is intentionally disabled while busy. Finish that
                    // request before selecting again; lock is the interrupt path.
                    workspace.queryRelease.signal()
                    await eventually { !model.busy }
                }
                model.select(try XCTUnwrap(model.descriptors.first))
                XCTAssertNil(model.accountsPage); XCTAssertNil(model.balances); XCTAssertNil(model.selectedAccount)
                model.setMode(.accounts); model.open()
                await eventually { model.accountsPage != nil && !model.busy }
                if !accounts {
                    model.nextAccountsPage()
                    await eventually { model.accountsPage?.accounts.first?.openID == 8 && !model.busy }
                }
                let selectedID: Int64 = accounts ? 7 : 8
                let selectedName = accounts ? "Assets:A" : "Assets:B"
                model.selectAccount(selectedID)
                await eventually { model.balances != nil && !model.busy }
                // After lock/unlock, release the old epoch only AFTER the new
                // selection has published; it must not clear or replace new state.
                if lockAndUnlock { workspace.queryRelease.signal() }
                await eventually { workspace.closes == 1 }
                XCTAssertEqual(model.selectedAccount?.openID, selectedID)
                XCTAssertEqual(model.accountsPage?.accounts.first?.openID, selectedID)
                XCTAssertTrue(try XCTUnwrap(model.balances?.account).utf8.elementsEqual(selectedName.utf8))
                XCTAssertNotNil(model.lease)
                XCTAssertNil(model.message)
                XCTAssertFalse(model.busy)
                model.lock()
                await eventually { workspace.closes == 2 }
            }
        }
    }

    func testAccountsCanBeInitialModeAndSelectionClearsAllState() async throws {
        let (model, workspace, _) = fixture()
        try await select(model)
        model.setMode(.accounts)
        model.open()
        await eventually { model.accountsPage != nil && !model.busy }
        XCTAssertEqual(workspace.pageCount, 0)
        model.selectAccount(7)
        await eventually { model.balances != nil && !model.busy }
        model.select(try XCTUnwrap(model.descriptors.first))
        XCTAssertNil(model.accountsPage)
        XCTAssertNil(model.balances)
        XCTAssertNil(model.selectedAccount)
        XCTAssertNil(model.lease)
        XCTAssertEqual(model.mode, .transactions)
        model.lock()
    }

    func testLockDuringBalancesSuppressesLateResultAndClearsCatalog() async throws {
        let workspace = Workspace(); workspace.blockBalances = true
        let (model, _, _) = fixture(workspace: workspace)
        try await select(model)
        model.setMode(.accounts); model.open()
        await eventually { model.accountsPage != nil && !model.busy }
        model.selectAccount(7)
        let started = await browserTestWait(workspace.queryStarted)
        XCTAssertTrue(started)
        model.lock()
        XCTAssertNil(model.accountsPage)
        XCTAssertNil(model.balances)
        XCTAssertNil(model.selectedAccount)
        XCTAssertNil(model.detail)
        XCTAssertTrue(model.descriptors.isEmpty)
        workspace.queryRelease.signal()
        await eventually { workspace.closes == 1 }
        XCTAssertNil(model.balances)
        XCTAssertNil(model.lease)
    }

    func testAccountsAndBalancesFailClosedOnOversizeAndMismatches() async throws {
        for fault in ["oversized", "revision"] {
            let workspace = Workspace(); workspace.accountsFault = fault
            let (model, _, _) = fixture(workspace: workspace)
            try await select(model)
            model.setMode(.accounts); model.open()
            await eventually { model.message != nil && !model.busy }
            XCTAssertNil(model.accountsPage)
            XCTAssertNil(model.lease)
            XCTAssertEqual(workspace.pageCount, 0)
            model.lock()
        }
        for fault in ["oversized", "revision", "account", "basis", "decimal"] {
            let workspace = Workspace(); workspace.balancesFault = fault
            let (model, _, _) = fixture(workspace: workspace)
            try await select(model)
            model.setMode(.accounts); model.open()
            await eventually { model.accountsPage != nil && !model.busy }
            model.selectAccount(7)
            await eventually { model.message != nil && !model.busy }
            XCTAssertNil(model.accountsPage)
            XCTAssertNil(model.selectedAccount)
            XCTAssertNil(model.balances)
            XCTAssertNil(model.lease)
            XCTAssertEqual(workspace.opens, 1)
            XCTAssertEqual(workspace.pageCount, 0)
            model.lock()
        }
    }

    func testLockWhileAuthenticatingSuppressesLateCatalogAccess() async {
        let auth = Authentication()
        auth.suspend = true
        let (model, _, calls) = fixture(auth: auth)
        model.unlock()
        await eventually { auth.continuation != nil }
        model.lock()
        auth.continuation?.resume()
        auth.continuation = nil
        // Let the stale authentication task complete; it must not list.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.locked)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(calls.count, 0)
        XCTAssertTrue(model.descriptors.isEmpty)
    }

    func testLockDuringBuildNeverOpensReader() async throws {
        let workspace = Workspace()
        workspace.blockBuild = true
        let (model, _, _) = fixture(workspace: workspace)
        try await select(model)
        model.prepareBuild()
        await eventually { model.confirmation != nil }
        model.confirmBuild()
        let started = await browserTestWait(workspace.queryStarted)
        XCTAssertTrue(started)
        model.lock()
        await eventually { workspace.locks >= 2 }
        workspace.queryRelease.signal()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(workspace.opens, 0)
        XCTAssertTrue(model.locked)
        XCTAssertNil(model.page)
        XCTAssertNil(model.confirmation)
    }

    func testDetailTransportRejectsMoreThanOneMiBBeforeDecode() async {
        XCTAssertEqual(BoundedIndexWire.responseLimit, 1 << 20)
        XCTAssertThrowsError(try BoundedIndexWire.decode(BoundedIndexDetail.self,
            json: String(repeating: " ", count: (1 << 20) + 1), limit: BoundedIndexWire.responseLimit)) { error in
            XCTAssertEqual(error as? BoundedReadIndexError, .resourceLimit)
        }
    }

    func testUnavailableDoesNotAuthenticateOrList() async {
        let auth = Authentication()
        let (model, workspace, calls) = fixture(available: false, auth: auth)
        model.unlock()
        XCTAssertTrue(model.locked)
        XCTAssertEqual(auth.calls, 0)
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(workspace.opens, 0)
    }

    func testRejectedAuthenticationDoesNotList() async {
        let auth = Authentication()
        auth.failure = true
        let (model, _, calls) = fixture(auth: auth)
        model.unlock()
        await eventually { !model.busy }
        XCTAssertTrue(model.locked)
        XCTAssertEqual(calls.count, 0)
        XCTAssertTrue(model.descriptors.isEmpty)
    }

    func testSelectionDoesNotOpenOrBuildAndPagesReuseOneScope() async throws {
        let (model, workspace, calls) = fixture()
        try await select(model)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(workspace.opens, 0)
        XCTAssertEqual(workspace.builds, 0)
        model.open()
        await eventually { model.page != nil }
        XCTAssertEqual(model.page?.transactions.map(\.id), [1])
        model.nextPage()
        XCTAssertNil(model.page)
        await eventually { model.page?.transactions.first?.id == 2 }
        XCTAssertEqual(model.page?.transactions.count, 1)
        model.firstPage()
        await eventually { model.page?.transactions.first?.id == 1 }
        XCTAssertEqual(workspace.opens, 1)
        XCTAssertEqual(workspace.pageCount, 3)
        XCTAssertEqual(workspace.closes, 0)
        model.lock()
        XCTAssertNil(model.page)
        XCTAssertNil(model.detail)
        XCTAssertTrue(model.descriptors.isEmpty)
        await eventually { workspace.closes == 1 && workspace.locks > 0 }
        XCTAssertTrue(workspace.offMain)
    }

    func testBuildRequiresExplicitConfirmationAndDrainsScope() async throws {
        let (model, workspace, _) = fixture()
        try await select(model)
        model.open()
        await eventually { model.page != nil }
        model.prepareBuild()
        await eventually { model.confirmation != nil }
        XCTAssertEqual(workspace.builds, 0)
        model.dismissConfirmation()
        XCTAssertEqual(workspace.builds, 0)
        model.prepareBuild()
        await eventually { model.confirmation != nil }
        model.confirmBuild()
        await eventually { workspace.builds == 1 && model.page != nil }
        XCTAssertEqual(workspace.opens, 2)
        XCTAssertEqual(workspace.closes, 1)
        model.lock()
        await eventually { workspace.closes == 2 }
    }

    func testOversizedPageFailsClosed() async throws {
        let workspace = Workspace()
        workspace.oversized = true
        let (model, _, _) = fixture(workspace: workspace)
        try await select(model)
        model.open()
        await eventually { !model.busy }
        XCTAssertNil(model.page)
        XCTAssertNil(model.lease)
        XCTAssertNotNil(model.message)
        model.lock()
    }

    func testOneOutstandingRequestAndLockSuppressesLatePageAfterUnlock() async throws {
        let workspace = Workspace()
        workspace.blockNext = true
        let (model, _, _) = fixture(workspace: workspace)
        try await select(model)
        model.open()
        await eventually { model.page != nil }
        model.nextPage()
        let started = await browserTestWait(workspace.queryStarted)
        XCTAssertTrue(started)
        model.firstPage()
        model.nextPage()
        XCTAssertEqual(workspace.pageCount, 2)
        model.lock()
        XCTAssertNil(model.page)
        XCTAssertNil(model.detail)
        XCTAssertNil(model.selected)
        model.unlock()
        await eventually { !model.locked }
        workspace.queryRelease.signal()
        await eventually { workspace.closes == 1 }
        XCTAssertNil(model.page)
        XCTAssertNil(model.lease)
        model.lock()
    }

    func testDetailPagesReplaceAndReuseReaderAndClearOnNavigation() async throws {
        let (model, workspace, _) = fixture()
        try await select(model)
        model.open()
        await eventually { model.page != nil }
        model.showDetail(1)
        await eventually { model.detail != nil }
        XCTAssertEqual(model.detail?.records.count, 2)
        model.nextDetailPage()
        XCTAssertNil(model.detail)
        await eventually { model.detail != nil }
        XCTAssertEqual(model.detail?.records.count, 1) // NOT three accumulated records.
        XCTAssertNil(model.detail?.nextCursor)
        model.nextDetailPage()
        XCTAssertEqual(workspace.details, 2)
        model.firstDetailPage()
        XCTAssertNil(model.detail)
        await eventually { model.detail?.records.count == 2 }
        XCTAssertEqual(workspace.detailCursors, [nil, "detail-next", nil])
        XCTAssertEqual(workspace.opens, 1)
        XCTAssertEqual(workspace.closes, 0)
        model.dismissDetail()
        XCTAssertNil(model.detail)
        model.showDetail(1)
        await eventually { model.detail != nil }
        model.nextPage()
        XCTAssertNil(model.detail)
        await eventually { model.page?.transactions.first?.id == 2 }
        model.showDetail(2)
        await eventually { model.detail?.id == 2 }
        model.select(try XCTUnwrap(model.selected))
        XCTAssertNil(model.detail)
        XCTAssertNil(model.lease)
        await eventually { workspace.closes == 1 }
        model.lock()
    }

    func testDetailFailuresClearRetainedState() async throws {
        for failure in 0..<3 {
            let workspace = Workspace()
            workspace.oversizedDetail = failure == 0
            workspace.wrongDetailRevision = failure == 1
            workspace.malformedDetail = failure == 2
            let (model, _, _) = fixture(workspace: workspace)
            try await select(model)
            model.open()
            await eventually { model.page != nil }
            model.showDetail(1)
            await eventually { !model.busy }
            XCTAssertNil(model.detail)
            XCTAssertNil(model.page)
            XCTAssertNil(model.lease)
            XCTAssertNotNil(model.message)
            await eventually { workspace.closes == 1 }
            model.lock()
        }
    }

    func testLockSuppressesLateDetail() async throws {
        let workspace = Workspace()
        workspace.blockDetail = true
        let (model, _, _) = fixture(workspace: workspace)
        try await select(model)
        model.open()
        await eventually { model.page != nil }
        model.showDetail(999) // Not on the current page: rejected locally.
        XCTAssertEqual(workspace.details, 0)
        model.showDetail(1)
        let started = await browserTestWait(workspace.queryStarted)
        XCTAssertTrue(started)
        model.lock()
        XCTAssertNil(model.detail)
        model.unlock()
        await eventually { !model.locked && !model.busy }
        model.select(try XCTUnwrap(model.descriptors.first))
        workspace.queryRelease.signal()
        await eventually { workspace.closes == 1 }
        XCTAssertNil(model.detail)
        XCTAssertNil(model.page)
        XCTAssertNil(model.lease)
        model.lock()
    }
}

// Blocking fake synchronization stays on a dispatch worker, never a Swift
// cooperative executor. Darwin marks semaphore waits noasync (Linux does not).
private func browserTestWait(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
        }
    }
}
