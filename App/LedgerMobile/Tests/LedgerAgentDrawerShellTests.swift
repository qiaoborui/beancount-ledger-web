#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import LedgerMobile

/// The drawer moves the page as layers only: opening it must not lay the
/// page out again at another size or with another safe area, which is what
/// made the SwiftUI drawer hitch.
@MainActor
final class LedgerAgentDrawerShellTests: XCTestCase {
    private final class Probe: ObservableObject {
        var sizes: [CGSize] = []
        var safeAreas: [EdgeInsets] = []
    }

    private struct Page: View {
        let probe: Probe

        var body: some View {
            GeometryReader { proxy in
                Color.white
                    .onAppear { record(proxy) }
                    .onChange(of: proxy.size) { _, _ in record(proxy) }
                    .onChange(of: proxy.safeAreaInsets) { _, _ in record(proxy) }
            }
        }

        private func record(_ proxy: GeometryProxy) {
            probe.sizes.append(proxy.size)
            probe.safeAreas.append(proxy.safeAreaInsets)
        }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testOpeningMovesThePageWithoutLayingItOutAgain() throws {
        // In the host app's scene, so the page has a real safe area.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = LedgerAgentDrawerController()
        let probe = Probe()
        controller.updateDrawer(key: 0) { _ in AnyView(Color.gray) }
        controller.setPage(AnyView(Page(probe: probe)))
        controller.edgeOpens = true
        window.rootViewController = controller
        window.makeKeyAndVisible()
        spin(0.3)
        let sizes = probe.sizes.count
        let safeAreas = probe.safeAreas.count
        XCTAssertGreaterThan(sizes, 0)
        XCTAssertGreaterThan(probe.safeAreas.last?.top ?? 0, 0)

        controller.setOpen(true, animated: true)
        spin(0.8)
        XCTAssertTrue(controller.isOpen)
        controller.setOpen(false, animated: true)
        spin(0.8)
        XCTAssertFalse(controller.isOpen)

        XCTAssertEqual(probe.sizes.count, sizes, "the page was laid out at another size: \(probe.sizes)")
        XCTAssertEqual(probe.safeAreas.count, safeAreas, "the page's safe area changed: \(probe.safeAreas)")
        window.isHidden = true
    }
}
#endif
