import XCTest
@testable import LedgerMobile

final class LocalTransactionScanTests: XCTestCase {
    private let revision = "native-model-revision"

    private func transaction(
        _ index: Int = 0,
        date: String = "2026-09-23",
        payee: String = "Shop",
        narration: String = "Lunch",
        tags: [String]? = ["food"],
        postings: [LedgerPosting]? = nil,
        metadata: [String: LedgerMetadataValue]? = nil,
        entry: LedgerTransactionEntry? = nil
    ) -> LedgerTransaction {
        LedgerTransaction(
            date: date, payee: payee, narration: narration, metadata: metadata,
            tags: tags,
            postings: postings ?? [posting("Expenses:Food", 125), posting("Assets:Cash", -125)],
            editableEntry: entry,
            source: TransactionSource(file: "synthetic.bean", line: index + 1, hash: "row-\(index)")
        )
    }

    private func posting(_ account: String, _ amount: Int, _ currency: String = "CNY") -> LedgerPosting {
        LedgerPosting(account: account, amount: amount, currency: currency)
    }

    private func page(_ rows: [LedgerTransaction], next: String? = nil, revision: String? = nil) -> LedgerTransactionPage {
        LedgerTransactionPage(revision: revision ?? self.revision, transactions: rows, nextCursor: next, sensitiveUnlocked: true)
    }

    private func final(
        _ rows: [LedgerTransaction],
        filter: LedgerTransactionFilter = .init(),
        limits: LocalTransactionScan.Limits = .init()
    ) throws -> LocalTransactionScan.Result {
        var scan = try LocalTransactionScan(expectedRevision: revision, filter: filter, limits: limits)
        let result = try scan.consume(page(rows), requestedCursor: nil)
        return try XCTUnwrap(result)
    }

