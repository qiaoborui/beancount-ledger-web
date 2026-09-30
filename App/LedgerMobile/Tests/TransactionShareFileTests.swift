import Foundation
import XCTest
import SwiftUI
@testable import LedgerMobile

final class TransactionShareFileTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("synthetic-share-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testCompleteExportPermissionsContentAndExplicitDiscard() throws {
        let root = try root()
        let file = try TransactionShareFile(parentDirectory: root)
        var stream = try TransactionShareTextStream(summary: .init(count: 0, firstDate: nil, lastDate: nil), currency: "CNY")
        try stream.finish(write: file.append)
        let url = try file.finish()
        XCTAssertTrue(file.isFinished)
        XCTAssertEqual(try Data(contentsOf: url).count, file.byteCount)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
            TransactionShareTextFormatter.format(transactions: [], currency: "CNY"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertThrowsError(try file.append(Data("late".utf8)))
        XCTAssertThrowsError(try file.finish())
        file.discard()
        file.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testOversizedChunkDeletesPartialFileAndCannotBeReused() throws {
        let root = try root()
        let file = try TransactionShareFile(parentDirectory: root)
        try file.append(Data("synthetic partial".utf8))
        XCTAssertThrowsError(try file.append(Data(repeating: 1, count: 16 * 1_024 + 1)))
        XCTAssertThrowsError(try file.finish())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testDeinitRemovesUnfinishedAndFinishedExports() throws {
        for finished in [false, true] {
            let root = try root()
            var file: TransactionShareFile? = try TransactionShareFile(parentDirectory: root)
            try file?.append(Data("synthetic".utf8))
            if finished { _ = try file?.finish() }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
            file = nil
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testRejectsParentLinkAndCleanupNeverFollowsPayloadLink() throws {
        let root = try root()
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try TransactionShareFile(parentDirectory: link))
        let file = try TransactionShareFile(parentDirectory: root)
        try file.append(Data("synthetic".utf8))
        let url = try file.finish()
        let outside = root.appendingPathComponent("untouched.txt")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        file.discard()
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
    }

    func testCancellationDeletesPartialOutput() async throws {
        let root = try root()
        let task = Task {
            let file = try TransactionShareFile(parentDirectory: root)
            try file.append(Data("partial".utf8))
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try file.finish())
        }
        try await task.value
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
}

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
