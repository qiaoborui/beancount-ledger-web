import Foundation

/// Evens out a running turn's streamed text before it is drawn.
///
/// A model's deltas reach the phone in bursts: nothing for a moment, then a
/// whole sentence at once. Drawn as they come, the reply stands still and
/// then jumps. The pacer holds the streamed events in order and lets text
/// out a little every frame instead: each frame takes its share of what is
/// waiting so the queue is drawn within `drainWindow`, at least one
/// character, so a slow model still writes a character a frame and a burst
/// never waits more than the window behind the stream.
///
/// Every other event (a call starting or ending, reasoning closing, usage)
/// keeps its place: it is let out once the text before it has been, so the
/// live timeline never shows a call before the sentence that led to it.
///
/// The frames thin out as the reply grows, because each one lays the whole
/// reply out again; a long answer redraws less often in bigger steps.
struct LedgerAgentStreamPacer: Sendable {
    /// How long the text waiting at any moment takes to be let out.
    static let drainWindow: TimeInterval = 0.5

    private(set) var queue: [LedgerAgentLiveEvent] = []
    /// The characters of text and reasoning still held.
    private(set) var pendingCharacters = 0

    var isEmpty: Bool { queue.isEmpty }

    /// Seconds between frames for a reply this long so far.
    static func frameInterval(shownCharacters: Int) -> TimeInterval {
        switch shownCharacters {
        case ..<800: return 1.0 / 30
        case ..<2_000: return 1.0 / 20
        case ..<5_000: return 1.0 / 12
        default: return 1.0 / 8
        }
    }

    /// Characters let out per frame when `pending` wait and `frames` frames
    /// fit in the drain window.
    static func batch(pending: Int, frames: Double) -> Int {
        guard pending > 0 else { return 0 }
        return max(1, Int((Double(pending) / max(frames, 1)).rounded(.up)))
    }

    mutating func enqueue(_ event: LedgerAgentLiveEvent) {
        switch event {
        case let .textDelta(text):
            guard !text.isEmpty else { return }
            pendingCharacters += text.count
            if case let .textDelta(held)? = queue.last {
                queue[queue.count - 1] = .textDelta(held + text)
            } else {
                queue.append(event)
            }
        case let .thinkingDelta(text):
            guard !text.isEmpty else { return }
            pendingCharacters += text.count
            if case let .thinkingDelta(held)? = queue.last {
                queue[queue.count - 1] = .thinkingDelta(held + text)
            } else {
                queue.append(event)
            }
        default:
            queue.append(event)
        }
    }

    /// The events for one frame, `frames` being how many frames fit in the
    /// drain window: every event at the head of the queue, then this frame's
    /// share of the text, then any events right after text it finished.
    mutating func release(frames: Double) -> [LedgerAgentLiveEvent] {
        var budget = Self.batch(pending: pendingCharacters, frames: frames)
        var released: [LedgerAgentLiveEvent] = []
        while let head = queue.first {
            switch head {
            case let .textDelta(text):
                guard budget > 0 else { return released }
                let (taken, rest) = Self.split(text, budget)
                released.append(.textDelta(taken))
                budget -= taken.count
                pendingCharacters -= taken.count
                if rest.isEmpty { queue.removeFirst() } else { queue[0] = .textDelta(rest); return released }
            case let .thinkingDelta(text):
                guard budget > 0 else { return released }
                let (taken, rest) = Self.split(text, budget)
                released.append(.thinkingDelta(taken))
                budget -= taken.count
                pendingCharacters -= taken.count
                if rest.isEmpty { queue.removeFirst() } else { queue[0] = .thinkingDelta(rest); return released }
            default:
                released.append(head)
                queue.removeFirst()
            }
        }
        return released
    }

    /// Everything still held, at once.
    mutating func drain() -> [LedgerAgentLiveEvent] {
        let all = queue
        queue = []
        pendingCharacters = 0
        return all
    }

    private static func split(_ text: String, _ count: Int) -> (String, String) {
        guard count < text.count else { return (text, "") }
        let cut = text.index(text.startIndex, offsetBy: count)
        return (String(text[..<cut]), String(text[cut...]))
    }
}

extension LedgerAgentStreamPacer {
    /// How long a streamed character takes to fade in on the page.
    static let revealDuration: TimeInterval = 0.5
}

/// When each glyph of a block still being written appeared, so the page can
/// fade new text in, as FlowDown does, rather than have it pop: a glyph is
/// drawn at the share of `revealDuration` it has been on screen. A frame's
/// new glyphs start a little apart, all within the frame, so they sweep in
/// rather than land together, and the sweep never falls behind the stream.
/// Times only grow along the text, so once a glyph is whole every glyph
/// before it is too.
///
/// Drawing may happen off the main actor; the lock keeps the record whole.
final class LedgerAgentRevealStore: @unchecked Sendable {
    /// A block first drawn with more than this in it (reopened mid-reply, or
    /// scrolled back to) shows what it has at once.
    static let freshLimit = 40
    /// Every glyph of a frame starts within this.
    static let frameSpread: TimeInterval = 0.03
    static let maximumStagger: TimeInterval = 0.02

    private let lock = NSLock()
    private var appeared: [TimeInterval] = []
    private var drawn = false
    private var text: String?
    private var changedAt: TimeInterval = -.infinity

    /// Takes the text the block shows now.
    func note(_ text: String, now: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard text != self.text else { return }
        self.text = text
        changedAt = now
    }

    /// Nothing has changed for long enough that every glyph is whole.
    func isSettled(now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return now - changedAt > LedgerAgentStreamPacer.revealDuration + Self.frameSpread + 0.1
    }

    /// When each of `glyphs` glyphs appeared, the ones not seen before
    /// appearing from `now`.
    func appearances(glyphs: Int, now: TimeInterval) -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        if !drawn {
            drawn = true
            if glyphs > Self.freshLimit {
                appeared = Array(repeating: -.infinity, count: glyphs)
                return appeared
            }
        }
        if glyphs < appeared.count {
            appeared.removeLast(appeared.count - glyphs)
        } else if glyphs > appeared.count {
            let added = glyphs - appeared.count
            let step = min(Self.maximumStagger, Self.frameSpread / Double(added))
            let start = max(now, appeared.last ?? now)
            for offset in 0..<added { appeared.append(start + Double(offset) * step) }
        }
        return appeared
    }

    /// How much of a glyph that appeared at `appeared` is drawn at `now`.
    static func opacity(appeared: TimeInterval, now: TimeInterval) -> Double {
        min(max((now - appeared) / LedgerAgentStreamPacer.revealDuration, 0), 1)
    }
}