    private func assertError<T>(
        _ expected: LocalTransactionScan.ScanError,
        file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? LocalTransactionScan.ScanError, expected, file: file, line: line)
        }
    }

    func testStreams100kWithoutRetainingPagesOrTruncatingAggregates() throws {
        var limits = LocalTransactionScan.Limits()
        limits.maxVisibleCount = 1_000 // Explicit 1,000 is legal, not restricted to 999.
        var scan = try LocalTransactionScan(expectedRevision: revision, limits: limits)
        var result: LocalTransactionScan.Result?
        for batch in 0..<200 {
            // At most 500 synthetic rows are materialized at any time by the producer.
            let rows = (batch * 500..<(batch + 1) * 500).map { index in
                transaction(index, date: index < 50_000 ? "2026-09-23" : "2026-09-22",
                            tags: index == 99_999 ? ["last-page"] : ["food"])
            }
            let next = batch == 199 ? nil : "cursor-\(batch + 1)"
            result = try scan.consume(page(rows, next: next), requestedCursor: scan.nextCursor)
            if batch < 199 {
                XCTAssertNil(result)
                XCTAssertFalse(scan.isComplete)
                XCTAssertEqual(scan.retainedVisibleCount, min((batch + 1) * 500, 1_000))
                XCTAssertLessThanOrEqual(scan.visibleAccountedBytes, limits.maxVisibleBytes)
                XCTAssertLessThanOrEqual(scan.stateAccountedBytes, limits.maxStateBytes)
            }
        }
        let completed = try XCTUnwrap(result)
        XCTAssertTrue(scan.isComplete)
        XCTAssertNil(scan.nextCursor)
        XCTAssertEqual(scan.retainedVisibleCount, 0)
        XCTAssertEqual(completed.fullRangeCount, 100_000)
        XCTAssertEqual(completed.matchedCount, 100_000)
        XCTAssertEqual(completed.visibleTransactions.map(\.source.line), Array(1...1_000))
        XCTAssertEqual(Set(completed.visibleTransactions.map(\.id)).count, 1_000)
        XCTAssertTrue(completed.hasMoreMatches)
        XCTAssertEqual(completed.availableTags, ["food", "last-page"])
        XCTAssertEqual(completed.days.map(\.matchedCount), [50_000, 50_000])
        XCTAssertEqual(completed.days.map(\.expense), [6_250_000, 6_250_000])
        XCTAssertLessThanOrEqual(completed.visibleAccountedBytes, 4 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(completed.stateAccountedBytes, limits.maxStateBytes)
    }

    func testFacetsAreFullRangeAndFilteringAndSummariesMatchExistingSwift() throws {
        let rows = [
            transaction(0, tags: ["food", ""], postings: [posting("Expenses:Food", 1_000), posting("Assets:Cash", -1_000)]),
            transaction(1, tags: ["refund"], postings: [posting("Expenses:Food", -400), posting("Assets:Cash", 400)]),
            transaction(2, date: "2026-09-22", tags: ["salary"], postings: [posting("Income:Salary", -2_000)]),
            transaction(3, date: "2026-09-22", tags: ["reversal"], postings: [posting("Income:Salary", 500)]),
            transaction(4, date: "2026-09-21", tags: ["transfer"], postings: [posting("Assets:Bank", -700), posting("Assets:Cash", 700)]),
            transaction(5, tags: ["mixed"], postings: [posting("Expenses:Other", 10, "USD"), posting("Expenses:Food", 20, "EUR")]),
            transaction(6, tags: ["zero"], postings: [posting("Expenses:Food", 100), posting("Expenses:Food", -100), posting("Income:Other", -20)]),
            transaction(7, tags: ["adjust"], postings: [posting("Equity:Opening", 0)])
        ]
        XCTAssertTrue(TransactionPresentation(transaction: rows[1]).isRefund)
        XCTAssertEqual(TransactionPresentation(transaction: rows[1]).kind, .income)
        let expectedAccounts = Array(Set(rows.flatMap { $0.postings.map(\.account) }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let expectedTags = Array(Set(rows.flatMap { $0.tags ?? [] }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let filters = TransactionKindFilter.allCases.map { LedgerTransactionFilter(kind: $0) } + [
            LedgerTransactionFilter(account: "Expenses"),
            LedgerTransactionFilter(tags: ["food", "salary"]),
            LedgerTransactionFilter(query: "Shop", kind: .income, account: "Expenses", tags: ["refund"]),
            LedgerTransactionFilter(query: "not found")
        ]
        for filter in filters {
            var limits = LocalTransactionScan.Limits()
            limits.maxVisibleCount = 1
            var scan = try LocalTransactionScan(expectedRevision: revision, filter: filter, limits: limits)
            XCTAssertNil(try scan.consume(page(Array(rows.prefix(3)), next: "next"), requestedCursor: nil))
            let result = try XCTUnwrap(scan.consume(page(Array(rows.dropFirst(3))), requestedCursor: "next"))
            let matched = rows.filter(filter.matches)
            XCTAssertEqual(result.fullRangeCount, rows.count)
            XCTAssertEqual(result.matchedCount, matched.count)
            XCTAssertEqual(result.visibleTransactions, Array(matched.prefix(1)))
            XCTAssertEqual(result.availableAccounts, expectedAccounts)
            XCTAssertEqual(result.availableTags, expectedTags)
            let grouped = Dictionary(grouping: matched, by: \.date)
            XCTAssertEqual(result.days.map(\.date), grouped.keys.sorted(by: >))
            for day in result.days {
                let group = try XCTUnwrap(grouped[day.date])
                let signed = group.reduce(0) { total, tx in
                    total + tx.postings.filter { $0.account.hasPrefix("Expenses:") }.reduce(0) { $0 + $1.amount }
                }
                XCTAssertEqual(day.matchedCount, group.count)
                XCTAssertEqual(day.signedExpense, signed)
                XCTAssertEqual(day.expense, max(0, signed))
            }
        }
        // Mixed currencies remain native minor-unit sums, exactly as the current UI;
        // neither the scan nor its tests pretend these are converted CNY totals.
        XCTAssertEqual(try final([rows[5]]).days.first?.expense, 30)
    }

    func testRefundClampOccursOnlyAtEOFIncludingInvisibleAndNoncontiguousRows() throws {
        var limits = LocalTransactionScan.Limits()
        limits.maxVisibleCount = 1
        var scan = try LocalTransactionScan(expectedRevision: revision, limits: limits)
        XCTAssertNil(try scan.consume(page([
            transaction(0, postings: [posting("Expenses:Food", -500)])
        ], next: "a"), requestedCursor: nil))
        XCTAssertNil(try scan.consume(page([
            transaction(1, date: "2026-09-22", postings: [posting("Expenses:Food", -10)]),
            transaction(2, postings: [posting("Expenses:Food", 800)])
        ], next: "b"), requestedCursor: "a"))
        let result = try XCTUnwrap(scan.consume(page([
            transaction(3, postings: [posting("Expenses:Food", -400)])
        ]), requestedCursor: "b"))
        XCTAssertEqual(result.days.map(\.signedExpense), [-100, -10])
        XCTAssertEqual(result.days.map(\.expense), [0, 0])
        XCTAssertEqual(result.days.map(\.matchedCount), [3, 1])
        XCTAssertEqual(result.visibleTransactions.count, 1)
    }

    func testUnicodeCanonicalAndMismatchFixturesUseActualSwiftFilter() throws {
        let composed = "Caf\u{00e9}"
        let decomposed = "Cafe\u{0301}"
        let row = transaction(payee: composed, narration: "Σ ΟΣ İ ẞ 中文 👩‍💻", tags: [composed, "旅\u{884c}"],
                              postings: [posting("Expenses:\(composed):Lunch", 100)])
        let queries = [decomposed, composed.uppercased(), "σ", "ς", "οσ", "ος", "i", "i\u{0307}", "ß", "ss", "中文", "👩‍💻", "👩", "\u{2003}\(decomposed)\n中文", "#\(decomposed)"]
        for query in queries {
            let filter = LedgerTransactionFilter(query: query)
            XCTAssertEqual(try final([row], filter: filter).matchedCount, filter.matches(row) ? 1 : 0, query)
        }
        let canonical = LedgerTransactionFilter(query: decomposed, account: "Expenses:\(decomposed)", tags: [decomposed])
        XCTAssertTrue(canonical.matches(row))
        XCTAssertEqual(try final([row], filter: canonical).matchedCount, 1)
        // Swift canonical tag/account equality differs from raw UTF-8 comparisons.
        let other = transaction(1, payee: decomposed, tags: [decomposed], postings: [posting("Expenses:\(decomposed):Lunch", 10)])
        let facets = try final([row, other])
        XCTAssertEqual(facets.availableAccounts.count, 1)
        XCTAssertEqual(facets.availableTags.count, 2)
        // No diacritic stripping, metadata search, or amount search is introduced.
        XCTAssertEqual(try final([row], filter: .init(query: "Cafe")).matchedCount, 0)
        let metadata = transaction(metadata: ["note": .string("metadata-only")])
        XCTAssertEqual(try final([metadata], filter: .init(query: "metadata-only")).matchedCount, 0)
    }

    func testEmptyPagesAndZeroMatchesAdvanceRawCursorUntilExplicitEOF() throws {
        var scan = try LocalTransactionScan(expectedRevision: revision, filter: .init(query: "needle"))
        XCTAssertNil(try scan.consume(page([], next: "a"), requestedCursor: nil))
        XCTAssertEqual(scan.nextCursor, "a")
        XCTAssertNil(try scan.consume(page([transaction()], next: "b"), requestedCursor: "a"))
        XCTAssertEqual(scan.nextCursor, "b")
        XCTAssertNil(try scan.consume(page([], next: "c"), requestedCursor: "b"))
        XCTAssertEqual(scan.nextCursor, "c")
        XCTAssertNil(try scan.consume(page([transaction(1, payee: "needle")], next: "d"), requestedCursor: "c"))
        let result = try XCTUnwrap(scan.consume(page([]), requestedCursor: "d"))
        XCTAssertEqual(result.fullRangeCount, 2)
        XCTAssertEqual(result.matchedCount, 1)
        XCTAssertEqual(result.visibleTransactions.first?.source.line, 2)
        XCTAssertEqual(try final([]).fullRangeCount, 0)
    }

    func testRevisionIsRequiredForEveryPageAndErrorPoisonsScan() throws {
        var scan = try LocalTransactionScan(expectedRevision: revision)
        XCTAssertNil(try scan.consume(page([transaction()], next: "a"), requestedCursor: nil))
        assertError(.revisionMismatch) {
            try scan.consume(page([], revision: "replacement-model"), requestedCursor: "a")
        }
        XCTAssertFalse(scan.isComplete)
        XCTAssertEqual(scan.retainedVisibleCount, 0)
        assertError(.failed) { try scan.consume(page([]), requestedCursor: nil) }
        var first = try LocalTransactionScan(expectedRevision: revision)
        assertError(.revisionMismatch) { try first.consume(page([], revision: "wrong"), requestedCursor: nil) }
    }

    func testLockedPagesFailClosedOnDirectConsume() throws {
        for afterFirstPage in [false, true] {
            var scan = try LocalTransactionScan(expectedRevision: revision)
            if afterFirstPage {
                XCTAssertNil(try scan.consume(page([transaction()], next: "a"), requestedCursor: nil))
            }
            let locked = LedgerTransactionPage(
                revision: revision, transactions: [transaction(1)], nextCursor: nil, sensitiveUnlocked: false
            )
            assertError(.locked) {
                try scan.consume(locked, requestedCursor: afterFirstPage ? "a" : nil)
            }
            XCTAssertFalse(scan.isComplete)
            XCTAssertNil(scan.nextCursor)
            XCTAssertEqual(scan.retainedVisibleCount, 0)
            XCTAssertEqual(scan.visibleAccountedBytes, 0)
            XCTAssertEqual(scan.stateAccountedBytes, 0)
            assertError(.failed) { try scan.consume(page([]), requestedCursor: nil) }
        }
    }

    func testRejectsWrongCursorImmediateLoopsLongerLoopsAndEmptyTokens() throws {
        var wrong = try LocalTransactionScan(expectedRevision: revision)
        assertError(.unexpectedCursor) { try wrong.consume(page([]), requestedCursor: "not-first") }
        var reordered = try LocalTransactionScan(expectedRevision: revision)
        XCTAssertNil(try reordered.consume(page([], next: "a"), requestedCursor: nil))
        assertError(.unexpectedCursor) { try reordered.consume(page([]), requestedCursor: nil) }
        var immediate = try LocalTransactionScan(expectedRevision: revision)
        XCTAssertNil(try immediate.consume(page([], next: "a"), requestedCursor: nil))
        assertError(.repeatedCursor) { try immediate.consume(page([], next: "a"), requestedCursor: "a") }
        var longer = try LocalTransactionScan(expectedRevision: revision)
        XCTAssertNil(try longer.consume(page([], next: "a"), requestedCursor: nil))
        XCTAssertNil(try longer.consume(page([], next: "b"), requestedCursor: "a"))
        assertError(.repeatedCursor) { try longer.consume(page([], next: "a"), requestedCursor: "b") }
        var empty = try LocalTransactionScan(expectedRevision: revision)
        assertError(.emptyCursor) { try empty.consume(page([], next: ""), requestedCursor: nil) }
    }

    func testRejectsAllPagesAfterCompletion() throws {
        var scan = try LocalTransactionScan(expectedRevision: revision)
        XCTAssertNotNil(try scan.consume(page([]), requestedCursor: nil))
        assertError(.alreadyCompleted) { try scan.consume(page([]), requestedCursor: nil) }
        assertError(.alreadyCompleted) { try scan.consume(page([], revision: "different"), requestedCursor: "old") }
    }

    func testPageAndConfigurationLimits() throws {
        var scan = try LocalTransactionScan(expectedRevision: revision)
        assertError(.capacityExceeded(.pageRows)) {
            try scan.consume(page(Array(repeating: transaction(), count: 501)), requestedCursor: nil)
        }
        for count in [-1, 1_001] {
            var limits = LocalTransactionScan.Limits()
            limits.maxVisibleCount = count
            assertError(.invalidConfiguration) { try LocalTransactionScan(expectedRevision: revision, limits: limits) }
        }
        assertError(.invalidConfiguration) { try LocalTransactionScan(expectedRevision: "") }
        for keyPath in [\LocalTransactionScan.Limits.maxVisibleBytes, \.maxStateBytes, \.maxDays, \.maxAccounts, \.maxTags, \.maxPages] {
            var limits = LocalTransactionScan.Limits()
            limits[keyPath: keyPath] = -1
            assertError(.invalidConfiguration) { try LocalTransactionScan(expectedRevision: revision, limits: limits) }
        }
        var limits = LocalTransactionScan.Limits()
        limits.maxPages = 0
        assertError(.invalidConfiguration) { try LocalTransactionScan(expectedRevision: revision, limits: limits) }
        limits = .init()
        limits.maxVisibleCount = 0
        limits.maxVisibleBytes = 0
        let result = try final([transaction()], limits: limits)
        XCTAssertEqual(result.matchedCount, 1)
        XCTAssertTrue(result.visibleTransactions.isEmpty)
        XCTAssertTrue(result.hasMoreMatches)
    }

    func testVisibleByteBudgetExactFitAndFirstRowTooLargeStillComplete() throws {
        let row = transaction()
        let charged = try final([row]).visibleAccountedBytes
        XCTAssertGreaterThan(charged, row.narration.utf8.count)
        var limits = LocalTransactionScan.Limits()
        limits.maxVisibleBytes = charged
        let exact = try final([row], limits: limits)
        XCTAssertEqual(exact.visibleTransactions, [row])
        XCTAssertEqual(exact.visibleAccountedBytes, charged)
        XCTAssertFalse(exact.hasMoreMatches)

        for budget in [0, charged - 1] {
            limits.maxVisibleBytes = budget
            var scan = try LocalTransactionScan(expectedRevision: revision, limits: limits)
            let result = try XCTUnwrap(scan.consume(page([row]), requestedCursor: nil))
            XCTAssertTrue(scan.isComplete)
            XCTAssertTrue(result.visibleTransactions.isEmpty)
            XCTAssertEqual(result.visibleAccountedBytes, 0)
            XCTAssertEqual(result.fullRangeCount, 1)
            XCTAssertEqual(result.matchedCount, 1)
            XCTAssertEqual(result.days.first?.expense, 125)
            XCTAssertEqual(result.availableTags, ["food"])
            XCTAssertEqual(result.availableAccounts, ["Assets:Cash", "Expenses:Food"])
            XCTAssertTrue(result.hasMoreMatches)
        }
    }

    func testVisibleByteBudgetCrossesOnLaterPageAndNeverResumesForSmallerRows() throws {
        let first = transaction()
        let large = transaction(1, date: "2026-09-22", narration: String(repeating: "界", count: 4_000),
                                tags: ["large"], postings: [posting("Expenses:Travel", 300)])
        let small = transaction(2, date: "2026-09-21", tags: ["small"], postings: [posting("Expenses:Other", 20)])
        let later = transaction(3, tags: ["later"], postings: [posting("Expenses:Food", -25)])
        let unmatched = transaction(4, payee: "Excluded", tags: ["unmatched"], postings: [posting("Assets:Bank", 1)])
        let rows = [first, large, small, later, unmatched]
        let filter = LedgerTransactionFilter(query: "Shop")
        let full = try final(rows, filter: filter)
        var limits = LocalTransactionScan.Limits()
        // There is room for both smaller following rows, but not the large row.
        limits.maxVisibleBytes = try final([first, small, later]).visibleAccountedBytes
        XCTAssertGreaterThan(try final([large]).visibleAccountedBytes, limits.maxVisibleBytes)
        var scan = try LocalTransactionScan(expectedRevision: revision, filter: filter, limits: limits)
        XCTAssertNil(try scan.consume(page([first], next: "a"), requestedCursor: nil))
        XCTAssertNil(try scan.consume(page([large, small], next: "b"), requestedCursor: "a"))
        XCTAssertEqual(scan.retainedVisibleCount, 1)
        let result = try XCTUnwrap(scan.consume(page([later, unmatched]), requestedCursor: "b"))
        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(result.visibleTransactions, [first])
        XCTAssertEqual(result.visibleAccountedBytes, try final([first]).visibleAccountedBytes)
        XCTAssertTrue(result.hasMoreMatches)
        XCTAssertEqual(result.fullRangeCount, 5)
        XCTAssertEqual(result.matchedCount, 4)
        XCTAssertEqual(result.days, full.days)
        XCTAssertEqual(result.days.map(\.signedExpense), [100, 300, 20])
        XCTAssertEqual(result.availableAccounts, full.availableAccounts)
        XCTAssertEqual(result.availableTags, full.availableTags)
        XCTAssertTrue(result.availableTags.contains("unmatched"))
    }

    func testVisibleByteBudgetAccountsForMetadataAndEntriesAndCannotSkipFirstRow() throws {
        let row = transaction()
        let charged = try final([row]).visibleAccountedBytes
        let text = String(repeating: "界", count: 4_000)
        let extended = transaction(metadata: ["receipt": .string(text)], entry: LedgerTransactionEntry(
            date: "2026-09-23", narration: text, metadata: ["note": .string(text)], tags: [text], links: [text],
            postings: [LedgerTransactionEntryPosting(account: "Assets:Stock", amount: "1", currency: "ABC", costSpec: text)]
        ))
        XCTAssertGreaterThan(try final([extended]).visibleAccountedBytes, charged + 6 * text.utf8.count)
        var limits = LocalTransactionScan.Limits()
        limits.maxVisibleBytes = charged
        var scan = try LocalTransactionScan(expectedRevision: revision, limits: limits)
        XCTAssertNil(try scan.consume(page([extended], next: "a"), requestedCursor: nil))
        let result = try XCTUnwrap(scan.consume(page([row]), requestedCursor: "a"))
        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(result.visibleAccountedBytes, 0)
        XCTAssertTrue(result.visibleTransactions.isEmpty)
        XCTAssertTrue(result.hasMoreMatches)
        XCTAssertEqual(result.matchedCount, 2)
        XCTAssertEqual(result.days.first?.expense, 250)
        // Once the explicit visible count is filled, subsequent payloads are not retained.
        limits.maxVisibleCount = 1
        let capped = try final([row, extended], limits: limits)
        XCTAssertEqual(capped.visibleTransactions, [row])
        XCTAssertEqual(capped.matchedCount, 2)
    }

    func testFacetDayPageAndStateCapsAreTypedAndFailClosed() throws {
        var limits = LocalTransactionScan.Limits()
        limits.maxAccounts = 1
        assertError(.capacityExceeded(.accounts)) { try final([transaction()], filter: .init(query: "no-match"), limits: limits) }
        limits = .init()
        limits.maxTags = 0
        assertError(.capacityExceeded(.tags)) { try final([transaction()], filter: .init(query: "no-match"), limits: limits) }
        XCTAssertEqual(try final([transaction(tags: [""])], limits: limits).availableTags, [])
        limits = .init()
        limits.maxDays = 1
        assertError(.capacityExceeded(.days)) {
            try final([transaction(), transaction(1, date: "2026-09-22")], limits: limits)
        }
        limits.maxDays = 0
        XCTAssertEqual(try final([transaction()], filter: .init(query: "no-match"), limits: limits).days, [])
        limits = .init()
        limits.maxPages = 1
        var pages = try LocalTransactionScan(expectedRevision: revision, limits: limits)
        XCTAssertNil(try pages.consume(page([], next: "a"), requestedCursor: nil))
        assertError(.capacityExceeded(.pages)) { try pages.consume(page([]), requestedCursor: "a") }

        let initial = try LocalTransactionScan(expectedRevision: revision).stateAccountedBytes
        limits = .init()
        limits.maxStateBytes = initial
        XCTAssertEqual(try final([], limits: limits).stateAccountedBytes, initial)
        assertError(.capacityExceeded(.stateBytes)) { try final([transaction()], limits: limits) }
        var cursors = try LocalTransactionScan(expectedRevision: revision, limits: limits)
        assertError(.capacityExceeded(.stateBytes)) { try cursors.consume(page([], next: "a"), requestedCursor: nil) }
        limits.maxStateBytes = initial - 1
        assertError(.capacityExceeded(.stateBytes)) { try LocalTransactionScan(expectedRevision: revision, limits: limits) }
    }

    func testCheckedArithmeticPrecedesMatchesEvenForRowsThatWouldNotMatch() throws {
        let invalid: [[LedgerPosting]] = [
            [posting("Expenses:Food", Int.min)],
            [posting("Income:Salary", Int.min)],
            [posting("Assets:Cash", Int.min)],
            [posting("Expenses:Food", 1), posting("Expenses:Food", -1), posting("Income:Salary", Int.min)],
            [posting("Expenses:Food", Int.min), posting("Expenses:Food", Int.max), posting("Expenses:Food", 1)],
            [posting("Income:Salary", Int.min), posting("Income:Salary", Int.max), posting("Income:Salary", 1)],
            [posting("Expenses:Food", 1), posting("Expenses:Food", -1),
             posting("Income:Salary", Int.max), posting("Income:Salary", 1)],
            [posting("Expenses:Food", Int.max), posting("Expenses:Food", 1)],
            [posting("Income:Salary", Int.max), posting("Income:Salary", 1)],
            [posting("Expenses:Food", -Int.max), posting("Expenses:Food", -1)],
            [posting("Income:Salary", -Int.max), posting("Income:Salary", -1)],
            // The intermediate sum traps even though the mathematical final sum fits.
            [posting("Expenses:Food", Int.max), posting("Expenses:Food", 1), posting("Expenses:Food", -1)],
            [posting("Income:Salary", -Int.max), posting("Income:Salary", -2), posting("Income:Salary", 2)]
        ]
        for postings in invalid {
            assertError(.arithmeticOverflow) {
                try final([transaction(postings: postings)], filter: .init(query: "never-matches", kind: .transfer))
            }
        }
        XCTAssertEqual(try final([transaction(postings: [posting("Expenses:Food", Int.max)])]).days.first?.expense, Int.max)
        XCTAssertEqual(try final([transaction(postings: [posting("Expenses:Food", -Int.max)])]).days.first?.signedExpense, -Int.max)
        XCTAssertEqual(try final([transaction(postings: [posting("Assets:Cash", Int.max)])]).matchedCount, 1)
    }

    func testCheckedArithmeticAllowsSafeFinalSumsAndSkipsUnreachableBranches() throws {
        let fixtures: [(postings: [LedgerPosting], signedExpense: Int)] = [
            ([posting("Expenses:Food", Int.min), posting("Expenses:Food", 1)], -Int.max),
            ([posting("Income:Salary", Int.min), posting("Income:Salary", 1)], 0),
            // A zero expense sum reaches income, but not per-posting transfer abs().
            ([posting("Expenses:Food", Int.min), posting("Expenses:Food", Int.max), posting("Expenses:Food", 1),
              posting("Income:Salary", -1), posting("Assets:Cash", Int.min)], 0),
            ([posting("Expenses:Food", 1), posting("Income:Salary", Int.max), posting("Income:Salary", 1),
              posting("Assets:Cash", Int.min)], 1),
            ([posting("Expenses:Food", -1), posting("Income:Salary", Int.min)], -1),
            ([posting("Income:Salary", -1), posting("Assets:Cash", Int.min)], 0),
            ([posting("Income:Salary", Int.min), posting("Income:Salary", Int.max), posting("Income:Salary", 2),
              posting("Assets:Cash", Int.min)], 0)
        ]
        for fixture in fixtures {
            let row = transaction(postings: fixture.postings)
            // Exercise the real presentation as the oracle, not a duplicate classifier.
            let presentation = TransactionPresentation(transaction: row)
            XCTAssertGreaterThan(presentation.minorUnits, 0)
            for kind in TransactionKindFilter.allCases {
                let filter = LedgerTransactionFilter(kind: kind)
                let result = try final([row], filter: filter)
                let matches = filter.matches(row)
                XCTAssertEqual(result.matchedCount, matches ? 1 : 0)
                XCTAssertEqual(result.days.first?.signedExpense, matches ? fixture.signedExpense : nil)
            }
        }
    }

    func testDailySumsDetectOverflowAcrossPagesAndAfterVisibleCap() throws {
        for amounts in [[Int.max, 1], [-Int.max, -2]] {
            var limits = LocalTransactionScan.Limits()
            limits.maxVisibleCount = 1
            var scan = try LocalTransactionScan(expectedRevision: revision, limits: limits)
            XCTAssertNil(try scan.consume(page([transaction(postings: [posting("Expenses:Food", amounts[0])])], next: "a"), requestedCursor: nil))
            assertError(.arithmeticOverflow) {
                try scan.consume(page([transaction(1, postings: [posting("Expenses:Food", amounts[1])])]), requestedCursor: "a")
            }
            assertError(.failed) { try scan.consume(page([]), requestedCursor: nil) }
        }
        // A representable daily Int.min is safe: the final display clamps, never abs().
        let result = try final([
            transaction(postings: [posting("Expenses:Food", -Int.max)]),
            transaction(1, postings: [posting("Expenses:Food", -1)])
        ])
        XCTAssertEqual(result.days.first?.signedExpense, Int.min)
        XCTAssertEqual(result.days.first?.expense, 0)
    }

    func testReducerAndResultAreSendableValues() throws {
        func requiresSendable<T: Sendable>(_ value: T) {}
        requiresSendable(try LocalTransactionScan(expectedRevision: revision))
        requiresSendable(try final([]))
    }
}