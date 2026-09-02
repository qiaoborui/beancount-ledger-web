import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var session: LedgerSession

    private var importLinkPresented: Binding<Bool> {
        Binding(
            get: { session.primaryDestinationID == LedgerDestination.imports.rawValue },
            set: { presented in
                if !presented, session.primaryDestinationID == LedgerDestination.imports.rawValue {
                    session.primaryDestinationID = LedgerDestination.settings.rawValue
                }
            }
        )
    }

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
                            detail: "查看财务分析，管理设备安全和服务器连接。",
                            meta: nil
                        ) {
                            EmptyView()
                        }

                        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
                            Text("财务分析")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LedgerPalette.secondary)
                                .padding(.horizontal, 2)

                            LedgerPanel {
                                VStack(spacing: 0) {
                                    ForEach(Array(LedgerAnalysisKind.allCases.enumerated()), id: \.element) { index, kind in
                                        NavigationLink {
                                            LedgerAnalysisView(kind: kind)
                                        } label: {
                                            MoreNavigationRow(icon: kind.systemImage, title: kind.title, detail: kind.detail)
                                        }
                                        .buttonStyle(PressScaleButtonStyle())
                                        .accessibilityIdentifier("more-analysis-\(kind.rawValue)")

                                        if index < LedgerAnalysisKind.allCases.count - 1 {
                                            Divider().overlay(LedgerPalette.line).padding(.leading, 64)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, LedgerSpacing.lg)

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
                            Text("账本工具")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LedgerPalette.secondary)
                                .padding(.horizontal, 2)

                            LedgerPanel {
                                VStack(spacing: 0) {
                                    NavigationLink {
                                        ImportHistoryView()
                                    } label: {
                                        MoreNavigationRow(
                                            icon: "tray.and.arrow.down",
                                            title: "导入记录",
                                            detail: "各渠道覆盖日期、更新状态与归档历史"
                                        )
                                    }
                                    .buttonStyle(PressScaleButtonStyle())
                                    .accessibilityIdentifier("more-imports")

                                    Divider().overlay(LedgerPalette.line).padding(.leading, 64)

                                    NavigationLink {
                                        CurrencyAnalysisView()
                                    } label: {
                                        MoreNavigationRow(
                                            icon: "coloncurrencysign",
                                            title: "货币与汇率",
                                            detail: "估值货币、汇率来源与近期变化"
                                        )
                                    }
                                    .buttonStyle(PressScaleButtonStyle())
                                    .accessibilityIdentifier("more-currencies")

                                    Divider().overlay(LedgerPalette.line).padding(.leading, 64)

                                    NavigationLink {
                                        BQLQueryView()
                                    } label: {
                                        MoreNavigationRow(
                                            icon: "cylinder.split.1x2",
                                            title: "BQL 查询",
                                            detail: "高级筛选、聚合分析与查询历史"
                                        )
                                    }
                                    .buttonStyle(PressScaleButtonStyle())
                                    .accessibilityIdentifier("more-query")
                                }
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
            .navigationDestination(isPresented: importLinkPresented) {
                ImportHistoryView()
            }
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
