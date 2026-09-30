import XCTest
import UIKit
@testable import LedgerMobile

final class LaunchResourceTests: XCTestCase {
    func testInstalledBundleContainsBrandedLaunchScreen() throws {
        let bundle = Bundle.main
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "UILaunchStoryboardName") as? String, "LaunchScreen")
        XCTAssertNotNil(bundle.url(forResource: "LaunchScreen", withExtension: "storyboardc"))
        XCTAssertNotNil(UIImage(named: "LaunchMark", in: bundle, compatibleWith: nil))
        XCTAssertNotNil(UIColor(named: "LaunchBackground", in: bundle, compatibleWith: nil))
        XCTAssertNotNil(UIColor(named: "LaunchInk", in: bundle, compatibleWith: nil))
    }
}
