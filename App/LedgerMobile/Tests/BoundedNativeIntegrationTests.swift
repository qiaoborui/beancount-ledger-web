#if canImport(UIKit) && LEDGER_BOUNDED_READ_INDEX
import Foundation
import XCTest
@testable import LedgerMobile

final class BoundedNativeIntegrationTests: XCTestCase {
    func testAppContainerPublicationPagingValuationAndLifecycle() async throws {
        try await exercise(transactionCount: 205)
    }

    func testTenThousandTransactionsRemainPagedInAppContainer() async throws {
        try await exercise(transactionCount: 10_000)
    }

    private func exercise(transactionCount: Int) async throws {
        XCTAssertEqual(Bundle.main.bundleURL.pathExtension, "app")
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let root = support.appendingPathComponent("BoundedNativeTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = LocalLedgerWorkspace(rootDirectory: root)
        var source = """
        2026-01-01 open Assets:Cash USD
        2026-01-01 open Expenses:Food USD
        2026-01-01 price USD 2 EUR

        """
        for index in 0..<transactionCount {
            source += "\n2026-01-02 * \"Synthetic \(index)\"\n  Expenses:Food  1 USD\n  Assets:Cash  -1 USD\n"
        }
        let revision = try await workspace.commit(changes: [.write(Data(source.utf8), to: "main.bean")], validator: {
            try await EmbeddedBeancountValidator.shared.validate(workspace: $0)
        })
        let publication = BoundedLedgerPublication(workspace: workspace)
        publication.unlock()
        let manifest = try await publication.rebuild(expectedRevisionID: revision.id)
        XCTAssertEqual(manifest.index.schemaVersion, 3)
        XCTAssertEqual(manifest.index.transactions, Int64(transactionCount))
        let escaped = try await publication.withReadLease { lease, reader in
            XCTAssertEqual(lease.source.revisionID, revision.id)
            XCTAssertFalse(lease.isStale)
            var cursor: String?
            var count = 0
            repeat {
                let page = try reader.transactions(limit: 100, cursor: cursor)
                XCTAssertLessThanOrEqual(page.transactions.count, 100)
                count += page.transactions.count
                cursor = page.nextCursor
            } while cursor != nil
            XCTAssertEqual(count, transactionCount)
            XCTAssertEqual(try reader.accountSummary(account: "Assets:Cash", currency: "USD").currentBalance, "-\(transactionCount)")
            XCTAssertEqual(try reader.priceLookup(base: "USD", quote: "EUR").price?.quantity, "2")
            XCTAssertEqual(try reader.valueLegacyCents(amount: -Int64(transactionCount) * 100, base: "USD", quote: "EUR").amount, -Int64(transactionCount) * 200)
            let attributes = try FileManager.default.attributesOfItem(atPath: lease.database.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            #if !targetEnvironment(simulator)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
            #endif
            return reader
        }
        XCTAssertThrowsError(try escaped.transactions())
        publication.lock()
        do {
            _ = try await publication.withReadLease { _, reader in try reader.transactions().transactions.count }
            XCTFail("Locked publication must reject reads")
        } catch { XCTAssertEqual(error as? BoundedReadIndexError, .unavailable) }
        publication.unlock()
        do {
            _ = try await publication.withReadLease { _, reader in
                publication.cancel()
                return try reader.transactions().transactions.count
            }
            XCTFail("Canceled read scope must reject results")
        } catch { XCTAssertEqual(error as? BoundedReadIndexError, .canceled) }
        let count = try await publication.withReadLease { _, reader in try reader.transactions().transactions.count }
        XCTAssertEqual(count, 100)
    }
}
#endif
