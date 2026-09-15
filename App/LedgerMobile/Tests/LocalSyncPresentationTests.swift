import XCTest
@testable import LedgerMobile

final class LocalSyncPresentationTests: XCTestCase {
    func testDeviceStorageOpensConfigurationAndDoesNotClaimRemoteBackup() {
        let presentation = LocalSyncPresentation(status: nil, hasGit: false, busy: false, automaticEnabled: true)
        XCTAssertEqual(presentation.title, "已保存到本机")
        XCTAssertEqual(presentation.indicator, .local)
        XCTAssertEqual(presentation.action, .storageSettings)
    }

    func testConfiguredUnknownAndPendingStateCanSynchronize() {
        let statuses: [LocalStorageSyncStatus?] = [nil, .init(mode: .git, phase: .pending)]
        for status in statuses {
            let presentation = LocalSyncPresentation(status: status, hasGit: true, busy: false, automaticEnabled: true)
            XCTAssertEqual(presentation.title, "等待同步")
            XCTAssertEqual(presentation.indicator, .pending)
            XCTAssertEqual(presentation.action, .synchronize)
            XCTAssertFalse(presentation.isBusy)
        }
    }

    func testBusySlotPreventsDuplicateSynchronization() {
        let presentation = LocalSyncPresentation(status: .init(mode: .git, phase: .synced),
            hasGit: true, busy: true, automaticEnabled: true)
        XCTAssertTrue(presentation.isBusy)
        XCTAssertEqual(presentation.title, "正在同步")
        XCTAssertEqual(presentation.indicator, .syncing)
    }

    func testConflictRequiresExplicitResolutionAndFailureCanRetry() {
        for phase in [LocalStorageSyncStatus.Phase.conflicted, .failed] {
            let presentation = LocalSyncPresentation(status: .init(mode: .git, phase: phase),
                hasGit: true, busy: false, automaticEnabled: true)
            XCTAssertTrue(presentation.needsAttention)
            XCTAssertEqual(presentation.indicator, .attention)
            XCTAssertEqual(presentation.action, phase == .conflicted ? .storageSettings : .synchronize)
        }
    }

    func testPausedAutomaticSyncStillAllowsManualSync() {
        let presentation = LocalSyncPresentation(status: .init(mode: .git, phase: .synced),
            hasGit: true, busy: false, automaticEnabled: false)
        XCTAssertEqual(presentation.title, "已同步，自动同步已暂停")
        XCTAssertEqual(presentation.indicator, .local)
        XCTAssertEqual(presentation.action, .synchronize)
        XCTAssertFalse(presentation.isBusy)
    }

    func testCancelledSyncLabelDoesNotDisableManualRetry() {
        let presentation = LocalSyncPresentation(status: .init(mode: .git, phase: .synchronizing),
            hasGit: true, busy: false, automaticEnabled: true)
        XCTAssertEqual(presentation.title, "等待同步")
        XCTAssertFalse(presentation.isBusy)
    }

    func testSuccessfulAutomaticSyncShowsSyncedIndicator() {
        let presentation = LocalSyncPresentation(status: .init(mode: .git, phase: .synced),
            hasGit: true, busy: false, automaticEnabled: true)
        XCTAssertEqual(presentation.indicator, .synced)
        XCTAssertEqual(presentation.title, "已同步")
    }
}
