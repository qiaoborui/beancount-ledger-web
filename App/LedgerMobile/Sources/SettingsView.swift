import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
