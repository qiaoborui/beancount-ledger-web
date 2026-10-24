import Foundation
import XCTest
@testable import LedgerMobile

final class LocalLedgerEngineTests: XCTestCase {
    func testPageWireBoundPrecedesDecodeForResultsAndEnvelopes() throws {
        let result = Data(#"{"revision":"r","transactions":[],"sensitiveUnlocked":true}"#.utf8)
        let envelope = Data(#"{"ok":true,"status":200,"result":\#(String(decoding: result, as: UTF8.self))}"#.utf8)
        for (data, wrapped) in [(result, false), (envelope, true)] {
            let response = wrapped ? LocalLedgerResponse(envelope: data) : LocalLedgerResponse(result: data)
            XCTAssertEqual(try response.decodeTransactionPage(maximumBytes: data.count).revision, "r")
            XCTAssertThrowsError(try response.decodeTransactionPage(maximumBytes: data.count - 1))
        }
        let malformed = LocalLedgerResponse(result: Data(repeating: 0xff, count: 10))
        XCTAssertThrowsError(try malformed.decodeTransactionPage(maximumBytes: 9)) {
            XCTAssertEqual($0 as? LocalLedgerError, .operationFailed("交易分页响应超过容量限制"))
        }
    }

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

    func testTypedResponsePreservesExactNumbersAndNulls() throws {
        struct Payload: Decodable {
            let exact: Int64
            let decimal: Decimal
            let text: String
            let values: [Bool?]
        }
        let raw = Data(#"{"ok":true,"status":200,"result":{"exact":9007199254740993,"decimal":1234567890.123456789,"text":"中文\\\"","values":[true,null,false]}}"#.utf8)
        let result = try LocalLedgerResponse(envelope: raw).decode(Payload.self)
        XCTAssertEqual(result.exact, 9_007_199_254_740_993)
        XCTAssertEqual(result.decimal, Decimal(string: "1234567890.123456789"))
        XCTAssertEqual(result.values, [true, nil, false])
        XCTAssertTrue(result.text.hasPrefix("中文"))
        for raw in [#"{"ok":true,"status":204}"#, #"{"ok":true,"status":200,"result":null}"#] {
            XCTAssertNil(try LocalLedgerResponse(envelope: Data(raw.utf8)).decode(Int?.self))
            XCTAssertThrowsError(try LocalLedgerResponse(envelope: Data(raw.utf8)).decode(Int.self))
        }
        XCTAssertEqual(try LocalLedgerResponse(envelope: Data(#"{"ok":true,"status":200,"result":[1,2,3]}"#.utf8)).decode([Int].self), [1,2,3])
    }

    func testRootFoundationTypesKeepDecoderStrategies() throws {
        let decimal = try LocalLedgerResponse(envelope: Data(#"{"ok":true,"status":200,"result":1234567890.123456789}"#.utf8)).decode(Decimal.self)
        XCTAssertEqual(decimal, Decimal(string: "1234567890.123456789"))
        XCTAssertEqual(try LocalLedgerResponse(envelope: Data(#"{"ok":true,"status":200,"result":"AQID"}"#.utf8)).decode(Data.self), Data([1,2,3]))
        XCTAssertEqual(try LocalLedgerResponse(envelope: Data(#"{"ok":true,"status":200,"result":123}"#.utf8)).decode(Date.self), Date(timeIntervalSinceReferenceDate: 123))
    }

    func testTypedFailurePrecedesResultDecodingAndMatchesLegacyMessage() throws {
        for raw in [
            #"{"ok":false,"status":400,"result":{"error":"invalid ledger"},"diagnostics":[{"message":"fallback"}]}"#,
            #"{"ok":true,"status":500,"result":[1,2],"diagnostics":[{"message":"failed"}]}"#,
            #"{"ok":false,"status":200,"result":{"error":12}}"#,
            #"{"ok":false,"status":400,"diagnostics":[]}"#
        ] {
            let data = Data(raw.utf8)
            var legacy: LocalLedgerError?
            XCTAssertThrowsError(try LocalLedgerJSON.resultData(data)) { legacy = $0 as? LocalLedgerError }
            XCTAssertNotNil(legacy)
            XCTAssertThrowsError(try LocalLedgerResponse(envelope: data).decode([Int].self)) {
                XCTAssertEqual($0 as? LocalLedgerError, legacy)
            }
        }
        for raw in ["{}", #"{"ok":"true","status":200}"#, #"{"ok":true,"status":"200"}"#,
                    #"{"ok":true,"status":200,"diagnostics":[{"message":3}],"result":1}"#,
                    #"{"ok":true,"status":200,"result":"wrong type"}"#, "invalid"] {
            XCTAssertThrowsError(try LocalLedgerResponse(envelope: Data(raw.utf8)).decode(Int.self))
        }
    }

    func testLegacyEngineDefaultResponseStillDecodesResultJSON() async throws {
        struct Legacy: LocalLedgerEngine {
            func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data { Data("[1,2]".utf8) }
        }
        let engine: any LocalLedgerEngine = Legacy()
        let response = try await engine.response(.init(workspaceRoot: "/fixture", runtimeRoot: "/runtime", entrypoint: "main.bean", method: "GET", path: "/test"))
        XCTAssertEqual(try response.decode([Int].self), [1,2])
        XCTAssertEqual(try response.resultData(), Data("[1,2]".utf8))
    }

    func testOptInSyntheticTypedDecodeComparison() throws {
        guard ProcessInfo.processInfo.environment["LEDGER_PERF_TYPED_DECODE"] == "1" else {
            throw XCTSkip("Opt-in synthetic response decoding comparison")
        }
        struct Row: Codable, Equatable { let id: Int64; let amount: String; let label: String }
        let rows = (0..<10_000).map { Row(id: 9_007_199_254_740_993 + Int64($0), amount: "123.456789", label: "Synthetic 中文") }
        var raw = Data(#"{"ok":true,"status":200,"result":"#.utf8)
        raw.append(try JSONEncoder().encode(rows)); raw.append(Data("}".utf8))
        let response = LocalLedgerResponse(envelope: raw)
        var samples = [[Double](), [Double]()]
        for iteration in 0..<22 {
            for path in (iteration.isMultiple(of: 2) ? [0,1] : [1,0]) {
                let start = ContinuousClock.now
                let actual = try autoreleasepool {
                    if path == 0 { return try JSONDecoder().decode([Row].self, from: LocalLedgerJSON.resultData(raw)) }
                    return try response.decode([Row].self)
                }
                let elapsed = start.duration(to: .now).components
                if iteration >= 2 { samples[path].append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) }
                XCTAssertEqual(actual, rows)
            }
        }
        for (index, values) in samples.enumerated() {
            let sorted = values.sorted()
            print("synthetic_typed_decode path=\(index == 0 ? "legacy" : "direct") n=\(sorted.count) bytes=\(raw.count) p50_ms=\((sorted[9]+sorted[10])/2) p95_ms=\(sorted[18])")
        }
    }

    func testPageCursorConflictIsStructuredAndOtherFailuresUnchanged() throws {
        for (status, expected) in [(409, LocalLedgerError.staleTransactionCursor),
                                   (400, LocalLedgerError.operationFailed("invalid")),
                                   (413, LocalLedgerError.operationFailed("invalid"))] {
            let response = LocalLedgerResponse(envelope: Data("{\"ok\":false,\"status\":\(status),\"result\":{\"error\":\"invalid\"}}".utf8))
            XCTAssertThrowsError(try response.decodeTransactionPage()) {
                XCTAssertEqual($0 as? LocalLedgerError, expected)
            }
        }
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

    func testCanonicalHandleCacheReleasesIdleModelsOnMemoryPressure() {
        var cache = LocalCanonicalHandleCache()
        let current = LocalCanonicalHandle(workspace: "/ledger/generations/two/workspace",
            entrypoint: "main.bean", handle: "current")
        let idle = LocalCanonicalHandle(workspace: "/older/generations/one/workspace",
            entrypoint: "main.bean", handle: "idle")
        _ = cache.remember(idle)
        _ = cache.remember(current)
        XCTAssertEqual(cache.handles, [current, idle])

        let plan = cache.releaseIdleModels()
        XCTAssertEqual(plan.keep, "current")
        XCTAssertEqual(plan.released, ["idle"])
        XCTAssertEqual(cache.handles, [current])
        XCTAssertEqual(cache.handle(workspace: current.workspace, entrypoint: current.entrypoint), "current")
        XCTAssertNil(cache.handle(workspace: idle.workspace, entrypoint: idle.entrypoint))

        var empty = LocalCanonicalHandleCache()
        let none = empty.releaseIdleModels()
        XCTAssertNil(none.keep)
        XCTAssertEqual(none.released, [])
    }

    func testCanonicalHandleCacheTouchKeepsTheLedgerBeingViewed() {
        var cache = LocalCanonicalHandleCache()
        let first = LocalCanonicalHandle(workspace: "/first/generations/one/workspace",
            entrypoint: "main.bean", handle: "one")
        let second = LocalCanonicalHandle(workspace: "/second/generations/two/workspace",
            entrypoint: "main.bean", handle: "two")
        _ = cache.remember(first)
        _ = cache.remember(second)
        XCTAssertEqual(cache.handles, [second, first])

        // A committed read is evidence of the ledger being viewed, not of the
        // registration order: switching back must move the hit to the front so
        // memory pressure keeps it.
        XCTAssertEqual(cache.touch(workspace: first.workspace, entrypoint: first.entrypoint), "one")
        XCTAssertEqual(cache.handles, [first, second])
        let plan = cache.releaseIdleModels()
        XCTAssertEqual(plan.keep, "one")
        XCTAssertEqual(plan.released, ["two"])
        XCTAssertEqual(cache.handles, [first])

        // A miss neither reorders nor invents a handle.
        XCTAssertNil(cache.touch(workspace: "/other/generations/x/workspace", entrypoint: "main.bean"))
        XCTAssertEqual(cache.handles, [first])
    }

    func testCanonicalHandleCacheSupersedesGenerationsAndEvictsByRecency() {
        var cache = LocalCanonicalHandleCache()
        let olderGeneration = LocalCanonicalHandle(workspace: "/ledger/generations/one/workspace",
            entrypoint: "main.bean", handle: "one")
        let newerGeneration = LocalCanonicalHandle(workspace: "/ledger/generations/two/workspace",
            entrypoint: "main.bean", handle: "two")
        _ = cache.remember(olderGeneration)
        XCTAssertEqual(cache.remember(newerGeneration), ["one"])
        XCTAssertEqual(cache.handles, [newerGeneration])

        let entries = (0..<(LocalCanonicalHandleCache.limit + 1)).map { index in
            LocalCanonicalHandle(workspace: "/ledger\(index)/generations/one/workspace",
                entrypoint: "main.bean", handle: "h\(index)")
        }
        var released: [String] = []
        for entry in entries { released += cache.remember(entry) }
        XCTAssertEqual(released, [newerGeneration.handle, "h0"])
        XCTAssertEqual(cache.handles.map(\.handle), ["h4", "h3", "h2", "h1"])
        XCTAssertEqual(cache.handle(workspace: entries[4].workspace, entrypoint: "main.bean"), "h4")
        cache.forget("h3")
        XCTAssertNil(cache.handle(workspace: entries[3].workspace, entrypoint: "main.bean"))
    }

    func testNativeControlRequestsMatchTheGoDispatcherContract() throws {
        // The Go dispatcher rejects unknown JSON fields, so these standalone
        // requests must carry exactly version/operation plus one control field.
        func encoded(_ request: LocalModelControlRequest) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        }
        let memory = try encoded(.init(operation: "memory-limit", availableBytes: 1_610_612_736))
        XCTAssertEqual(memory["version"] as? Int, 1)
        XCTAssertEqual(memory["operation"] as? String, "memory-limit")
        XCTAssertEqual((memory["availableBytes"] as? NSNumber)?.int64Value, 1_610_612_736)
        XCTAssertNil(memory["modelHandle"])
        XCTAssertEqual(Set(memory.keys), ["version", "operation", "availableBytes"])

        let release = try encoded(.init(operation: "model-release-idle", modelHandle: "handle"))
        XCTAssertEqual(release["operation"] as? String, "model-release-idle")
        XCTAssertEqual(release["modelHandle"] as? String, "handle")
        XCTAssertNil(release["availableBytes"])
        XCTAssertEqual(Set(release.keys), ["version", "operation", "modelHandle"])
    }
}
