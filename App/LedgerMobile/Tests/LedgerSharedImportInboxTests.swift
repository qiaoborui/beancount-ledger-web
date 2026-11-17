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
        for name in ["../bill.csv", "a/bill.csv", "a\\bill.csv", "bill\n.csv", "bill\t.csv", "bill\u{7F}.csv", "bill\u{0}.csv", "bill.exe", "bill"] {
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

    func testAgentInboxKeepsImagesAndTheNote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = LedgerSharedImportInbox(directory: root.appendingPathComponent("agent"), purpose: .agent)
        let imports = LedgerSharedImportInbox(directory: root.appendingPathComponent("imports"))
        let source = root.appendingPathComponent("payload")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
        XCTAssertThrowsError(try imports.enqueue(fileURL: source, originalName: "截图.PNG"))
        let item = try agent.enqueue(fileURL: source, originalName: "截图.PNG", note: "  帮我记一下这笔  \n")
        XCTAssertEqual(item.note, "帮我记一下这笔")
        XCTAssertEqual(try agent.items(), [item])
        XCTAssertTrue(try imports.items().isEmpty)
        let blank = try agent.enqueue(fileURL: source, originalName: "b.jpg", note: " \n ")
        XCTAssertNil(blank.note)
        let long = try agent.enqueue(fileURL: source, originalName: "c.heic", note: String(repeating: "长", count: 5000))
        XCTAssertEqual(long.note?.count, LedgerSharedImportInbox.maximumNoteLength)
        XCTAssertEqual(try agent.items().count, 3)
        XCTAssertThrowsError(try agent.enqueue(fileURL: source, originalName: "bill.zip"))
    }

    func testItemsSavedBeforeNotesStillDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"a.csv","byteCount":3,"createdAt":0}"#
        let item = try JSONDecoder().decode(LedgerSharedImportInbox.Item.self, from: Data(json.utf8))
        XCTAssertNil(item.note)
    }

    func testAgentExtensionsMatchWhatTheAssistantReads() {
        for ext in LedgerSharedImportInbox.agentExtensions {
            XCTAssertNotNil(LedgerAgentAttachments.kind(of: "file." + ext), ext)
        }
        let assistant = LedgerAgentAttachments.tableExtensions.union(LedgerAgentAttachments.textExtensions)
            .union(LedgerAgentAttachments.imageExtensions).union(["pdf"])
        XCTAssertEqual(assistant, LedgerSharedImportInbox.agentExtensions)
        XCTAssertEqual(LedgerSharedImportInbox.agentMaximumBytes, LedgerAgentAttachments.maximumBytes)
    }

    func testSharedDeliveryAsksEachRequestOnceOldestFirst() {
        let early = LedgerSharedImportInbox.Item(id: UUID(), name: "a.csv", byteCount: 1,
                                                 createdAt: Date(timeIntervalSince1970: 1), note: "对一下账")
        let late = LedgerSharedImportInbox.Item(id: UUID(), name: "b.png", byteCount: 1,
                                                createdAt: Date(timeIntervalSince1970: 2), note: "对一下账")
        let other = LedgerSharedImportInbox.Item(id: UUID(), name: "c.pdf", byteCount: 1,
                                                 createdAt: Date(timeIntervalSince1970: 3), note: "记下这笔")
        let delivery = LedgerAgentSharedDelivery(items: [other, late, early])
        XCTAssertEqual(delivery.items.map(\.name), ["a.csv", "b.png", "c.pdf"])
        XCTAssertEqual(delivery.note, "对一下账\n\n记下这笔")
        XCTAssertNil(LedgerAgentSharedDelivery(items: [LedgerSharedImportInbox.Item(
            id: UUID(), name: "a.csv", byteCount: 1, createdAt: Date())]).note)
    }
}
