import XCTest

extension XCUIApplication {
    /// A tab of the compact tab bar, expanded first if it was minimized.
    ///
    /// On iOS 26 the tab bar minimizes while content scrolls
    /// (`tabBarMinimizeBehavior(.onScrollDown)`), leaving only the selected tab,
    /// reported as collapsed, and the floating button. Other tabs are not in
    /// the accessibility tree until the selected tab is tapped to expand the bar.
    func compactTab(_ label: String, timeout: TimeInterval = 5) -> XCUIElement {
        let tab = tabBars.buttons[label]
        if tab.exists { return tab }
        let collapsed = tabBars.buttons
            .matching(NSPredicate(format: "value IN %@", ["已折叠", "Collapsed"]))
            .firstMatch
        if collapsed.waitForExistence(timeout: 1) { collapsed.tap() }
        _ = tab.waitForExistence(timeout: timeout)
        return tab
    }
}
