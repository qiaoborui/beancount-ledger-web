import SwiftUI
import UIKit

/// Settings → 诊断: the crash reports this app wrote, plus the report the native
/// ledger engine leaves behind, without any third-party SDK.
///
/// Everything here comes from `Application Support/LedgerDiagnostics/` or the
/// ledger's own `runtime/` directory. Reports hold fixed app-authored context
/// only: no API key, amount or transaction is ever written.
struct LedgerCrashLogView: View {
    @EnvironmentObject private var session: LedgerSession
    @State private var entries: [LedgerCrashEntry] = []
    @State private var agentLog: LedgerCrashEntry?
    @State private var confirmingClear = false

    var body: some View {
        List {
            Section {
                if entries.isEmpty {
                    Text("没有崩溃记录")
                        .balancedFont(size: 14)
                        .foregroundStyle(BalancedPalette.meta)
                        .frame(minHeight: 44, alignment: .leading)
                        .listRowBackground(BalancedPalette.page)
                        .accessibilityIdentifier("diagnostics-empty")
                } else {
                    ForEach(entries) { entry in
                        NavigationLink {
                            LedgerCrashLogDetailView(entry: entry, onDelete: { delete(entry) })
                        } label: {
                            row(entry)
                        }
                        .listRowBackground(BalancedPalette.page)
                        .accessibilityIdentifier("diagnostics-crash-entry")
                    }
                    .onDelete { offsets in
                        for index in offsets where entries.indices.contains(index) {
                            delete(entries[index])
                        }
                    }
                }
            } header: {
                TerminalSectionLabel(text: String(localized: "崩溃日志"))
                    .listRowBackground(BalancedPalette.page)
            } footer: {
                Text("最近 20 条，超出后自动删掉最旧的。记录只有时间、App 版本、页面和操作路径，不含 API Key、金额或交易内容。点一条可以复制或分享给开发者。")
                    .balancedFont(size: 12.5)
                    .foregroundStyle(BalancedPalette.meta)
                    .listRowBackground(BalancedPalette.page)
            }

            if let agentLog {
                Section {
                    NavigationLink {
                        LedgerCrashLogDetailView(entry: agentLog, onDelete: nil)
                    } label: {
                        row(agentLog)
                    }
                    .listRowBackground(BalancedPalette.page)
                    .accessibilityIdentifier("diagnostics-agent-entry")
                } header: {
                    TerminalSectionLabel(text: String(localized: "账本引擎"))
                        .listRowBackground(BalancedPalette.page)
                } footer: {
                    Text("设备端引擎留下的诊断信息。账本助手页面仍会在下次打开时提示一次。")
                        .balancedFont(size: 12.5)
                        .foregroundStyle(BalancedPalette.meta)
                        .listRowBackground(BalancedPalette.page)
                }
            }

            if !entries.isEmpty {
                Section {
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Text("清空全部崩溃日志")
                            .balancedFont(size: 15, weight: .text)
                            .foregroundStyle(BalancedPalette.expense)
                            .frame(minHeight: 44, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("diagnostics-clear")
                }
            }
        }
        .terminalNativeChrome()
        .navigationTitle(String(localized: "诊断"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .confirmationDialog("清空全部崩溃日志？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                LedgerCrashLog.shared.clear()
                reload()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除本机上的崩溃日志，不影响账本。")
        }
    }

    private func row(_ entry: LedgerCrashEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .balancedFont(size: 15, weight: .text)
                    .foregroundStyle(BalancedPalette.ink)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .balancedFont(size: 12)
                    .foregroundStyle(BalancedPalette.meta)
            }
            Spacer(minLength: 8)
            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                .balancedFont(size: 12)
                .foregroundStyle(BalancedPalette.meta)
        }
        .frame(minHeight: 44)
    }

    private func delete(_ entry: LedgerCrashEntry) {
        LedgerCrashLog.shared.delete(entry)
        reload()
    }

    private func reload() {
        entries = LedgerCrashLog.shared.entries()
        agentLog = nil
        guard let repository = session.localRepository else { return }
        let runtime = repository.workspace.rootDirectory.appendingPathComponent("runtime")
        for name in [LedgerAgentCrashReport.fileName, "agent-crash.previous.log"] {
            let url = runtime.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            let text = LedgerAgentCrashReport
                .crashingGoroutine(String(decoding: data.prefix(LedgerAgentCrashReport.maximumBytes), as: UTF8.self))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            agentLog = LedgerCrashEntry(url: url, title: String(localized: "账本引擎诊断"),
                                        date: date, size: data.count, text: text)
            break
        }
    }
}

private struct LedgerCrashLogDetailView: View {
    let entry: LedgerCrashEntry
    /// nil for a report another part of the app owns and shows itself.
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var confirmingDelete = false

    var body: some View {
        List {
            Section {
                ScrollView {
                    Text(entry.text)
                        .balancedMono(size: 11)
                        .foregroundStyle(BalancedPalette.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 460)
                .listRowBackground(BalancedPalette.page)
            } header: {
                TerminalSectionLabel(text: entry.date.formatted(date: .abbreviated, time: .shortened))
                    .listRowBackground(BalancedPalette.page)
            }

            Section {
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = entry.text
                        copied = true
                    } label: {
                        Label {
                            Text(copied ? String(localized: "已复制") : String(localized: "复制"))
                        } icon: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                    .accessibilityIdentifier("diagnostics-copy")
                    ShareLink(item: entry.text) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("diagnostics-share")
                    if onDelete != nil {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("删除", systemImage: "trash")
                                .foregroundStyle(BalancedPalette.expense)
                        }
                        .accessibilityIdentifier("diagnostics-delete")
                    }
                }
                .buttonStyle(.balanced(.outline))
                .listRowBackground(BalancedPalette.page)
            } footer: {
                Text("报告只含固定的诊断字段，不含 API Key、账本金额或交易内容。")
                    .balancedFont(size: 12.5)
                    .foregroundStyle(BalancedPalette.meta)
                    .listRowBackground(BalancedPalette.page)
            }
        }
        .terminalNativeChrome()
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除这条崩溃日志？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
    }
}
