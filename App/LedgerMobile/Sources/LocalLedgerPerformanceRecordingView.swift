import SwiftUI

/// Opt-in control for local-ledger performance recording.
///
/// Everything measured here is aggregate timing and memory of the local ledger
/// pipeline; the report never contains ledger text, amounts, accounts or
/// payees. Reports are written to the app's own
/// `Application Support/PerfRecords/` directory, never into a ledger tree, and
/// leave the device through the system share sheet (the app does not expose its
/// Documents through `UIFileSharingEnabled`).
struct LocalLedgerPerformanceRecordingView: View {
    @ObservedObject private var recording = LocalLedgerPerformanceRecording.shared
    @State private var confirmingDelete = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { recording.isEnabled },
                                     set: { recording.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("记录本地账本性能").balancedFont(size: 15, weight: .text)
                        Text(recording.isEnabled ? "正在记录" : "未开启")
                            .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    }
                }
                .accessibilityIdentifier("perf-recording-toggle")
                .listRowBackground(BalancedPalette.page)
            } header: {
                TerminalSectionLabel(text: String(localized: "录制"))
                    .listRowBackground(BalancedPalette.page)
            } footer: {
                Text("开启后，每次本地账本的解析、校验与分页耗时，以及内存峰值会聚合成一份 JSON。报告只含聚合数字，不含账本内容。")
                    .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    .listRowBackground(BalancedPalette.page)
            }

            Section {
                Picker("合成负载档位", selection: Binding(
                    get: { recording.workloadTierLabel ?? "none" },
                    set: { recording.setWorkloadTier($0 == "none" ? nil : $0) }
                )) {
                    Text("不标注").tag("none")
                    ForEach(LocalLedgerPerformanceRecorder.WorkloadTier.allCases, id: \.rawValue) { tier in
                        Text(tier.label).tag(tier.label)
                    }
                }
                .accessibilityIdentifier("perf-recording-tier")
                .disabled(!recording.isEnabled)
                .listRowBackground(BalancedPalette.page)
            } header: {
                TerminalSectionLabel(text: String(localized: "测量协议"))
                    .listRowBackground(BalancedPalette.page)
            } footer: {
                Text("只有用方案里的合成账本（10k / 50k / 100k / 200k）测量时才选档位；选档位后报告会带上该档位，并把规范流条目数当作负载规模记录。")
                    .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    .listRowBackground(BalancedPalette.page)
            }

            Section {
                if recording.files.isEmpty {
                    Text("还没有报告。完成一次本地账本加载或写入后会出现。")
                        .balancedFont(size: 14).foregroundStyle(BalancedPalette.meta)
                        .listRowBackground(BalancedPalette.page)
                } else {
                    ForEach(recording.files, id: \.self) { file in
                        ShareLink(item: file) {
                            Label(file.lastPathComponent, systemImage: "square.and.arrow.up")
                                .balancedFont(size: 14)
                                .foregroundStyle(BalancedPalette.ink)
                        }
                        .accessibilityIdentifier("perf-recording-share")
                        .listRowBackground(BalancedPalette.page)
                    }
                    Button {
                        recording.writeNow()
                    } label: {
                        Text("立即写出一份当前报告").balancedFont(size: 14)
                    }
                    .accessibilityIdentifier("perf-recording-write-now")
                    .listRowBackground(BalancedPalette.page)
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Text("删除所有报告").balancedFont(size: 14)
                    }
                    .listRowBackground(BalancedPalette.page)
                }
                if let error = recording.lastError {
                    Text(error).balancedFont(size: 12).foregroundStyle(BalancedPalette.expense)
                        .listRowBackground(BalancedPalette.page)
                }
            } header: {
                TerminalSectionLabel(text: String(localized: "报告"))
                    .listRowBackground(BalancedPalette.page)
            } footer: {
                Text("点文件名用系统分享把 JSON 发到「文件」、AirDrop 或邮件。报告写在 App 自己的 Application Support/PerfRecords，不会进入账本目录。")
                    .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    .listRowBackground(BalancedPalette.page)
            }
        }
        .terminalNativeChrome()
        .navigationTitle("性能录制")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recording.refreshFiles() }
        .confirmationDialog("删除所有性能报告？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { recording.deleteAllReports() }
            Button("取消", role: .cancel) {}
        }
    }
}
