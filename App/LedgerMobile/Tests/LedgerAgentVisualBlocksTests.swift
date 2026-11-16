import CoreGraphics
import XCTest
@testable import LedgerMobile

final class LedgerAgentVisualBlocksTests: XCTestCase {
    /// Every `visual` example in the ledger-visuals skill, which the model
    /// copies, draws in full.
    func testSkillExamplesDecodeInFull() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let skill = root.appendingPathComponent("server/mobileagent/skills/ledger-visuals")
        let files = try FileManager.default.contentsOfDirectory(atPath: skill.path).filter { $0.hasSuffix(".md") }
        var examples = 0
        for file in files {
            let text = try String(contentsOf: skill.appendingPathComponent(file), encoding: .utf8)
            for case let .visual(visual) in LedgerAgentReplyText.segments(text) {
                XCTAssertFalse(visual.blocks.isEmpty, file)
                examples += 1
            }
            for fence in Self.fences(text, language: "visual") {
                XCTAssertEqual(LedgerAgentVisual.drops(json: fence), [], "\(file): \(fence.prefix(80))")
            }
        }
        XCTAssertGreaterThanOrEqual(examples, 5)
    }

    static func fences(_ text: String, language: String) -> [String] {
        var fences: [String] = [], lines: [Substring] = [], inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                if inside { fences.append(lines.joined(separator: "\n")) }
                inside = !inside && line.dropFirst(3).trimmingCharacters(in: .whitespaces) == language
                lines = []
            } else if inside {
                lines.append(line)
            }
        }
        return fences
    }

    func testSankeyDropsLoopsAndColumnsByLongestPath() throws {
        let json = #"{"blocks":[{"type":"sankey","flows":[{"from":"工资","to":"招行","value":100},{"from":"招行","to":"餐饮","value":40},{"from":"工资","to":"餐饮","value":10},{"from":"餐饮","to":"工资","value":5},{"from":"招行","to":"招行","value":1},{"from":"a","to":"b","value":0}]}]}"#
        let visual = try XCTUnwrap(LedgerAgentVisual(json: json))
        guard case let .sankey(sankey) = visual.blocks[0] else { return XCTFail("\(visual.blocks)") }
        XCTAssertEqual(sankey.flows.map(\.value), [100, 40, 10])
        XCTAssertEqual(sankey.nodes.map(\.name), ["工资", "招行", "餐饮"])
        XCTAssertEqual(sankey.nodes.map(\.column), [0, 1, 2])
        XCTAssertEqual(sankey.nodes.map(\.value), [110, 100, 50])

        let layout = sankey.layout(width: 300, height: 200, nodeWidth: 10, gap: 10)
        // The tallest column fills the height.
        XCTAssertEqual(layout.frames[0].height, 200, accuracy: 0.001)
        XCTAssertEqual(layout.frames[2].maxX, 300, accuracy: 0.001)
        // A node's outgoing bands stack without overlap.
        let fromWage = layout.bands.filter { sankey.flows[$0.flow].from == "工资" }.sorted { $0.fromY < $1.fromY }
        XCTAssertEqual(fromWage[0].fromY + fromWage[0].thickness, fromWage[1].fromY, accuracy: 0.001)
    }

    func testSquarifyFillsTheBoxWithoutOverlap() {
        let box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let frames = LedgerAgentVisual.Treemap.squarify(values, in: box)
        XCTAssertEqual(frames.count, values.count)
        let area = frames.reduce(0) { $0 + Double($1.width * $1.height) }
        XCTAssertEqual(area, 60000, accuracy: 0.5)
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(Double(frame.width * frame.height) / 60000, values[index] / 24, accuracy: 0.001)
            XCTAssertTrue(box.insetBy(dx: -0.01, dy: -0.01).contains(frame), "\(frame)")
            for other in frames[(index + 1)...] {
                XCTAssertLessThan(Double(frame.intersection(other).width * frame.intersection(other).height), 0.01)
            }
        }
        XCTAssertEqual(LedgerAgentVisual.Treemap.squarify([0, 0], in: box), [.zero, .zero])
    }

    func testGaugeMatrixAndTransactionsDecodeLeniently() throws {
        let json = #"""
        {"blocks":[
         {"type":"gauge","items":[{"label":"储蓄率","value":"34%"},{"label":"应急金","value":42000,"max":60000,"target":50000},{"label":"坏","value":1,"max":0}]},
         {"type":"matrix","columns":["9月","10月","11月"],"rows":[{"label":"餐饮","values":[1600,"1,820.5"]},{"label":"旅行","values":[null,1280,""]}],"totals":true},
         {"type":"transactions","items":[{"date":"2026-10-05","payee":"东航","amount":-1280,"tags":["#国庆"]},{"date":"2026-10-05","narration":"报销","amount":"1280"},{"date":"2026-10-04","amount":-3},{"date":"2026-10-03","narration":"午饭","amount":-25}]}]}
        """#
        let visual = try XCTUnwrap(LedgerAgentVisual(json: json))
        XCTAssertEqual(visual.blocks.count, 3)
        guard case let .gauge(gauge) = visual.blocks[0], case let .matrix(matrix) = visual.blocks[1],
              case let .transactions(list) = visual.blocks[2] else { return XCTFail("\(visual.blocks)") }
        XCTAssertEqual(gauge.items.map(\.label), ["储蓄率", "应急金"])
        XCTAssertEqual(gauge.items[1].ratio, 0.7, accuracy: 0.0001)
        XCTAssertEqual(matrix.rows[0].values, [1600, 1820.5, nil])
        XCTAssertEqual(matrix.rows[1].values, [nil, 1280, nil])
        XCTAssertEqual(matrix.columnTotals, [1600, 3100.5, 0])
        XCTAssertEqual(matrix.peak, 1820.5)
        XCTAssertEqual(list.items.count, 3)
        XCTAssertEqual(list.items[0].tags, ["国庆"])
        XCTAssertEqual(list.days(list.items).map(\.items.count), [2, 1])
        XCTAssertEqual(list.items[2].destination?.absoluteString, "ledger://transactions?date=2026-10-03")
        XCTAssertEqual(LedgerAgentVisual.drops(json: json), ["blocks.0.items.2", "blocks.2.items.2"])
    }

    func testTreemapKeepsOneLevelOfPositiveChildren() throws {
        let json = #"{"blocks":[{"type":"treemap","items":[{"label":"餐饮","value":30,"children":[{"label":"外卖","value":20,"children":[{"label":"深","value":1}]},{"label":"退款","value":-5}]},{"label":"零","value":0}]}]}"#
        let visual = try XCTUnwrap(LedgerAgentVisual(json: json))
        guard case let .treemap(treemap) = visual.blocks[0] else { return XCTFail("\(visual.blocks)") }
        XCTAssertEqual(treemap.items.map(\.label), ["餐饮"])
        XCTAssertEqual(treemap.items[0].children.map(\.label), ["外卖"])
        XCTAssertEqual(treemap.items[0].children[0].children, [])
    }
}
