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
    /// The row's title: payee, narration or the bill's name.
    static let titleSize: CGFloat = 16
    /// The optional label beside the title (category, "已导入").
    static let secondarySize: CGFloat = 12.5
    /// The trailing amount in the expanded row.
    static let amountSize: CGFloat = 17
    /// The amount beside the camera in the compact pill.
    static let compactSize: CGFloat = 14

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
}
