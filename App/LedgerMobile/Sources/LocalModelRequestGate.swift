import Foundation

/// Process-wide reader/writer gate. Registration and canonical export mutate the
/// model handle table and the exporter scratch directory, so they need exclusivity.
/// Ordinary reads of an already-registered generation only read an immutable
/// snapshot, and the Go side already guards its caches, so they may run together.
///
/// This used to be a plain FIFO mutex. Every page fetch, every bootstrap and every
/// analysis read queued behind whichever request happened to hold it, including a
/// multi-second Python export. Writers are preferred so a long scroll cannot starve
/// a mutation; a mutation that arrives during a burst of reads waits at most for
/// the reads already in flight.
actor LocalModelRequestGate {
    static let shared = LocalModelRequestGate()
    init() {}
    private var readers = 0
    private var writerActive = false
    private var waitingWriters = 0
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    func acquireRead() async {
        if !writerActive, waitingWriters == 0 {
            readers += 1
            return
        }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func releaseRead() {
        readers -= 1
        resumeWaiters()
    }

    func acquireWrite() async {
        if !writerActive, readers == 0 {
            writerActive = true
            return
        }
        waitingWriters += 1
        await withCheckedContinuation { writeWaiters.append($0) }
    }

    func releaseWrite() {
        writerActive = false
        resumeWaiters()
    }

    private func resumeWaiters() {
        guard !writerActive else { return }
        if !writeWaiters.isEmpty {
            guard readers == 0 else { return }
            writerActive = true
            waitingWriters -= 1
            writeWaiters.removeFirst().resume()
            return
        }
        while let waiter = readWaiters.first {
            readWaiters.removeFirst()
            readers += 1
            waiter.resume()
        }
    }
}
