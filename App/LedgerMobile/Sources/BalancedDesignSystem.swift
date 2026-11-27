import SwiftUI

/// Tokens for the Balanced design language (docs/design/ios-balanced).
/// Chroma is reserved for direction: `income` and `expense`; everything else is ink.
enum BalancedPalette {
    static let page = Color(uiColor: .ledgerThemed(.page))
    static let sunken = Color(uiColor: .ledgerThemed(.sunken))
    static let ink = Color(uiColor: .ledgerThemed(.ink))
    static let secondary = Color(uiColor: .ledgerThemed(.secondary))
    static let meta = Color(uiColor: .ledgerThemed(.meta))
    static let rule = Color(uiColor: .ledgerThemed(.rule))
    /// Field underlines, day separators, the sheet grabber. A decorative divider,
    /// below the 3:1 contrast a control boundary needs — see `edge`.
    static let ruleStrong = Color(uiColor: .ledgerThemed(.ruleStrong))
    /// The only tone used as a *control* boundary (buttons, segments, toggles,
    /// chevrons, the checkbox, the range field). Clears 3:1 against both `page`
    /// and `sunken` in both themes; `rule`/`ruleStrong` never carry this job.
    static let edge = Color(uiColor: .ledgerThemed(.edge))
    static let income = Color(uiColor: .ledgerThemed(.income))
    static let expense = Color(uiColor: .ledgerThemed(.expense))
    /// A raised card on the page (account groups): white on paper by day.
    static let card = Color(uiColor: .ledgerThemed(.card))
    /// An icon well inside a `card`.
    static let well = Color(uiColor: .ledgerThemed(.well))
    /// A selected row on the `sunken` ground.
    static let selected = Color(uiColor: .ledgerThemed(.selected))

    // Chart marks follow the 配色方案 (`LedgerChartTokens`). Paper keeps the
    // ink / income / expense marks; Pure and Slate bring brighter hues. Use
    // these for data marks and their legend keys only, never for text.

    /// A single-series mark: a balance line, a bar, the 留存 slab.
    static let chartAccent = Color(uiColor: .ledgerThemed(.chartAccent))
    static let chartIncome = Color(uiColor: .ledgerThemed(.chartIncome))
    static let chartExpense = Color(uiColor: .ledgerThemed(.chartExpense))
    private static let series = (0..<6).map { Color(uiColor: .ledgerThemed(.chartSeries($0))) }
    /// The `index`th series of a multi-series chart, wrapping after six.
    static func chartSeries(_ index: Int) -> Color {
        series[((index % series.count) + series.count) % series.count]
    }
}

extension UIColor {
    /// A colour from the active 配色方案 (`LedgerColorTheme.active`), resolved
    /// for the light or dark appearance each time it is drawn. Switching the
    /// scheme takes effect on the next resolve; `LedgerColorThemeStore`
    /// forces that across the app.
    static func ledgerThemed(_ token: LedgerThemeToken) -> UIColor {
        UIColor { traits in
            let tokens = LedgerColorTheme.active.tokens(dark: traits.userInterfaceStyle == .dark)
            return UIColor(hex: UInt(tokens.value(token)))
        }
    }
}

/// The type weights. Since the 素白 theme the app sets everything in the
/// system face (SF Pro, with PingFang for Chinese) at these weights; the IBM
/// Plex names stay for the few places that still ask for a face by name.
enum BalancedWeight {
    case regular
    case text
    case medium
    case semibold

    var sansPostscriptName: String {
        switch self {
        case .regular: "IBMPlexSans"
        case .text: "IBMPlexSans-Text"
        case .medium: "IBMPlexSans-Medm"
        case .semibold: "IBMPlexSans-SmBld"
        }
    }

