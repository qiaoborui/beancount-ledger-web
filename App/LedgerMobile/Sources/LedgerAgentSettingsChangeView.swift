#if os(iOS)
import SwiftUI

/// The record under an answer that changed the App's own settings — the home
/// page, the tabs, the valuation currency, the reminders, the reports — with
/// the way back. It reads like the written-change row beside it, because both
/// are things the assistant did outside the conversation.
struct LedgerAgentSettingsChangeRow: View {
    let change: LedgerAgentAppSettingsChange
    var undoing = false
    var canUndo = false
    var undoFailure: String? = nil
    var onUndo: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if change.undoneAt != nil {
                    Label(String(localized: "已撤销设置改动 · \(change.titles)"), systemImage: "arrow.uturn.backward")
                        .balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                } else {
                    Label(String(localized: "已更改设置：\(change.titles)"), systemImage: "slider.horizontal.3")
                        .balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    Spacer(minLength: 8)
                    Button(action: onUndo) {
                        if undoing { ProgressView().controlSize(.small) } else { Text("撤销") }
                    }
                    .buttonStyle(.balanced(.quiet))
                    .disabled(!canUndo)
                    .accessibilityIdentifier("ledger-agent-undo-settings")
                }
            }
            if let undoFailure {
                Text(undoFailure).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.expense)
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("ledger-agent-settings-changed")
    }
}
#endif
