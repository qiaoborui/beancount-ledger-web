import Foundation

/// How the 账本助手 composer reads its text. The field grows to several lines,
/// so the software keyboard's Return types a newline instead of submitting;
/// a newline typed at the very end is read as Return and sends instead.
enum LedgerAgentComposer {
    /// The text to keep in the field after an edit from `old` to `new`, and
    /// whether the edit was Return. Only one newline added after the old text
    /// counts: a pasted block of lines, or a newline typed in the middle,
    /// stays in the field.
    static func submission(old: String, new: String) -> (text: String, submit: Bool) {
        guard new.count == old.count + 1, new.hasSuffix("\n"), new.dropLast() == old[...] else {
            return (new, false)
        }
        return (old, true)
    }
}