    var systemWeight: Font.Weight {
        switch self {
        case .regular, .text: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }

    /// The system face at a design size, scaled for Dynamic Type the way
    /// `Font.custom(_:size:relativeTo:)` scales a named face.
    func font(size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .system(size: BalancedTypeScale.scaled(size, relativeTo: style), weight: systemWeight)
    }
}

enum BalancedTypeScale {
    static func scaled(_ size: CGFloat, relativeTo style: Font.TextStyle) -> CGFloat {
        UIFontMetrics(forTextStyle: style.uiTextStyle).scaledValue(for: size)
    }
}

extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

enum BalancedMonoWeight {
    case regular
    case medium

    var postscriptName: String {
        switch self {
        case .regular: "IBMPlexMono"
        case .medium: "IBMPlexMono-Medm"
        }
    }
}

/// Source Serif 4 — the reading voice, after Claude's replies: a serif for
/// Latin letters and digits, with Songti SC for CJK. Used only for the ledger
/// agent's prose; lists, amounts and controls stay in Plex Sans.
enum BalancedSerifWeight {
    case regular
    case semibold

    var postscriptName: String {
        switch self {
        case .regular: "SourceSerif4-Regular"
        case .semibold: "SourceSerif4-Semibold"
        }
    }

    /// Songti SC ships with iOS, so Chinese reads as a serif without bundling
    /// a multi-megabyte CJK face. It only has regular and bold.
    var cjkPostscriptName: String {
        switch self {
        case .regular: "STSongti-SC-Regular"
        case .semibold: "STSongti-SC-Bold"
        }
    }
}

/// Reading text: 16pt, about 1.75 line height. Source Serif 4's natural line
/// is ~1.37em, so 6pt of extra spacing lands near 28pt per line.
///
/// A `Font` can name only one face, and Source Serif 4 has no CJK. Reading
/// text therefore goes through `serifified(_:)`, which sets Songti SC on CJK
/// runs and leaves Latin and digits to Source Serif.
enum BalancedReading {
    static let size: CGFloat = 16
    static let lineSpacing: CGFloat = 6

    /// Since the 素白 theme replies read in the system sans like the rest of
    /// the app; the serif faces are no longer used.
    static func font(_ weight: BalancedSerifWeight = .regular, size: CGFloat = size, relativeTo: Font.TextStyle = .body) -> Font {
        .system(size: BalancedTypeScale.scaled(size, relativeTo: relativeTo), weight: weight == .semibold ? .semibold : .regular)
    }

    static func cjkFont(_ weight: BalancedSerifWeight = .regular, size: CGFloat = size, relativeTo: Font.TextStyle = .body) -> Font {
        font(weight, size: size, relativeTo: relativeTo)
    }

    /// Reading text with the Chinese face on its CJK runs. Keep `.font(font(…))`
    /// on the view as the base: Latin, digits and anything after their own
    /// formatting inherit it. `weight` is that base weight, so a semibold
    /// heading keeps semibold Chinese.
    static func serifified(_ text: String, weight: BalancedSerifWeight = .regular, size: CGFloat = size, relativeTo: Font.TextStyle = .body) -> AttributedString {
        serifified(AttributedString(text), weight: weight, size: size, relativeTo: relativeTo)
    }

