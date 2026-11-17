#if os(iOS)
import SwiftUI

/// 定时任务, from the assistant's drawer: every run the always-on host
/// pushed to the repository's automation-runs branch, newest first. A tap
/// opens the run as a conversation to continue, with its draft on the
/// change card the first time.
struct LedgerAutomationView: View {
    /// Opens the run's conversation on the chat page; true reloads its draft.
    var onOpen: (LedgerAutomationRun, Bool) -> Void

    @ObservedObject private var center = LedgerAutomationCenter.shared

    var body: some View {
        List {
            if let error = center.error {
                Section {
                    Label {
                        Text(verbatim: error).balancedFont(size: 13).foregroundStyle(BalancedPalette.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(BalancedPalette.secondary)
                    }
                }
            }
            if center.availability == .none {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有定时任务的运行记录").balancedFont(size: 15, weight: .medium)
                            .foregroundStyle(BalancedPalette.ink)
                        Text("在账本仓库的 automations/ 里写好任务，并在家里常开的机器上装好 ledger-automation 后，每次运行会推到仓库的 automation-runs 分支，结果就出现在这里。账本需要用 Git 同步。")
                            .balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    }
                    .padding(.vertical, 6)
                }
            } else if center.availability == .unknown, center.refreshing {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在读取运行记录…").balancedFont(size: 14).foregroundStyle(BalancedPalette.meta)
                    }
                }
            }
            ForEach(center.runs) { run in row(run) }
        }
        .navigationTitle("定时任务")
        .terminalNativeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .refreshable { await center.refresh() }
        .task {
            await center.refresh()
            center.markSeen()
        }
        .onDisappear { center.markSeen() }
    }

    private func row(_ run: LedgerAutomationRun) -> some View {
        Button {
            onOpen(run, false)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: symbol(run.status)).font(.system(size: 16, weight: .regular))
                    .foregroundStyle(run.status == .ok ? BalancedPalette.ink : BalancedPalette.secondary)
                    .frame(width: 22)
                    .accessibilityLabel(run.statusText)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: run.taskName).balancedFont(size: 15, weight: .medium)
                            .foregroundStyle(BalancedPalette.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(run.slot.formatted(date: .abbreviated, time: .shortened))
                            .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    }
                    if !run.summary.isEmpty {
                        Text(verbatim: run.summary).balancedFont(size: 13).foregroundStyle(BalancedPalette.secondary)
                            .lineLimit(2)
                    }
                    Text(verbatim: caption(run)).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                }
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(run.status != .ok)
        .contextMenu {
            if run.status == .ok {
                Button { onOpen(run, false) } label: { Label("打开对话", systemImage: "bubble.left") }
                if run.hasDraft {
                    Button { onOpen(run, true) } label: { Label("重新载入草稿", systemImage: "arrow.down.doc") }
                }
            }
        }
        .accessibilityIdentifier("ledger-automation-run")
    }

    private func symbol(_ status: LedgerAutomationRun.Status) -> String {
        switch status {
        case .ok: "checkmark.circle"
        case .degraded: "clock.arrow.circlepath"
        case .failed: "exclamationmark.circle"
        }
    }

    private func caption(_ run: LedgerAutomationRun) -> String {
        var parts: [String] = []
        if run.status != .ok { parts.append(run.statusText) }
        if run.findings > 0 {
            parts.append(run.newFindings > 0 ? String(localized: "\(run.findings) 处问题，新 \(run.newFindings) 处")
                                             : String(localized: "\(run.findings) 处问题"))
        }
        if run.hasDraft {
            let files = run.draftFiles?.count ?? 0
            parts.append(files > 0 ? String(localized: "草稿改了 \(files) 个文件") : String(localized: "有草稿"))
        }
        if parts.isEmpty { parts.append(String(localized: "没有发现问题")) }
        return parts.joined(separator: " · ")
    }
}
#endif
