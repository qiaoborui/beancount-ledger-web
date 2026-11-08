import Foundation
import XCTest
@testable import LedgerMobile

final class LocalModelRequestGateTests: XCTestCase {
    /// Counts how many holders are inside the critical section at once.
    private actor Tracker {
        private(set) var concurrent = 0
        private(set) var peak = 0
        func enter() { concurrent += 1; peak = max(peak, concurrent) }
        func leave() { concurrent -= 1 }
    }

    func testReadsRunConcurrently() async {
        let gate = LocalModelRequestGate()
        let tracker = Tracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.acquireRead()
                    await tracker.enter()
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await tracker.leave()
                    await gate.releaseRead()
                }
            }
        }
        let peak = await tracker.peak
        XCTAssertGreaterThan(peak, 1, "ordinary reads must not serialize")
    }

    func testWriteExcludesReads() async {
        let gate = LocalModelRequestGate()
        let tracker = Tracker()
        await gate.acquireWrite()
        // Readers queue behind the writer. Release from inside the group, otherwise
        // the group would wait on children that wait on this scope forever.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await gate.acquireRead()
                    await tracker.enter()
                    await tracker.leave()
                    await gate.releaseRead()
                }
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
            let peakWhileWriting = await tracker.peak
            XCTAssertEqual(peakWhileWriting, 0, "no reader may enter while a writer holds the gate")
            await gate.releaseWrite()
        }
        let peakAfter = await tracker.peak
        XCTAssertGreaterThan(peakAfter, 0, "queued readers must run once the writer releases")
    }

    func testWritesExcludeEachOther() async {
        let gate = LocalModelRequestGate()
        let tracker = Tracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await gate.acquireWrite()
                    await tracker.enter()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    await tracker.leave()
                    await gate.releaseWrite()
                }
            }
        }
        let peak = await tracker.peak
        XCTAssertEqual(peak, 1, "writers must be exclusive")
    }

    /// A writer queued behind readers must not be starved by further readers, and
    /// readers already inside must finish before it starts.
    func testQueuedWriterIsPreferredOverNewReaders() async {
        let gate = LocalModelRequestGate()
        let order = Recorder()
        await gate.acquireRead()
        let writer = Task {
            await gate.acquireWrite()
            await order.append("write")
            await gate.releaseWrite()
        }
        // Give the writer a chance to queue behind the current reader.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let lateReader = Task {
            await gate.acquireRead()
            await order.append("read")
            await gate.releaseRead()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await gate.releaseRead()
        await writer.value
        await lateReader.value
        let sequence = await order.values
        XCTAssertEqual(sequence.first, "write", "a queued writer must not be overtaken by a later reader")
    }

    func testWriterLaneIsExclusiveAndFirstComeFirstServed() async {
        let lane = LocalModelWriterLane()
        let order = Recorder()
        await lane.acquire()
        var writers: [Task<Void, Never>] = []
        for index in 0..<3 {
            writers.append(Task {
                await lane.acquire()
                await order.append("writer-\(index)")
                await lane.release()
            })
            // Queue them in a known order.
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let whileHeld = await order.values
        XCTAssertTrue(whileHeld.isEmpty, "no writer may enter while another holds the lane")
        await lane.release()
        for writer in writers { await writer.value }
        let sequence = await order.values
        XCTAssertEqual(sequence, ["writer-0", "writer-1", "writer-2"])
    }

    /// The lane is what lets a publication export without blocking reads: a
    /// writer holding only the lane must leave the gate open to readers, while
    /// a second writer still waits.
    func testReadersIgnoreTheWriterLane() async {
        let gate = LocalModelRequestGate()
        let lane = LocalModelWriterLane()
        let order = Recorder()
        await lane.acquire()
        let secondWriter = Task {
            await lane.acquire()
            await order.append("write")
            await lane.release()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await gate.acquireRead()
        await order.append("read")
        await gate.releaseRead()
        let whileHeld = await order.values
        XCTAssertEqual(whileHeld, ["read"], "a reader must not wait for the writer lane")
        await lane.release()
        await secondWriter.value
        let sequence = await order.values
        XCTAssertEqual(sequence, ["read", "write"])
    }

    private actor Recorder {
        private(set) var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }
}
