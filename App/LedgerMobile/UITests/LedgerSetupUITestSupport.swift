import XCTest

extension XCUIApplication {
    /// A fresh fixture has no ledger, so the app opens on the setup
    /// conversation, which keeps the manual ways in (新建空账本, the wizard,
    /// importing a folder) in its menu. Opens that menu and waits for them.
    func revealLedgerSetupMenu(timeout: TimeInterval = 10) -> Bool {
        let more = buttons["ledger-setup-more"]
        guard more.waitForExistence(timeout: timeout) else { return buttons["local-ledger-create"].exists }
        more.tap()
        return buttons["local-ledger-create"].waitForExistence(timeout: 5)
    }
}
