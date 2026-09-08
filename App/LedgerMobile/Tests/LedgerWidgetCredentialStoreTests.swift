import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerWidgetCredentialStoreTests: XCTestCase {
    func testSuspendingCredentialClearsMarkerWhenLegacySynchronizationReturnsFalse() throws {
        let suiteName = "widget-credential-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UnsuccessfulSynchronizationDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "ledger.widgets.active-credential-key.v1"
        defaults.set("test-credential", forKey: key)
        let store = SystemLedgerWidgetCredentialStore(accessGroup: "test-group", sharedDefaults: defaults)

        XCTAssertNoThrow(try store.suspend())
        XCTAssertNil(defaults.string(forKey: key))
    }

    func testSuspendingCredentialStillFailsWhenSharedDefaultsAreUnavailable() {
        let store = SystemLedgerWidgetCredentialStore(accessGroup: "test-group", sharedDefaults: nil)
        XCTAssertThrowsError(try store.suspend())
    }
}

private final class UnsuccessfulSynchronizationDefaults: UserDefaults {
    override func synchronize() -> Bool { false }
}
