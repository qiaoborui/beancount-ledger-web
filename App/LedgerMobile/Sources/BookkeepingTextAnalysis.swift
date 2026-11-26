import Foundation

/// Text helpers for `BookkeepingAccountMatcher`, which reads the words of a
/// Siri / Shortcuts recording to pick its accounts.
enum BookkeepingText {
    /// Full-width digits, letters and money symbols folded to ASCII. Each UTF-16
    /// unit maps to exactly one unit, so ranges on the folded text address the
    /// original text. The full-width comma stays: it separates clauses.
    static func fold(_ text: String) -> String {
        var units = Array(text.utf16)
        for index in units.indices {
            let unit = units[index]
            switch unit {
            case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A, 0xFF04, 0xFF05, 0xFF0B, 0xFF0D, 0xFF0E, 0xFF0F, 0xFF1A:
                units[index] = unit - 0xFEE0
            case 0xFFE5: units[index] = 0x00A5 // ￥ → ¥
            case 0xFFE1: units[index] = 0x00A3 // ￡ → £
            case 0x3000: units[index] = 0x0020
            default: break
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func scalar(_ text: NSString, _ location: Int) -> Unicode.Scalar? {
        guard location >= 0, location < text.length else { return nil }
        return Unicode.Scalar(text.character(at: location))
    }
}
