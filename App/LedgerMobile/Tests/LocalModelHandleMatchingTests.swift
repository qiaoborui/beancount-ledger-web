import Foundation
import XCTest
@testable import LedgerMobile

/// Adoption is only correct when the staging request and the committed model
/// belong to the same ledger; a workspace-path comparison can never match them
/// because generation and staging roots differ by construction.
final class LocalModelHandleMatchingTests: XCTestCase {
    private let ledger = "/Application Support/Ledgers/11111111-1111-1111-1111-111111111111"
    private let otherLedger = "/Application Support/Ledgers/22222222-2222-2222-2222-222222222222"

    private func generationRoot(_ ledger: String, _ id: String = "initial") -> String {
        ledger + "/generations/" + id + "/workspace"
    }

    private func stagingRoot(_ ledger: String, _ id: String = "proposal") -> String {
        ledger + "/staging/" + id + "/workspace"
    }

    private func handle(_ workspace: String, entrypoint: String = "main.bean",
                        handle: String = "handle", version: String = "version") -> LocalCanonicalHandle {
        .init(workspace: workspace, entrypoint: entrypoint, handle: handle, version: version)
    }

    func testStagingRootMatchesItsOwnLedgerGeneration() {
        let source = handle(generationRoot(ledger), handle: "committed")
        let match = LocalModelHandleMatching.adoptionSource(in: [source],
            entrypoint: "main.bean", stagingRoot: stagingRoot(ledger))
        XCTAssertEqual(match, source)
    }

    func testStagingRootDoesNotMatchAnotherLedger() {
        let foreign = handle(generationRoot(otherLedger))
        XCTAssertNil(LocalModelHandleMatching.adoptionSource(in: [foreign],
            entrypoint: "main.bean", stagingRoot: stagingRoot(ledger)))
    }

    func testEntrypointMustMatch() {
        let source = handle(generationRoot(ledger), entrypoint: "other.bean")
        XCTAssertNil(LocalModelHandleMatching.adoptionSource(in: [source],
            entrypoint: "main.bean", stagingRoot: stagingRoot(ledger)))
    }

    func testEmptyHandleListHasNoAdoptionSource() {
        XCTAssertNil(LocalModelHandleMatching.adoptionSource(in: [],
            entrypoint: "main.bean", stagingRoot: stagingRoot(ledger)))
    }

    func testMostRecentlyUsedHandleWinsWithinTheSameLedger() {
        let newest = handle(generationRoot(ledger, "newer"), handle: "newest")
        let older = handle(generationRoot(ledger, "older"), handle: "older")
        let match = LocalModelHandleMatching.adoptionSource(in: [newest, older],
            entrypoint: "main.bean", stagingRoot: stagingRoot(ledger))
        XCTAssertEqual(match?.handle, "newest")
    }

    func testUnmanagedRootsAreTheirOwnLedger() {
        XCTAssertEqual(LocalModelHandleMatching.ledgerRoot("/tmp/custom/workspace"), "/tmp/custom/workspace")
        XCTAssertNil(LocalModelHandleMatching.adoptionSource(in: [handle("/tmp/custom/workspace")],
            entrypoint: "main.bean", stagingRoot: "/tmp/other/workspace"))
    }

    func testLedgerRootCollapsesBothManagedLayouts() {
        XCTAssertEqual(LocalModelHandleMatching.ledgerRoot(generationRoot(ledger)), ledger)
        XCTAssertEqual(LocalModelHandleMatching.ledgerRoot(stagingRoot(ledger)), ledger)
        XCTAssertNotEqual(LocalModelHandleMatching.ledgerRoot(generationRoot(ledger)),
                          LocalModelHandleMatching.ledgerRoot(generationRoot(otherLedger)))
    }
}
