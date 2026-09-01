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
    @State private var filters = LedgerTransactionFilter()
    @State private var filterPresented = false

    private var transactions: [LedgerTransaction] {
        session.ledger?.transactions ?? []
    }

    private var filteredTransactions: [LedgerTransaction] {
        transactions.filter(filters.matches)
    }

    private var availableAccounts: [String] {
        Array(Set(transactions.flatMap { $0.postings.map(\.account) }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var availableTags: [String] {
        Array(Set(transactions.flatMap { $0.tags ?? [] }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var activeStructuredFilterCount: Int {
        (filters.kind == .all ? 0 : 1)
            + (filters.account == nil ? 0 : 1)
            + (filters.tags.isEmpty ? 0 : 1)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LedgerAppBar {
                    PrivacyToolbarButton()
                }

                if let ledger = session.ledger, !ledger.transactions.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                                LedgerPageIntro(
                                    title: "\(session.selectedRange.displayTitle)流水",
                                    detail: "搜索收付款对象、说明、账户和标签。",
                                    meta: "\(ledger.transactions.count) 笔",
                                    style: .inline
                                ) {
                                    LedgerToolbarButton(
                                        action: { filterPresented = true },
                                        accessibilityLabel: "筛选交易"
                                    ) {
                                        ZStack(alignment: .topTrailing) {
                                            Image(systemName: "line.3.horizontal.decrease")
                                            if activeStructuredFilterCount > 0 {
                                                Text("\(activeStructuredFilterCount)")
                                                    .font(.system(size: 8, weight: .bold).monospacedDigit())
                                                    .foregroundStyle(LedgerPalette.onBrand)
                                                    .frame(width: 15, height: 15)
                                                    .background(LedgerPalette.cobalt)
                                                    .clipShape(Circle())
                                                    .offset(x: 8, y: -7)
                                            }
                                        }
                                    }
                                }

                                LedgerTimeRangeControl()
                            }
                            .padding(LedgerSpacing.lg)
                            .background(LedgerPalette.panel)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(LedgerPalette.line).frame(height: 1)
                            }
                            .padding(.bottom, LedgerSpacing.md)

                            TransactionSearchField(text: $filters.query)
                                .padding(.horizontal, LedgerSpacing.lg)
                                .padding(.bottom, LedgerSpacing.md)

                            if filters.kind != .all || filters.account != nil || !filters.tags.isEmpty {
                                TransactionFilterChips(filters: $filters)
                                    .padding(.bottom, LedgerSpacing.md)
                            }

                            HStack {
                                Text("\(filteredTransactions.count) / \(ledger.transactions.count) 笔")
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

                            Group {
                                if filteredTransactions.isEmpty {
                                    VStack(spacing: LedgerSpacing.md) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 20, weight: .medium))
                                            .foregroundStyle(LedgerPalette.cobalt)
                                        Text("没有匹配的交易")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(LedgerPalette.ink)
                                        Text("调整关键词、交易类型、账户或标签筛选。")
                                            .font(.system(size: 12))
                                            .foregroundStyle(LedgerPalette.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 56)
                                } else {
                                    LazyVStack(spacing: 10) {
                                        ForEach(filteredTransactions) { transaction in
                                            NavigationLink {
                                                TransactionDetailView(transaction: transaction)
                                            } label: {
                                                TransactionCard(transaction: transaction)
                                            }
                                            .buttonStyle(PressScaleButtonStyle())
                                        }
                                    }
                                    .padding(.horizontal, LedgerSpacing.lg)
                                }
                            }
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
            .sheet(isPresented: $filterPresented) {
                TransactionFilterSheet(
                    kind: $filters.kind,
                    account: $filters.account,
                    tags: $filters.tags,
                    accounts: availableAccounts,
                    availableTags: availableTags,
                    onDone: { filterPresented = false }
                )
                .ledgerPrivacyProtectedSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

private struct TransactionSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: LedgerSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LedgerPalette.secondary)
            TextField("搜索交易、账户或标签", text: $text)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(LedgerPalette.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.leading, LedgerSpacing.md)
        .padding(.trailing, text.isEmpty ? LedgerSpacing.md : LedgerSpacing.xs)
        .frame(minHeight: 44)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
    }
}

private struct TransactionFilterChips: View {
    @Binding var filters: LedgerTransactionFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LedgerSpacing.sm) {
                if filters.kind != .all {
                    filterChip(title: filters.kind.title) {
                        filters.kind = .all
                    }
                }
                if let account = filters.account {
                    filterChip(title: account.split(separator: ":").last.map(String.init) ?? account) {
                        filters.account = nil
                    }
                }
                ForEach(filters.tags.sorted(), id: \.self) { tag in
                    filterChip(title: "#\(tag)") {
                        filters.tags.remove(tag)
                    }
                }
                Button("清除筛选") {
                    filters.kind = .all
                    filters.account = nil
                    filters.tags.removeAll()
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(minHeight: 32)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, LedgerSpacing.lg)
        }
    }

    private func filterChip(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(LedgerPalette.olive)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(LedgerPalette.tag)
            .clipShape(Capsule())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel("移除筛选：\(title)")
    }
}

