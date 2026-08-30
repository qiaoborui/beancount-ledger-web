import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var session: LedgerSession

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LedgerAppBar {
                    PrivacyToolbarButton()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: LedgerSpacing.xl) {
                        LedgerPageIntro(
                            title: "更多",
                            detail: "管理设备安全、隐私锁定和服务器连接。",
                            meta: nil
                        ) {
                            EmptyView()
                        }

                        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
                            Text("管理")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LedgerPalette.secondary)
                                .padding(.horizontal, 2)

                            LedgerPanel {
                                NavigationLink {
                                    SettingsView(showsAppBar: false)
                                } label: {
                                    MoreNavigationRow(
                                        icon: "gearshape",
                                        title: "设置",
                                        detail: "Face ID、自动锁定、服务器与会话"
                                    )
                                }
                                .buttonStyle(PressScaleButtonStyle())
                            }
                        }
                        .padding(.horizontal, LedgerSpacing.lg)

                        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
                            Text("当前客户端")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LedgerPalette.secondary)
                                .padding(.horizontal, 2)

                            LedgerPanel {
                                HStack(spacing: LedgerSpacing.md) {
                                    Image(systemName: "iphone.gen3")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(LedgerPalette.cobalt)
                                        .frame(width: 36, height: 36)
                                        .background(LedgerPalette.tag)
                                        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("原生只读模式")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(LedgerPalette.ink)
                                        Text(session.serverURL?.host ?? "Ledger iOS")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(LedgerPalette.secondary)
                                    }
                                    Spacer()
                                    Text("只读")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(LedgerPalette.cobalt)
                                        .padding(.horizontal, 9)
                                        .frame(minHeight: 28)
                                        .background(LedgerPalette.tag)
                                        .clipShape(Capsule())
                                }
                                .padding(LedgerSpacing.lg)
                            }
                        }
                        .padding(.horizontal, LedgerSpacing.lg)
                    }
                    .padding(.bottom, LedgerLayout.compactTabBarClearance)
                }
            }
            .background(LedgerPalette.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct MoreNavigationRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: LedgerSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(width: 36, height: 36)
                .background(LedgerPalette.tag)
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(LedgerPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .padding(LedgerSpacing.lg)
        .contentShape(Rectangle())
    }
}
