import SwiftUI
import XCTest
@testable import LedgerMobile

// Renders the bar's mark, so it needs the iOS app host and stays out of the
// portable SwiftPM test target.
@MainActor
final class LedgerMarkTests: XCTestCase {
    /// The svg's 40-unit square, fitted to the rect: the glyph fills its box
    /// instead of floating inside it.
    func testShapeFillsItsRect() {
        let rect = CGRect(x: 0, y: 0, width: 18, height: 18)
        let bounds = LedgerTabMarkShape().path(in: rect).boundingRect
        XCTAssertEqual(bounds.minX, 0, accuracy: 0.01)
        XCTAssertEqual(bounds.minY, 0, accuracy: 0.01)
        XCTAssertEqual(bounds.width, 18, accuracy: 0.01)
        XCTAssertEqual(bounds.height, 18, accuracy: 0.01)
    }

    /// The bar gets an 18pt mark in the middle of a 25pt canvas with even
    /// padding, the page filled through, and the L cut-out and the fold's gap
    /// left clear. A regression to a filled square fails here.
    func testGlyphIsCentredWithEvenPadding() throws {
        let image = try XCTUnwrap(LedgerTabMark.rendered())
        XCTAssertEqual(image.size, CGSize(width: 25, height: 25))
        XCTAssertEqual(image.scale, 4)
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cgImage.width, 100)
        XCTAssertEqual(cgImage.height, 100)

        let alpha = try AlphaGrid(image: cgImage)
        // 3.5pt of padding each side is 14px at 4x; the far corners stay clear.
        for (x, y) in [(2, 2), (97, 2), (2, 97), (97, 97)] {
            XCTAssertEqual(alpha.at(x: x, y: y), 0, "corner \(x),\(y) must stay clear")
        }
        // Inside the page.
        XCTAssertGreaterThan(alpha.at(x: 22, y: 24), 240)
        // The middle of the L's vertical slot, and the gap beside the fold.
        XCTAssertLessThan(alpha.at(x: 37, y: 48), 10)
        XCTAssertLessThan(alpha.at(x: 60, y: 28), 10)
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
