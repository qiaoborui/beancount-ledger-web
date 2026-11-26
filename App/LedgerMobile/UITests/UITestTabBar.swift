import XCTest

extension XCUIApplication {
    /// A tab of the compact tab bar by its name.
    ///
    /// A local ledger draws its own icon bar (`LedgerIconTabBar`), whose
    /// buttons are named `ledger-tab-<name>`; a remote ledger keeps the system
    /// tab bar. On iOS 26 that bar minimizes while content scrolls
    /// (`tabBarMinimizeBehavior(.onScrollDown)`), leaving only the selected
    /// tab, reported as collapsed; it is tapped to expand the bar first.
    func compactTab(_ label: String, timeout: TimeInterval = 5) -> XCUIElement {
        let icon = buttons["ledger-tab-\(label)"]
        let tab = tabBars.buttons[label]
        if icon.exists { return icon }
        if tab.exists { return tab }
        let collapsed = tabBars.buttons
            .matching(NSPredicate(format: "value IN %@", ["已折叠", "Collapsed"]))
            .firstMatch
        if collapsed.exists { collapsed.tap() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if icon.exists { return icon }
            if tab.exists { return tab }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return tabBars.firstMatch.exists ? tab : icon
    }

    /// The bottom bar of either kind, for checks that it is (not) on screen.
    var compactTabBarExists: Bool {
        tabBars.firstMatch.exists || otherElements["ledger-icon-tab-bar"].exists
            || buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ledger-tab-'")).firstMatch.exists
    }
}
