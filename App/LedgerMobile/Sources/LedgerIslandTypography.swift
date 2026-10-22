import CoreGraphics
import CoreText
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Island type metrics and text measurement.
///
/// The layout maths in `LedgerIslandMotion.swift` and the portable tests both
/// need these numbers, so they live beside the motion code instead of the
/// SwiftUI island view. Text is measured with Core Text on every platform, so
/// this file stays importable from the portable package; the SwiftUI `Font`
/// constants live with the view that draws them.
enum LedgerIslandFonts {
    static let titleSize: CGFloat = 16
    static let titleLineHeight: CGFloat = 20
    static let subtitleLineHeight: CGFloat = 16

    /// Weight of the system font at `size`, as UIKit would pick it.
    static func weight(_ weight: FontWeight) -> CTFont? {
        #if canImport(UIKit)
        return UIFont.systemFont(ofSize: 16, weight: weight.uiFontWeight)
        #else
        return CTFontCreateUIFontForLanguage(.system, 16, nil)
        #endif
    }

    enum FontWeight {
        case medium
        case semibold
        case bold

        #if canImport(UIKit)
        var uiFontWeight: UIFont.Weight {
            switch self {
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
        #endif
    }

    /// Width `text` occupies at `size` and `weight`.
    static func width(_ text: String, size: CGFloat, weight: FontWeight, rounded: Bool = false) -> Double {
        Double(ceil(measuredWidth(text, size: size, weight: weight, rounded: rounded)))
    }

    /// Width the title needs on one line; drives the one- vs two-line choice.
    static func measuredWidth(_ text: String, size: CGFloat, weight: FontWeight) -> Double {
        width(text, size: size, weight: weight)
    }

    private static func measuredWidth(_ text: String, size: CGFloat, weight: FontWeight, rounded: Bool) -> CGFloat {
        guard let base = LedgerIslandFonts.weight(weight) else {
            // No font table (extremely unlikely): approximate with 0.6 em per glyph.
            return CGFloat(text.count) * size * 0.6
        }
        let font = CTFontCreateCopyWithAttributes(base, size, nil, attributes(rounded: rounded))
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        )
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func attributes(rounded: Bool) -> CTFontDescriptor? {
        guard rounded else { return nil }
        let traits: [String: Any] = [
            kCTFontWeightTrait as String: 0.4,
            kCTFontWidthTrait as String: 0,
            kCTFontSlantTrait as String: 0,
            // Apple's rounded system design is only reachable through this key.
            "NSCTFontUIFontDesignTrait": 2,
        ]
        return CTFontDescriptorCreateWithAttributes(traits as CFDictionary)
    }

    /// How `text` folds into at most `count` lines that fit `width`: breaks at
    /// spaces for Latin text and after any character for CJK. Used to measure a
    /// title before it is laid out, so the island can reserve the right rows.
    static func foldedLines(_ text: String, size: CGFloat, weight: FontWeight, count: Int, width limit: Double) -> [String] {
        let limit = max(limit, 1)
        var lines: [String] = []
        var current = ""
        func flush() {
            // A fold never keeps the space it broke at.
            while current.hasSuffix(" ") { current.removeLast() }
            if !current.isEmpty { lines.append(current) }
            current = ""
        }
        for chunk in chunks(of: text) {
            let candidate = current + chunk
            if width(candidate, size: size, weight: weight) <= limit {
                current = candidate
                continue
            }
            // The space between two words is where the line breaks.
            if chunk.allSatisfy({ $0 == " " }) {
                flush()
                continue
            }
            // A word that cannot follow on this line starts a new one, unless
            // it is the first thing on the line and only then breaks itself.
            if !current.isEmpty {
                flush()
                if width(chunk, size: size, weight: weight) <= limit {
                    current = chunk
                    continue
                }
            }
            for character in chunk {
                let next = current + String(character)
                if !current.isEmpty && width(next, size: size, weight: weight) > limit {
                    flush()
                    current = String(character)
                } else {
                    current = next
                }
            }
        }
        flush()
        while lines.count > count, let last = lines.popLast() {
            // Lines broke at a space between Latin words; put it back.
            let latin = lines[lines.count - 1].last?.isASCII == true && last.first?.isASCII == true
            lines[lines.count - 1] += (latin ? " " : "") + last
        }
        return lines
    }

    /// Latin words stay whole; every other run (CJK, emoji) breaks by character.
    private static func chunks(of text: String) -> [String] {
        var result: [String] = []
        var word = ""
        var space = ""
        for character in text {
            if character == " " {
                if !word.isEmpty { result.append(word); word = "" }
                space.append(character)
                continue
            }
            if !space.isEmpty { result.append(space); space = "" }
            word.append(character)
        }
        if !word.isEmpty { result.append(word) }
        if !space.isEmpty { result.append(space) }
        return result
    }
}

struct LedgerIslandTextLayout {
    let title: String
    let rows: LedgerIslandStage.Layout.TextRows
    let scale: Double

    var lines: Int { rows.titleLines }

    init(title: String, totalWidth: Double) {
        self.title = title
        // A title takes two lines only when the full column cannot hold it.
        // Latin text fits more characters per line than CJK, so the fold points
        // come from the measured per-character width, and the first fold keeps
        // the last word whole rather than cutting it mid-word.
        let oneLine = LedgerIslandFonts.measuredWidth(title, size: LedgerIslandFonts.titleSize, weight: .semibold)
        if oneLine <= totalWidth {
            rows = .init(titleLines: 1)
            scale = 1
        } else {
            let lines = LedgerIslandFonts.foldedLines(
                title, size: LedgerIslandFonts.titleSize, weight: .semibold,
                count: LedgerIslandStage.Layout.titleLines, width: totalWidth)
            let widest = lines.map {
                LedgerIslandFonts.width($0, size: LedgerIslandFonts.titleSize, weight: .semibold)
            }.max() ?? oneLine
            rows = .init(titleLines: LedgerIslandStage.Layout.titleLines)
            // Prefer two lines at full size; fall back to a smaller type only
            // when even two lines would be cut.
            if widest <= totalWidth {
                scale = 1
            } else {
                let smallLines = LedgerIslandFonts.foldedLines(
                    title, size: LedgerIslandFonts.titleSize, weight: .semibold,
                    count: LedgerIslandStage.Layout.titleLines,
                    width: totalWidth / LedgerIslandStage.Layout.longTitleScale)
                let smallWidth = smallLines.map {
                    LedgerIslandFonts.width($0, size: LedgerIslandFonts.titleSize, weight: .semibold)
                }.max() ?? widest
                scale = smallWidth <= totalWidth ? LedgerIslandStage.Layout.longTitleScale : 1
            }
        }
    }

    /// The text column runs below the camera, across the island's width.
    static func columnWidth(stage: LedgerIslandStage) -> Double {
        max(60, stage.expandedWidth - 2 * LedgerIslandStage.Layout.inset)
    }

    /// Rows the stage should reserve for this notice, measured at the settled
    /// column (the shape may still be growing when the notice is presented).
    @MainActor
    static func rows(for notice: LedgerIslandNotice, stage: LedgerIslandStage) -> LedgerIslandStage.Layout.TextRows {
        LedgerIslandTextLayout(title: notice.title, totalWidth: columnWidth(stage: stage)).rows
    }
}
