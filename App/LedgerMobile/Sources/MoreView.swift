import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var session: LedgerSession

    private var overflowDestination: Binding<LedgerDestination?> {
        Binding(
            get: {
                let destination = LedgerDestination.stored(session.primaryDestinationID)
                guard destination != .settings,
                      !session.compactTabDestinations.contains(destination) else { return nil }
                return destination
            },
            set: { destination in
                if let destination {
                    session.primaryDestinationID = destination.rawValue
                } else {
                    let current = LedgerDestination.stored(session.primaryDestinationID)
                    guard current != .settings,
                          !session.compactTabDestinations.contains(current) else { return }
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
                            Text("主要页面")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LedgerPalette.secondary)
                                .padding(.horizontal, 2)

                            LedgerPanel {
                                VStack(spacing: 0) {
                                    MoreDestinationButton(
                                        destination: .overview,
                                        detail: "净资产、收支与近期财务动态"
                                    )

                                    Divider().overlay(LedgerPalette.line).padding(.leading, 64)

                                    MoreDestinationButton(
                                        destination: .transactions,
                                        detail: "浏览、筛选与编辑账本流水"
                                    )

                                    Divider().overlay(LedgerPalette.line).padding(.leading, 64)

                                    MoreDestinationButton(
                                        destination: .accounts,
                                        detail: "查看账户余额、变化与明细"
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, LedgerSpacing.lg)

                        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
                            Text("财务分析")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LedgerPalette.secondary)
                                .padding(.horizontal, 2)

                            LedgerPanel {
                                VStack(spacing: 0) {
                                    ForEach(Array(LedgerAnalysisKind.allCases.enumerated()), id: \.element) { index, kind in
                                        MoreDestinationButton(
                                            destination: destination(for: kind),
                                            detail: kind.detail,
                                            accessibilityIdentifier: "more-analysis-\(kind.rawValue)"
                                        )

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
                                    MoreDestinationButton(
                                        destination: .imports,
                                        detail: "各渠道覆盖日期、更新状态与归档历史",
                                        accessibilityIdentifier: "more-imports"
                                    )

                                    Divider().overlay(LedgerPalette.line).padding(.leading, 64)

                                    MoreDestinationButton(
                                        destination: .currencies,
                                        detail: "估值货币、汇率来源与近期变化",
                                        accessibilityIdentifier: "more-currencies"
                                    )

                                    Divider().overlay(LedgerPalette.line).padding(.leading, 64)

                                    MoreDestinationButton(
                                        destination: .query,
                                        detail: "高级筛选、聚合分析与查询历史",
                                        accessibilityIdentifier: "more-query"
                                    )
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
                                        Text("原生账本模式")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(LedgerPalette.ink)
                                        Text(session.serverURL?.host ?? "Ledger iOS")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(LedgerPalette.secondary)
                                    }
                                    Spacer()
                                    Text("读写")
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
            .navigationDestination(item: overflowDestination) { destination in
                overflowDestinationView(destination)
            }
        }
    }

    private func destination(for kind: LedgerAnalysisKind) -> LedgerDestination {
        switch kind {
        case .assets: .assets
        case .incomeExpense: .incomeExpense
        case .investments: .investments
        }
    }

    @ViewBuilder
    private func overflowDestinationView(_ destination: LedgerDestination) -> some View {
        switch destination {
        case .overview:
            OverviewView()
        case .assets:
            LedgerAnalysisView(kind: .assets)
        case .incomeExpense:
            LedgerAnalysisView(kind: .incomeExpense)
        case .investments:
            LedgerAnalysisView(kind: .investments)
        case .currencies:
            CurrencyAnalysisView()
        case .query:
            BQLQueryView()
        case .imports:
            ImportHistoryView()
        case .transactions:
            TransactionsView()
        case .accounts:
            AccountsView()
        case .settings:
            SettingsView(showsAppBar: false)
        }
    }
}

private struct MoreDestinationButton: View {
    @EnvironmentObject private var session: LedgerSession

    let destination: LedgerDestination
    let detail: String
    var accessibilityIdentifier: String? = nil

    var body: some View {
        Button {
            session.primaryDestinationID = destination.rawValue
        } label: {
            MoreNavigationRow(icon: destination.systemImage, title: destination.title, detail: detail)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityIdentifier(accessibilityIdentifier ?? "more-\(destination.rawValue)")
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