    /// The attributed form, for Markdown run through `inline(_:)`: inline code
    /// keeps its own face, `**strong**` becomes the semibold Source Serif or
    /// Songti face, and links keep the attributes they came with.
    static func serifified(_ input: AttributedString, weight: BalancedSerifWeight = .regular, size: CGFloat = size, relativeTo: Font.TextStyle = .body) -> AttributedString {
        var output = AttributedString()
        for run in input.runs {
            let attributes = run.attributes
            let intent = run.inlinePresentationIntent ?? []
            let text = String(input[run.range].characters)
            if intent.contains(.code) {
                var piece = AttributedString(text)
                piece.setAttributes(attributes)
                output.append(piece)
                continue
            }
            var chunk = ""
            var chunkIsCJK: Bool?
            func flush() {
                guard !chunk.isEmpty, let isCJK = chunkIsCJK else { return }
                var piece = AttributedString(chunk)
                piece.setAttributes(attributes)
                if intent.contains(.stronglyEmphasized) {
                    // The face carries the weight; drop the intent so SwiftUI
                    // doesn't synthesise a heavier Bold on top of it.
                    var remaining = intent.subtracting(.stronglyEmphasized)
                    piece.inlinePresentationIntent = remaining.isEmpty ? nil : remaining
                    piece.font = isCJK
                        ? cjkFont(.semibold, size: size, relativeTo: relativeTo)
                        : font(.semibold, size: size, relativeTo: relativeTo)
                } else if isCJK {
                    piece.font = cjkFont(weight, size: size, relativeTo: relativeTo)
                }
                output.append(piece)
                chunk = ""
            }
            for character in text {
                let isCJK = character.isCJKReading
                if chunkIsCJK != isCJK {
                    flush()
                    chunkIsCJK = isCJK
                }
                chunk.append(character)
            }
            flush()
        }
        return output
    }
}

private extension Character {
    /// Han, kana, CJK punctuation and fullwidth forms: what Songti draws.
    /// ASCII (including `build/`, `2.3` and `.cache`) stays with Source Serif.
    var isCJKReading: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x2FFF, 0x3000...0x30FF, 0x31C0...0x31EF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
                true
            default:
                false
            }
        }
    }
}

/// IBM Plex Sans at a design size that still follows Dynamic Type via
/// `Font.custom(_:size:relativeTo:)`.
struct BalancedFontModifier: ViewModifier {
    let size: CGFloat
    let weight: BalancedWeight
    let relativeTo: Font.TextStyle

    func body(content: Content) -> some View {
        content.font(weight.font(size: size, relativeTo: relativeTo))
    }
}

/// IBM Plex Mono — reserved for account paths and beancount source previews.
struct BalancedMonoFontModifier: ViewModifier {
    let size: CGFloat
    let weight: BalancedMonoWeight
    let relativeTo: Font.TextStyle

    func body(content: Content) -> some View {
        content.font(.system(size: BalancedTypeScale.scaled(size, relativeTo: relativeTo), weight: weight == .medium ? .medium : .regular, design: .monospaced))
    }
}

extension View {
    /// IBM Plex Sans. Everything — body, headings, labels, buttons. Never use
    /// this for amounts; use `BalancedAmount` instead.
    func balancedFont(size: CGFloat, weight: BalancedWeight = .regular, relativeTo: Font.TextStyle = .body) -> some View {
        modifier(BalancedFontModifier(size: size, weight: weight, relativeTo: relativeTo))
    }

    /// IBM Plex Mono. Two jobs only: account paths, and beancount source /
    /// repository URL/branch/token fields. Never set a number in mono.
    func balancedMono(size: CGFloat, weight: BalancedMonoWeight = .regular, relativeTo: Font.TextStyle = .footnote) -> some View {
        modifier(BalancedMonoFontModifier(size: size, weight: weight, relativeTo: relativeTo))
    }
}

/// An amount in Plex Sans with tabular figures — proportional, never mono.
///
/// `currencyScale`, when set, renders the currency symbol as its own `Text`
/// run at that scale in `--ink-3` ahead of the figure — the `.txn .amt .cur` /
/// `.row .row-val .cur` treatment (0.78em, ink-3) — instead of `MoneyText`'s
/// plain inline symbol. The figure itself always uses `abs(minorUnits)`: a
/// liability's naturally-negative ledger balance reads as a positive number
/// in the direction colour, never a minus sign duplicating what colour says.
struct BalancedAmount: View {
    @EnvironmentObject private var session: LedgerSession
    let minorUnits: Int
    let currency: String
    var size: CGFloat = 15
    var color: Color = BalancedPalette.ink
    var prefix = ""
    var showsCurrency = false
    var currencyScale: CGFloat? = nil