private struct TransactionFilterSheet: View {
    @Binding var kind: TransactionKindFilter
    @Binding var account: String?
    @Binding var tags: Set<String>
    let accounts: [String]
    let availableTags: [String]
    let onDone: () -> Void

    @State private var tagQuery = ""

    private var displayedTags: [String] {
        let allTags = Array(Set(availableTags).union(tags))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let query = tagQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !query.isEmpty else { return allTags }
        return allTags.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("交易类型") {
                    Picker("交易类型", selection: $kind) {
                        ForEach(TransactionKindFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section("账户") {
                    Picker("账户", selection: $account) {
                        Text("全部账户").tag(Optional<String>.none)
                        ForEach(accounts, id: \.self) { value in
                            Text(value).tag(Optional(value))
                        }
                    }
                }

                Section {
                    HStack(spacing: LedgerSpacing.sm) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(LedgerPalette.secondary)
                        TextField("搜索标签", text: $tagQuery)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if availableTags.isEmpty, tags.isEmpty {
                        Text("当前范围没有标签")
                            .foregroundStyle(LedgerPalette.secondary)
                    } else if displayedTags.isEmpty {
                        Text("没有匹配标签")
                            .foregroundStyle(LedgerPalette.secondary)
                    } else {
                        ForEach(displayedTags, id: \.self) { tag in
                            Button {
                                if tags.contains(tag) {
                                    tags.remove(tag)
                                } else {
                                    tags.insert(tag)
                                }
                            } label: {
                                HStack {
                                    Text("#\(tag)")
                                        .foregroundStyle(LedgerPalette.ink)
                                    Spacer()
                                    if tags.contains(tag) {
                                        Image(systemName: "checkmark")
                                            .fontWeight(.semibold)
                                            .foregroundStyle(LedgerPalette.cobalt)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("transaction-tag-filter-\(tag)")
                            .accessibilityValue(tags.contains(tag) ? "已选择" : "未选择")
                        }
                    }
                } header: {
                    HStack {
                        Text("标签")
                        if !tags.isEmpty {
                            Text("已选 \(tags.count)")
                        }
                    }
                } footer: {
                    Text("选择多个标签时，显示包含其中任一标签的交易。")
                }

                if kind != .all || account != nil || !tags.isEmpty {
                    Section {
                        Button("重置筛选", role: .destructive) {
                            kind = .all
                            account = nil
                            tags.removeAll()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(LedgerPalette.canvas)
            .navigationTitle("筛选交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: onDone)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(LedgerPalette.cobalt)
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
                        .fixedSize(horizontal: false, vertical: true)
                    if !presentation.subtitle.isEmpty {
                        Text(presentation.subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(LedgerPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                AmountLabel(
                                    minorUnits: posting.amount,
                                    currency: posting.currency ?? presentation.currency,
                                    font: .system(size: 12, weight: .semibold)
                                )
                                .layoutPriority(1)
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
                            .fixedSize(horizontal: false, vertical: true)
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
