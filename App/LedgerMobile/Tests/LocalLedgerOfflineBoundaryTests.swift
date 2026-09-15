import Foundation
import XCTest
@testable import LedgerMobile

/// Rejects HTTP(S) at URLSession's protocol boundary while exercising the
/// production local read/write bridges. The fixture owns every ledger file.
final class LocalLedgerOfflineBoundaryTests: XCTestCase {
    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URL] = []
        func record(_ url: URL) { lock.lock(); defer { lock.unlock() }; requests.append(url) }
        func take() -> [URL] { lock.lock(); defer { lock.unlock() }; defer { requests.removeAll() }; return requests }
    }

    private final class OfflineProtocol: URLProtocol, @unchecked Sendable {
        static let requests = Requests()
        override class func canInit(with request: URLRequest) -> Bool {
            guard let url = request.url, ["http", "https"].contains(url.scheme ?? "") else { return false }
            requests.record(url)
            return true
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }

    func testCanonicalReadsEditsAndTagsWithHTTPDisabled() async throws {
        #if os(iOS)
        XCTAssertTrue(URLProtocol.registerClass(OfflineProtocol.self))
        defer { URLProtocol.unregisterClass(OfflineProtocol.self) }
        // Verify that the boundary blocks the same shared URLSession used by
        // the HTTP client before testing the local repository.
        do {
            _ = try await URLSession.shared.data(from: URL(string: "https://offline-boundary.invalid/probe")!)
            XCTFail("The offline boundary should reject HTTP")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        XCTAssertFalse(OfflineProtocol.requests.take().isEmpty)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineBoundary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = LocalLedgerCatalog(rootDirectory: root)
        let descriptor = try await catalog.create(name: "Device only")
        let repository = catalog.repository(for: descriptor)
        _ = try await repository.bootstrap(start: "2026-09-01", end: "2026-10-01", today: "2026-09-15", valuationCurrency: "CNY")
        func entry(_ amount: String, narration: String) -> LedgerTransactionEntry {
            LedgerTransactionEntry(date: "2026-09-15", payee: "Offline fixture", narration: narration,
                metadata: [:], tags: [], postings: [.init(account: "Expenses:Food", amount: amount, currency: "CNY"),
                                         .init(account: "Assets:Cash", amount: "-" + amount, currency: "CNY")])
        }
        try await repository.addTransaction(entry: entry("8.00", narration: "Original"))
        let created = try await repository.globalTransactions()
        let original = try XCTUnwrap(created.transactions.first)
        try await repository.updateTransaction(source: original.source, entry: entry("9.25", narration: "Edited on device"))
        let edited = try await repository.globalTransactions()
        let updated = try XCTUnwrap(edited.transactions.first)
        XCTAssertEqual(updated.narration, "Edited on device")
        try await repository.addTransactionTags(sources: [updated.source], tags: ["offline-checked"])
        let tagged = try await repository.globalTransactions()
        XCTAssertTrue(try XCTUnwrap(tagged.transactions.first).tags?.contains("offline-checked") == true)
        _ = try await repository.dashboard(start: "2026-09-01", end: "2026-10-01", valuationCurrency: "CNY")
        _ = try await repository.runBQL(query: "SELECT account, sum(value) AS total FROM postings GROUP BY account", valuationCurrency: "CNY")
        _ = try await repository.importProviders()
        _ = try await repository.importDocuments()
        let draft = try await repository.readFile(path: descriptor.entrypoint)
        try await repository.saveFile(draft, text: draft.text + "\n; Edited offline\n")
        let final = try await repository.readFile(path: descriptor.entrypoint)
        XCTAssertTrue(final.text.contains("Edited offline"))
        XCTAssertTrue(OfflineProtocol.requests.take().isEmpty, "Local operations attempted an HTTP request")
        #else
        throw XCTSkip("Requires the iOS app-host embedded Go and Beancount runtimes")
        #endif
    }
}
