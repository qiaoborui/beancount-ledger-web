import XCTest

extension XCUIElement {
    /// Taps a popover menu item.
    ///
    /// iOS 26 draws the popover's pointer over the first item's upper half, and a
    /// tap on the item's centre is swallowed by it: the menu closes and the action
    /// never runs. Aim at the lower edge of the row instead, which works for every
    /// item of the menu.
    func tapMenuItem() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
    }
}
