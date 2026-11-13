import SwiftUI
import UIKit

/// 账本助手's glyph in the compact tab bar: the app's own mark from
/// `Supporting/AppIcon/ledger-mark.svg`, a page with an L cut out of it and a
/// turned corner down its notch. It is drawn with a shape so it stays crisp at
/// tab-bar sizes and does not need an asset catalogue. The widget extension
/// restates this geometry in `WidgetDesign.swift`; the app target never
/// compiles that file.
struct LedgerMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        // The svg's 64-unit view box keeps the mark in its middle 40 units
        // (12...52); that square is fitted to the rect and centred.
        let scale = min(rect.width, rect.height) / 40
        let originX = rect.midX - 20 * scale
        let originY = rect.midY - 20 * scale
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + (x - 12) * scale, y: originY + (y - 12) * scale)
        }
        var path = Path()
        // The page: M12 12H36V28H52V52H12Z.
        path.addLines([point(12, 12), point(36, 12), point(36, 28), point(52, 28), point(52, 52), point(12, 52)])
        path.closeSubpath()
        // The L, cut out of the page with even-odd filling: M22 22H28V40H42V46H22Z.
        path.addLines([point(22, 22), point(28, 22), point(28, 40), point(42, 40), point(42, 46), point(22, 46)])
        path.closeSubpath()
        // The turned corner, held off the page's notch: M40 12L52 24H40Z.
        path.addLines([point(40, 12), point(52, 24), point(40, 24)])
        path.closeSubpath()
        return path
    }
}

/// The tab bar's copy of the mark, rendered once into a template image.
///
/// A tab bar draws a label's image and not an arbitrary view, so the shape has
/// to become one. Template rendering keeps the icon free of colours: the system
/// tints it for the selected tab, the unselected tabs and each appearance, the
/// same way it tints the SF Symbols beside it.
@MainActor
enum LedgerTabMark {
    /// A bar glyph sits in about 25pt. The mark fills 18pt of that canvas so it
    /// reads a little quieter than a system symbol, centred with even padding
    /// all round; the same image serves the detached glass button and the
    /// ordinary trailing tab item before iOS 26.
    private static let canvas: CGFloat = 25
    private static let mark: CGFloat = 18

    static let image: Image = {
        let content = LedgerMarkShape()
            .fill(Color.black, style: FillStyle(eoFill: true))
            .frame(width: mark, height: mark)
            .frame(width: canvas, height: canvas)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        guard let rendered = renderer.uiImage else {
            // Never expected; an ordinary symbol is a better bar than no glyph.
            return Image(systemName: LedgerDestination.agent.systemImage)
        }
        return Image(uiImage: rendered.withRenderingMode(.alwaysTemplate))
    }()
}
