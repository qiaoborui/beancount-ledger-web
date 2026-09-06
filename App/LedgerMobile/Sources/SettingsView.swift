import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var compactTabConfigurationPresented = false
    var showsAppBar = true

    var body: some View {
        VStack(spacing: 0) {
            if showsAppBar {
                LedgerAppBar {
                    PrivacyToolbarButton()
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: LedgerSpacing.xl) {
                    LedgerPageIntro(
                        title: showsAppBar ? "设置" : "设备与会话",
                        detail: "管理这台设备的解锁方式、隐私锁定和服务器连接。",
                        meta: nil
                    ) {
                        EmptyView()
                    }

                    if let error = session.errorMessage {
                        StatusBanner(message: error, onDismiss: session.dismissError)
                            .padding(.horizontal, horizontalSizeClass == .regular ? 0 : LedgerSpacing.lg)
                    }

                    settingsSection(title: "导航", detail: "仅影响紧凑宽度") {
                        Button {
                            compactTabConfigurationPresented = true
                        } label: {
                            HStack(spacing: LedgerSpacing.md) {
                                SettingsIcon(systemName: "rectangle.bottomthird.inset.filled")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("底部标签栏")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(LedgerPalette.ink)
                                    Text(session.compactTabDestinations.map(\.compactTitle).joined(separator: "、"))
                                        .font(.system(size: 11))
                                        .foregroundStyle(LedgerPalette.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(session.compactTabDestinations.count)/\(LedgerDestination.compactTabLimit)")
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(LedgerPalette.cobalt)
                                    .padding(.horizontal, 8)
                                    .frame(minHeight: 26)
                                    .background(LedgerPalette.tag)
                                    .clipShape(Capsule())
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                            .padding(LedgerSpacing.lg)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .accessibilityIdentifier("settings-compact-tabs")
                    }
                    .padding(.horizontal, horizontalSizeClass == .regular ? 0 : LedgerSpacing.lg)

                    settingsSection(title: "设备安全", detail: "仅影响这台设备") {
                        SettingsToggleRow(
                            icon: session.biometricSystemImage,
                            title: session.biometricTitle,
                            detail: biometricDetail,
                            isOn: Binding(
                                get: { session.hasBiometricUnlock },
                                set: { enabled in
                                    Task { await session.setBiometricUnlockEnabled(enabled) }
                                }
                            )
                        )
                        .disabled(session.biometricKind == .unavailable || session.isBiometricSettingBusy)

                        SettingsDivider()

                        HStack(spacing: LedgerSpacing.md) {
                            SettingsIcon(systemName: "timer")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("自动锁定")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.ink)
                                Text("离开 App 后超过设定时间需要重新验证")
                                    .font(.system(size: 11))
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Picker("自动锁定", selection: lockIntervalBinding) {
                                ForEach(LedgerLockInterval.allCases) { interval in
                                    Text(interval.title).tag(interval)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(LedgerPalette.cobalt)
                        }
                        .padding(LedgerSpacing.lg)
                    }
                    .padding(.horizontal, horizontalSizeClass == .regular ? 0 : LedgerSpacing.lg)

                    settingsSection(title: "连接", detail: "当前 Ledger Web 后端") {
                        HStack(alignment: .top, spacing: LedgerSpacing.md) {
                            SettingsIcon(systemName: "server.rack")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("服务器")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.ink)
                                Text(session.serverURL?.absoluteString ?? "未配置")
                                    .font(.system(size: 12, weight: .medium).monospaced())
                                    .foregroundStyle(LedgerPalette.secondary)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(LedgerSpacing.lg)
                    }
                    .padding(.horizontal, horizontalSizeClass == .regular ? 0 : LedgerSpacing.lg)

                    settingsSection(title: "会话", detail: "控制当前设备上的访问状态") {
                        SettingsActionRow(
                            icon: "lock.fill",
                            title: "立即锁定",
                            detail: "立即隐藏账本，下次进入需在本机验证",
                            color: LedgerPalette.cobalt
                        ) {
                            Task { await session.lock() }
                        }

                        SettingsDivider()

                        SettingsActionRow(
                            icon: "rectangle.portrait.and.arrow.right",
                            title: "退出登录",
                            detail: "保留这台设备的 Face ID 设置",
                            color: LedgerPalette.risk
                        ) {
                            session.logout()
                        }

                        SettingsDivider()

                        SettingsActionRow(
                            icon: "arrow.triangle.2.circlepath",
                            title: "更换服务器",
                            detail: "清除当前服务器的本机生物凭据并返回配置页",
                            color: LedgerPalette.cobalt
                        ) {
                            session.changeServer()
                        }
                    }
                    .padding(.horizontal, horizontalSizeClass == .regular ? 0 : LedgerSpacing.lg)
                }
                .ledgerAdaptivePageWidth()
                .padding(.top, horizontalSizeClass == .regular ? LedgerSpacing.xxl : 0)
                .padding(.horizontal, horizontalSizeClass == .regular ? LedgerSpacing.xxl : 0)
                .padding(.bottom, horizontalSizeClass == .regular ? LedgerSpacing.xxl : LedgerLayout.compactTabBarClearance)
            }
            .refreshable { await session.refresh() }
        }
        .background(LedgerPalette.canvas)
        .navigationTitle(showsAppBar ? "" : "设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsAppBar ? .hidden : .visible, for: .navigationBar)
        .toolbarBackground(LedgerPalette.panel, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if !showsAppBar {
                ToolbarItem(placement: .topBarTrailing) {
                    PrivacyToolbarButton()
                }
            }
        }
        .sheet(isPresented: $compactTabConfigurationPresented) {
            CompactTabConfigurationView(initialDestinations: session.compactTabDestinations) { destinations in
                session.setCompactTabDestinations(destinations)
            }
        }
    }

    private var biometricDetail: String {
        if session.biometricKind == .unavailable {
            return "请先在系统设置中配置生物识别"
        }
        return session.hasBiometricUnlock
            ? "使用受 Keychain 保护的设备令牌快速解锁"
            : "启用时会创建可在服务端撤销的设备令牌"
    }

    private var lockIntervalBinding: Binding<LedgerLockInterval> {
        Binding(
            get: { session.lockInterval },
            set: session.setLockInterval
        )
    }

    private func settingsSection<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                Spacer()
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
            }
            .padding(.horizontal, 2)

            LedgerPanel {
                VStack(spacing: 0) {
                    content()
                }
            }
        }
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
                            SettingsIcon(systemName: destination.systemImage)
                            Text(destination.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(LedgerPalette.ink)
                            Spacer(minLength: LedgerSpacing.sm)
                            Button {
                                remove(destination)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 18, weight: .medium))
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
                    Text("拖动右侧排序控件调整显示顺序，底栏会固定保留“更多”。")
                }

                Section("可添加") {
                    ForEach(availableDestinations) { destination in
                        Button {
                            add(destination)
                        } label: {
                            HStack(spacing: LedgerSpacing.md) {
                                SettingsIcon(systemName: destination.systemImage)
                                Text(destination.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(LedgerPalette.ink)
                                Spacer(minLength: LedgerSpacing.sm)
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 18, weight: .medium))
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
            .toolbarBackground(LedgerPalette.panel, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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

private struct SettingsIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(LedgerPalette.cobalt)
            .frame(width: 36, height: 36)
            .background(LedgerPalette.tag)
            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
    }
}

private struct SettingsToggleRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: LedgerSpacing.md) {
                SettingsIcon(systemName: icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }
        }
        .tint(LedgerPalette.cobalt)
        .padding(LedgerSpacing.lg)
    }
}

private struct SettingsActionRow: View {
    let icon: String
    let title: String
    let detail: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LedgerSpacing.md) {
                SettingsIcon(systemName: icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(color)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LedgerPalette.secondary)
            }
            .padding(LedgerSpacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(LedgerPalette.line)
            .frame(height: 1)
            .padding(.leading, LedgerSpacing.lg + 36 + LedgerSpacing.md)
    }
}
