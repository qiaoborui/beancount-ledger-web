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
