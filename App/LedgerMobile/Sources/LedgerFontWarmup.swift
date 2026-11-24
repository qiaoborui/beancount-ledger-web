#if os(iOS)
import UIKit

/// Loads the faces the assistant falls back to before it first needs them.
///
/// Plex Sans and Source Serif have no Chinese and no emoji, so the first
/// reply with either sends Core Text looking through the system's fallback
/// list and reading Songti SC, PingFang and Apple Color Emoji off disk, on
/// the main thread, in the middle of laying the reply out. That was the
/// hitch on the first Chinese or emoji answer after a launch. Setting a line
/// of each here, off the main thread, does that work once while nothing is
/// on screen yet; Core Text keeps the faces and the fallback lists after it.
enum LedgerFontWarmup {
    private static let started = ManagedAtomicFlag()

    static func start() {
        guard started.setOnce() else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { warm() }
    }

    private static func warm() {
        let sample = "账本助手：本月支出 ¥1,234.56，餐饮占 32%。好的👌✅📊🙂"
        let names = ["IBMPlexSans-Regular", "IBMPlexSans-Text", "IBMPlexSans-Medium",
                     "SourceSerif4-Regular", "SourceSerif4-Semibold",
                     "STSongti-SC-Regular", "STSongti-SC-Bold"]
        var fonts = names.compactMap { UIFont(name: $0, size: 16) }
        fonts.append(.systemFont(ofSize: 16))
        fonts.append(.systemFont(ofSize: 16, weight: .semibold))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        _ = renderer.image { _ in
            for font in fonts {
                let line = NSAttributedString(string: sample, attributes: [.font: font])
                // Drawing, not only measuring: glyphs are rasterised and the
                // emoji face's bitmaps are read in.
                line.draw(at: .zero)
            }
        }
    }
}

/// Set once, from any thread.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    /// True the first time only.
    func setOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !set else { return false }
        set = true
        return true
    }
}
#endif
