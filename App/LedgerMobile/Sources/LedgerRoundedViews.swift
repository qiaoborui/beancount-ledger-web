import SwiftUI

/// The round shapes the conversation pages use among Liquid Glass: the
/// question bubble, the cards in a conversation, and the wells inside them.
/// The rest of the app keeps the 3pt Balanced corners.
enum LedgerRound {
    /// A question bubble.
    static let bubble: CGFloat = 20
    /// A card in the conversation: a choice, a change, a form.
    static let card: CGFloat = 22
    /// A well inside a card, or a notice on its own.
    static let inset: CGFloat = 16
}

extension View {
    /// A card in the conversation: the sunken fill with 22pt continuous
    /// corners. It is paper, not glass, so a long card stays readable.
    func ledgerCard(padding: CGFloat = 0) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BalancedPalette.sunken, in: RoundedRectangle(cornerRadius: LedgerRound.card, style: .continuous))
    }

    /// A well inside a card: the page fill with 16pt corners and a hairline,
    /// for rows (files, fields, steps) that would otherwise run on rules.
    func ledgerInsetWell() -> some View {
        let shape = RoundedRectangle(cornerRadius: LedgerRound.inset, style: .continuous)
        return self
            .background(BalancedPalette.page, in: shape)
            .overlay(shape.stroke(BalancedPalette.rule, lineWidth: 0.5))
    }
}

/// The options of an `ask_user` card: each one a capsule on the card. One
/// tap answers a single choice; several are ticked, then sent together.
struct LedgerAskCard: View {
    let ask: LedgerAgentAsk
    @Binding var picked: Set<String>
    var identifier = "ledger-ask-choice"
    var disabled = false
    let onAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ask.options, id: \.self) { option in
                Button {
                    if ask.allowsMultiple {
                        if picked.contains(option) { picked.remove(option) } else { picked.insert(option) }
                    } else {
                        onAnswer(option)
                    }
                } label: {
                    HStack(spacing: 10) {
                        if ask.allowsMultiple { LedgerRoundTick(on: picked.contains(option)) }
                        Text(option).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                            .multilineTextAlignment(.leading)
                            .padding(.vertical, 10)
                        Spacer(minLength: 12)
                        if !ask.allowsMultiple {
                            Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(BalancedPalette.edge)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(BalancedPalette.page, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(picked.contains(option) ? BalancedPalette.ink : BalancedPalette.rule,
                                    lineWidth: picked.contains(option) ? 1.2 : 0.5)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(ask.allowsMultiple && picked.contains(option) ? .isSelected : [])
                .accessibilityIdentifier(identifier)
            }
            HStack(spacing: 10) {
                Text(ask.allowsMultiple ? String(localized: "可多选；也可以直接在下面输入") : String(localized: "也可以直接在下面输入"))
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                Spacer(minLength: 8)
                if ask.allowsMultiple {
                    Button("发送") { onAnswer(ask.answer(picked)) }
                        .buttonStyle(.balanced(.primary))
                        .fixedSize()
                        .disabled(picked.isEmpty)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
        .disabled(disabled)
        .ledgerCard(padding: 12)
    }
}

/// A round check for a multiple choice.
struct LedgerRoundTick: View {
    let on: Bool

    var body: some View {
        ZStack {
            Circle().fill(on ? BalancedPalette.ink : Color.clear)
            Circle().stroke(on ? BalancedPalette.ink : BalancedPalette.edge, lineWidth: 1.5)
            if on {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(BalancedPalette.page)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// A conversation's input bar on the pages that have no attachments or
/// model chip (first-run setup): one glass capsule with the field and the
/// solid send circle, which turns into stop while an answer runs.
struct LedgerChatInputBar: View {
    @Binding var text: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding
    var isRunning = false
    var canSend: Bool
    let onSend: () -> Void
    var onStop: () -> Void = {}

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField(text: $text, prompt: Text(placeholder).foregroundStyle(BalancedPalette.meta), axis: .vertical) {
                Text(placeholder)
            }
            .balancedFont(size: 15)
            .lineLimit(1...5)
            .focused(focused)
            .submitLabel(.send)
            .onSubmit { if canSend { onSend() } }
            .padding(.vertical, 11)
            Button {
                if isRunning { onStop() } else if canSend { onSend() }
            } label: {
                Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(BalancedPalette.page)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(BalancedPalette.ink))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isRunning && !canSend)
            .opacity(!isRunning && !canSend ? 0.32 : 1)
            .accessibilityLabel(isRunning ? "停止" : "发送")
            .accessibilityIdentifier("ai-onboarding-send")
        }
        .padding(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 5))
        .modifier(LedgerChatInputGlass())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .padding(.top, 4)
    }
}

/// Glass for the input capsule on iOS 26; the sunken well with a hairline
/// before it. The corner is half the one-line height, so a single line is a
/// capsule and a longer draft keeps the same curve.
private struct LedgerChatInputGlass: ViewModifier {
    private static let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Self.shape)
        } else {
            content
                .background(Self.shape.fill(BalancedPalette.sunken))
                .overlay(Self.shape.stroke(BalancedPalette.rule, lineWidth: 1))
        }
    }
}
