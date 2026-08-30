import SwiftUI

struct TransactionRow: View {
    let transaction: LedgerTransaction

    private var presentation: TransactionPresentation {
        TransactionPresentation(transaction: transaction)
    }

    var body: some View {
        HStack(spacing: LedgerSpacing.md) {
            Text(LedgerDateText.shortDate(transaction.date))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(LedgerPalette.secondary)
                .frame(width: 44, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(1)
                if !presentation.subtitle.isEmpty {
                    Text(presentation.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(LedgerPalette.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AmountLabel(
                minorUnits: presentation.minorUnits,
                currency: presentation.currency,
                prefix: amountPrefix(presentation.kind),
                font: .system(size: 13, weight: .semibold),
                color: amountColor(presentation.kind)
            )
            .lineLimit(1)
        }
        .padding(.vertical, LedgerSpacing.md)
        .contentShape(Rectangle())
    }
}

struct TransactionsView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LedgerAppBar {
                    PrivacyToolbarButton()
                }

                if let ledger = session.ledger, !ledger.transactions.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            LedgerPageIntro(
                                title: "\(session.selectedRange.displayTitle)流水",
                                detail: "按日期浏览所选范围的交易与分录来源。",
                                meta: "\(ledger.transactions.count) 笔"
                            ) {
                                EmptyView()
                            }

                            LedgerTimeRangeControl()
                            .padding(.horizontal, LedgerSpacing.lg)
                            .padding(.bottom, LedgerSpacing.md)

                            HStack {
                                Text("\(ledger.transactions.count) / \(ledger.transactions.count) 笔")
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(LedgerPalette.secondary)
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 28)
                                    .background(LedgerPalette.tag)
                                    .clipShape(Capsule())
                                Spacer()
                            }
                            .padding(.horizontal, LedgerSpacing.lg)
                            .padding(.bottom, LedgerSpacing.md)

                            if let error = session.errorMessage {
                                StatusBanner(message: error, onDismiss: session.dismissError)
                                    .padding(.horizontal, LedgerSpacing.lg)
                                    .padding(.bottom, LedgerSpacing.md)
                            }

                            LazyVStack(spacing: 10) {
                                ForEach(ledger.transactions) { transaction in
                                    NavigationLink {
                                        TransactionDetailView(transaction: transaction)
                                    } label: {
                                        TransactionCard(transaction: transaction)
                                    }
                                    .buttonStyle(PressScaleButtonStyle())
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
                        icon: "list.bullet.rectangle",
                        title: "所选范围暂无流水",
                        detail: "服务器返回的所选范围没有交易。"
                    )
                }
            }
            .background(LedgerPalette.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct TransactionCard: View {
    let transaction: LedgerTransaction

    private var presentation: TransactionPresentation {
        TransactionPresentation(transaction: transaction)
    }

    private var category: String? {
        transaction.postings.first {
            $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:")
        }?.account
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: LedgerSpacing.md) {
                Text(presentation.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AmountLabel(
                    minorUnits: presentation.minorUnits,
                    currency: presentation.currency,
                    prefix: amountPrefix(presentation.kind),
                    font: .system(size: 15, weight: .semibold),
                    color: amountColor(presentation.kind)
                )
                .lineLimit(1)
            }

            if !presentation.subtitle.isEmpty {
                Text(presentation.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(LedgerPalette.warm)
                    .lineLimit(2)
            }

            HStack(spacing: LedgerSpacing.sm) {
                Text(transaction.date)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                if let category {
                    Text(category)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(LedgerPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LedgerSpacing.lg)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
    }
}

struct TransactionDetailView: View {
    let transaction: LedgerTransaction

    private var presentation: TransactionPresentation {
        TransactionPresentation(transaction: transaction)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
                    Text(presentation.title)
                        .font(.system(size: 23, weight: .semibold))
                        .tracking(-0.45)
                        .foregroundStyle(LedgerPalette.ink)
                    if !presentation.subtitle.isEmpty {
                        Text(presentation.subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    AmountLabel(
                        minorUnits: presentation.minorUnits,
                        currency: presentation.currency,
                        prefix: amountPrefix(presentation.kind),
                        font: .system(size: 30, weight: .semibold),
                        color: amountColor(presentation.kind)
                    )
                    .tracking(-0.8)
                    .padding(.top, LedgerSpacing.xs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LedgerSpacing.lg)
                .background(LedgerPalette.panel)

                DetailSection(title: "日期") {
                    Text(transaction.date)
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundStyle(LedgerPalette.ink)
                }

                DetailSection(title: "分录") {
                    VStack(spacing: 0) {
                        ForEach(Array(transaction.postings.enumerated()), id: \.offset) { index, posting in
                            HStack(alignment: .firstTextBaseline, spacing: LedgerSpacing.md) {
                                Text(posting.account)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(LedgerPalette.warm)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                AmountLabel(
                                    minorUnits: posting.amount,
                                    currency: posting.currency ?? presentation.currency,
                                    font: .system(size: 12, weight: .semibold)
                                )
                            }
                            .padding(.vertical, LedgerSpacing.md)

                            if index < transaction.postings.count - 1 {
                                Divider().overlay(LedgerPalette.line)
                            }
                        }
                    }
                }

                if let tags = transaction.tags, !tags.isEmpty {
                    DetailSection(title: "标签") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: LedgerSpacing.sm) {
                                ForEach(tags, id: \.self) { tag in
                                    Text("#\(tag)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(LedgerPalette.olive)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(LedgerPalette.tag)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }

                DetailSection(title: "账本来源") {
                    VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
                        Text(transaction.source.file)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LedgerPalette.warm)
                            .textSelection(.enabled)
                        Text("第 \(transaction.source.line) 行")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                }
            }
            .padding(.bottom, LedgerSpacing.xxl)
        }
        .background(LedgerPalette.canvas)
        .navigationTitle("交易详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(LedgerPalette.panel, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PrivacyToolbarButton()
            }
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.md) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LedgerSpacing.lg)
        .background(LedgerPalette.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(LedgerPalette.line).frame(height: 1)
        }
    }
}

private func amountPrefix(_ kind: TransactionKind) -> String {
    switch kind {
    case .expense: return "−"
    case .income: return "+"
    case .transfer: return ""
    }
}

private func amountColor(_ kind: TransactionKind) -> Color {
    switch kind {
    case .expense: return LedgerPalette.expense
    case .income: return LedgerPalette.income
    case .transfer: return LedgerPalette.gold
    }
}