    var body: some View {
        Group {
            if let currencyScale, showsCurrency, session.amountsVisible {
                scaledCurrencyText(scale: currencyScale)
            } else {
                Text(session.amountsVisible ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency, showsCurrency: showsCurrency) : "••••••")
                    .font(BalancedWeight.text.font(size: size, relativeTo: .body))
            }
        }
        .monospacedDigit()
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.45)
        .ledgerRollingAmount(minorUnits)
        .accessibilityLabel(session.amountsVisible ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency) : String(localized: "金额已隐藏"))
    }

    private func scaledCurrencyText(scale: CGFloat) -> Text {
        let symbol = MoneyText.currencySymbol(for: currency)
        let number = MoneyText.format(minorUnits: abs(minorUnits), currency: currency, showsCurrency: false)
        var result = Text(verbatim: "")
        if !prefix.isEmpty {
            result = Text(prefix)
                .font(BalancedWeight.text.font(size: size, relativeTo: .body))
                .foregroundColor(color)
        }
        return result
            + Text(symbol)
                .font(BalancedWeight.text.font(size: size * scale, relativeTo: .body))
                .foregroundColor(BalancedPalette.meta)
            + Text(number)
                .font(BalancedWeight.text.font(size: size, relativeTo: .body))
                .foregroundColor(color)
    }
}

/// `.sechead` — the section head. No numbered prefix: the label is the heading.
struct BalancedSectionLabel: View {
    let text: String
    var aside: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(text)
                .balancedFont(size: 12.5, weight: .medium)
                .tracking(0.375)
                .foregroundStyle(BalancedPalette.meta)
            if let aside {
                Spacer()
                Text(aside)
                    .balancedFont(size: 12.5)
                    .foregroundStyle(BalancedPalette.meta)
            }
        }
        .frame(minHeight: 28, alignment: .bottom)
    }
}

/// `.mark` — the shared selection device used by tabs, segment filters and
/// reconciliation status filters. Since the 素白 theme a capsule chip: ink
/// with page-coloured text when selected, a grey well otherwise.
struct BalancedMark: View {
    let title: String
    let selected: Bool
    var size: CGFloat = 15

    var body: some View {
        Text(title)
            .balancedFont(size: size - 1, weight: .medium)
            .foregroundStyle(selected ? BalancedPalette.page : BalancedPalette.secondary)
            .lineLimit(1)
            .padding(.horizontal, 13)
            .frame(minHeight: 32)
            .background(selected ? BalancedPalette.ink : BalancedPalette.sunken, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
    }
}

/// `.tag` — a status word in a small tinted capsule.
struct BalancedTag: View {
    enum Kind { case neutral, pending, ok }
    let text: String
    var kind: Kind = .neutral

    private var color: Color {
        switch kind {
        case .neutral: BalancedPalette.meta
        case .pending: BalancedPalette.expense
        case .ok: BalancedPalette.income
        }
    }

    var body: some View {
        Text(text)
            .balancedFont(size: 12, weight: .medium)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule(style: .continuous))
    }
}

/// `.btn` — full width, 48pt min, 3px radius, 1px `--edge` border. Inside a
/// view marked `balancedRoundedControls()` (the 账本助手 and the onboarding
/// conversation, which sit among Liquid Glass) it is a capsule instead.
struct BalancedButtonStyle: ButtonStyle {
    enum Variant { case outline, primary, quiet, risk }
    var variant: Variant = .outline
    var isDisabled = false

    func makeBody(configuration: Configuration) -> some View {
        BalancedButtonBody(label: configuration.label, isPressed: configuration.isPressed,
                           variant: variant, isDisabled: isDisabled)
    }
}

