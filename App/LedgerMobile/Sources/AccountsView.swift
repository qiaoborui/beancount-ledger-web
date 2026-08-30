import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LedgerAppBar {
                    PrivacyToolbarButton()
                }

                if let ledger = session.ledger, !ledger.accountSections.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            LedgerPageIntro(
                                title: "账户与余额",
                                detail: "按账户类型查看当前余额与统一估值。",
                                meta: "\(ledger.accountBalances.count) 个账户"
                            ) {
                                EmptyView()
                            }

                            VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                                HStack(spacing: LedgerSpacing.sm) {
                                    Text("全部")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(LedgerPalette.onBrand)
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 34)
                                        .background(LedgerPalette.cobalt)
                                        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
                                    Text("按类型分组")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(LedgerPalette.secondary)
                                    Spacer()
                                }

                                if let error = session.errorMessage {
                                    StatusBanner(message: error, onDismiss: session.dismissError)
                                }
                            }
                            .padding(.horizontal, LedgerSpacing.lg)
                            .padding(.bottom, LedgerSpacing.lg)

                            LazyVStack(spacing: LedgerSpacing.md) {
                                ForEach(ledger.accountSections) { section in
                                    AccountGroupPanel(
                                        section: section,
                                        valuationCurrency: ledger.valuationCurrency
                                    )
                                }
                            }
                            .padding(.horizontal, LedgerSpacing.lg)
                            .padding(
                                .bottom,
                                horizontalSizeClass == .regular
                                    ? LedgerSpacing.xxl
                                    : LedgerLayout.compactTabBarClearance
                            )
                        }
                        .ledgerAdaptivePageWidth()
                        .padding(.vertical, horizontalSizeClass == .regular ? LedgerSpacing.xl : 0)
                    }
                    .refreshable { await session.refresh() }
                } else {
                    EmptyLedgerState(
                        icon: "building.columns",
                        title: "暂无账户余额",
                        detail: "服务器返回的账本没有可展示的账户余额。"
                    )
                }
            }
            .background(LedgerPalette.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct AccountGroupPanel: View {
    let section: AccountBalanceSection
    let valuationCurrency: String

    private var total: Int {
        section.rows
            .filter { !$0.valuationMissing }
            .reduce(0) { $0 + $1.valuation }
    }

    private var initials: String {
        String(section.title.prefix(1))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: LedgerSpacing.md) {
                Text(initials)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LedgerPalette.olive)
                    .frame(width: 44, height: 44)
                    .background(LedgerPalette.tag)
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text("\(section.rows.count) 个账户")
                        .font(.system(size: 11))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                AmountLabel(
                    minorUnits: total,
                    currency: valuationCurrency,
                    font: .system(size: 15, weight: .semibold),
                    color: LedgerPalette.gold
                )
                .lineLimit(1)
            }
            .padding(LedgerSpacing.lg)

            Divider().overlay(LedgerPalette.line)

            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                AccountRowView(row: row)
                    .padding(.horizontal, LedgerSpacing.lg)

                if index < section.rows.count - 1 {
                    Divider()
                        .overlay(LedgerPalette.line)
                        .padding(.leading, LedgerSpacing.lg)
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

private struct AccountRowView: View {
    let row: AccountBalanceRow

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: LedgerSpacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text(row.account)
                        .font(.system(size: 10))
                        .foregroundStyle(LedgerPalette.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if row.valuationMissing {
                    Text("缺少汇率")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerPalette.risk)
                } else {
                    AmountLabel(
                        minorUnits: row.valuation,
                        currency: row.valuationCurrency,
                        font: .system(size: 13, weight: .semibold)
                    )
                    .lineLimit(1)
                }
            }

            if row.nativeCurrency != row.valuationCurrency {
                HStack {
                    Text("原币")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                    Spacer()
                    AmountLabel(
                        minorUnits: row.nativeAmount,
                        currency: row.nativeCurrency,
                        font: .system(size: 10, weight: .medium),
                        color: LedgerPalette.secondary
                    )
                }
            }
        }
        .padding(.vertical, LedgerSpacing.md)
        .accessibilityElement(children: .combine)
    }
}
