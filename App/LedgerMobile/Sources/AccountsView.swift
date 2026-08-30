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
                NavigationLink {
                    AccountDetailView(account: row.account)
                } label: {
                    HStack(spacing: LedgerSpacing.sm) {
                        AccountRowView(row: row)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    .padding(.horizontal, LedgerSpacing.lg)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleButtonStyle())

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

struct AccountDetailView: View {
    @EnvironmentObject private var session: LedgerSession
    let account: String

    @State private var detail: LedgerAccountDetail?
    @State private var errorMessage: String?
    @State private var reloadToken = 0

    var body: some View {
        Group {
            if let detail {
                detailContent(detail)
            } else if let errorMessage {
                VStack(spacing: LedgerSpacing.lg) {
                    EmptyLedgerState(
                        icon: "exclamationmark.triangle",
                        title: "账户详情加载失败",
                        detail: errorMessage
                    )
                    Button("重新加载") {
                        reloadToken += 1
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LedgerPalette.onBrand)
                    .padding(.horizontal, LedgerSpacing.xl)
                    .frame(minHeight: 44)
                    .background(LedgerPalette.cobalt)
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                    .buttonStyle(PressScaleButtonStyle())
                    .padding(.bottom, LedgerSpacing.xxl)
                }
            } else {
                VStack(spacing: LedgerSpacing.md) {
                    ProgressView()
                        .tint(LedgerPalette.cobalt)
                    Text("正在加载账户详情")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(LedgerPalette.canvas)
        .navigationTitle(detail?.label ?? "账户详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(LedgerPalette.panel, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PrivacyToolbarButton()
            }
        }
        .task(id: reloadToken) {
            await load()
        }
    }

    private func detailContent(_ detail: LedgerAccountDetail) -> some View {
        ScrollView {
            LazyVStack(spacing: LedgerSpacing.md) {
                VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                    HStack(alignment: .top, spacing: LedgerSpacing.md) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(detail.label)
                                .font(.system(size: 22, weight: .semibold))
                                .tracking(-0.4)
                                .foregroundStyle(LedgerPalette.ink)
                            if let alias = detail.alias, alias != detail.label {
                                Text(alias)
                                    .font(.system(size: 12))
                                    .foregroundStyle(LedgerPalette.olive)
                            }
                            Text(detail.account)
                                .font(.system(size: 11, weight: .medium).monospaced())
                                .foregroundStyle(LedgerPalette.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !detail.active {
                            Text("已关闭")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(LedgerPalette.secondary)
                                .padding(.horizontal, 8)
                                .frame(minHeight: 26)
                                .background(LedgerPalette.tag)
                                .clipShape(Capsule())
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("当前余额")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(LedgerPalette.secondary)
                        AmountLabel(
                            minorUnits: detail.currentBalance,
                            currency: detail.currency,
                            font: .system(size: 27, weight: .semibold),
                            color: detail.account.hasPrefix("Liabilities:")
                                ? LedgerPalette.expense
                                : LedgerPalette.gold
                        )
                        .tracking(-0.7)
                        .lineLimit(1)
                    }
                }
                .padding(LedgerSpacing.lg)
                .background(LedgerPalette.panel)
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                        .stroke(LedgerPalette.line, lineWidth: 1)
                }

                if let errorMessage {
                    StatusBanner(message: errorMessage) {
                        self.errorMessage = nil
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("账户流水")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Spacer()
                    Text("\(detail.rows.count) 笔")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .padding(.top, LedgerSpacing.sm)

                if detail.rows.isEmpty {
                    Text("这个账户暂无关联流水。")
                        .font(.system(size: 13))
                        .foregroundStyle(LedgerPalette.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else {
                    LedgerPanel {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(detail.rows.reversed().enumerated()), id: \.element.id) { index, row in
                                NavigationLink {
                                    TransactionDetailView(transaction: row.transaction)
                                } label: {
                                    AccountHistoryRow(row: row, currency: detail.currency)
                                }
                                .buttonStyle(PressScaleButtonStyle())

                                if index < detail.rows.count - 1 {
                                    Divider()
                                        .overlay(LedgerPalette.line)
                                        .padding(.leading, LedgerSpacing.lg)
                                }
                            }
                        }
                    }
                }
            }
            .padding(LedgerSpacing.lg)
            .padding(.bottom, LedgerSpacing.xxl)
            .ledgerAdaptivePageWidth()
        }
        .refreshable { await load(replacingContent: false) }
    }

    private func load(replacingContent: Bool = true) async {
        if replacingContent {
            detail = nil
        }
        errorMessage = nil
        do {
            let updatedDetail = try await session.accountDetail(for: account)
            guard !Task.isCancelled else { return }
            detail = updatedDetail
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AccountHistoryRow: View {
    let row: LedgerAccountDetailRow
    let currency: String

    private var title: String {
        if !row.payee.isEmpty { return row.payee }
        if !row.narration.isEmpty { return row.narration }
        return "未命名交易"
    }

    var body: some View {
        HStack(alignment: .center, spacing: LedgerSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(1)
                HStack(spacing: LedgerSpacing.sm) {
                    Text(row.date)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                    if !row.narration.isEmpty, row.narration != title {
                        Text(row.narration)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(LedgerPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                AmountLabel(
                    minorUnits: row.change,
                    currency: currency,
                    prefix: row.change > 0 ? "+" : "",
                    font: .system(size: 13, weight: .semibold),
                    color: row.change >= 0 ? LedgerPalette.income : LedgerPalette.expense
                )
                .lineLimit(1)
                AmountLabel(
                    minorUnits: row.balance,
                    currency: currency,
                    font: .system(size: 10, weight: .medium),
                    color: LedgerPalette.secondary
                )
                .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .padding(LedgerSpacing.lg)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
