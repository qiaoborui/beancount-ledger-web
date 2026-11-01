import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LedgerMobile

final class LedgerAgentAttachmentsTests: XCTestCase {
    func testIDsAndStoredNames() {
        let existing = [LedgerAgentAttachment(id: "a1", name: "x.csv", kind: .table, bytes: 1, fileName: "a1-x.csv"),
                        LedgerAgentAttachment(id: "a3", name: "y.csv", kind: .table, bytes: 1, fileName: "a3-y.csv")]
        XCTAssertEqual(LedgerAgentAttachments.nextID(after: []), "a1")
        XCTAssertEqual(LedgerAgentAttachments.nextID(after: existing), "a4")
        XCTAssertEqual(LedgerAgentAttachments.storedName(id: "a1", original: "../招行/10月.csv"), "a1-10月.csv")
        XCTAssertEqual(LedgerAgentAttachments.storedName(id: "a2", original: ".hidden"), "a2-hidden")
        XCTAssertEqual(LedgerAgentAttachments.storedName(id: "a2", original: "a:b.xlsx"), "a2-a_b.xlsx")
        XCTAssertLessThanOrEqual(LedgerAgentAttachments.storedName(id: "a1", original: String(repeating: "长", 200) + ".pdf").count, 80)
    }

    func testKindsFollowTheExtension() {
        XCTAssertEqual(LedgerAgentAttachments.kind(of: "bill.XLSX"), .table)
        XCTAssertEqual(LedgerAgentAttachments.kind(of: "bill.csv"), .table)
        XCTAssertEqual(LedgerAgentAttachments.kind(of: "bill.pdf"), .pdf)
        XCTAssertEqual(LedgerAgentAttachments.kind(of: "IMG_1.HEIC"), .image)
        XCTAssertNil(LedgerAgentAttachments.kind(of: "archive.zip"))
    }

    /// Pieces OCR returns on one visual line stay one line, left to right,
    /// so a statement table keeps its rows.
    func testRecognizedPiecesBecomeLines() {
        let pieces: [LedgerAgentAttachments.OCRPiece] = [
            .init(text: "25.00", minX: 0.8, midY: 0.70, height: 0.02),
            .init(text: "2026-01-05 食堂", minX: 0.1, midY: 0.705, height: 0.02),
            .init(text: "招商银行", minX: 0.1, midY: 0.9, height: 0.03),
            .init(text: "30.00", minX: 0.8, midY: 0.6, height: 0.02),
            .init(text: "2026-01-08 滴滴", minX: 0.1, midY: 0.6, height: 0.02),
        ]
        XCTAssertEqual(LedgerAgentAttachments.lines(from: pieces), "招商银行\n2026-01-05 食堂\t25.00\n2026-01-08 滴滴\t30.00")
    }

