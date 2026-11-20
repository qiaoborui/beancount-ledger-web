import SwiftUI
import UIKit
import XCTest
@testable import LedgerMobile

/// Switching 配色方案 must repaint views that never read the scheme
/// themselves: palette colours are static dynamic `UIColor`s that SwiftUI
/// does not resolve again on its own, so the root rebuilds the tree. Needs
/// the iOS app host (a real window), so it stays out of the SwiftPM target.
@MainActor
final class LedgerColorThemeRenderingTests: XCTestCase {
    private var savedTheme: LedgerColorTheme = .paper

    override func setUp() async throws {
        try await super.setUp()
        savedTheme = LedgerColorThemeStore.shared.theme
        LedgerColorThemeStore.shared.select(.paper)
    }

    override func tearDown() async throws {
        LedgerColorThemeStore.shared.select(savedTheme)
        try await super.tearDown()
    }

    func testSwitchRepaintsAnAlreadyRenderedPage() async throws {
        let window = try makeWindow(Root())
        defer { window.isHidden = true }

        try await assertPage(window, equals: 0xFBFAF8, "paper")
        LedgerColorThemeStore.shared.select(.neutral)
        try await assertPage(window, equals: 0xFFFFFF, "neutral")
        LedgerColorThemeStore.shared.select(.slate)
        try await assertPage(window, equals: 0xF7F8FA, "slate")
        LedgerColorThemeStore.shared.select(.paper)
        try await assertPage(window, equals: 0xFBFAF8, "paper again")
    }

    func testSwitchRepaintsInDarkMode() async throws {
        let window = try makeWindow(Root())
        window.overrideUserInterfaceStyle = .dark
        defer { window.isHidden = true }

        try await assertPage(window, equals: 0x121110, "paper dark")
        LedgerColorThemeStore.shared.select(.neutral)
        try await assertPage(window, equals: 0x000000, "neutral dark")
    }

    // MARK: Helpers

    /// RootView's shape: the shell is keyed by the scheme, above a child
    /// that does not read it.
    private struct Root: View {
        @ObservedObject var store = LedgerColorThemeStore.shared
        var body: some View {
            Page().id(store.theme)
        }
    }

    private struct Page: View {
        var body: some View {
            BalancedPalette.page.ignoresSafeArea()
        }
    }

    private func makeWindow(_ view: some View) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    private func assertPage(_ window: UIWindow, equals expected: UInt32, _ label: String,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        var actual: UInt32 = 0
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            actual = centrePixel(window)
            if Self.close(actual, expected) { return }
        }
        XCTFail("\(label): page is #\(String(actual, radix: 16)), expected #\(String(expected, radix: 16))",
                file: file, line: line)
    }

    /// Within 2 per channel, for colour-management rounding.
    private static func close(_ a: UInt32, _ b: UInt32) -> Bool {
        [16, 8, 0].allSatisfy { shift in abs(Int((a >> shift) & 0xFF) - Int((b >> shift) & 0xFF)) <= 2 }
    }

    private func centrePixel(_ window: UIWindow) -> UInt32 {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }
        let x = cgImage.width / 2, y = cgImage.height / 2
        let offset = y * cgImage.bytesPerRow + x * (cgImage.bitsPerPixel / 8)
        let info = cgImage.bitmapInfo
        let alphaFirst = [CGImageAlphaInfo.premultipliedFirst, .first, .noneSkipFirst]
            .contains(CGImageAlphaInfo(rawValue: info.rawValue & CGBitmapInfo.alphaInfoMask.rawValue) ?? .none)
        let littleEndian = info.contains(.byteOrder32Little)
        var r = bytes[offset], g = bytes[offset + 1], b = bytes[offset + 2]
        if littleEndian && alphaFirst {        // BGRA in memory
            b = bytes[offset]; g = bytes[offset + 1]; r = bytes[offset + 2]
        } else if alphaFirst {                 // ARGB
            r = bytes[offset + 1]; g = bytes[offset + 2]; b = bytes[offset + 3]
        }
        return UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }
}
