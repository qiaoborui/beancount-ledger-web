import Foundation
import XCTest
@testable import LedgerMobile

final class LocalLedgerEngineTests: XCTestCase {
    func testBridgePreservesLargeIntegersAndNestedValues() throws {
        let raw = Data(#"{"ok":true,"status":200,"result":{"exact":9007199254740993,"decimal":1.25,"null":null,"array":[true,"中文",{"amount":"0.0001"}]}}"#.utf8)
        let result = try LocalLedgerJSON.resultData(raw)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual((object["exact"] as? NSNumber)?.int64Value, 9_007_199_254_740_993)
        XCTAssertEqual(object["decimal"] as? Double, 1.25)
        XCTAssertTrue(object["null"] is NSNull)
        XCTAssertEqual((object["array"] as? [Any])?[1] as? String, "中文")
    }

    func testBridgeRejectsFailedOrMalformedEnvelopes() throws {
        for (raw, message) in [
            (#"{"ok":false,"status":400,"result":{"error":"invalid ledger"},"diagnostics":[{"message":"fallback"}]}"#, "invalid ledger"),
            (#"{"ok":true,"status":500,"diagnostics":[{"message":"failed"}]}"#, "failed")
        ] {
            XCTAssertThrowsError(try LocalLedgerJSON.resultData(Data(raw.utf8))) {
                XCTAssertEqual($0 as? LocalLedgerError, .operationFailed(message))
            }
        }
        for raw in ["{}", #"{"ok":"true","status":200}"#, #"{"ok":true,"status":"200"}"#, "invalid"] {
            XCTAssertThrowsError(try LocalLedgerJSON.resultData(Data(raw.utf8)))
        }
        XCTAssertEqual(try LocalLedgerJSON.resultData(Data(#"{"ok":true,"status":204}"#.utf8)), Data("null".utf8))
    }

    func testRequestSplicesCanonicalModelWithoutChangingQueryOrBody() throws {
        let canonical = Data(#"{"version":1,"entries":[{"Postings":[{"Quantity":{"Number":"0.0001","Currency":"BTC"}}]}],"options":{"operating_currency":"CNY"}}"#.utf8)
        let request = LocalLedgerEngineRequest(workspaceRoot: "/fixture/generations/one/workspace", runtimeRoot: "/fixture/runtime",
            entrypoint: "main.bean", method: "POST", path: "/api/ledger/bql",
            query: ["currency": "CNY"], body: .object(["query": .string("SELECT '中文\\\"'")]))
        let encoded = try LocalLedgerJSON.requestData(request, canonical: canonical)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(decoded["path"] as? String, request.path)
        XCTAssertEqual(decoded["query"] as? [String: String], request.query)
        XCTAssertEqual((decoded["body"] as? [String: String])?["query"], "SELECT '中文\\\"'")
        let actual = try JSONSerialization.data(withJSONObject: XCTUnwrap(decoded["canonical"]), options: .sortedKeys)
        let expected = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: canonical), options: .sortedKeys)
        XCTAssertEqual(actual, expected)
    }
}
