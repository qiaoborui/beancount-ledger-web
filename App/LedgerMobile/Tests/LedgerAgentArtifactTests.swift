import Foundation
import XCTest
@testable import LedgerMobile

/// 账本助手 artifacts: the `artifact` fence, its id, versions and sync.
final class LedgerAgentArtifactTests: XCTestCase {
    private let block = #"{"id":"food-2026","title":"2026 餐饮","summary":"按月看","subtitle":"截至 11-16","blocks":[{"type":"note","text":"一"}]}"#

    func testFenceDecodesIntoAnArtifactWithItsOwnTitle() {
        let segments = LedgerAgentReplyText.segments("做好了：\n```artifact\n\(block)\n```\n点开看。")
        guard segments.count == 3, case let .artifact(artifact) = segments[1] else { return XCTFail("\(segments)") }
        XCTAssertEqual(artifact.id, "food-2026")
        XCTAssertEqual(artifact.title, "2026 餐饮")
        XCTAssertEqual(artifact.summary, "按月看")
        XCTAssertNil(artifact.visual.title, "the card and screen carry the title, not the page")
        XCTAssertEqual(artifact.visual.subtitle, "截至 11-16")
        XCTAssertEqual(artifact.visual.blocks, [.note("一")])
        XCTAssertEqual(artifact.json, block)
        XCTAssertEqual(LedgerAgentReplyText.plainText("```artifact\n\(block)\n```"), "2026 餐饮")
    }

    func testStreamingArtifactShowsABuildingCardAndAStoppedOneIsNotACard() {
        let head = "看：\n```artifact\n{\"id\":\"x\",\"title\":\"十月\",\"blocks\":[{\"type\":\"note\",\"text\":\"一\"},"
        XCTAssertEqual(LedgerAgentReplyText.segments(head, ending: .streaming), [.prose("看："), .buildingArtifact(title: "十月")])
        let stopped = LedgerAgentReplyText.segments(head, ending: .stopped)
        XCTAssertEqual(stopped.count, 2)
        guard case .visual = stopped.last else { return XCTFail("a stopped artifact keeps its finished blocks: \(stopped)") }
        XCTAssertTrue(LedgerAgentArtifactRecord.specs(in: head).isEmpty)
    }

    func testIDsAreNormalizedAndStable() {
        XCTAssertEqual(LedgerAgentArtifactSpec.normalizedID("Food 2026!", title: ""), "food-2026")
        XCTAssertEqual(LedgerAgentArtifactSpec.normalizedID("--a__b--", title: ""), "a-b")
        let derived = LedgerAgentArtifactSpec.normalizedID(nil, title: "餐饮面板")
        XCTAssertTrue(derived.hasPrefix("artifact-"))
        XCTAssertEqual(derived, LedgerAgentArtifactSpec.normalizedID("餐饮", title: "餐饮面板"))
        XCTAssertTrue(LedgerAgentArtifactSpec.isValidID(derived))
        XCTAssertFalse(LedgerAgentArtifactSpec.isValidID("../agent-memory"))
        XCTAssertFalse(LedgerAgentArtifactSpec.isValidID("Food"))
        XCTAssertFalse(LedgerAgentArtifactSpec.isValidID(""))
        XCTAssertEqual(LedgerAgentArtifactSpec.normalizedID(String(repeating: "a", count: 80), title: "").count, 48)
    }

    func testRecordingAddsAVersionOncePerReply() throws {
        let spec = try XCTUnwrap(LedgerAgentArtifactSpec(json: block))
        let conversation = UUID(), first = UUID(), second = UUID()
        let created = try XCTUnwrap(LedgerAgentArtifactRecord.recording(spec, in: nil, conversation: conversation, message: first))
        XCTAssertEqual(created.versions.map(\.number), [1])
        // Saving the same reply again adds nothing.
        XCTAssertNil(LedgerAgentArtifactRecord.recording(spec, in: created, conversation: conversation, message: first))
        // Neither does the same block from another reply.
        XCTAssertNil(LedgerAgentArtifactRecord.recording(spec, in: created, conversation: conversation, message: second))

        let changed = try XCTUnwrap(LedgerAgentArtifactSpec(json: block.replacingOccurrences(of: "\"一\"", with: "\"二\"")
            .replacingOccurrences(of: "2026 餐饮", with: "2026 餐饮（新）")))
        let updated = try XCTUnwrap(LedgerAgentArtifactRecord.recording(changed, in: created, conversation: conversation, message: second))
        XCTAssertEqual(updated.versions.map(\.number), [1, 2])
        XCTAssertEqual(updated.title, "2026 餐饮（新）")
        XCTAssertEqual(updated.version(writtenBy: first)?.spec, block)
        XCTAssertEqual(updated.version(writtenBy: second)?.number, 2)

        // It round-trips through the file the native tools read.
        let data = try LedgerAgentArtifactRecord.encoder.encode(updated)
        XCTAssertEqual(LedgerAgentArtifactRecord.decode(data), updated)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let versions = try XCTUnwrap(object["versions"] as? [[String: Any]])
        XCTAssertEqual(versions.last?["spec"] as? String, changed.json)
        XCTAssertNotNil(object["updatedAt"] as? String)
    }

    func testOldVersionsAreDroppedPastTheLimit() throws {
        var record: LedgerAgentArtifactRecord?
        for index in 0..<(LedgerAgentArtifactRecord.maximumVersions + 3) {
            let spec = try XCTUnwrap(LedgerAgentArtifactSpec(json: #"{"id":"a","title":"A","blocks":[{"type":"note","text":"\#(index)"}]}"#))
            record = LedgerAgentArtifactRecord.recording(spec, in: record, conversation: nil, message: UUID()) ?? record
        }
        let versions = try XCTUnwrap(record).versions
        XCTAssertEqual(versions.count, LedgerAgentArtifactRecord.maximumVersions)
        XCTAssertEqual(versions.last?.number, LedgerAgentArtifactRecord.maximumVersions + 3)
    }

    func testReplyWithTwoBlocksOfOneIDKeepsTheLast() {
        let other = block.replacingOccurrences(of: "\"一\"", with: "\"二\"")
        let specs = LedgerAgentArtifactRecord.specs(in: "```artifact\n\(block)\n```\n再改：\n```artifact\n\(other)\n```")
        XCTAssertEqual(specs.map(\.json), [other])
    }

    func testArtifactsSync() {
        XCTAssertTrue(LedgerAgentSyncLayout.isSynced("agent-artifacts/food-2026.json"))
        XCTAssertFalse(LedgerAgentSyncLayout.isSynced("agent-artifacts/Food.json"))
        XCTAssertFalse(LedgerAgentSyncLayout.isSynced("agent-artifacts/x/food.json"))
        XCTAssertNil(LedgerAgentSyncLayout.conversationID(of: "agent-artifacts/food-2026.json"))
    }
}
