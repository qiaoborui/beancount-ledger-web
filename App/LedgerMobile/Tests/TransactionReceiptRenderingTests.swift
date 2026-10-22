import SwiftUI
import XCTest
@testable import LedgerMobile

// Renders the SwiftUI receipt card, so it needs the iOS app host and stays out
// of the portable SwiftPM test target.
@MainActor
final class TransactionReceiptRenderingTests: XCTestCase {
    func testReceiptRendersWithPostingsWithoutSessionInBothAppearances() throws {
        let transaction = LedgerTransaction(date: "2026-09-28", payee: "Synthetic", narration: "Receipt regression",
            postings: [.init(account: "Expenses:Food", amount: 125, currency: "CNY"),
                       .init(account: "Assets:Cash", amount: -125, currency: "CNY")],
            source: .init(file: "synthetic.bean", line: 1, hash: "receipt-test"))
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: SingleTransactionReceiptCard(
                transaction: transaction, accountLabels: ["Assets:Cash": "现金"])
                .environment(\.colorScheme, scheme))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, 340)
            XCTAssertGreaterThan(image.size.height, 100)
            XCTAssertNotNil(image.pngData())
        }
    }
}
