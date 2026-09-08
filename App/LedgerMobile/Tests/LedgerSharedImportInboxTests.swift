import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerSharedImportInboxTests: XCTestCase {
    private func fixture() throws -> (URL, LedgerSharedImportInbox) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, LedgerSharedImportInbox(directory: root.appendingPathComponent("inbox")))
    }

    func testCopySurvivesProviderTemporaryFileAndRemovalPreservesOriginal() throws {
        let (root, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("provider-temp")
        let data = Data("date,amount\n2026-09-01,12.34".utf8)
        try data.write(to: source)
        let item = try inbox.enqueue(fileURL: source, originalName: "账单.CSV")
        XCTAssertEqual(item.name, "账单.CSV")
        XCTAssertEqual(try inbox.items(), [item])
        XCTAssertEqual(try inbox.read(item), data)
        try inbox.remove(item)
        XCTAssertTrue(try inbox.items().isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), data)
        let second = try inbox.enqueue(fileURL: source, originalName: "账单.csv")
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try inbox.read(second), data)
    }

    func testRejectsUnsafeNamesUnsupportedTypesAndWebURLs() throws {
        let (root, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bill.csv")
        try Data("safe fixture".utf8).write(to: source)
        for name in ["../bill.csv", "a/bill.csv", "a\\bill.csv", "bill\n.csv", "bill.exe", "bill"] {
            XCTAssertThrowsError(try inbox.enqueue(fileURL: source, originalName: name), name)
        }
        XCTAssertThrowsError(try inbox.enqueue(fileURL: URL(string: "https://example.com/bill.csv")!))
        XCTAssertTrue(try inbox.items().isEmpty)
    }

    func testRejectsEmptyOversizedDirectoryAndSymlinkInputs() throws {
        let (root, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bill.csv")
        try Data().write(to: source)
        XCTAssertThrowsError(try inbox.enqueue(fileURL: source))
        try Data(repeating: 65, count: LedgerSharedImportInbox.maximumBytes + 1).write(to: source)
        XCTAssertThrowsError(try inbox.enqueue(fileURL: source))
        XCTAssertThrowsError(try inbox.enqueue(fileURL: root, originalName: "bill.csv"))
        let link = root.appendingPathComponent("link.csv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try inbox.enqueue(fileURL: link))
    }

    func testCapacityAndDifferentFilesWithSameName() throws {
        let (root, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bill.csv")
        try Data("fixture".utf8).write(to: source)
        for _ in 0..<LedgerSharedImportInbox.maximumItems { try inbox.enqueue(fileURL: source) }
        let items = try inbox.items()
        XCTAssertEqual(Set(items.map(\.id)).count, LedgerSharedImportInbox.maximumItems)
        XCTAssertThrowsError(try inbox.enqueue(fileURL: source))
        try inbox.remove(XCTUnwrap(items.first))
        XCTAssertNoThrow(try inbox.enqueue(fileURL: source))
    }

    func testRejectsTamperedMetadataAndPayloadSymlink() throws {
        let (root, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bill.csv")
        try Data("fixture".utf8).write(to: source)
        let item = try inbox.enqueue(fileURL: source)
        let folder = inbox.directory.appendingPathComponent(item.id.uuidString)
        let payload = folder.appendingPathComponent("payload")
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: source)
        XCTAssertThrowsError(try inbox.read(item))
        let forged = LedgerSharedImportInbox.Item(id: item.id, name: "../bill.csv", byteCount: item.byteCount, createdAt: item.createdAt)
        try JSONEncoder().encode(forged).write(to: folder.appendingPathComponent("item.json"))
        XCTAssertTrue(try inbox.items().isEmpty)
        XCTAssertThrowsError(try inbox.read(item))
        XCTAssertThrowsError(try inbox.remove(item))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
