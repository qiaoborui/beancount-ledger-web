import Foundation

/// The portable part of the 账本助手's voice input: the level history behind
/// the waveform, how dictated text joins what is already in the field, and the
/// timer text. The microphone and the recognizer live in
/// `LedgerAgentVoiceRecorder`, which only the app target compiles.

/// A rolling history of microphone levels, drawn as bars that slide left
/// continuously. A level is recorded every `interval`; the picture is a pure
/// function of the time it is drawn at, so a 60 fps redraw moves every bar by
/// a fraction of its pitch instead of jumping one whole slot per sample, and
/// the newest bar grows from nothing at the right edge while it is young.
struct LedgerVoiceWaveform: Equatable, Sendable {
    /// Seconds between two recorded levels.
    static let interval: TimeInterval = 0.05
    /// Quietest level the meter tells from silence, in dBFS.
    static let floorDecibels: Float = -50

    struct Sample: Equatable, Sendable {
        /// 0…1.
        let level: Double
        let time: TimeInterval
    }

    /// One bar of a frame.
    struct Bar: Equatable, Sendable {
        /// Seconds since the level was recorded.
        let age: TimeInterval
        /// 0…1, already scaled down while the bar is still growing in.
        let height: Double
        /// Distance from the right edge in units of `interval`.
        var slots: Double { age / LedgerVoiceWaveform.interval }
    }

    /// Enough for the widest dock, at the finest pitch, with room to spare.
    static let capacity = 240

    private(set) var samples: [Sample] = []

    mutating func append(level: Double, at time: TimeInterval) {
        samples.append(Sample(level: min(max(level, 0), 1), time: time))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    mutating func reset() { samples = [] }

    /// The bars to draw at `now`, newest first, none older than `span`
    /// seconds (the width of the strip). Only the newest bar can be younger
    /// than one interval, and it is the one that grows.
    func bars(at now: TimeInterval, span: TimeInterval) -> [Bar] {
        var result: [Bar] = []
        for sample in samples.reversed() {
            let age = max(now - sample.time, 0)
            if age > span { break }
            let growth = min(age / Self.interval, 1)
            result.append(Bar(age: age, height: sample.level * growth))
        }
        return result
    }

    /// 0…1 for a power in dBFS, linear between the floor and 0 dB with the
    /// quiet end lifted a little so speech at a normal distance fills about
    /// three quarters of the height.
    static func level(decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        if decibels <= floorDecibels { return 0 }
        if decibels >= 0 { return 1 }
        let linear = Double((decibels - floorDecibels) / -floorDecibels)
        return pow(linear, 1.6)
    }

    /// The level of a block of samples: its RMS, in dBFS, through `level`.
    static func level(samples: UnsafeBufferPointer<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for value in samples { sum += value * value }
        let rms = (sum / Float(samples.count)).squareRoot()
        return level(decibels: rms > 0 ? 20 * log10(rms) : -.infinity)
    }
}

/// Dictated text and the field it goes into.
enum LedgerVoiceTranscript {
    /// The field after `transcript` is dictated after `base`: the two are
    /// joined with a space only where both sides are Latin or digits, since
    /// Chinese text takes none, and an empty transcript leaves `base` as it was.
    static func merged(base: String, transcript: String) -> String {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return base }
        guard let last = base.last, let first = spoken.first else { return spoken }
        if last.isWhitespace || last.isNewline { return base + spoken }
        return base + (isWordLike(last) && isWordLike(first) ? " " : "") + spoken
    }

    private static func isWordLike(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    /// m:ss for the recording timer; an hour or more reads h:mm:ss.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
