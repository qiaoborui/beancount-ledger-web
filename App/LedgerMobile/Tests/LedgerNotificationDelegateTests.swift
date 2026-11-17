#if os(iOS)
import Foundation
import XCTest
@testable import LedgerMobile

/// A tap's completion handler goes back to UIKit, which throws "Call must be
/// made on main thread" when it is called anywhere else (the 1.4.28 crash on a
/// 账本助手 notification tap).
final class LedgerNotificationDelegateTests: XCTestCase {
    func testTapDeliveredOffMainIsHandledAndCompletedOnMain() {
        let handled = expectation(description: "handled")
        let completed = expectation(description: "completed")
        DispatchQueue.global(qos: .userInitiated).async {
            LedgerNotificationDelegate.onMain({
                XCTAssertTrue(Thread.isMainThread)
                handled.fulfill()
            }, then: {
                XCTAssertTrue(Thread.isMainThread)
                completed.fulfill()
            })
        }
        wait(for: [handled, completed], timeout: 5, enforceOrder: true)
    }

    func testTapDeliveredOnMainCompletesBeforeReturning() {
        XCTAssertTrue(Thread.isMainThread)
        let handled = expectation(description: "handled")
        let completed = expectation(description: "completed")
        LedgerNotificationDelegate.onMain({
            handled.fulfill()
        }, then: {
            XCTAssertTrue(Thread.isMainThread)
            completed.fulfill()
        })
        // Already fulfilled, without letting the main queue run.
        wait(for: [handled, completed], timeout: 0, enforceOrder: true)
    }
}
#endif
