import Foundation
import XCTest
@testable import LedgerMobile

/// Opt-in synthetic capacity probe. Never opens the configured app catalog.
final class LocalLedger100kIntegrationTests: XCTestCase {
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
        let pageStart = ContinuousClock.now
        let first = try await repository.transactionPage(limit: 100)
        XCTAssertEqual(first.transactions.count, 100)
        XCTAssertNotNil(first.nextCursor)
        print("SYNTHETIC100K first_page_ms=\(Self.ms(pageStart.duration(to: .now)))")
        let next = try await repository.transactionPage(cursor: first.nextCursor, limit: 100)
        XCTAssertEqual(next.revision, first.revision)
        XCTAssertTrue(Set(first.transactions.map(\.id)).isDisjoint(with: Set(next.transactions.map(\.id))))
        let bootstrapStart = ContinuousClock.now
        let home = try await repository.bootstrap(start: "2026-09-01", end: "2026-10-01", today: "2026-09-23", valuationCurrency: "CNY")
        XCTAssertGreaterThan(home.summary.expense, 0)
        print("SYNTHETIC100K bootstrap_ms=\(Self.ms(bootstrapStart.duration(to: .now)))")
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

    private static func ms(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
}
