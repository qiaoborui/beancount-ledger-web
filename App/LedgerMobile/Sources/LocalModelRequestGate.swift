import Foundation

/// Process-wide reader/writer gate. Registration, promotion and handle releases
/// change the committed model handle table, so they need exclusivity. Ordinary
/// reads of an already-registered generation only read an immutable snapshot,
/// and the Go side already guards its caches, so they may run together. Writer
/// state that readers never see (the exporter scratch directory, the stream
/// cache, the stage slot) is serialized by `LocalModelWriterLane` instead, so a
/// canonical export no longer holds this gate.
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

/// Process-wide FIFO lane for writers. Readers never enter it.
///
/// The gate's exclusive mode guards what committed reads can observe: the
/// committed handle tables (Swift and Go) and handle releases. Writers also own
/// state no reader touches: the `canonical-stream` scratch directory, the
/// canonical stream cache and the native core's single stage slot. Those only
/// need writers to take turns, so a writer holds this lane for its whole
/// operation and takes the gate exclusively only for the short sections that
/// change what readers see. A publication's multi-second Python export then no
/// longer stalls scrolling, search and the overview.
///
/// Lock order is always lane, then gate. Nothing waits for the lane while
/// holding the gate, so the two cannot deadlock.
actor LocalModelWriterLane {
    static let shared = LocalModelWriterLane()
    init() {}
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the lane straight to the next writer in arrival order.
    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
