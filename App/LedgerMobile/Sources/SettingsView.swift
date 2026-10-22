import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var compactTabConfigurationPresented = false
    @State private var editingCurrentLedger = false
    @State private var confirmingDeleteCurrent = false
    @State private var showingLockIntervalPicker = false
    var isRoot = true

    var body: some View {
        List {
            if let error = session.errorMessage {
                Section { StatusBanner(message: error, onDismiss: session.dismissError) }
            }
            Section {
                SettingsRow(title: String(localized: "底部标签栏"), value: session.compactTabDestinations.map(\.compactTitle).joined(separator: String(localized: "、"))) {
                    compactTabConfigurationPresented = true
                }
                .accessibilityIdentifier("settings-compact-tabs")
            } header: { TerminalSectionLabel(text: String(localized: "导航")).listRowBackground(BalancedPalette.page)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)) }

            Section {
                if session.isLocal {
                    Toggle(isOn: Binding(
                        get: { session.localPrivacyProtectionEnabled },
                        set: { enabled in Task { await session.setLocalPrivacyProtectionEnabled(enabled) } }
                    )) {
                        SettingsRowLabel(title: String(localized: "\(session.biometricTitle) 保护"), detail: String(localized: "打开账本时验证身份"))
                    }
                    .disabled(session.isBiometricSettingBusy || session.isAuthenticationBusy)
                    .accessibilityIdentifier("settings-local-authentication")
                    .settingsRowRule()
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    Toggle(isOn: Binding(
                        get: { session.localPrivacyCoverEnabled },
                        set: { session.setLocalPrivacyCoverEnabled($0) }
                    )) {
                        SettingsRowLabel(title: String(localized: "隐私遮罩"), detail: String(localized: "切换应用时遮住内容"))
                    }
                    .disabled(session.isBiometricSettingBusy || session.isAuthenticationBusy)
                    .accessibilityIdentifier("settings-local-privacy-cover")
                    .settingsRowRule()
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    SettingsRowLabel(title: String(localized: "使用设备密码或生物识别解锁"), detail: nil)
                        .frame(minHeight: 44)
                        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if session.localPrivacyProtectionEnabled {
                    SettingsRow(title: String(localized: "自动锁定"), value: lockIntervalBinding.wrappedValue.title) {
                        showingLockIntervalPicker = true
                    }
                    Button {
                        Task { await session.lock() }
                    } label: {
                        Text("立即锁定").balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink)
                            .frame(minHeight: 44, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } header: {
                TerminalSectionLabel(text: String(localized: "隐私与安全")).listRowBackground(BalancedPalette.page)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            } footer: {
                Text(session.isLocal
                    ? "身份验证控制打开账本时的验证；隐私遮罩控制切换应用时是否遮住账本。两个开关互不影响，仅用于当前账本。"
                    : "打开账本需要验证身份，切换应用时隐藏账本。")
                    .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    .listRowBackground(BalancedPalette.page)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            if session.isLocal {
                if let ledgerID = session.currentLocalLedgerDescriptor?.id {
                    Section {
                        SettingsNavRow(title: String(localized: "智能分类"), value: ImportClassificationSettings.shared.isEnabled(for: ledgerID) ? String(localized: "已启用") : String(localized: "未配置")) {
                            ImportClassificationSettingsView(ledgerID: ledgerID)
                        }
                        .accessibilityIdentifier("settings-classification")
                        SettingsNavRow(title: String(localized: "语义解析"), value: BookkeepingSettings.shared.hasKey ? (BookkeepingSettings.shared.configuration.model.isEmpty ? String(localized: "已配置") : BookkeepingSettings.shared.configuration.model) : String(localized: "未配置"), valueMono: true) {
                            BookkeepingSettingsView()
                        }
                        .accessibilityIdentifier("settings-semantic-parser")
                    } header: { TerminalSectionLabel(text: String(localized: "AI 与智能记账")).listRowBackground(BalancedPalette.page)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)) }
                }
                Section {
                    SettingsRow(title: String(localized: "名称"), value: session.localLedgerName, showsChevron: false) {
                        editingCurrentLedger = true
                    }
                    .accessibilityIdentifier("settings-edit-current-ledger")
                    SettingsNavRow(title: String(localized: "浏览、编辑与导出文件")) { LocalLedgerFilesView() }
                        .accessibilityIdentifier("settings-local-files")
                    SettingsNavRow(title: String(localized: "存储与同步")) { LocalLedgerStorageView() }
                        .accessibilityIdentifier("local-storage-settings")
                } header: { TerminalSectionLabel(text: String(localized: "本地账本")).listRowBackground(BalancedPalette.page)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)) }
                Section {
                    Button("切换账本") { session.chooseLedger() }
                        .buttonStyle(.plain)
                        .balancedFont(size: 15, weight: .text)
                        .foregroundStyle(BalancedPalette.ink)
                        .frame(minHeight: 44, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    Button {
                        confirmingDeleteCurrent = true
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("删除当前账本").balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.expense)
                            Text("永久抹除所有本地数据").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                        }
                        .frame(minHeight: 44, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-delete-current-ledger")
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } footer: {
                    Text("小组件会在本地账本更新后显示新的摘要。切换账本会保留文件；删除账本将永久抹除所有本地数据。")
                        .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        .listRowBackground(BalancedPalette.page)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
            }
            Section {
                HStack {
                    Text("版本").balancedFont(size: 14).foregroundStyle(BalancedPalette.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("本地版 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                            .balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                        // Stamped at build time by scripts/stamp-ios-build-commit.sh.
                        if let commit = Bundle.main.object(forInfoDictionaryKey: "LedgerGitCommit") as? String {
                            Text(commit).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                                .textSelection(.enabled)
                                .accessibilityLabel("构建提交 \(commit)")
                        }
                    }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("settings-app-version")
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .confirmationDialog("自动锁定", isPresented: $showingLockIntervalPicker, titleVisibility: .visible) {
            ForEach(LedgerLockInterval.allCases) { interval in
                Button(interval.title) { session.setLockInterval(interval) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(BalancedPalette.page)
        .listStyle(.plain)
        .listSectionSeparator(.hidden, edges: .top)
        .ledgerNavigation(String(localized: "设置"), isRoot: isRoot)
        .sheet(isPresented: $compactTabConfigurationPresented) {
            CompactTabConfigurationView(initialDestinations: session.compactTabDestinations) { destinations in
                session.setCompactTabDestinations(destinations)
            }
            .ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: $editingCurrentLedger) {
            if let current = session.currentLocalLedgerDescriptor {
                EditLedgerSheet(ledger: current)
            }
        }
        .confirmationDialog("确定删除当前账本“\(session.localLedgerName)”？", isPresented: $confirmingDeleteCurrent, titleVisibility: .visible) {
            Button("永久删除账本", role: .destructive) {
                if let current = session.currentLocalLedgerDescriptor {
                    Task {
                        try? await session.deleteLocalLedger(current)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作将永久删除该账本在此设备上的所有文件、交易与配置，且不可恢复。")
        }
        .toggleStyle(BalancedToggleStyle())
    }

    private var biometricDetail: String {
        if session.biometricKind == .unavailable {
            return String(localized: "请先在系统设置中配置生物识别")
        }
        return session.hasBiometricUnlock
            ? String(localized: "使用生物识别快速解锁账本")
            : String(localized: "启用后可在这台设备上快速解锁")
    }

    private var widgetRefreshStatusTitle: String {
        if !session.hasBiometricUnlock { return String(localized: "等待\(session.biometricTitle)") }
        switch session.widgetRefreshStatus.phase {
        case .waitingForBiometrics:
            return String(localized: "等待启用")
        case .provisioning:
            return String(localized: "正在配置")
        case .ready:
            return String(localized: "已就绪")
        case .refreshing:
            return String(localized: "正在刷新")
        case .success:
            return String(localized: "运行正常")
        case .credentialUnavailable:
            return String(localized: "凭据缺失")
        case .authorizationRejected:
            return String(localized: "凭据已失效")
        case .serverOutdated:
            return String(localized: "服务端待更新")
        case .serverUnavailable:
            return String(localized: "服务端异常")
        case .invalidConfiguration:
            return String(localized: "配置异常")
        case .invalidResponse:
            return String(localized: "响应异常")
        case .networkUnavailable:
            return String(localized: "网络异常")
        case .storageUnavailable:
            return String(localized: "安全存储异常")
        }
    }

    private var widgetRefreshDetail: String {
        if !session.hasBiometricUnlock {
            return String(localized: "启用\(session.biometricTitle)后可更新小组件")
        }
        switch session.widgetRefreshStatus.phase {
        case .waitingForBiometrics:
            return String(localized: "启用设备生物识别后自动配置")
        case .provisioning:
            return String(localized: "正在启用后台刷新")
        case .ready:
            return String(localized: "已启用后台更新，点按立即刷新")
        case .refreshing:
            return String(localized: "正在从 Ledger Web 获取最新小组件快照")
        case .success:
            if let date = session.widgetRefreshStatus.lastSuccessAt {
                return String(localized: "上次成功：\(date.formatted(date: .abbreviated, time: .shortened))")
            }
            return String(localized: "最近一次后台刷新成功")
        case .credentialUnavailable:
            return String(localized: "后台刷新尚未启用，点按重试")
        case .authorizationRejected:
            return String(localized: "完成身份验证后点按轮换凭据")
        case .serverOutdated:
            return String(localized: "Ledger Web 需要部署小组件快照接口")
        case .serverUnavailable:
            if let status = session.widgetRefreshStatus.httpStatus {
                return String(localized: "服务端返回 HTTP \(status)；点按重试")
            }
            return String(localized: "服务端暂时无法处理小组件刷新")
        case .invalidConfiguration:
            return String(localized: "服务器地址需要使用有效的 HTTPS Origin")
        case .invalidResponse:
            return String(localized: "服务端返回了小组件无法识别的数据")
        case .networkUnavailable:
            return String(localized: "检查网络后点按重试")
        case .storageUnavailable:
            return String(localized: "App 与小组件无法访问共享 Keychain 或 App Group")
        }
    }

    private var widgetRefreshStatusColor: Color {
        switch session.widgetRefreshStatus.phase {
        case .ready, .success:
            LedgerPalette.success
        case .provisioning, .refreshing:
            LedgerPalette.cobalt
        case .waitingForBiometrics, .credentialUnavailable:
            LedgerPalette.secondary
        case .authorizationRejected, .serverOutdated, .serverUnavailable,
             .invalidConfiguration, .invalidResponse, .networkUnavailable, .storageUnavailable:
            LedgerPalette.risk
        }
    }

    private var lockIntervalBinding: Binding<LedgerLockInterval> {
        Binding(
            get: { session.lockInterval },
            set: session.setLockInterval
        )
    }

}

private struct CompactTabConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var destinations: [LedgerDestination]

    let onSave: ([LedgerDestination]) -> Void

    init(
        initialDestinations: [LedgerDestination],
        onSave: @escaping ([LedgerDestination]) -> Void
    ) {
        _destinations = State(initialValue: LedgerDestination.normalizedCompactTabs(initialDestinations))
        self.onSave = onSave
    }

    private var availableDestinations: [LedgerDestination] {
        LedgerDestination.compactTabCandidates.filter { !destinations.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(destinations) { destination in
                        HStack(spacing: 12) {
                            Image(systemName: destination.systemImage)
                                .font(.system(size: 15))
                                .foregroundStyle(BalancedPalette.ink)
                                .frame(width: 24)
                            Text(destination.title)
                                .balancedFont(size: 15, weight: .text)
                                .foregroundStyle(BalancedPalette.ink)
                            Spacer(minLength: 8)
                            Button {
                                remove(destination)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(destinations.count > 1 ? BalancedPalette.expense : BalancedPalette.meta)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(destinations.count <= 1)
                            .accessibilityLabel("移除\(destination.title)")
                            .accessibilityIdentifier("compact-tab-remove-\(destination.rawValue)")
                        }
                        .frame(minHeight: 44)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    .onMove { source, destination in
                        destinations.move(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    TerminalSectionLabel(text: String(localized: "已显示 \(destinations.count)/\(LedgerDestination.compactTabLimit)"))
                        .listRowBackground(BalancedPalette.page)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                } footer: {
                    Text("拖动右侧排序控件调整显示顺序，底栏固定保留“更多”和“搜索”。")
                        .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        .listRowBackground(BalancedPalette.page)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }

                Section {
                    ForEach(availableDestinations) { destination in
                        Button {
                            add(destination)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: destination.systemImage)
                                    .font(.system(size: 15))
                                    .foregroundStyle(BalancedPalette.ink)
                                    .frame(width: 24)
                                Text(destination.title)
                                    .balancedFont(size: 15)
                                    .foregroundStyle(BalancedPalette.ink)
                                Spacer(minLength: 8)
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(BalancedPalette.ink)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(destinations.count >= LedgerDestination.compactTabLimit)
                        .accessibilityIdentifier("compact-tab-add-\(destination.rawValue)")
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } header: { TerminalSectionLabel(text: String(localized: "可添加")).listRowBackground(BalancedPalette.page)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)) }

                Section {
                    Button("恢复默认") {
                        destinations = LedgerDestination.defaultCompactTabs
                    }
                    .balancedFont(size: 15)
                    .foregroundStyle(BalancedPalette.ink)
                    .accessibilityIdentifier("compact-tab-reset")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .accessibilityIdentifier("compact-tab-list")
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(BalancedPalette.page)
            .navigationTitle("底部标签栏")
            .terminalNativeChrome()
            .navigationBarTitleDisplayMode(.inline)

            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(destinations)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("compact-tab-save")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func add(_ destination: LedgerDestination) {
        guard destinations.count < LedgerDestination.compactTabLimit,
              !destinations.contains(destination),
              destination != .settings else { return }
        destinations.append(destination)
    }

    private func remove(_ destination: LedgerDestination) {
        guard destinations.count > 1 else { return }
        destinations.removeAll { $0 == destination }
    }
}

/// `.row row--tap` with a trailing `--ink-3` value and an `--edge` chevron —
/// the settings rows that open a picker or editor (底部标签栏, 自动锁定, 名称).
private struct SettingsRow: View {
    let title: String
    let value: String
    var showsChevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink)
                Spacer(minLength: 8)
                Text(value).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BalancedPalette.edge)
                }
            }
            .frame(minHeight: 44)
            .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// `.row` title/sub pair used as a `Toggle` label — the row itself carries no
/// affordance, so it gets no chevron and no rule (the toggle rows share one).
private struct SettingsRowLabel: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink)
            if let detail {
                Text(detail).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
            }
        }
        .frame(minHeight: 44, alignment: .leading)
    }
}

/// `.row` — exactly one `--rule` hairline spanning the full row (label +
/// trailing control), not just under the label text. Applied at the call
/// site of every `Toggle` row so the rule reaches the same right edge as
/// every other row's rule, including the toggle's own column.
private struct SettingsRowRule: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
    }
}

private extension View {
    func settingsRowRule() -> some View { modifier(SettingsRowRule()) }
}

/// A `.row row--tap` that pushes a destination, with an optional trailing
/// value (`已启用`, a model id in mono) before the `--edge` chevron.
private struct SettingsNavRow<Destination: View>: View {
    let title: String
    var value: String?
    var valueMono = false
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink { destination() } label: {
            HStack(spacing: 12) {
                Text(title).balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink)
                Spacer(minLength: 8)
                if let value {
                    if valueMono {
                        Text(value).balancedMono(size: 12).foregroundStyle(BalancedPalette.meta)
                    } else {
                        Text(value).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BalancedPalette.edge)
            }
            .frame(minHeight: 44)
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
