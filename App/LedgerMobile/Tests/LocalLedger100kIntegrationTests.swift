import Foundation
import XCTest
@testable import LedgerMobile

/// Opt-in synthetic capacity probe. Never opens the configured app catalog.
@MainActor
final class LocalLedger100kIntegrationTests: XCTestCase {
    private struct Authenticator: LocalLedgerAuthenticating {
        let isAvailable = true
        func authenticate() async throws { }
    }

    private struct InertWidgetStore: LedgerWidgetCredentialStoring {
        let isAvailable = false
        func load() throws -> LedgerWidgetCredential? { nil }
        func save(_ credential: LedgerWidgetCredential) throws { }
        func suspend() throws { }
        func pendingRevocation() throws -> LedgerWidgetCredential? { nil }
        func completeRevocation(deviceID: String) throws { }
    }

    func testSynthetic100kPagedReadAndConfirmedWrite() async throws {
        #if os(iOS)
        guard ProcessInfo.processInfo.environment["LEDGER_100K_TEST"] == "1" else {
            throw XCTSkip("Opt-in100k synthetic capacity test")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Synthetic100k-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var main = "option \"operating_currency\" \"CNY\"\n2000-01-01 commodity CNY\n2000-01-01 open Assets:Cash CNY\n2000-01-01 open Expenses:Food CNY\n"
        for file in 0..<100 {
            var text = ""
            for row in 0..<1000 {
                let number = file * 1000 + row
                text += "2026-\(String(format: "%02d", number % 12 + 1))-\(String(format: "%02d", number % 28 + 1)) * \"Synthetic\" \"Row \(number)\"\n  Expenses:Food 1 CNY\n  Assets:Cash -1 CNY\n"
            }
            let name = "part-\(file).bean"
            try text.write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
            main += "include \"\(name)\"\n"
        }
        try main.write(to: source.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        let catalog = LocalLedgerCatalog(rootDirectory: root.appendingPathComponent("catalog"))
        let start = ContinuousClock.now
        let descriptor = try await catalog.importLedger(from: source, name: "Synthetic capacity")
        print("SYNTHETIC100K import_ms=\(Self.ms(start.duration(to: .now)))")
        let repository = catalog.repository(for: descriptor)
        let suite = "synthetic-100k-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = LedgerSession(localOnly: true, localCatalog: catalog, localAuthenticator: Authenticator(),
            defaults: defaults, widgetSnapshotStore: LedgerWidgetSnapshotStore(suiteName: suite, lockDirectory: root),
            widgetCredentialStore: InertWidgetStore(), ledgerNow: { Date(timeIntervalSince1970: 1_790_164_800) })
        let sessionStart = ContinuousClock.now
        await session.openLocalLedger(descriptor)
        XCTAssertEqual(session.phase, .ready)
        await session.applyRange(.year(year: 2026))
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.ledger?.summary.expense, 10_000_000)
        XCTAssertEqual(session.ledger?.transactions.count, 100)
        XCTAssertFalse(session.hasCachedGlobalTransactions)
        XCTAssertTrue(session.globalTransactions.isEmpty)
        let selectionRevision = try XCTUnwrap(session.localTransactionPresentationRevision)
        var selection = LocalTransactionSelection(revisionID: selectionRevision,
            start: session.selectedRange.start, end: session.selectedRange.queryEndExclusive)
        selection.setAll(matching: .init(), selected: true)
        let selectionFacts = try await session.localTransactionSelectionFacts(filter: .init(), selection: selection)
        XCTAssertEqual(selectionFacts.selectedCount, 100_000)
        XCTAssertEqual(selectionFacts.selectedMatchingCount, 100_000)
        XCTAssertNil(selectionFacts.tagSources)
        print("SYNTHETIC100K default_session_and_selection_ms=\(Self.ms(sessionStart.duration(to: .now)))")
        session.chooseLedger()
        let pageStart = ContinuousClock.now
        let first = try await repository.transactionPage(limit: 100)
        XCTAssertEqual(first.transactions.count, 100)
        XCTAssertNotNil(first.nextCursor)
        print("SYNTHETIC100K first_page_ms=\(Self.ms(pageStart.duration(to: .now)))")
        let next = try await repository.transactionPage(cursor: first.nextCursor, limit: 100)
        XCTAssertEqual(next.revision, first.revision)
        XCTAssertTrue(Set(first.transactions.map(\.id)).isDisjoint(with: Set(next.transactions.map(\.id))))
        let bqlStart = ContinuousClock.now
        let aggregate = try await repository.runBQL(
            query: "SELECT count(*), sum(amount) FROM postings WHERE account = 'Expenses:Food'",
            valuationCurrency: "CNY")
        XCTAssertEqual(aggregate.rowCount, 1)
        XCTAssertEqual(aggregate.rows, [[.number(100000), .number(10000000)]])
        print("SYNTHETIC100K aggregate_bql_ms=\(Self.ms(bqlStart.duration(to: .now)))")
        let bootstrapStart = ContinuousClock.now
        let home = try await repository.bootstrap(start: "2026-09-01", end: "2026-10-01", today: "2026-09-23", valuationCurrency: "CNY")
        print("SYNTHETIC100K bootstrap_ms=\(Self.ms(bootstrapStart.duration(to: .now)))")
        // Oracle reads the full month, independently of bootstrap row limits.
        let monthlyCount = (0..<100_000).filter { $0 % 12 + 1 == 9 }.count
        XCTAssertEqual(home.summary.expense, monthlyCount * 100)
        let monthlyOracle = try await repository.runBQL(
            query: "SELECT count(*), sum(amount), max(amount) FROM postings WHERE account = 'Expenses:Food' AND date >= '2026-09-01' AND date < '2026-10-01'",
            valuationCurrency: "CNY")
        XCTAssertEqual(monthlyOracle.rows, [[.number(Double(monthlyCount)), .number(Double(monthlyCount * 100)), .number(100)]])
        let categoryStart = ContinuousClock.now
        let currentRevision = try await repository.workspace.currentRevision()
        let revision = try XCTUnwrap(currentRevision)
        let categories = try await repository.overviewCategories(start: "0001-01-01", end: "9999-12-31", expectedRevisionID: revision.id)
        XCTAssertEqual(categories.transactionCount, 100_000)
        XCTAssertEqual(categories.highestExpense, .init(title: "Synthetic", minorUnits: 100))
        XCTAssertEqual(categories.positiveTotalMinorUnits, 10000000)
        XCTAssertEqual(categories.categories.count, 1)
        XCTAssertEqual(categories.categories.first?.positiveTransactionCount, 100000)
        print("SYNTHETIC100K overview_categories_ms=\(Self.ms(categoryStart.duration(to: .now)))")
        let monthly = try await repository.overviewCategories(start: "2026-09-01", end: "2026-10-01", expectedRevisionID: revision.id)
        XCTAssertEqual(monthly.transactionCount, monthlyCount)
        XCTAssertEqual(monthly.highestExpense, .init(title: "Synthetic", minorUnits: 100))
        XCTAssertEqual(monthly.positiveTotalMinorUnits, home.summary.expense)
        // Traverse the real bridge without retaining all rows or IDs. Ordering
        // plus adjacent-source uniqueness detects boundary duplication; exact
        // full counts and posting totals independently verify the traversal.
        let windowStart = ContinuousClock.now
        let reader = try await repository.makeTransactionWindow(start: "0001-01-01", end: "9999-12-31",
            expectedRevisionID: revision.id)
        var seen = 0
        var windows = 0
        var expense = 0
        var previous: LedgerTransaction?
        while true {
            let window = try await reader.nextWindow()
            windows += 1
            XCTAssertLessThanOrEqual(window.transactions.count, 1_000)
            XCTAssertLessThanOrEqual(window.accountedBytes, 4 * 1_024 * 1_024)
            for row in window.transactions {
                if let previous {
                    XCTAssertGreaterThanOrEqual(previous.date, row.date)
                    XCTAssertNotEqual(previous.source, row.source)
                }
                previous = row
                seen += 1
                expense += row.postings.filter { $0.account.hasPrefix("Expenses:") }.reduce(0) { $0 + $1.amount }
            }
            if windows == 1 {
                print("SYNTHETIC100K first_window_ms=\(Self.ms(windowStart.duration(to: .now)))")
            }
            if window.isComplete {
                let summary = try XCTUnwrap(window.summary)
                XCTAssertEqual(summary.fullRangeCount, 100_000)
                XCTAssertEqual(summary.matchedCount, 100_000)
                XCTAssertEqual(summary.days.reduce(0) { $0 + $1.signedExpense }, 10_000_000)
                XCTAssertEqual(Set(summary.availableAccounts), ["Assets:Cash", "Expenses:Food"])
                XCTAssertTrue(summary.visibleTransactions.isEmpty)
                break
            }
            XCTAssertNil(window.summary)
        }
        XCTAssertEqual(seen, 100_000)
        XCTAssertEqual(expense, 10_000_000)
        print("SYNTHETIC100K windows=\(windows) traversal_ms=\(Self.ms(windowStart.duration(to: .now)))")
        await reader.invalidate()
        let entry = LedgerTransactionEntry(date: "2026-09-23", payee: "Synthetic", narration: "Confirmed capacity probe", postings: [
            .init(account: "Expenses:Food", amount: "1", currency: "CNY"), .init(account: "Assets:Cash", amount: "-1", currency: "CNY")])
        let previewStart = ContinuousClock.now
        let preview = try await repository.prepareBookkeeping(.manual(entry))
        print("SYNTHETIC100K preview_ms=\(Self.ms(previewStart.duration(to: .now)))")
        let commitStart = ContinuousClock.now
        _ = try await repository.commitPrepared(preview)
        print("SYNTHETIC100K commit_ms=\(Self.ms(commitStart.duration(to: .now)))")
        let after = try await repository.bootstrap(start: "2026-09-01", end: "2026-10-01", today: "2026-09-23", valuationCurrency: "CNY")
        XCTAssertEqual(after.summary.expense, home.summary.expense + 100)
        let fresh = try await repository.transactionPage(limit: 100)
        XCTAssertNotEqual(fresh.revision, first.revision)
        print("SYNTHETIC100K total_ms=\(Self.ms(start.duration(to: .now)))")
        #else
        throw XCTSkip("Requires embedded iOS runtime")
        #endif
    }

