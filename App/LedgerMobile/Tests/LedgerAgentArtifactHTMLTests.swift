import Foundation
import XCTest
@testable import LedgerMobile

/// Advanced artifacts: the `artifact-html` fence, its sandbox document and
/// the bridge's rules.
final class LedgerAgentArtifactHTMLTests: XCTestCase {
    private let source = "{\"id\":\"calc\",\"title\":\"计算器\",\"summary\":\"算一算\"}\n<div id=\"x\"></div>\n<script>ledger.rows(\"SELECT 1\")</script>"

    func testFenceDecodesIntoAnHTMLArtifactThatSavesAndReadsBack() throws {
        let segments = LedgerAgentReplyText.segments("做好了：\n```artifact-html\n\(source)\n```")
        guard case let .artifact(artifact) = segments.last else { return XCTFail("\(segments)") }
        XCTAssertEqual(artifact.id, "calc")
        XCTAssertEqual(artifact.title, "计算器")
        XCTAssertEqual(artifact.summary, "算一算")
        XCTAssertTrue(artifact.isHTML)
        XCTAssertTrue(artifact.html?.hasPrefix("<div id=\"x\">") == true)
        XCTAssertTrue(artifact.visual.blocks.isEmpty)
        // A saved version reads back as the same artifact.
        let record = try XCTUnwrap(LedgerAgentArtifactRecord.recording(artifact, in: nil, conversation: nil, message: nil))
        XCTAssertEqual(LedgerAgentArtifactSpec(json: try XCTUnwrap(record.latest).spec), artifact)
        XCTAssertEqual(LedgerAgentArtifactRecord.specs(in: "```artifact-html\n\(source)\n```").map(\.id), ["calc"])
    }

    func testStreamingShowsTheTitleAndAStoppedPageIsDropped() {
        let head = "看：\n```artifact-html\n{\"id\":\"calc\",\"title\":\"计算器\"}\n<div>"
        XCTAssertEqual(LedgerAgentReplyText.segments(head, ending: .streaming), [.prose("看："), .buildingArtifact(title: "计算器")])
        XCTAssertEqual(LedgerAgentReplyText.segments("```artifact-html\n{\"id\":", ending: .streaming), [.buildingArtifact(title: nil)])
        XCTAssertEqual(LedgerAgentReplyText.segments(head, ending: .stopped), [.prose("看：")])
    }

    func testMalformedPagesAreShownAsCode() {
        for bad in ["<div>no header</div>", "{\"id\":\"a\"}", "{\"id\":\"a\"}\nplain text", "{oops\n<div></div>"] {
            XCTAssertNil(LedgerAgentArtifactSpec(json: bad), bad)
            guard case .code = LedgerAgentReplyText.segments("```artifact-html\n\(bad)\n```").last else {
                return XCTFail(bad)
            }
        }
        let huge = "{\"id\":\"a\"}\n<div>" + String(repeating: "x", count: LedgerAgentArtifactHTML.maximumBytes) + "</div>"
        XCTAssertNil(LedgerAgentArtifactSpec(html: huge))
    }

    func testDocumentPutsThePolicyFirstAndBlocksTheNetwork() {
        let document = LedgerAgentArtifactHTML.document(body: "<p>hi</p>", context: .init(title: "a<b", today: "2026-11-16", currency: "CNY"))
        let head = document.components(separatedBy: "<head>")[1]
        XCTAssertTrue(head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<meta http-equiv=\"Content-Security-Policy\""))
        for directive in ["default-src 'none'", "connect-src 'none'", "frame-src 'none'", "form-action 'none'"] {
            XCTAssertTrue(LedgerAgentArtifactHTML.contentSecurityPolicy.contains(directive), directive)
        }
        XCTAssertFalse(LedgerAgentArtifactHTML.contentSecurityPolicy.contains("http"))
        XCTAssertTrue(document.contains("<title>a&lt;b</title>"))
        XCTAssertTrue(document.contains("const [today,currency]=[\"2026-11-16\",\"CNY\"]"))
        XCTAssertTrue(document.hasSuffix("<p>hi</p>\n</body></html>"))
        let rules = try? JSONSerialization.jsonObject(with: Data(LedgerAgentArtifactHTML.contentRules.utf8)) as? [[String: Any]]
        XCTAssertEqual(rules?.count, 4)
        // WebKit refuses a rule list whose regexes use alternation.
        let filters = rules?.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String } ?? []
        XCTAssertEqual(filters.count, 4)
        XCTAssertFalse(filters.contains { $0.contains("|") || $0.contains("(") }, "\(filters)")
    }

    func testOnlyReadOnlyQueriesRun() {
        XCTAssertTrue(LedgerAgentArtifactHTML.allows(query: "  select month, sum(value) FROM postings"))
        XCTAssertTrue(LedgerAgentArtifactHTML.allows(query: "BALANCES"))
        XCTAssertFalse(LedgerAgentArtifactHTML.allows(query: ""))
        XCTAssertFalse(LedgerAgentArtifactHTML.allows(query: "PRINT"))
        XCTAssertFalse(LedgerAgentArtifactHTML.allows(query: "SELECT " + String(repeating: "x", count: 5000)))
    }

    func testReplyTurnsCentsIntoYuan() throws {
        let result = BQLResult(columns: [BQLColumn(name: "month", type: "string"), BQLColumn(name: "total", type: "money"),
                                         BQLColumn(name: "count", type: "number")],
                               rows: [[.string("2026-10"), .number(182050), .number(32)], [.string("2026-11"), .null, .number(0)]],
                               query: "SELECT", valuationCurrency: "CNY", limit: 100, rowCount: 2)
        let reply = LedgerAgentArtifactHTML.reply(result)
        let rows = try XCTUnwrap(reply["rows"] as? [[Any]])
        XCTAssertEqual(rows[0][1] as? Double, 1820.5)
        XCTAssertEqual(rows[0][2] as? Double, 32)
        XCTAssertTrue(rows[1][1] is NSNull)
        XCTAssertEqual(reply["truncated"] as? Bool, false)
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: reply), "the page receives plain JSON values")
    }

    /// The example in the skill's html.md is a page the app accepts, and
    /// every query in it is one the bridge runs.
    func testSkillExampleIsAValidPage() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/mobileagent/skills/ledger-visuals/html.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let fences = LedgerAgentVisualBlocksTests.fences(text, language: "artifact-html")
        let example = try XCTUnwrap(fences.last)
        let spec = try XCTUnwrap(LedgerAgentArtifactSpec(html: example))
        XCTAssertEqual(spec.id, "emergency-fund")
        let queries = try NSRegularExpression(pattern: #"ledger\.rows\("([^"]+)"\)"#)
            .matches(in: example, range: NSRange(example.startIndex..., in: example))
            .compactMap { Range($0.range(at: 1), in: example).map { String(example[$0]) } }
        XCTAssertEqual(queries.count, 2)
        XCTAssertTrue(queries.allSatisfy(LedgerAgentArtifactHTML.allows(query:)))
    }
}
