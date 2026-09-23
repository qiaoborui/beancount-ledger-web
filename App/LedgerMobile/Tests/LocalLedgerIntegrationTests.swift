import Foundation
import XCTest
#if canImport(BeancountRuntime)
import BeancountRuntime
#endif
@testable import LedgerMobile

/// Exercises the production Go + CPython bridges in the signed app host.
/// Every file belongs to a unique temporary fixture; no configured ledger is read.
final class LocalLedgerIntegrationTests: XCTestCase {
    func testCandidateScanMatchesLegacyUnicodeFiltersAndFullSummariesWithoutWrites() async throws {
        #if os(iOS) && canImport(BeancountRuntime) && canImport(LedgerCore)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CandidateIntegration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = LocalLedgerWorkspace(rootDirectory: root)
        let composed = "Caf\u{00e9}"
        let decomposed = "Cafe\u{0301}"
        // One long grapheme, not hundreds of transactions or parser invocations.
        let combining = "a" + String(repeating: "\u{0301}", count: 600)
        let unicode = "✁ 👩\u{200d}💻 " + combining
        var text = """
        2000-01-01 open Assets:Cash CNY
        2000-01-01 open Assets:Bank CNY
        2000-01-01 open Expenses:Food CNY
        2000-01-01 open Income:Other CNY
        2000-01-01 open Expenses:Outside CNY

        """
        // The entire first page is deliberately irrelevant to Unicode/refund filters.
        for index in 0..<500 {
            text += """
            2026-09-23 * "Ordinary" "Synthetic row \(index)" #ordinary
              Expenses:Food 1 CNY
              Assets:Cash -1 CNY

            """
        }
        for payee in [composed, decomposed] {
            text += """
            2026-09-22 * "\(payee)" "\(unicode)" #unicode
              Expenses:Food 2 CNY
              Assets:Cash -2 CNY

            """
        }
        text += """
        2026-09-21 * "Synthetic credit" "Metadata-only evidence" #refund
          type: "退款"
          fixture: "not candidate evidence"
          Income:Other -3 CNY
          Assets:Cash 3 CNY

        2026-09-21 * "Synthetic reversal" "Signed expense" #reversal
          Expenses:Food -4 CNY
          Assets:Cash 4 CNY

        2026-09-20 * "Synthetic move" "Tail-only account and tag" #tail
          Assets:Bank 5 CNY
          Assets:Cash -5 CNY

        2026-08-31 * "Outside" "Before range" #outside
          Expenses:Outside 7 CNY
          Assets:Cash -7 CNY

        2026-10-01 * "Outside" "Exclusive end" #outside
          Expenses:Outside 7 CNY
          Assets:Cash -7 CNY

        """
        let original = Data(text.utf8)
        // One real canonical validation/commit; never use the configured catalog.
        let initial = try await workspace.commit(changes: [.write(original, to: "main.bean")]) { root in
            try await EmbeddedBeancountValidator.shared.validate(workspace: root, entryFile: "main.bean")
        }
        let repository = LocalLedgerRepository(
            descriptor: .init(id: UUID(), name: "Synthetic candidates", entrypoint: "main.bean", createdAt: Date()),
            workspace: workspace)
        let start = "2026-09-01", end = "2026-10-01"
        let bootstrap = try await repository.bootstrapSnapshot(start: start, end: end, today: "2026-09-23", valuationCurrency: "CNY")
        XCTAssertEqual(bootstrap.revisionID, initial.id)
        XCTAssertTrue(bootstrap.payload.sensitiveUnlocked)
        let legacy = try await repository.globalTransactions()
        XCTAssertEqual(legacy.transactions.count, 507)
        let rows = legacy.transactions.filter { $0.date >= start && $0.date < end }
        XCTAssertEqual(rows.count, 505)

        let first = try await repository.candidatePage(start: start, end: end, expectedRevisionID: bootstrap.revisionID)
        XCTAssertEqual(first.transactions.count, 500)
        let cursor = try XCTUnwrap(first.nextCursor)
        let last = try await repository.candidatePage(start: start, end: end, cursor: cursor, expectedRevisionID: bootstrap.revisionID)
        XCTAssertEqual(last.transactions.count, 5)
        XCTAssertNil(last.nextCursor)
        XCTAssertEqual(last.revision, first.revision)
        let candidates = first.transactions + last.transactions
        // Compare the actual wire projection, not only IDs/counts. Candidate rows
        // omit editor drafts and arbitrary metadata but retain string type evidence.
        func projection(_ row: LedgerTransaction) -> LedgerTransaction {
            let metadata = row.metadata?["type"]?.stringValue.map { ["type": LedgerMetadataValue.string($0)] }
            return LedgerTransaction(date: row.date, payee: row.payee, narration: row.narration,
                                     metadata: metadata, tags: row.tags, postings: row.postings, source: row.source)
        }
        XCTAssertEqual(candidates, rows.map(projection))
        XCTAssertTrue(candidates.allSatisfy { $0.editableEntry == nil })
        let refund = try XCTUnwrap(candidates.first { $0.narration == "Metadata-only evidence" })
        XCTAssertEqual(refund.metadata, ["type": .string("退款")])
        XCTAssertTrue(TransactionPresentation(transaction: refund).isRefund)
        XCTAssertEqual(TransactionPresentation(transaction: refund).kind, .income)
        let legacyRefund = try XCTUnwrap(rows.first { $0.id == refund.id })
        XCTAssertEqual(legacyRefund.metadata?["fixture"], .string("not candidate evidence"))

        let accounts = Array(Set(rows.flatMap { $0.postings.map(\.account) }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let tags = Array(Set(rows.flatMap { $0.tags ?? [] }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var limits = LocalTransactionScan.Limits()
        limits.maxVisibleCount = 2
        let filters = [
            LedgerTransactionFilter(),
            LedgerTransactionFilter(query: composed),
            LedgerTransactionFilter(query: decomposed),
            LedgerTransactionFilter(query: "✁"),
            LedgerTransactionFilter(query: "👩\u{200d}💻"),
            LedgerTransactionFilter(query: "👩"),
            LedgerTransactionFilter(query: combining),
            LedgerTransactionFilter(query: "\(decomposed) ✁", kind: .expense, account: "Expenses", tags: ["unicode"]),
            LedgerTransactionFilter(kind: .income, tags: ["refund", "reversal"]),
            LedgerTransactionFilter(kind: .transfer),
            LedgerTransactionFilter(query: "no synthetic match")
        ]
        XCTAssertEqual(rows.filter(LedgerTransactionFilter(query: decomposed).matches).count, 2)
        XCTAssertEqual(rows.filter(LedgerTransactionFilter(query: combining).matches).count, 2)
        for filter in filters {
            let result = try await repository.scanTransactions(start: start, end: end, filter: filter,
                                                               expectedRevisionID: bootstrap.revisionID, limits: limits)
            let matched = rows.filter(filter.matches)
            XCTAssertEqual(result.revision, first.revision)
            XCTAssertEqual(result.fullRangeCount, 505)
            XCTAssertEqual(result.matchedCount, matched.count, "Filter: \(filter)")
            XCTAssertEqual(result.visibleTransactions, matched.prefix(2).map(projection))
            XCTAssertEqual(result.hasMoreMatches, matched.count > 2)
            XCTAssertEqual(result.availableAccounts, accounts)
            XCTAssertEqual(result.availableTags, tags)
            XCTAssertTrue(result.availableAccounts.contains("Assets:Bank"))
            XCTAssertTrue(result.availableTags.contains("tail"))
            XCTAssertFalse(result.availableTags.contains("outside"))
            let grouped = Dictionary(grouping: matched, by: \.date)
            XCTAssertEqual(result.days.map(\.date), grouped.keys.sorted(by: >))
            for day in result.days {
                let group = try XCTUnwrap(grouped[day.date])
                let signed = group.flatMap(\.postings).filter { $0.account.hasPrefix("Expenses:") }
                    .reduce(0) { $0 + $1.amount }
                XCTAssertEqual(day.matchedCount, group.count)
                XCTAssertEqual(day.signedExpense, signed)
                XCTAssertEqual(day.expense, max(0, signed))
            }
        }
        // A workspace UUID, not the native page revision, pairs reads to bootstrap.
        let wrongRevision = UUID()
        do {
            _ = try await repository.candidatePage(start: start, end: end, expectedRevisionID: wrongRevision)
            XCTFail("Candidate page accepted a non-bootstrap UUID")
        } catch {
            XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision)
        }
        do {
            _ = try await repository.scanTransactions(start: start, end: end, filter: .init(), expectedRevisionID: wrongRevision)
            XCTFail("Candidate scan accepted a non-bootstrap UUID")
        } catch {
            XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision)
        }
        let after = try await workspace.currentRevision()
        let saved = try await workspace.readFile(at: "main.bean")
        let presented = await repository.presentedRevisionID
        XCTAssertEqual(after, initial, "Read-only candidate operations must not publish a ledger revision")
        XCTAssertEqual(saved, original, "Candidate operations must preserve exact ledger bytes")
        XCTAssertEqual(presented, bootstrap.revisionID, "Candidate reads must not change the presented bootstrap UUID")
        #else
        throw XCTSkip("Requires the iOS app-host Python and Go bridges")
        #endif
    }

    func testValidationOnlyBridgeKeepsCanonicalDiagnosticsAndReadModel() async throws {
        #if os(iOS) && canImport(BeancountRuntime)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ValidationOnly-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main.bean")
        let valid = """
        plugin "beancount.plugins.auto_accounts"
        2026-01-01 * "Synthetic precision fixture"
          Assets:Cash -1.234567 CNY
          Expenses:Food 1.234567 CNY

        """
        try valid.write(to: main, atomically: true, encoding: .utf8)
        try await EmbeddedBeancountValidator.shared.validate(workspace: root)
        let model = try await EmbeddedBeancountValidator.shared.canonicalModel(workspace: root)
        XCTAssertTrue(String(decoding: model, as: UTF8.self).contains("1.234567"))
        // Call the native symbol too: its success payload must contain no model.
        let pointer = root.path.withCString { workspace in
            "main.bean".withCString { BRValidateOnly(workspace, $0) }
        }
        let raw = try XCTUnwrap(pointer)
        defer { BRFree(raw) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["errors"])
        XCTAssertEqual((object["errors"] as? [Any])?.count, 0)
        try valid.replacingOccurrences(of: "Food 1.234567", with: "Food 1.000000")
            .write(to: main, atomically: true, encoding: .utf8)
        var messages: [String] = []
        do {
            try await EmbeddedBeancountValidator.shared.validate(workspace: root)
            XCTFail("Validation-only accepted an unbalanced transaction")
        } catch let error as EmbeddedBeancountValidator.ValidationError { messages.append(error.message) }
        do {
            _ = try await EmbeddedBeancountValidator.shared.canonicalModel(workspace: root)
            XCTFail("Canonical load accepted an unbalanced transaction")
        } catch let error as EmbeddedBeancountValidator.ValidationError { messages.append(error.message) }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first, messages.last)
        #else
        throw XCTSkip("Requires the app-linked canonical Beancount runtime")
        #endif
    }

    func testCanonicalStreamExportIsSmallExclusiveAndKeepsSourceUntouched() async throws {
        #if os(iOS) && canImport(BeancountRuntime)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("StreamIntegration-" + UUID().uuidString)
        let source = base.appendingPathComponent("workspace")
        let output = base.appendingPathComponent("canonical.records")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let text = "2000-01-01 open Assets:Cash CNY\n"
        try text.write(to: source.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        let result = try await EmbeddedBeancountValidator.shared.exportCanonical(workspace: source, to: output)
        XCTAssertEqual(result.entries, 1)
        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertEqual(result.sha256.count, 64)
        let exported = try Data(contentsOf: output)
        XCTAssertEqual(result.bytes, exported.count)
        XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("end_entry"))
        do {
            _ = try await EmbeddedBeancountValidator.shared.exportCanonical(workspace: source, to: output)
            XCTFail("Existing export overwritten")
        } catch is EmbeddedBeancountValidator.ValidationError { }
        XCTAssertEqual(try Data(contentsOf: output), exported)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("main.bean"), encoding: .utf8), text)
        #else
        throw XCTSkip("Requires embedded canonical runtime")
        #endif
    }

    func testConcurrentModelReadsAndDiscardedPreviewKeepCursorValid() async throws {
        #if os(iOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HandleIntegration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = LocalLedgerCatalog(rootDirectory: root)
        let descriptor = try await catalog.create(name: "Handles")
        let repository = catalog.repository(for: descriptor)
        func entry(_ n: Int) -> LedgerTransactionEntry {
            LedgerTransactionEntry(date: "2026-09-01", payee: "Synthetic", narration: "Row \(n)", postings: [
                .init(account: "Expenses:Food", amount: "1", currency: "CNY"),
                .init(account: "Assets:Cash", amount: "-1", currency: "CNY")])
        }
        _ = try await repository.bootstrap(start: "2026-09-01", end: "2026-10-01", today: "2026-09-01", valuationCurrency: "CNY")
        for i in 0..<3 { try await repository.addTransaction(entry: entry(i)) }
        let pages = try await withThrowingTaskGroup(of: LedgerTransactionPage.self) { group in
            for _ in 0..<4 { group.addTask { try await repository.transactionPage(limit: 1) } }
            var results: [LedgerTransactionPage] = []
            for try await page in group { results.append(page) }
            return results
        }
        XCTAssertEqual(Set(pages.map(\.revision)).count, 1)
        let cursor = try XCTUnwrap(pages.first?.nextCursor)
        let preview = try await repository.prepareBookkeeping(.manual(entry(4)))
        await repository.discardPrepared(preview)
        let probe = try await repository.transactionPage(limit: 1)
        XCTAssertEqual(probe.revision, pages.first?.revision, "Preview must preserve exact committed model identity")
        let next = try await repository.transactionPage(cursor: cursor, limit: 1)
        XCTAssertEqual(next.revision, pages.first?.revision)
        XCTAssertNotEqual(next.transactions.first?.id, pages.first?.transactions.first?.id)
        let evidence = try await repository.classificationHistoryPage(cursor: nil)
        XCTAssertEqual(evidence.revision, next.revision)
        XCTAssertEqual(evidence.transactions.count, 3)
        XCTAssertTrue(evidence.transactions.allSatisfy { $0.editableEntry == nil })
        #else
        throw XCTSkip("Requires embedded native model registry")
        #endif
    }

    func testCanonicalOfflineCreateReadAddEditDeleteAndReopen() async throws {
        #if os(iOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalIntegration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = LocalLedgerCatalog(rootDirectory: root)
        let descriptor = try await catalog.create(name: "Offline integration")
        let repository = catalog.repository(for: descriptor)
        let empty = try await repository.bootstrap(start: "2026-09-01", end: "2026-10-01", today: "2026-09-15", valuationCurrency: "CNY")
        XCTAssertTrue(empty.transactions.isEmpty)
        XCTAssertTrue(empty.sensitiveUnlocked)
        XCTAssertFalse(empty.accounts.isEmpty)

        func entry(_ amount: String, credit: String, narration: String) -> LedgerTransactionEntry {
            LedgerTransactionEntry(date: "2026-09-15", payee: "Offline fixture", narration: narration,
                metadata: ["file": .string("receipt.pdf")], tags: ["offline"], postings: [
                    .init(account: "Expenses:Food", amount: amount, currency: "CNY"),
                    .init(account: "Assets:Cash", amount: credit, currency: "CNY")
                ])
        }
        try await repository.addTransaction(entry: entry("12.34", credit: "-12.34", narration: "created offline"))
        let initial = try await repository.globalTransactions()
        XCTAssertEqual(initial.transactions.count, 1)
        let transaction = try XCTUnwrap(initial.transactions.first)
        XCTAssertEqual(transaction.narration, "created offline")
        XCTAssertEqual(transaction.metadata?["file"], .string("receipt.pdf"))
        XCTAssertFalse(transaction.source.file.hasPrefix("/"))

        let beforeInvalid = try await repository.workspace.currentRevision()
        do {
            try await repository.addTransaction(entry: entry("12.34", credit: "-11.00", narration: "must reject"))
            XCTFail("Canonical validation accepted an unbalanced transaction")
        } catch { }
        let afterInvalid = try await repository.workspace.currentRevision()
        XCTAssertEqual(beforeInvalid?.id, afterInvalid?.id)

        try await repository.updateTransaction(source: transaction.source,
            entry: entry("15.67", credit: "-15.67", narration: "edited offline"))
        let updated = try await repository.globalTransactions()
        XCTAssertEqual(updated.transactions.count, 1)
        XCTAssertEqual(updated.transactions.first?.narration, "edited offline")
        XCTAssertEqual(updated.transactions.first?.editableEntry?.metadata["file"], .string("receipt.pdf"))
        _ = try await repository.homeReport(start: "2026-09-01", end: "2026-10-01", valuationCurrency: "CNY")
        _ = try await repository.dashboard(start: "2026-09-01", end: "2026-10-01", valuationCurrency: "CNY")
        _ = try await repository.incomeStatement(start: "2026-09-01", end: "2026-10-01", valuationCurrency: "CNY")
        _ = try await repository.accountDetail(account: "Assets:Cash", currency: "CNY", start: "2026-09-01", end: "2026-10-01")
        _ = try await repository.investments()
        _ = try await repository.runBQL(query: "SELECT account, sum(value) AS total FROM postings GROUP BY account", valuationCurrency: "CNY")

        let reopened = LocalLedgerCatalog(rootDirectory: root)
        let descriptors = try await reopened.list()
        XCTAssertEqual(descriptors, [descriptor])
        let restored = reopened.repository(for: descriptor)
        let restoredTransactions = try await restored.globalTransactions()
        XCTAssertEqual(restoredTransactions.transactions.first?.narration, "edited offline")
        try await restored.deleteTransaction(source: XCTUnwrap(restoredTransactions.transactions.first).source, reason: "Integration fixture cleanup")
        let deleted = try await restored.globalTransactions()
        XCTAssertTrue(deleted.transactions.isEmpty)
        let exported = try await restored.exportLedger()
        defer { try? FileManager.default.removeItem(at: exported) }
        let saved = try String(contentsOf: exported.appendingPathComponent("transactions/2026/09.bean"), encoding: .utf8)
        XCTAssertTrue(saved.contains("file: \"receipt.pdf\""), "Stored metadata must retain the exact user value, including in recoverable deletion comments")
        try await EmbeddedBeancountValidator.shared.validate(workspace: exported, entryFile: descriptor.entrypoint)
        #else
        throw XCTSkip("Requires the app-linked iOS Go and canonical Beancount runtimes")
        #endif
    }
}