private struct BalancedButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let variant: BalancedButtonStyle.Variant
    let isDisabled: Bool
    @Environment(\.balancedRoundedControls) private var rounded

    var body: some View {
        // Capsules everywhere since the 素白 theme.
        let shape = Capsule(style: .continuous)
        label
            .balancedFont(size: 15, weight: .medium)
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 18)
            .background(backgroundColor)
            .overlay {
                if variant == .risk {
                    shape.stroke(BalancedPalette.ruleStrong, lineWidth: 1)
                }
            }
            .clipShape(shape)
            .contentShape(shape)
            .opacity(isDisabled ? 0.38 : (isPressed ? 0.75 : 1))
    }

    private var labelColor: Color {
        switch variant {
        case .outline: BalancedPalette.ink
        case .primary: BalancedPalette.page
        case .quiet: BalancedPalette.secondary
        case .risk: BalancedPalette.expense
        }
    }

    private var backgroundColor: Color {
        switch variant {
        case .primary: BalancedPalette.ink
        case .outline: BalancedPalette.sunken
        case .quiet, .risk: .clear
        }
    }
}

private struct BalancedRoundedControlsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Buttons and wells take the round Liquid Glass shapes (capsules, 20pt+
    /// corners) instead of the 3pt Balanced corners.
    var balancedRoundedControls: Bool {
        get { self[BalancedRoundedControlsKey.self] }
        set { self[BalancedRoundedControlsKey.self] = newValue }
    }
}

extension View {
    /// Round shapes for every Balanced control below: the conversation pages
    /// sit among glass, whose capsules a 3pt corner fights.
    func balancedRoundedControls(_ on: Bool = true) -> some View {
        environment(\.balancedRoundedControls, on)
    }
}

extension ButtonStyle where Self == BalancedButtonStyle {
    static func balanced(_ variant: BalancedButtonStyle.Variant = .outline, disabled: Bool = false) -> BalancedButtonStyle {
        BalancedButtonStyle(variant: variant, isDisabled: disabled)
    }
}

/// `.settle` — the double rule. Two 1px ink hairlines with one pixel of air
/// between them, drawn edge to edge. Follows a total that has been verified.
struct BalancedSettle: ViewModifier {
    var quiet = false

    func body(content: Content) -> some View {
        content
            .padding(.bottom, 5)
            .overlay(alignment: .bottom) {
                VStack(spacing: 1) {
                    Rectangle().fill(quiet ? BalancedPalette.ruleStrong : BalancedPalette.ink).frame(height: 1)
                    Rectangle().fill(quiet ? BalancedPalette.ruleStrong : BalancedPalette.ink).frame(height: 1)
                }
            }
    }
}

extension View {
    /// Marks a total as closed and verified — the double-rule claim. Use at
    /// most once or twice per screen; it is the system's strongest statement.
    func balancedSettle(quiet: Bool = false) -> some View {
        modifier(BalancedSettle(quiet: quiet))
    }
}

/// `.band` — the one grouping device: a sunken well, square corners, never a
/// floating card. Used once or twice per screen.
struct BalancedBand: ViewModifier {
    var lead = false
    /// Among glass the band is a card with 22pt corners; elsewhere it runs
    /// square to the column.
    @Environment(\.balancedRoundedControls) private var rounded

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.top, lead ? 18 : 14)
            .padding(.bottom, lead ? 16 : 14)
            // A rounded grey well everywhere since the 素白 theme.
            .background(BalancedPalette.sunken, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

extension View {
    func balancedBand(lead: Bool = false) -> some View {
        modifier(BalancedBand(lead: lead))
    }
}

/// `.toggle` — an iOS-shaped 51×31 capsule switch: ink track with a page
/// thumb when on, a grey well when off. Native `Toggle` binding and
/// accessibility are unchanged; only the rendering differs.
struct BalancedToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { configuration.isOn.toggle() }
            } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule(style: .continuous)
                        .fill(configuration.isOn ? BalancedPalette.ink : BalancedPalette.well)
                    Circle()
                        .fill(configuration.isOn ? BalancedPalette.page : Color.white)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .frame(width: 27, height: 27)
                        .padding(2)
                }
                .frame(width: 51, height: 31)
            }
            .buttonStyle(.plain)
        }
    }
}