    func testSyntheticRichLedgerGoldenAccountingAndBoundedSession() async throws {
        #if os(iOS)
        let rawCount = ProcessInfo.processInfo.environment["LEDGER_RICH_CAPACITY_COUNT"] ?? ""
        guard let count = Int(rawCount), [1_000, 10_000, 50_000, 100_000].contains(count) else {
            throw XCTSkip("Set LEDGER_RICH_CAPACITY_COUNT to an approved synthetic fixture size")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticRich-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let groups = count / 4
        var main = """
        plugin "beancount.plugins.auto_accounts"
        option "operating_currency" "CNY"
        2000-01-01 commodity CNY
        2000-01-01 commodity USD
        2000-01-01 commodity VT
        2026-01-01 price USD 7.10 CNY
        2026-01-01 price VT 160 CNY

        """
        var sourceBytes = 0
        var metadataRows = 0
        var transactionHeaderBytes = 0
        var postingBytes = 0
        var metadataBytes = 0
        for file in 0..<(count / 1_000) {
            var lines: [String] = []
            lines.reserveCapacity(4_000)
            for offset in 0..<1_000 {
                let number = file * 1_000 + offset
                let date = "2026-\(String(format: "%02d", number % 12 + 1))-\(String(format: "%02d", number % 28 + 1))"
                switch number % 4 {
                case 0:
                    lines.append("\(date) * \"Synthetic\" \"CNY expense \(number)\"\n  Expenses:Food 1 CNY\n  Assets:Cash -1 CNY\n")
                case 1:
                    lines.append("\(date) * \"Synthetic\" \"USD expense \(number)\"\n  Expenses:Travel 1 USD\n  Assets:Dollar -1 USD\n")
                case 2:
                    lines.append("\(date) * \"Synthetic\" \"Stock buy \(number)\"\n  Assets:Broker 1 VT {10 USD}\n  Assets:Dollar -10 USD\n")
                default:
                    lines.append("\(date) * \"Synthetic\" \"Metadata \(number)\" #fixture\n  note: \"synthetic metadata only\"\n  Expenses:Food 2 CNY\n  Assets:Cash -2 CNY\n")
                    metadataRows += 1
                }
                let recordLines = lines[lines.count - 1].split(separator: "\n")
                transactionHeaderBytes += recordLines[0].utf8.count + 1
                for line in recordLines.dropFirst() {
                    if line.hasPrefix("  note:") { metadataBytes += line.utf8.count + 1 }
                    else { postingBytes += line.utf8.count + 1 }
                }
            }
            let name = "part-\(file).bean"
            let data = Data(lines.joined().utf8)
            try data.write(to: source.appendingPathComponent(name))
            sourceBytes += data.count
            main += "include \"\(name)\"\n"
        }
        let mainData = Data(main.utf8)
        try mainData.write(to: source.appendingPathComponent("main.bean"))
        sourceBytes += mainData.count
        XCTAssertEqual(transactionHeaderBytes + postingBytes + metadataBytes, sourceBytes - mainData.count)
        let manifest: [String: Int] = ["transactions": count, "postings": count * 2,
            "metadataTransactions": metadataRows, "sourceFiles": count / 1_000 + 1,
            "sourceBytes": sourceBytes, "sourceRecordCount": count * 3 + metadataRows,
            "sourceRecordBytes": transactionHeaderBytes + postingBytes + metadataBytes,
            "transactionHeaderBytes": transactionHeaderBytes, "postingBytes": postingBytes,
            "metadataBytes": metadataBytes, "expectedExpenseCNYMinor": groups * 1_010,
            "expectedCashCNYMinor": -groups * 300, "expectedDollarUSDMinor": -groups * 1_100,
            "expectedBrokerVTMinor": groups * 100]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let attachment = XCTAttachment(data: manifestData, uniformTypeIdentifier: "public.json")
        attachment.name = "synthetic-rich-\(count)-manifest.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        let catalog = LocalLedgerCatalog(rootDirectory: root.appendingPathComponent("catalog"))
        let started = ContinuousClock.now
        let descriptor = try await catalog.importLedger(from: source, name: "Synthetic rich \(count)")
        let repository = catalog.repository(for: descriptor)
        let currentRevision = try await repository.workspace.currentRevision()
        let revision = try XCTUnwrap(currentRevision?.id)
        let page = try await repository.bootstrapPage(start: "2026-01-01", end: "2027-01-01",
            today: "2026-09-23", valuationCurrency: "CNY", expectedRevisionID: revision)
        XCTAssertTrue(page.bootstrap.transactions.isEmpty)
        XCTAssertEqual(page.transactionPage.transactions.count, 100)
        XCTAssertNotNil(page.transactionPage.nextCursor)
        XCTAssertEqual(page.bootstrap.summary.expense, groups * 1_010)
        let balances = Dictionary(uniqueKeysWithValues: page.bootstrap.accountBalances.map {
            ("\($0.account):\($0.currency)", $0.amount)
        })
        XCTAssertEqual(balances["Assets:Cash:CNY"], -groups * 300)
        XCTAssertEqual(balances["Assets:Dollar:USD"], -groups * 1_100)
        XCTAssertEqual(balances["Assets:Broker:VT"], groups * 100)
        let bql = try await repository.runBQL(query: "SELECT count(*), sum(amount) FROM postings WHERE account = 'Expenses:Food'", valuationCurrency: "CNY")
        XCTAssertEqual(bql.rows, [[.number(Double(groups * 2)), .number(Double(groups * 300))]])
        let suite = "synthetic-rich-\(count)-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = LedgerSession(localOnly: true, localCatalog: catalog, localAuthenticator: Authenticator(),
            defaults: defaults, widgetSnapshotStore: LedgerWidgetSnapshotStore(suiteName: suite, lockDirectory: root),
            widgetCredentialStore: InertWidgetStore(), ledgerNow: { Date(timeIntervalSince1970: 1_790_164_800) })
        await session.openLocalLedger(descriptor)
        await session.applyRange(.year(year: 2026))
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.ledger?.summary.expense, groups * 1_010)
        XCTAssertEqual(session.ledger?.transactions.count, 100)
        XCTAssertTrue(session.globalTransactions.isEmpty)
        session.chooseLedger()
        print("SYNTHETIC_RICH count=\(count) source_bytes=\(sourceBytes) total_ms=\(Self.ms(started.duration(to: .now)))")
        #else
        throw XCTSkip("Requires embedded iOS runtime")
        #endif
    }

    private static func ms(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
}
