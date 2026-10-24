import Foundation
import XCTest
@testable import LedgerMobile

/// The retained stage model is what makes a publication reuse the preview's Go
/// registration. Its bookkeeping must be bounded, keyed per ledger, and must
/// always report the handles a replacement makes unpromotable.
final class LocalStageRetentionTests: XCTestCase {
    private func entry(_ handle: String, workspace: String = "/ledger/staging/a/workspace",
                       version: String = "version") -> LocalStageRetention.Entry {
        .init(handle: handle, workspace: workspace, sourceVersion: version)
    }

    func testRetainReturnsReplacedAndEvictedHandlesForRelease() {
        var retention = LocalStageRetention()
        let first = LocalStageRetention.key(ledgerRoot: "/ledger", entrypoint: "main.bean")
        let second = LocalStageRetention.key(ledgerRoot: "/other", entrypoint: "main.bean")

        XCTAssertEqual(retention.retain(entry("one"), for: first), [])
        XCTAssertEqual(retention.entry(for: first)?.handle, "one")
        // Replacing a stage in the same ledger releases the previous handle, so
        // a preview that is still open can never be promoted by mistake.
        XCTAssertEqual(retention.retain(entry("two"), for: first), ["one"])
        XCTAssertEqual(retention.entry(for: first)?.handle, "two")
        XCTAssertEqual(retention.retain(entry("three", workspace: "/other/staging/b/workspace"), for: second), [])
        XCTAssertEqual(retention.entry(for: first)?.handle, "two")
        // The global cap is small because a retained stage is a full model; the
        // oldest stage is released when the cap is exceeded.
        let third = LocalStageRetention.key(ledgerRoot: "/third", entrypoint: "main.bean")
        XCTAssertEqual(retention.retain(entry("four", workspace: "/third/staging/c/workspace"), for: third), ["two"])
        XCTAssertNil(retention.entry(for: first))
        XCTAssertEqual(retention.entry(for: third)?.handle, "four")
        XCTAssertLessThanOrEqual(retention.order.count, LocalStageRetention.limit)
    }

    func testTakeAndDiscardAreSingleUseAndIndependentPerLedger() {
        var retention = LocalStageRetention()
        let first = LocalStageRetention.key(ledgerRoot: "/ledger", entrypoint: "main.bean")
        let sameLedgerOtherEntrypoint = LocalStageRetention.key(ledgerRoot: "/ledger", entrypoint: "other.bean")
        _ = retention.retain(entry("one"), for: first)
        _ = retention.retain(entry("two", workspace: "/ledger/staging/b/workspace"), for: sameLedgerOtherEntrypoint)
        XCTAssertNotEqual(first, sameLedgerOtherEntrypoint)
        XCTAssertEqual(retention.take(first)?.handle, "one")
        XCTAssertNil(retention.take(first))
        XCTAssertEqual(retention.entry(for: sameLedgerOtherEntrypoint)?.handle, "two")
        XCTAssertEqual(retention.take(sameLedgerOtherEntrypoint)?.handle, "two")
        XCTAssertNil(retention.take(LocalStageRetention.key(ledgerRoot: "/unknown", entrypoint: "main.bean")))
    }

    func testRetentionKeepsTheNewestStageWhenTheLimitIsReached() {
        var retention = LocalStageRetention()
        for index in 0..<(LocalStageRetention.limit + 1) {
            let key = LocalStageRetention.key(ledgerRoot: "/ledger-\(index)", entrypoint: "main.bean")
            _ = retention.retain(entry("handle-\(index)"), for: key)
        }
        XCTAssertEqual(retention.order.count, LocalStageRetention.limit)
        let newest = LocalStageRetention.key(ledgerRoot: "/ledger-\(LocalStageRetention.limit)", entrypoint: "main.bean")
        XCTAssertEqual(retention.entry(for: newest)?.handle, "handle-\(LocalStageRetention.limit)")
    }
}