    func testStoringATableCopiesItAndAnImageGetsAPreview() async throws {
        let directory = try root()
        let csv = try await LedgerAgentAttachments.store(Data("日期,金额\n2026-01-05,25\n".utf8), name: "bill.csv",
                                                        kind: .table, id: "a1", into: directory)
        XCTAssertEqual(csv.fileName, "a1-bill.csv")
        XCTAssertNil(csv.textFileName)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(csv.fileName)).count, csv.bytes)

        let image = try await LedgerAgentAttachments.importImage(try png(width: 3000, height: 1500), name: "shot.png",
                                                                 id: "a2", into: directory)
        let preview = try XCTUnwrap(image.imageFileName)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(directory.appendingPathComponent(preview) as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, LedgerAgentAttachments.imagePixels)
        XCTAssertNotNil(image.textFileName)
        XCTAssertEqual(image.kind, .image)
    }

    func testAPDFWithoutATextLayerCountsItsPages() async throws {
        let directory = try root()
        let attachment = try await LedgerAgentAttachments.store(try blankPDF(pages: 2), name: "scan.pdf",
                                                               kind: .pdf, id: "a1", into: directory)
        XCTAssertEqual(attachment.pages, 2)
        XCTAssertNotNil(attachment.textFileName)
        XCTAssertEqual(attachment.recognizedCharacters, 0)
        XCTAssertTrue(attachment.detail.contains("2 页"))
    }

    /// Staged files go with the next question and stay new until a turn
    /// answers, so a failed turn's retry announces them again.
    @MainActor
    func testConversationSendsStagedFilesUntilATurnAnswers() async throws {
        let conversation = LedgerAgentConversation()
        let file = LedgerAgentAttachment(id: "a1", name: "招行.csv", kind: .table, bytes: 10, fileName: "a1-招行.csv")
        conversation.stage(file)
        conversation.stage(file)
        XCTAssertEqual(conversation.staged.count, 1)
        let directory = URL(fileURLWithPath: "/runtime/agent-attachments/c")
        XCTAssertEqual(conversation.attachmentPayloads(in: directory),
                       [.init(id: "a1", name: "招行.csv", path: "/runtime/agent-attachments/c/a1-招行.csv", new: true)])

        conversation.send("对账") { _, _, _ in .init(ok: false, error: "503 overloaded") }
        XCTAssertTrue(conversation.staged.isEmpty)
        XCTAssertEqual(conversation.messages.last?.attachments, ["招行.csv"])
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.attachmentPayloads(in: directory).map(\.new), [true])

        conversation.send("对账") { _, _, _ in .init(ok: true, reply: "对上 3 笔") }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.messages.first?.attachments, ["招行.csv"], "the retried question keeps its files")
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.attachmentPayloads(in: directory).map(\.new), [false])

        let saved = try XCTUnwrap(conversation.saved())
        let decoded = try JSONDecoder().decode(LedgerAgentSavedConversation.self, from: JSONEncoder().encode(saved))
        let reopened = LedgerAgentConversation(restoring: decoded)
        XCTAssertEqual(reopened.attachments, [file])
        XCTAssertEqual(reopened.messages.first?.attachments, ["招行.csv"])

        conversation.reset()
        XCTAssertTrue(conversation.attachments.isEmpty)
    }

    /// Records saved before attachments existed still open.
    func testOlderSavedConversationsDecode() throws {
        let json = #"{"version":1,"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","createdAt":0,"updatedAt":0,"messages":[{"role":"user","text":"hi","toolCalls":[]}],"unwrittenChange":false}"#
        let saved = try JSONDecoder().decode(LedgerAgentSavedConversation.self, from: Data(json.utf8))
        XCTAssertNil(saved.attachments)
        XCTAssertNil(saved.messages.first?.attachments)
    }

    func testTurnRequestCarriesAttachmentsOnlyWhenThereAreAny() throws {
        var request = LedgerAgentTurnRequest(turnId: "t", workspaceRoot: "/w", runtimeRoot: "/r", entrypoint: "main.bean",
            modelHandle: nil, sensitiveUnlocked: true, provider: "anthropic", model: "m", apiKey: "k", history: [], message: "hi")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNil(object["attachments"])
        request.attachments = [.init(id: "a1", name: "b.pdf", path: "/r/agent-attachments/c/a1-b.pdf",
                                     textPath: "/r/agent-attachments/c/a1-b.pdf.txt", pages: 2, new: true)]
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let sent = try XCTUnwrap((object["attachments"] as? [[String: Any]])?.first)
        XCTAssertEqual(sent["textPath"] as? String, "/r/agent-attachments/c/a1-b.pdf.txt")
        XCTAssertEqual(sent["new"] as? Bool, true)
        XCTAssertNil(sent["imagePath"])
    }

    func testReconcileToolTitleNamesTheAccounts() throws {
        let call = try JSONDecoder().decode(LedgerAgentToolCall.self, from: Data(
            #"{"name":"reconcile_attachment","arguments":{"id":"a1","accounts":["Liabilities:Card:CMB"]},"isError":false}"#.utf8))
        XCTAssertEqual(call.title, "对账 · Liabilities:Card:CMB")
    }

    func testWorkspaceKeepsAttachmentsOutsideGenerationsAndSweepsOrphans() async throws {
        let workspace = LocalLedgerWorkspace(rootDirectory: try root())
        let kept = UUID(), orphan = UUID()
        let directory = try await workspace.agentAttachmentDirectory(id: kept)
        XCTAssertEqual(directory.standardizedFileURL, workspace.agentAttachmentLocation(id: kept).standardizedFileURL)
        XCTAssertTrue(directory.path.contains("/runtime/agent-attachments/"))
        _ = try await workspace.agentAttachmentDirectory(id: orphan)
        try Data("x".utf8).write(to: directory.appendingPathComponent("a1-x.csv"))
        try await workspace.protectAgentAttachments(id: kept)
        await workspace.removeAgentAttachments(keeping: [kept])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("a1-x.csv").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.agentAttachmentLocation(id: orphan).path))
        await workspace.removeAgentConversation(id: kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: Fixtures

    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func blankPDF(pages: Int) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    @MainActor
    private func waitUntilIdle(_ conversation: LedgerAgentConversation) async throws {
        for _ in 0..<200 where conversation.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(conversation.isRunning)
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerAgentAttachmentsTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
