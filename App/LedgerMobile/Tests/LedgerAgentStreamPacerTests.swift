import XCTest
@testable import LedgerMobile

final class LedgerAgentStreamPacerTests: XCTestCase {
    func testBatchDrainsWithinTheWindowAndNeverStalls() {
        XCTAssertEqual(LedgerAgentStreamPacer.batch(pending: 0, frames: 15), 0)
        XCTAssertEqual(LedgerAgentStreamPacer.batch(pending: 3, frames: 15), 1)
        XCTAssertEqual(LedgerAgentStreamPacer.batch(pending: 150, frames: 15), 10)
        XCTAssertEqual(LedgerAgentStreamPacer.batch(pending: 151, frames: 15), 11)
        XCTAssertEqual(LedgerAgentStreamPacer.batch(pending: 5, frames: 0), 5)
    }

    func testFramesThinOutAsTheReplyGrows() {
        let short = LedgerAgentStreamPacer.frameInterval(shownCharacters: 10)
        let long = LedgerAgentStreamPacer.frameInterval(shownCharacters: 10_000)
        XCTAssertEqual(short, 1.0 / 30, accuracy: 0.0001)
        XCTAssertGreaterThan(long, short)
    }

    func testDeltasOfOneKindMergeAndAreLetOutInShares() {
        var pacer = LedgerAgentStreamPacer()
        pacer.enqueue(.textDelta("一二三四五"))
        pacer.enqueue(.textDelta("六七八九十"))
        pacer.enqueue(.textDelta(""))
        XCTAssertEqual(pacer.queue, [.textDelta("一二三四五六七八九十")])
        XCTAssertEqual(pacer.pendingCharacters, 10)

        XCTAssertEqual(pacer.release(frames: 4), [.textDelta("一二三")])
        XCTAssertEqual(pacer.pendingCharacters, 7)
        XCTAssertEqual(pacer.release(frames: 4), [.textDelta("四五")])
        XCTAssertEqual(pacer.release(frames: 1), [.textDelta("六七八九十")])
        XCTAssertTrue(pacer.isEmpty)
        XCTAssertEqual(pacer.release(frames: 4), [])
    }

    func testOtherEventsKeepTheirPlaceBehindTheText() {
        var pacer = LedgerAgentStreamPacer()
        pacer.enqueue(.thinkingDelta("先查一下"))
        pacer.enqueue(.thinkingEnd(durationMs: 800, redacted: false))
        let call = LedgerAgentToolCall(name: "run_bql", isError: false, callId: "c1")
        pacer.enqueue(.toolStart(call))
        pacer.enqueue(.textDelta("共 8"))

        // Half the reasoning: the call waits for the rest.
        XCTAssertEqual(pacer.release(frames: 4), [.thinkingDelta("先查")])
        // The rest of it, then everything up to the next text, then that
        // text's share of what the frame has left.
        XCTAssertEqual(pacer.release(frames: 2),
                       [.thinkingDelta("一下"), .thinkingEnd(durationMs: 800, redacted: false), .toolStart(call),
                        .textDelta("共")])
        XCTAssertEqual(pacer.release(frames: 1), [.textDelta(" 8")])
    }

    func testAnEventAtTheHeadGoesAtOnce() {
        var pacer = LedgerAgentStreamPacer()
        pacer.enqueue(.compactionStart)
        pacer.enqueue(.compactionEnd(summarizedTurns: 2))
        XCTAssertEqual(pacer.release(frames: 15), [.compactionStart, .compactionEnd(summarizedTurns: 2)])
        XCTAssertTrue(pacer.isEmpty)
    }

    func testCharactersAreNeverCutInHalf() {
        var pacer = LedgerAgentStreamPacer()
        pacer.enqueue(.textDelta("👨‍👩‍👧花了"))
        XCTAssertEqual(pacer.pendingCharacters, 3)
        XCTAssertEqual(pacer.release(frames: 3), [.textDelta("👨‍👩‍👧")])
        XCTAssertEqual(pacer.drain(), [.textDelta("花了")])
        XCTAssertEqual(pacer.pendingCharacters, 0)
    }

    func testPacedEventsBuildTheSameTurn() {
        let events: [LedgerAgentLiveEvent] = [
            .thinkingDelta("先查"), .thinkingDelta("十月"), .thinkingEnd(durationMs: 500, redacted: false),
            .toolStart(.init(name: "run_bql", isError: false, callId: "c1")),
            .toolEnd(.init(name: "run_bql", isError: false, callId: "c1", durationMs: 30)),
            .textDelta("十月餐饮"), .textDelta("共 812 元。"), .usage(.init(contextTokens: 10, contextWindow: 100)),
        ]
        var direct = LedgerAgentLiveTurn()
        events.forEach { direct.apply($0) }

        var pacer = LedgerAgentStreamPacer()
        var paced = LedgerAgentLiveTurn()
        for event in events {
            pacer.enqueue(event)
            pacer.release(frames: 3).forEach { paced.apply($0) }
        }
        while !pacer.isEmpty { pacer.release(frames: 3).forEach { paced.apply($0) } }
        XCTAssertEqual(paced, direct)
    }
}