/// `.key--total .v` — 21/500 value with the currency symbol set to 0.62em in
/// `--ink-3`, so the figure reads as a number first and a currency second.
enum BalancedKeyTotalText {
    /// `currencyScale` is 0.78em on a plain `.key` and 0.62em on `.key--total`
    /// per styles.css. The sign (`prefix`) stays full size in the value colour
    /// and sits before the (shrunk) currency symbol — only the symbol shrinks.
    static func value(minorUnits: Int, currency: String, prefix: String = "", color: Color, amountsVisible: Bool, size: CGFloat = 21, currencyScale: CGFloat = 0.62) -> Text {
        guard amountsVisible else {
            return Text("••••••")
                .font(BalancedWeight.medium.font(size: size, relativeTo: .title2))
                .foregroundColor(color)
        }
        let symbol = MoneyText.currencySymbol(for: currency)
        let number = MoneyText.format(minorUnits: abs(minorUnits), currency: currency, showsCurrency: false)
        var result = Text(verbatim: "")
        if !prefix.isEmpty {
            result = Text(prefix)
                .font(BalancedWeight.medium.font(size: size, relativeTo: .title2))
                .foregroundColor(color)
        }
        return result
        + Text(symbol)
            .font(BalancedWeight.text.font(size: size * currencyScale, relativeTo: .title2))
            .foregroundColor(BalancedPalette.meta)
        + Text(number)
            .font(BalancedWeight.medium.font(size: size, relativeTo: .title2))
            .foregroundColor(color)
    }
}

/// `.key` — a label/value pair on a shared baseline; `.key--total` steps the
/// value up to 21/500 with a scaled currency symbol. Pass `settle`/`settleQuiet`
/// to close the column with the double rule once this is the verified total.
struct BalancedKeyRow: View {
    @EnvironmentObject private var session: LedgerSession
    let label: String
    let minorUnits: Int
    let currency: String
    var prefix = ""
    var color: Color = BalancedPalette.ink
    var isTotal = false
    var settle = false
    var settleQuiet = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .balancedFont(size: isTotal ? 15 : 14, weight: isTotal ? .medium : .regular)
                .foregroundStyle(isTotal ? BalancedPalette.ink : BalancedPalette.secondary)
            Spacer()
            BalancedKeyTotalText.value(minorUnits: minorUnits, currency: currency, prefix: prefix, color: color, amountsVisible: session.amountsVisible, size: isTotal ? 21 : 15, currencyScale: isTotal ? 0.62 : 0.78)
        }
        .padding(.vertical, isTotal ? 0 : 3)
        .padding(.top, isTotal ? 10 : 0)
        .modifier(settle ? AnyViewModifier(BalancedSettle(quiet: settleQuiet)) : AnyViewModifier(EmptyModifier()))
    }
}

/// `.empty` — centred, generous vertical padding, a 1px-stroke glyph in
/// `--ink-3`, an h3 at 16px, one sentence at 13.5px, and at most one button.
/// Shared by any screen with nothing to show — the sentence says what to do,
/// not how the system feels about it.
struct BalancedEmptyState: View {
    let glyph: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: glyph).font(.system(size: 30, weight: .ultraLight)).foregroundStyle(BalancedPalette.meta)
            Text(title).balancedFont(size: 16, weight: .medium).foregroundStyle(BalancedPalette.ink)
            Text(detail).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.meta).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

/// Type-erases a `ViewModifier` so a conditional branch can pick between two
/// concrete modifier types without `AnyView`'s loss of layout identity.
struct AnyViewModifier: ViewModifier {
    private let apply: (Content) -> AnyView
    init<M: ViewModifier>(_ modifier: M) {
        apply = { AnyView($0.modifier(modifier)) }
    }
    func body(content: Content) -> some View { apply(content) }
}
