import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesRegularLayout: Bool { horizontalSizeClass == .regular }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LedgerAppBar {
                    HStack(spacing: LedgerSpacing.sm) {
                        PrivacyToolbarButton()
                        SessionMenu()
                    }
                }

                if let ledger = session.ledger {
                    ScrollView {
                        LazyVStack(spacing: usesRegularLayout ? LedgerSpacing.xl : 0) {
                            if usesRegularLayout {
                                HStack(alignment: .bottom, spacing: LedgerSpacing.xl) {
                                    overviewIntro
                                    LedgerTimeRangeControl()
                                        .frame(width: 420)
                                }
                            } else {
                                overviewIntro

                                LedgerTimeRangeControl()
                                .padding(.horizontal, LedgerSpacing.lg)
                                .padding(.bottom, LedgerSpacing.lg)
                            }

                            if let error = session.errorMessage {
                                StatusBanner(message: error, onDismiss: session.dismissError)
                                    .padding(.horizontal, usesRegularLayout ? 0 : LedgerSpacing.lg)
                                    .padding(.bottom, usesRegularLayout ? 0 : LedgerSpacing.lg)
                            }

                            MonthlyConclusion(
                                ledger: ledger,
                                range: session.selectedRange,
                                regular: usesRegularLayout
                            )
                            .padding(.horizontal, usesRegularLayout ? 0 : LedgerSpacing.lg)
                            .padding(.bottom, usesRegularLayout ? 0 : LedgerSpacing.lg)

                            if usesRegularLayout {
                                HStack(alignment: .top, spacing: LedgerSpacing.xl) {
                                    PositionSection(ledger: ledger, regular: true)
                                        .frame(maxWidth: .infinity)
                                    RecentTransactionsSection(
                                        transactions: Array(ledger.transactions.prefix(6)),
                                        regular: true
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                            } else {
                                PositionSection(ledger: ledger, regular: false)
                                    .padding(.horizontal, LedgerSpacing.lg)
                                    .padding(.bottom, LedgerSpacing.lg)
                                RecentTransactionsSection(
                                    transactions: Array(ledger.transactions.prefix(6)),
                                    regular: false
                                )
                                .padding(.horizontal, LedgerSpacing.lg)
                            }
                        }
                        .ledgerAdaptivePageWidth()
                        .padding(.vertical, usesRegularLayout ? LedgerSpacing.xl : 0)
                        .padding(
                            .bottom,
                            usesRegularLayout ? LedgerSpacing.xxl : LedgerLayout.compactTabBarClearance
                        )
                    }
                    .refreshable { await session.refresh() }
                } else {
                    EmptyLedgerState(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "暂无财务数据",
                        detail: "下拉刷新后重新读取所选范围。"
                    )
                }
            }
            .background(LedgerPalette.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var overviewIntro: some View {
        LedgerPageIntro(
            title: "财务概览",
            detail: "查看所选范围的结余、资产位置与最近流水。",
            meta: session.selectedRange.metricScope
        ) {
            EmptyView()
        }
    }
}

private struct SessionMenu: View {
    @EnvironmentObject private var session: LedgerSession

    var body: some View {
        Menu {
            Button {
                Task { await session.lock() }
            } label: {
                Label("锁定金额", systemImage: "lock")
            }
            Button {
                session.logout()
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
            Button {
                session.changeServer()
            } label: {
                Label("更换服务器", systemImage: "server.rack")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(width: 40, height: 40)
                .background(LedgerPalette.canvas)
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous)
                        .stroke(LedgerPalette.line, lineWidth: 1)
                }
        }
        .accessibilityLabel("更多")
    }
}

private struct MonthlyConclusion: View {
    let ledger: LedgerBootstrap
    let range: LedgerDateRange
    let regular: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionIntro(
                title: "\(range.metricScope)结论",
                detail: "当前页面聚焦所选范围现金流结果。"
            )
            horizontalDivider
            metricGrid
        }
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var metricGrid: some View {
        if regular {
            HStack(spacing: 0) {
                netMetric
                verticalDivider
                incomeMetric
                verticalDivider
                expenseMetric
                verticalDivider
                TransactionCountMetric(count: ledger.transactions.count)
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    netMetric
                    verticalDivider
                    incomeMetric
                }
                horizontalDivider
                HStack(spacing: 0) {
                    expenseMetric
                    verticalDivider
                    TransactionCountMetric(count: ledger.transactions.count)
                }
            }
        }
    }

    private var netMetric: some View {
        LedgerMetric(
            label: "\(range.metricScope)结余",
            minorUnits: ledger.summary.net,
            currency: ledger.summary.currency,
            detail: "收入减去支出",
            color: ledger.summary.net < 0 ? LedgerPalette.risk : LedgerPalette.ink,
            primary: true
        )
    }

    private var incomeMetric: some View {
        LedgerMetric(
            label: "\(range.metricScope)收入",
            minorUnits: ledger.summary.income,
            currency: ledger.summary.currency,
            detail: "当前范围汇总",
            color: LedgerPalette.income
        )
    }

    private var expenseMetric: some View {
        LedgerMetric(
            label: "\(range.metricScope)支出",
            minorUnits: ledger.summary.expense,
            currency: ledger.summary.currency,
            detail: "当前范围汇总",
            color: LedgerPalette.expense
        )
    }

    private var verticalDivider: some View {
        Divider().overlay(LedgerPalette.line)
    }

    private var horizontalDivider: some View {
        Divider().overlay(LedgerPalette.line)
    }
}

