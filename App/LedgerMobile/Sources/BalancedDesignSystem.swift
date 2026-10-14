import SwiftUI

/// Tokens for the Balanced design language (docs/design/ios-balanced).
/// Chroma is reserved for direction: `income` and `expense`; everything else is ink.
enum BalancedPalette {
    static let page = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x121110) : UIColor(hex: 0xFBFAF8) })
    static let sunken = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x1B1918) : UIColor(hex: 0xF1EFE9) })
    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xF6F3EE) : UIColor(hex: 0x14100C) })
    static let secondary = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xC4BCB0) : UIColor(hex: 0x453E36) })
    static let meta = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x9A9086) : UIColor(hex: 0x6F675A) })
    static let rule = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x2B2825) : UIColor(hex: 0xE2DED4) })
    /// Field underlines, day separators, the sheet grabber. A decorative divider,
    /// below the 3:1 contrast a control boundary needs — see `edge`.
    static let ruleStrong = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x423C36) : UIColor(hex: 0xC8C2B4) })
    /// The only tone used as a *control* boundary (buttons, segments, toggles,
    /// chevrons, the checkbox, the range field). Clears 3:1 against both `page`
    /// and `sunken` in both themes; `rule`/`ruleStrong` never carry this job.
    static let edge = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x78746E) : UIColor(hex: 0x88837A) })
    static let income = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x4FBFAB) : UIColor(hex: 0x0D5346) })
    static let expense = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xCF7A52) : UIColor(hex: 0x96401F) })
}

/// IBM Plex Sans weights bundled with the app. 450 ("Text") is the workhorse —
/// it reads as a normal weight on Plex and is used for row titles and amounts.
/// CJK text falls back to PingFang via the system cascade automatically.
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

/// IBM Plex Sans at a design size that still follows Dynamic Type via
/// `Font.custom(_:size:relativeTo:)`.
struct BalancedFontModifier: ViewModifier {
    let size: CGFloat
    let weight: BalancedWeight
    let relativeTo: Font.TextStyle

    func body(content: Content) -> some View {
        content.font(.custom(weight.sansPostscriptName, size: size, relativeTo: relativeTo))
    }
}

/// IBM Plex Mono — reserved for account paths and beancount source previews.
struct BalancedMonoFontModifier: ViewModifier {
    let size: CGFloat
    let weight: BalancedMonoWeight
    let relativeTo: Font.TextStyle

    func body(content: Content) -> some View {
        content.font(.custom(weight.postscriptName, size: size, relativeTo: relativeTo))
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
                    .font(.custom(BalancedWeight.text.sansPostscriptName, size: size, relativeTo: .body))
            }
        }
        .monospacedDigit()
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.45)
        .accessibilityLabel(session.amountsVisible ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency) : "金额已隐藏")
    }

    private func scaledCurrencyText(scale: CGFloat) -> Text {
        let symbol = MoneyText.currencySymbol(for: currency)
        let number = MoneyText.format(minorUnits: abs(minorUnits), currency: currency, showsCurrency: false)
        var result = Text(verbatim: "")
        if !prefix.isEmpty {
            result = Text(prefix)
                .font(.custom(BalancedWeight.text.sansPostscriptName, size: size, relativeTo: .body))
                .foregroundColor(color)
        }
        return result
            + Text(symbol)
                .font(.custom(BalancedWeight.text.sansPostscriptName, size: size * scale, relativeTo: .body))
                .foregroundColor(BalancedPalette.meta)
            + Text(number)
                .font(.custom(BalancedWeight.text.sansPostscriptName, size: size, relativeTo: .body))
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

/// `.mark` — the shared 2px underline selection device used by tabs, segment
/// filters and reconciliation status filters. No pills, no filled backgrounds.
struct BalancedMark: View {
    let title: String
    let selected: Bool
    var size: CGFloat = 15

    var body: some View {
        Text(title)
            .balancedFont(size: size, weight: .regular)
            .foregroundStyle(selected ? BalancedPalette.ink : BalancedPalette.meta)
            .padding(.bottom, 7)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selected ? BalancedPalette.ink : Color.clear)
                    .frame(height: 2)
            }
    }
}

/// `.tag` — a status word with an underline instead of a filled pill.
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
            .balancedFont(size: 12)
            .foregroundStyle(color)
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) { Rectangle().fill(color).frame(height: 1) }
    }
}

/// `.btn` — full width, 48pt min, 3px radius, 1px `--edge` border.
struct BalancedButtonStyle: ButtonStyle {
    enum Variant { case outline, primary, quiet, risk }
    var variant: Variant = .outline
    var isDisabled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .balancedFont(size: 15, weight: .medium)
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 18)
            .background(backgroundColor)
            .overlay {
                if variant == .outline || variant == .risk {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(BalancedPalette.edge, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .opacity(isDisabled ? 0.38 : (configuration.isPressed ? 0.75 : 1))
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
        variant == .primary ? BalancedPalette.ink : .clear
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

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.top, lead ? 18 : 14)
            .padding(.bottom, lead ? 16 : 14)
            .background(BalancedPalette.sunken)
    }
}

extension View {
    func balancedBand(lead: Bool = false) -> some View {
        modifier(BalancedBand(lead: lead))
    }
}

/// `.toggle` — a 44×28 square-cornered (2px) switch with a 1px `--edge`
/// border; filled `--ink` with a `--bg` thumb when on. Native `Toggle`
/// binding/accessibility behaviour is unchanged — only the rendering differs.
struct BalancedToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Button {
                configuration.isOn.toggle()
            } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(configuration.isOn ? BalancedPalette.ink : Color.clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .stroke(configuration.isOn ? BalancedPalette.ink : BalancedPalette.edge, lineWidth: 1)
                        }
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(configuration.isOn ? BalancedPalette.page : BalancedPalette.meta)
                        .frame(width: 20, height: 20)
                        .padding(3)
                }
                .frame(width: 44, height: 28)
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
                .font(.custom(BalancedWeight.medium.sansPostscriptName, size: size, relativeTo: .title2))
                .foregroundColor(color)
        }
        let symbol = MoneyText.currencySymbol(for: currency)
        let number = MoneyText.format(minorUnits: abs(minorUnits), currency: currency, showsCurrency: false)
        var result = Text(verbatim: "")
        if !prefix.isEmpty {
            result = Text(prefix)
                .font(.custom(BalancedWeight.medium.sansPostscriptName, size: size, relativeTo: .title2))
                .foregroundColor(color)
        }
        return result
        + Text(symbol)
            .font(.custom(BalancedWeight.text.sansPostscriptName, size: size * currencyScale, relativeTo: .title2))
            .foregroundColor(BalancedPalette.meta)
        + Text(number)
            .font(.custom(BalancedWeight.medium.sansPostscriptName, size: size, relativeTo: .title2))
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
