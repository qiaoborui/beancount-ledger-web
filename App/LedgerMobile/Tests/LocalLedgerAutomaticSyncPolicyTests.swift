import XCTest
@testable import LedgerMobile

@MainActor
final class LocalLedgerAutomaticSyncPolicyTests: XCTestCase {
    func testPermanentFailuresPauseAutomaticSync() {
        for code in ["git.authentication", "git.authorization", "git.invalid_request", "git.unsafe_path", "git.limit_exceeded"] {
            XCTAssertTrue(LedgerSession.automaticSyncRequiresAttention(LocalGitTransportFailure(code: code, message: "fixture")))
        }
        XCTAssertTrue(LedgerSession.automaticSyncRequiresAttention(LocalStorageError.conflicts(["main.bean"])))
        XCTAssertTrue(LedgerSession.automaticSyncRequiresAttention(LocalStorageError.corruptSyncState))
    }

    func testTransientFailuresRemainRetryable() {
        for code in ["git.timeout", "git.remote_changed", "git.non_fast_forward", "git.failed", "git.cancelled"] {
            XCTAssertFalse(LedgerSession.automaticSyncRequiresAttention(LocalGitTransportFailure(code: code, message: "fixture")))
        }
        XCTAssertFalse(LedgerSession.automaticSyncRequiresAttention(LocalStorageError.synchronizationInProgress))
        XCTAssertFalse(LedgerSession.automaticSyncRequiresAttention(LocalLedgerWorkspace.WorkspaceError.staleRevision))
    }
}