private struct TransactionCountMetric: View {
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            Text("交易笔数")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
            Text(String(count))
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .tracking(-0.35)
                .foregroundStyle(LedgerPalette.ink)
            Text("当前范围记录")
                .font(.system(size: 11))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .padding(LedgerSpacing.lg)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(LedgerPalette.panel)
    }
}

private struct SectionIntro: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(LedgerPalette.ink)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LedgerSpacing.lg)
        .padding(.vertical, LedgerSpacing.lg)
    }
}

private struct PositionSection: View {
    let ledger: LedgerBootstrap
    let regular: Bool

    private var totals: BalanceSheetTotals { ledger.balanceSheetTotals }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionIntro(
                title: "当前头寸",
                detail: "总资产、总负债以及当前净资产位置。"
            )
            Divider().overlay(LedgerPalette.line)
            if regular {
                HStack(spacing: 0) {
                    netWorthRow
                    Divider().overlay(LedgerPalette.line)
                    assetsRow
                    Divider().overlay(LedgerPalette.line)
                    liabilitiesRow
                }
            } else {
                netWorthRow
                Divider().overlay(LedgerPalette.line)
                assetsRow
                Divider().overlay(LedgerPalette.line)
                liabilitiesRow
            }
        }
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
    }

    private var netWorthRow: some View {
        PositionRow(
            label: "净资产",
            detail: "总资产减去总负债",
            amount: totals.netWorth,
            currency: ledger.valuationCurrency,
            color: LedgerPalette.gold,
            primary: true
        )
    }

    private var assetsRow: some View {
        PositionRow(
            label: "总资产",
            detail: "按估值币种汇总",
            amount: totals.assets,
            currency: ledger.valuationCurrency
        )
    }

    private var liabilitiesRow: some View {
        PositionRow(
            label: "总负债",
            detail: "按负债绝对值汇总",
            amount: totals.liabilities,
            currency: ledger.valuationCurrency
        )
    }
}

private struct PositionRow: View {
    let label: String
    let detail: String
    let amount: Int
    let currency: String
    var color = LedgerPalette.ink
    var primary = false

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
            AmountLabel(
                minorUnits: amount,
                currency: currency,
                font: .system(size: primary ? 26 : 20, weight: .semibold),
                color: color
            )
            .tracking(primary ? -0.7 : -0.4)
            .lineLimit(1)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LedgerSpacing.lg)
        .padding(.vertical, 18)
    }
}

private struct RecentTransactionsSection: View {
    let transactions: [LedgerTransaction]
    let regular: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionIntro(
                title: "最近流水",
                detail: transactions.isEmpty ? "所选范围暂无流水。" : "按日期显示最近的账本记录。"
            )
            Divider().overlay(LedgerPalette.line)

            if transactions.isEmpty {
                Text("所选范围暂无流水")
                    .font(.system(size: 13))
                    .foregroundStyle(LedgerPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LedgerSpacing.lg)
            } else {
                ForEach(Array(transactions.enumerated()), id: \.element.id) { index, transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction)
                    } label: {
                        TransactionRow(transaction: transaction)
                            .padding(.horizontal, LedgerSpacing.lg)
                    }
                    .buttonStyle(.plain)

                    if index < transactions.count - 1 {
                        Divider()
                            .overlay(LedgerPalette.line)
                            .padding(.leading, 72)
                    }
                }
            }
        }
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
    }
}
