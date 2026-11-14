import Foundation
import XCTest
@testable import LedgerMobile

/// The 账本助手's voice input: the sliding waveform, the level meter and how
/// dictated text joins the field.
final class LedgerAgentVoiceTests: XCTestCase {
    // MARK: Waveform

    func testNewestBarGrowsFromTheRightEdge() {
        var wave = LedgerVoiceWaveform()
        wave.append(level: 0.8, at: 10)

        let born = wave.bars(at: 10, span: 1)
        XCTAssertEqual(born.count, 1)
        XCTAssertEqual(born[0].height, 0, accuracy: 1e-9)
        XCTAssertEqual(born[0].slots, 0, accuracy: 1e-9)

        let half = wave.bars(at: 10 + LedgerVoiceWaveform.interval / 2, span: 1)
        XCTAssertEqual(half[0].height, 0.4, accuracy: 1e-9)
        XCTAssertEqual(half[0].slots, 0.5, accuracy: 1e-9)

        let grown = wave.bars(at: 10 + LedgerVoiceWaveform.interval * 3, span: 1)
        XCTAssertEqual(grown[0].height, 0.8, accuracy: 1e-9)
        XCTAssertEqual(grown[0].slots, 3, accuracy: 1e-9)
    }

    func testBarsSlideContinuouslyBetweenSamples() {
        var wave = LedgerVoiceWaveform()
        wave.append(level: 0.5, at: 0)
        // The same bar a frame later is a fraction of a slot further left.
        let a = wave.bars(at: 1.000, span: 5)[0].slots
        let b = wave.bars(at: 1.0 + 1.0 / 60, span: 5)[0].slots
        XCTAssertEqual(b - a, (1.0 / 60) / LedgerVoiceWaveform.interval, accuracy: 1e-9)
        XCTAssertLessThan(b - a, 1)
    }

    func testBarsAreNewestFirstAndStopAtTheSpan() {
        var wave = LedgerVoiceWaveform()
        for index in 0..<10 { wave.append(level: Double(index) / 10, at: Double(index) * LedgerVoiceWaveform.interval) }
        let now = 9 * LedgerVoiceWaveform.interval
        let all = wave.bars(at: now, span: 10)
        XCTAssertEqual(all.map(\.age), all.map(\.age).sorted())
        XCTAssertEqual(all.count, 10)
        // Only the samples within 3 intervals of now remain.
        let few = wave.bars(at: now, span: 3 * LedgerVoiceWaveform.interval + 1e-9)
        XCTAssertEqual(few.count, 4)
    }

    func testHistoryIsBoundedAndLevelsClamped() {
        var wave = LedgerVoiceWaveform()
        for index in 0..<(LedgerVoiceWaveform.capacity + 50) { wave.append(level: 7, at: Double(index)) }
        XCTAssertEqual(wave.samples.count, LedgerVoiceWaveform.capacity)
        XCTAssertEqual(wave.samples.last?.level, 1)
        wave.append(level: -3, at: 1_000)
        XCTAssertEqual(wave.samples.last?.level, 0)
        wave.reset()
        XCTAssertTrue(wave.samples.isEmpty)
    }

    // MARK: Level

    func testLevelFromDecibels() {
        XCTAssertEqual(LedgerVoiceWaveform.level(decibels: -80), 0)
        XCTAssertEqual(LedgerVoiceWaveform.level(decibels: -.infinity), 0)
        XCTAssertEqual(LedgerVoiceWaveform.level(decibels: .nan), 0)
        XCTAssertEqual(LedgerVoiceWaveform.level(decibels: 0), 1)
        XCTAssertEqual(LedgerVoiceWaveform.level(decibels: 6), 1)
        let quiet = LedgerVoiceWaveform.level(decibels: -40)
        let speech = LedgerVoiceWaveform.level(decibels: -20)
        XCTAssertGreaterThan(quiet, 0)
        XCTAssertGreaterThan(speech, quiet)
        XCTAssertLessThan(speech, 1)
    }

    func testLevelOfSamples() {
        let silence = [Float](repeating: 0, count: 512)
        XCTAssertEqual(silence.withUnsafeBufferPointer { LedgerVoiceWaveform.level(samples: $0) }, 0)
        XCTAssertEqual([Float]().withUnsafeBufferPointer { LedgerVoiceWaveform.level(samples: $0) }, 0)
        let full = [Float](repeating: 1, count: 512)
        XCTAssertEqual(full.withUnsafeBufferPointer { LedgerVoiceWaveform.level(samples: $0) }, 1, accuracy: 1e-9)
        // A square wave at half scale sits at −6 dBFS.
        let half = [Float](repeating: 0.5, count: 512)
        XCTAssertEqual(half.withUnsafeBufferPointer { LedgerVoiceWaveform.level(samples: $0) },
                       LedgerVoiceWaveform.level(decibels: -6.0206), accuracy: 1e-4)
    }

    // MARK: Transcript

    func testMergedJoinsOnlyLatinWithASpace() {
        XCTAssertEqual(LedgerVoiceTranscript.merged(base: "", transcript: "上个月餐饮花了多少"), "上个月餐饮花了多少")
        XCTAssertEqual(LedgerVoiceTranscript.merged(base: "帮我查", transcript: "上个月餐饮"), "帮我查上个月餐饮")
        XCTAssertEqual(LedgerVoiceTranscript.merged(base: "check", transcript: "March spending"), "check March spending")
        XCTAssertEqual(LedgerVoiceTranscript.merged(base: "查 PR", transcript: "123"), "查 PR 123")
        XCTAssertEqual(LedgerVoiceTranscript.merged(base: "Uber", transcript: "打车"), "Uber打车")
        XCTAssertEqual(LedgerVoiceTranscript.merged(base: "第一行\n", transcript: "第二行"), "第一行\n第二行")
        XCTAssertEqual(LedgerVoiceTranscript.merged(base: "a ", transcript: "b"), "a b")
    }

    func testMergedWithNothingSaidKeepsTheField() {
        XCTAssertEqual(LedgerVoiceTranscript.merged(base: "草稿", transcript: ""), "草稿")
        XCTAssertEqual(LedgerVoiceTranscript.merged(base: "草稿", transcript: "  \n"), "草稿")
        XCTAssertEqual(LedgerVoiceTranscript.merged(base: "", transcript: "  你好 "), "你好")
    }

    func testClock() {
        XCTAssertEqual(LedgerVoiceTranscript.clock(0), "0:00")
        XCTAssertEqual(LedgerVoiceTranscript.clock(3.9), "0:03")
        XCTAssertEqual(LedgerVoiceTranscript.clock(65), "1:05")
        XCTAssertEqual(LedgerVoiceTranscript.clock(3661), "1:01:01")
        XCTAssertEqual(LedgerVoiceTranscript.clock(-4), "0:00")
    }
}
