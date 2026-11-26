import SwiftUI
import XCTest
@testable import LedgerMobile

// Renders the bar's mark, so it needs the iOS app host and stays out of the
// portable SwiftPM test target.
@MainActor
final class LedgerMarkTests: XCTestCase {
    /// The bar gets 豆豆 in a 24pt square in the middle of a 25pt canvas:
    /// the body filled through, the eyes cut out, the corners clear. A
    /// regression to a filled square, or to a face drawn in ink, fails here.
    func testGlyphIsTheSilhouetteWithItsFaceCutOut() throws {
        let image = try XCTUnwrap(LedgerTabMark.rendered())
        XCTAssertEqual(image.size, CGSize(width: 25, height: 25))
        XCTAssertEqual(image.scale, 4)
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cgImage.width, 100)
        XCTAssertEqual(cgImage.height, 100)

        // A grid unit is 24/64 pt, 1.5px at 4x, after half a point of padding.
        func px(_ unit: CGFloat) -> Int { Int((2 + unit * 1.5).rounded()) }
        let alpha = try AlphaGrid(image: cgImage)
        for (x, y) in [(2, 2), (97, 2), (2, 97), (97, 97)] {
            XCTAssertEqual(alpha.at(x: x, y: y), 0, "corner \(x),\(y) must stay clear")
        }
        // The belly, below the mouth.
        XCTAssertGreaterThan(alpha.at(x: px(32), y: px(50)), 240)
        // The middle of each eye.
        XCTAssertLessThan(alpha.at(x: px(28), y: px(37.4)), 40)
        XCTAssertLessThan(alpha.at(x: px(38.6), y: px(37.4)), 40)
    }

    /// Every state draws in every palette and size without trapping, and the
    /// loops stay finite.
    func testStatesAndPosesRender() {
        for state in LedgerMascotState.allCases {
            for time in [0.0, 0.3, 1.1, 2.37, 4.4] {
                let pose = LedgerMascotPose.at(time, state: state)
                XCTAssertTrue(pose.scaleX.isFinite && pose.scaleY.isFinite && pose.offset.height.isFinite)
            }
            let variants: [(LedgerMascotPalette, Bool)] = [(.light, false), (.dark, true), (.mono(.black), true)]
            for (palette, small) in variants {
                let renderer = ImageRenderer(content: LedgerMascotCanvas(state: state, palette: palette, small: small,
                                                                         pose: .at(0.5, state: state))
                    .frame(width: 64, height: 64))
                XCTAssertNotNil(renderer.uiImage, "\(state)")
            }
        }
        XCTAssertEqual(LedgerMascotPose.entrance(0), .rest)
        XCTAssertEqual(LedgerMascotPose.entrance(1), .rest)
    }

    /// The draft's path data comes through as written.
    func testPathParserReadsAbsoluteCommands() {
        let box = LedgerMascotPath.parse("M10 20H30V40L10 40Z").boundingRect
        XCTAssertEqual(box, CGRect(x: 10, y: 20, width: 20, height: 20))
        let curve = LedgerMascotPath.parse("M0 0C0 -10 10 -10 10 0Q5 8 0 0Z").boundingRect
        XCTAssertEqual(curve.minX, 0, accuracy: 0.01)
        XCTAssertEqual(curve.maxX, 10, accuracy: 0.01)
        XCTAssertLessThan(curve.minY, -5)
        XCTAssertGreaterThan(curve.maxY, 2)
    }
}

/// The rendered glyph's alpha channel, counted from its top-left pixel.
private struct AlphaGrid {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: [UInt8]

    init(image: CGImage) throws {
        let width = image.width
        let height = image.height
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try XCTUnwrap(context.data)
        self.width = width
        self.height = height
        self.bytesPerRow = context.bytesPerRow
        self.pixels = Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: context.bytesPerRow * height
        ))
    }

    func at(x: Int, y: Int) -> UInt8 {
        // A CGContext's first row is its bottom one.
        pixels[(height - 1 - y) * bytesPerRow + x * 4 + 3]
    }
}
