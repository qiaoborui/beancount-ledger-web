import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var compactTabConfigurationPresented = false
    @State private var editingCurrentLedger = false
    @State private var confirmingDeleteCurrent = false
    var isRoot = true

    var body: some View {
        Form {
            if let error = session.errorMessage {
                Section { StatusBanner(message: error, onDismiss: session.dismissError) }
            }
            Section("导航") {
                Button {
                    compactTabConfigurationPresented = true
                } label: {
                    LabeledContent {
                        Text(session.compactTabDestinations.map(\.compactTitle).joined(separator: "、"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Label("底部标签栏", systemImage: "rectangle.bottomthird.inset.filled")
                    }
                }
                .accessibilityIdentifier("settings-compact-tabs")
            }
            Section {
                Label("使用设备密码或生物识别解锁", systemImage: "lock.shield")

                Picker(selection: lockIntervalBinding) {
                    ForEach(LedgerLockInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                } label: {
                    Label("自动锁定", systemImage: "timer")
                }
                Button {
                    Task { await session.lock() }
                } label: {
                    Label("立即锁定", systemImage: "lock.fill")
                }
            } header: {
                Text("隐私与安全")
            } footer: {
                Text("本地账本由这台设备保护。离开 App 后按设定时间锁定，切换应用时始终隐藏账本。")
            }
            if session.isLocal {
                if let ledgerID = session.currentLocalLedgerDescriptor?.id {
                    Section("AI 与智能记账") {
                        NavigationLink { ImportClassificationSettingsView(ledgerID: ledgerID) } label: {
                            HStack {
                                Label("智能分类", systemImage: "sparkles")
                                Spacer()
                                Text(ImportClassificationSettings.shared.isEnabled(for: ledgerID) ? "已启用" : "未配置")
                                    .font(.footnote)
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                        }
                        .accessibilityIdentifier("settings-classification")
                        NavigationLink { BookkeepingSettingsView() } label: {
                            HStack {
                                Label("语义解析", systemImage: "text.bubble")
                                Spacer()
                                Text(BookkeepingSettings.shared.hasKey ? (BookkeepingSettings.shared.configuration.model.isEmpty ? "已配置" : BookkeepingSettings.shared.configuration.model) : "未配置")
                                    .font(.footnote)
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                        }
                        .accessibilityIdentifier("settings-semantic-parser")
                    }
                }
                Section("本地账本") {
                    Button {
                        editingCurrentLedger = true
                    } label: {
                        HStack {
                            Text("名称")
                                .foregroundStyle(LedgerPalette.ink)
                            Spacer()
                            Text(session.localLedgerName)
                                .foregroundStyle(LedgerPalette.secondary)
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(LedgerPalette.cobalt)
                        }
                    }
                    .accessibilityIdentifier("settings-edit-current-ledger")

                    Label("数据保存在这台设备", systemImage: "internaldrive")
                    NavigationLink("浏览、编辑与导出文件") { LocalLedgerFilesView() }
                        .accessibilityIdentifier("settings-local-files")
                    NavigationLink("存储与同步") { LocalLedgerStorageView() }
                        .accessibilityIdentifier("local-storage-settings")
                }
                Section {
                    Button("切换账本") { session.chooseLedger() }
                    Button("删除当前账本", role: .destructive) {
                        confirmingDeleteCurrent = true
                    }
                    .foregroundStyle(LedgerPalette.risk)
                    .accessibilityIdentifier("settings-delete-current-ledger")
                } footer: { Text("小组件会在本地账本更新后显示新的摘要。切换账本会保留文件；删除账本将永久抹除所有本地数据。") }
            }
            Section {
                LabeledContent("版本", value: "本地版 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                    .accessibilityIdentifier("settings-app-version")
            }
        }
        .formStyle(.grouped)
        .font(.subheadline)
        .ledgerNavigation("设置", isRoot: isRoot)
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
    }

    private var biometricDetail: String {
        if session.biometricKind == .unavailable {
            return "请先在系统设置中配置生物识别"
        }
        return session.hasBiometricUnlock
            ? "使用生物识别快速解锁账本"
            : "启用后可在这台设备上快速解锁"
    }

    private var widgetRefreshStatusTitle: String {
        if !session.hasBiometricUnlock { return "等待\(session.biometricTitle)" }
        switch session.widgetRefreshStatus.phase {
        case .waitingForBiometrics:
            return "等待启用"
        case .provisioning:
            return "正在配置"
        case .ready:
            return "已就绪"
        case .refreshing:
            return "正在刷新"
        case .success:
            return "运行正常"
        case .credentialUnavailable:
            return "凭据缺失"
        case .authorizationRejected:
            return "凭据已失效"
        case .serverOutdated:
            return "服务端待更新"
        case .serverUnavailable:
            return "服务端异常"
        case .invalidConfiguration:
            return "配置异常"
        case .invalidResponse:
            return "响应异常"
        case .networkUnavailable:
            return "网络异常"
        case .storageUnavailable:
            return "安全存储异常"
        }
    }

    private var widgetRefreshDetail: String {
        if !session.hasBiometricUnlock {
            return "启用\(session.biometricTitle)后可更新小组件"
        }
        switch session.widgetRefreshStatus.phase {
        case .waitingForBiometrics:
            return "启用设备生物识别后自动配置"
        case .provisioning:
            return "正在启用后台刷新"
        case .ready:
            return "已启用后台更新，点按立即刷新"
        case .refreshing:
            return "正在从 Ledger Web 获取最新小组件快照"
        case .success:
            if let date = session.widgetRefreshStatus.lastSuccessAt {
                return "上次成功：\(date.formatted(date: .abbreviated, time: .shortened))"
            }
            return "最近一次后台刷新成功"
        case .credentialUnavailable:
            return "后台刷新尚未启用，点按重试"
        case .authorizationRejected:
            return "完成身份验证后点按轮换凭据"
        case .serverOutdated:
            return "Ledger Web 需要部署小组件快照接口"
        case .serverUnavailable:
            if let status = session.widgetRefreshStatus.httpStatus {
                return "服务端返回 HTTP \(status)；点按重试"
            }
            return "服务端暂时无法处理小组件刷新"
        case .invalidConfiguration:
            return "服务器地址需要使用有效的 HTTPS Origin"
        case .invalidResponse:
            return "服务端返回了小组件无法识别的数据"
        case .networkUnavailable:
            return "检查网络后点按重试"
        case .storageUnavailable:
            return "App 与小组件无法访问共享 Keychain 或 App Group"
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
                        HStack(spacing: LedgerSpacing.md) {
                            Image(systemName: destination.systemImage)
                                .foregroundStyle(LedgerPalette.cobalt)
                                .frame(width: 28)
                            Text(destination.title)
                                .font(.system(.subheadline, design: .default, weight: .semibold))
                                .foregroundStyle(LedgerPalette.ink)
                            Spacer(minLength: LedgerSpacing.sm)
                            Button {
                                remove(destination)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(.headline, design: .default, weight: .medium))
                                    .foregroundStyle(destinations.count > 1 ? LedgerPalette.risk : LedgerPalette.secondary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(destinations.count <= 1)
                            .accessibilityLabel("移除\(destination.title)")
                            .accessibilityIdentifier("compact-tab-remove-\(destination.rawValue)")
                        }
                    }
                    .onMove { source, destination in
                        destinations.move(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    Text("已显示 \(destinations.count)/\(LedgerDestination.compactTabLimit)")
                } footer: {
                    Text("拖动右侧排序控件调整显示顺序，底栏固定保留“更多”和“搜索”。")
                }

                Section("可添加") {
                    ForEach(availableDestinations) { destination in
                        Button {
                            add(destination)
                        } label: {
                            HStack(spacing: LedgerSpacing.md) {
                                Image(systemName: destination.systemImage)
                                    .foregroundStyle(LedgerPalette.cobalt)
                                    .frame(width: 28)
                                Text(destination.title)
                                    .font(.system(.subheadline, design: .default, weight: .medium))
                                    .foregroundStyle(LedgerPalette.ink)
                                Spacer(minLength: LedgerSpacing.sm)
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(.headline, design: .default, weight: .medium))
                                    .foregroundStyle(LedgerPalette.cobalt)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(destinations.count >= LedgerDestination.compactTabLimit)
                        .accessibilityIdentifier("compact-tab-add-\(destination.rawValue)")
                    }
                }

                Section {
                    Button("恢复默认") {
                        destinations = LedgerDestination.defaultCompactTabs
                    }
                    .foregroundStyle(LedgerPalette.cobalt)
                    .accessibilityIdentifier("compact-tab-reset")
                }
            }
            .accessibilityIdentifier("compact-tab-list")
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(LedgerPalette.canvas)
            .navigationTitle("底部标签栏")
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
