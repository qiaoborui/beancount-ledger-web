import SwiftUI

private enum TransactionAmountParser {
    static func minorUnits(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 128,
              trimmed.range(of: "^[+-]?\\d+(\\.\\d*)?$", options: .regularExpression) != nil,
              let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let number = NSDecimalNumber(decimal: decimal * 100)
        guard number != .notANumber else { return nil }
        return number.rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )).intValue
    }
}

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
    @State private var selectingTags = false
    @State private var selectedTransactionIDs: Set<String> = []
    @State private var tagEditorPresented = false
    @State private var actionMessage: String?

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
                                    HStack(spacing: LedgerSpacing.xs) {
                                        LedgerToolbarButton(
                                            action: {
                                                selectingTags.toggle()
                                                if !selectingTags { selectedTransactionIDs.removeAll() }
                                            },
                                            accessibilityLabel: selectingTags ? "完成标签选择" : "选择交易添加标签"
                                        ) {
                                            Image(systemName: selectingTags ? "checkmark" : "tag")
                                        }
                                        .accessibilityIdentifier("transaction-tag-selection")
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

                            if let actionMessage {
                                StatusBanner(message: actionMessage) { self.actionMessage = nil }
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
                                            if selectingTags {
                                                Button {
                                                    toggleTagSelection(transaction)
                                                } label: {
                                                    TransactionSelectableCard(
                                                        transaction: transaction,
                                                        selected: selectedTransactionIDs.contains(transaction.id)
                                                    )
                                                }
                                                .buttonStyle(PressScaleButtonStyle())
                                                .accessibilityIdentifier("transaction-select-row-\(transaction.source.line)")
                                            } else {
                                                NavigationLink {
                                                    TransactionDetailView(transaction: transaction)
                                                } label: {
                                                    TransactionCard(transaction: transaction)
                                                }
                                                .buttonStyle(PressScaleButtonStyle())
                                                .accessibilityIdentifier("transaction-row-\(transaction.source.line)")
                                            }
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
            .sheet(isPresented: $tagEditorPresented) {
                TransactionTagEditorSheet(
                    selectedCount: selectedTransactionIDs.count,
                    onApply: { tags in
                        try await applyTags(tags)
                    }
                )
                .ledgerPrivacyProtectedSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selectingTags {
                    TransactionTagSelectionBar(
                        selectedCount: selectedTransactionIDs.count,
                        totalCount: min(filteredTransactions.filter(isTagEligible).count, TransactionTagSelectionRules.maximumCount),
                        allSelected: allVisibleEligibleSelected,
                        onToggleAll: toggleAllVisibleForTags,
                        onAddTags: { tagEditorPresented = true },
                        onCancel: {
                            selectingTags = false
                            selectedTransactionIDs.removeAll()
                        }
                    )
                }
            }
            .onChange(of: transactions.map(\.id)) { _, ids in
                selectedTransactionIDs.formIntersection(ids)
            }
        }
    }

    private var allVisibleEligibleSelected: Bool {
        let eligible = filteredTransactions.filter(isTagEligible).prefix(TransactionTagSelectionRules.maximumCount)
        return !eligible.isEmpty && eligible.allSatisfy { selectedTransactionIDs.contains($0.id) }
    }

    private func isTagEligible(_ transaction: LedgerTransaction) -> Bool {
        transaction.source.hash?.isEmpty == false
    }

    private func toggleTagSelection(_ transaction: LedgerTransaction) {
        guard isTagEligible(transaction) else {
            actionMessage = "该交易缺少并发校验信息，请刷新后重试。"
            return
        }
        if selectedTransactionIDs.contains(transaction.id) {
            selectedTransactionIDs.remove(transaction.id)
        } else if selectedTransactionIDs.count < TransactionTagSelectionRules.maximumCount {
            selectedTransactionIDs.insert(transaction.id)
        } else {
            actionMessage = "一次最多选择 200 条交易。"
        }
    }

    private func toggleAllVisibleForTags() {
        let eligible = filteredTransactions.filter(isTagEligible)
        if allVisibleEligibleSelected {
            selectedTransactionIDs.subtract(eligible.map(\.id))
        } else {
            let updated = TransactionTagSelectionRules.adding(eligible.map(\.id), to: selectedTransactionIDs)
            if updated.count == TransactionTagSelectionRules.maximumCount,
               eligible.contains(where: { !updated.contains($0.id) }) {
                actionMessage = "一次最多选择 200 条交易。"
            }
            selectedTransactionIDs = updated
        }
    }

    private func applyTags(_ tags: [String]) async throws {
        let selected = transactions.filter { selectedTransactionIDs.contains($0.id) && isTagEligible($0) }
        guard !selected.isEmpty else { throw LedgerTagValidationError.empty }
        try await session.addTransactionTags(sources: selected.map(\.source), tags: tags)
        selectedTransactionIDs.removeAll()
        selectingTags = false
        actionMessage = "已为 \(selected.count) 条交易添加标签。"
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

            if let tags = transaction.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(LedgerPalette.olive)
                                .padding(.horizontal, 8)
                                .frame(minHeight: 24)
                                .background(LedgerPalette.tag)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
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

private struct TransactionSelectableCard: View {
    let transaction: LedgerTransaction
    let selected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TransactionCard(transaction: transaction)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(selected ? LedgerPalette.cobalt : LedgerPalette.secondary)
                .padding(LedgerSpacing.md)
                .background(LedgerPalette.panel.opacity(0.86))
                .clipShape(Circle())
                .padding(4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(selected ? LedgerPalette.cobalt : Color.clear, lineWidth: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(selected ? "已选择" : "未选择")，\(transaction.payee)，用于添加标签")
    }
}

private struct TransactionTagSelectionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let allSelected: Bool
    let onToggleAll: () -> Void
    let onAddTags: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: LedgerSpacing.sm) {
            Button(allSelected ? "清空" : "全选") { onToggleAll() }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(minWidth: 48, minHeight: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("已选 \(selectedCount) 条")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(LedgerPalette.ink)
                Text("当前可选 \(totalCount) 条")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(LedgerPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("取消", action: onCancel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
                .frame(minHeight: 44)
            Button("添加标签", action: onAddTags)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LedgerPalette.onBrand)
                .padding(.horizontal, LedgerSpacing.md)
                .frame(minHeight: 44)
                .background(LedgerPalette.cobalt)
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                .disabled(selectedCount == 0)
                .opacity(selectedCount == 0 ? 0.52 : 1)
        }
        .buttonStyle(PressScaleButtonStyle())
        .padding(.horizontal, LedgerSpacing.lg)
        .padding(.vertical, LedgerSpacing.sm)
        .background(LedgerPalette.panel)
        .overlay(alignment: .top) { Rectangle().fill(LedgerPalette.line).frame(height: 1) }
    }
}

private struct TransactionTagEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selectedCount: Int
    let onApply: ([String]) async throws -> Void

    @State private var input = ""
    @State private var errorMessage: String?
    @State private var applying = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: LedgerSpacing.lg) {
                LedgerPageContext(
                    detail: "使用空格或逗号分隔多个标签。",
                    meta: "已选择 \(selectedCount) 条交易"
                )
                TextField("例如 travel, dining", text: $input)
                    .font(.system(size: 15, weight: .medium))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, LedgerSpacing.md)
                    .frame(minHeight: 48)
                    .background(LedgerPalette.panel)
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous).stroke(LedgerPalette.line, lineWidth: 1) }
                    .accessibilityIdentifier("transaction-bulk-tag-input")
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LedgerPalette.expense)
                }
                Button {
                    Task { await apply() }
                } label: {
                    PrimaryButtonLabel(title: "添加标签", loading: applying)
                }
                .buttonStyle(PressScaleButtonStyle())
                .disabled(applying)
                .accessibilityIdentifier("transaction-bulk-tag-apply")
                Spacer(minLength: 0)
            }
            .padding(LedgerSpacing.lg)
            .background(LedgerPalette.canvas)
            .navigationTitle("批量添加标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func apply() async {
        guard !applying else { return }
        do {
            let tags = try LedgerTagRules.parse(input)
            applying = true
            try await onApply(tags)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        applying = false
    }
}

struct TransactionDetailView: View {
    @EnvironmentObject private var session: LedgerSession

    @State private var transaction: LedgerTransaction
    @State private var editorPresented = false
    @State private var savedMessage: String?

    init(transaction: LedgerTransaction) {
        _transaction = State(initialValue: transaction)
    }

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

                if let savedMessage {
                    StatusBanner(message: savedMessage) { self.savedMessage = nil }
                        .padding(LedgerSpacing.lg)
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
                Button("编辑") { editorPresented = true }
                    .fontWeight(.semibold)
                    .disabled(transaction.source.hash?.isEmpty != false || transaction.editableEntry == nil)
                    .accessibilityIdentifier("transaction-edit")
            }
        }
        .sheet(isPresented: $editorPresented) {
            TransactionEditorView(
                transaction: transaction,
                accounts: session.ledger?.accounts ?? [],
                commodities: session.ledger?.commodities ?? [],
                onSave: { entry in
                    let previousSource = transaction.source
                    try await session.updateTransaction(source: transaction.source, entry: entry)
                    if let refreshed = session.ledger?.transactions.first(where: {
                        $0.source.file == previousSource.file
                            && $0.source.line == previousSource.line
                            && $0.represents(entry)
                    }) {
                        transaction = refreshed
                        savedMessage = "交易已保存。"
                    } else {
                        transaction = transaction.applying(entry, invalidatingSourceHash: true)
                        savedMessage = "交易已保存。请返回流水列表刷新后继续编辑。"
                    }
                }
            )
            .ledgerPrivacyProtectedSheet()
        }
    }
}

private extension LedgerTransaction {
    func applying(_ entry: LedgerTransactionEntry, invalidatingSourceHash: Bool = false) -> LedgerTransaction {
        LedgerTransaction(
            date: entry.date,
            payee: entry.payee,
            narration: entry.narration,
            metadata: entry.metadata.isEmpty ? nil : entry.metadata,
            tags: entry.tags.isEmpty ? nil : entry.tags,
            postings: entry.postings.map { posting in
                LedgerPosting(
                    account: posting.account,
                    amount: TransactionAmountParser.minorUnits(posting.amount) ?? 0,
                    currency: posting.currency
                )
            },
            editableEntry: entry,
            source: invalidatingSourceHash
                ? TransactionSource(file: source.file, line: source.line, hash: nil, gitSHA: nil)
                : source
        )
    }

    func represents(_ entry: LedgerTransactionEntry) -> Bool {
        if editableEntry == entry { return true }
        guard date == entry.date,
              payee == entry.payee,
              narration == entry.narration,
              metadata ?? [:] == entry.metadata,
              tags ?? [] == entry.tags,
              postings.count == entry.postings.count else { return false }

        return zip(postings, entry.postings).allSatisfy { posting, edited in
            posting.account == edited.account
                && posting.amount == TransactionAmountParser.minorUnits(edited.amount)
                && (posting.currency ?? "CNY") == edited.currency
        }
    }
}

private struct EditableTransactionPosting: Identifiable, Equatable {
    let id: UUID
    var account: String
    var amount: String
    var currency: String
    let flag: String?
    let costKind: String?
    let costAmount: String?
    let costCurrency: String?
    let costSpec: String?
    let priceKind: String?
    let priceAmount: String?
    let priceCurrency: String?

    init(
        id: UUID = UUID(),
        account: String,
        amount: String,
        currency: String,
        flag: String? = nil,
        costKind: String? = nil,
        costAmount: String? = nil,
        costCurrency: String? = nil,
        costSpec: String? = nil,
        priceKind: String? = nil,
        priceAmount: String? = nil,
        priceCurrency: String? = nil
    ) {
        self.id = id
        self.account = account
        self.amount = amount
        self.currency = currency
        self.flag = flag
        self.costKind = costKind
        self.costAmount = costAmount
        self.costCurrency = costCurrency
        self.costSpec = costSpec
        self.priceKind = priceKind
        self.priceAmount = priceAmount
        self.priceCurrency = priceCurrency
    }
}

private enum TransactionEditorError: LocalizedError {
    case payeeRequired
    case metadataInvalid
    case metadataKeyInvalid(String)
    case postingsRequired
    case accountRequired(Int)
    case amountInvalid(Int)
    case currencyInvalid(Int)

    var errorDescription: String? {
        switch self {
        case .payeeRequired: "请输入交易对方"
        case .metadataInvalid: "元数据需要使用 JSON 对象格式"
        case let .metadataKeyInvalid(key): "元数据键 \(key) 格式无效"
        case .postingsRequired: "交易至少需要两条分录"
        case let .accountRequired(index): "第 \(index + 1) 条分录缺少账户"
        case let .amountInvalid(index): "第 \(index + 1) 条分录金额格式无效"
        case let .currencyInvalid(index): "第 \(index + 1) 条分录币种格式无效"
        }
    }
}

private struct TransactionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let transaction: LedgerTransaction
    let accounts: [LedgerAccount]
    let commodities: [String]
    let onSave: (LedgerTransactionEntry) async throws -> Void

    @State private var date: Date
    @State private var payee: String
    @State private var narration: String
    @State private var tagsText: String
    @State private var metadataText: String
    @State private var postings: [EditableTransactionPosting]
    @State private var errorMessage: String?
    @State private var saving = false
    @FocusState private var keyboardFocused: Bool

    init(
        transaction: LedgerTransaction,
        accounts: [LedgerAccount],
        commodities: [String],
        onSave: @escaping (LedgerTransactionEntry) async throws -> Void
    ) {
        let baseline = transaction.editableEntry
        self.transaction = transaction
        self.accounts = accounts
        self.commodities = commodities
        self.onSave = onSave
        _date = State(initialValue: Self.parseDate(baseline?.date ?? transaction.date) ?? Date())
        _payee = State(initialValue: baseline?.payee ?? transaction.payee)
        _narration = State(initialValue: baseline?.narration ?? transaction.narration)
        _tagsText = State(initialValue: (baseline?.tags ?? transaction.tags ?? []).joined(separator: " "))
        _metadataText = State(initialValue: Self.metadataText(baseline?.metadata ?? transaction.metadata ?? [:]))
        _postings = State(initialValue: baseline?.postings.map {
            EditableTransactionPosting(
                account: $0.account,
                amount: $0.amount,
                currency: $0.currency,
                flag: $0.flag,
                costKind: $0.costKind,
                costAmount: $0.costAmount,
                costCurrency: $0.costCurrency,
                costSpec: $0.costSpec,
                priceKind: $0.priceKind,
                priceAmount: $0.priceAmount,
                priceCurrency: $0.priceCurrency
            )
        } ?? transaction.postings.map {
            EditableTransactionPosting(
                account: $0.account,
                amount: Self.decimalText($0.amount),
                currency: $0.currency ?? "CNY"
            )
        })
    }

    private var accountChoices: [LedgerAccount] {
        accounts.sorted { left, right in
            if left.active != right.active { return left.active && !right.active }
            return left.displayLabel.localizedStandardCompare(right.displayLabel) == .orderedAscending
        }
    }

    private var displayedTags: [String] {
        LedgerTagRules.normalized(
            tagsText.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，")))
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LedgerSpacing.xl) {
                    if let errorMessage {
                        StatusBanner(message: errorMessage) { self.errorMessage = nil }
                    }
                    transactionSection
                    tagsSection
                    postingsSection
                    metadataSection
                    HStack(alignment: .top, spacing: LedgerSpacing.sm) {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(LedgerPalette.cobalt)
                        Text("服务器会使用账本来源哈希检查并发修改，并在写入后校验 Beancount 语法。")
                            .font(.system(size: 11))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    .padding(.horizontal, LedgerSpacing.sm)
                }
                .padding(.horizontal, LedgerSpacing.lg)
                .padding(.vertical, LedgerSpacing.xl)
                .ledgerAdaptivePageWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(LedgerPalette.canvas)
            .navigationTitle("编辑交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(LedgerPalette.panel, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { keyboardFocused = false }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Rectangle().fill(LedgerPalette.line).frame(height: 1)
                    Button {
                        Task { await save() }
                    } label: {
                        PrimaryButtonLabel(title: "保存修改", loading: saving)
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .disabled(saving)
                    .accessibilityIdentifier("transaction-edit-save")
                    .padding(.horizontal, LedgerSpacing.lg)
                    .padding(.vertical, LedgerSpacing.md)
                }
                .background(LedgerPalette.panel)
            }
        }
        .interactiveDismissDisabled(saving)
        .privacySensitive()
    }

    private var transactionSection: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            SectionHeading(title: "交易信息", detail: "对应 Web 流水编辑字段")
            LedgerPanel {
                VStack(spacing: 0) {
                    editorTextField(title: "交易对方", placeholder: "输入商家或收付款对象", text: $payee, identifier: "transaction-edit-payee")
                    Divider().overlay(LedgerPalette.line).padding(.leading, LedgerSpacing.lg)
                    editorTextField(title: "说明", placeholder: "输入交易说明", text: $narration, identifier: "transaction-edit-narration")
                    Divider().overlay(LedgerPalette.line).padding(.leading, LedgerSpacing.lg)
                    HStack {
                        Text("日期")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LedgerPalette.ink)
                        Spacer()
                        DatePicker("日期", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                            .tint(LedgerPalette.cobalt)
                    }
                    .padding(.horizontal, LedgerSpacing.lg)
                    .frame(minHeight: 52)
                }
            }
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            SectionHeading(title: "标签", detail: "空格或逗号分隔，最多 50 个")
            LedgerPanel {
                VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                    TextField("travel, dining", text: $tagsText)
                        .font(.system(size: 14, weight: .medium))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($keyboardFocused)
                        .accessibilityIdentifier("transaction-edit-tags")
                    if !displayedTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(displayedTags, id: \.self) { tag in
                                    Text("#\(tag)")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(LedgerPalette.olive)
                                        .padding(.horizontal, 8)
                                        .frame(minHeight: 26)
                                        .background(LedgerPalette.tag)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(LedgerSpacing.lg)
            }
        }
    }

    private var postingsSection: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            HStack {
                SectionHeading(title: "分录", detail: "账户、金额与币种")
                Spacer()
                Button("添加分录") {
                    postings.append(EditableTransactionPosting(account: "", amount: "0.00", currency: commodities.first ?? "CNY"))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(minHeight: 40)
            }
            VStack(spacing: LedgerSpacing.md) {
                ForEach(postings.indices, id: \.self) { index in
                    postingEditor(index)
                }
            }
        }
    }

    private func postingEditor(_ index: Int) -> some View {
        LedgerPanel {
            VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                HStack {
                    Text("分录 \(index + 1)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                    Spacer()
                    if postings.count > 2 {
                        Button(role: .destructive) {
                            postings.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 40, height: 40)
                        }
                    }
                }
                TextField("Assets:Bank:Checking", text: $postings[index].account)
                    .font(.system(size: 13, weight: .medium).monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($keyboardFocused)
                    .accessibilityIdentifier("transaction-edit-posting-account-\(index)")
                Menu {
                    ForEach(accountChoices, id: \.account) { account in
                        Button {
                            postings[index].account = account.account
                        } label: {
                            Text("\(account.displayLabel) · \(account.account)")
                        }
                    }
                } label: {
                    Label("从账户列表选择", systemImage: "list.bullet")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerPalette.cobalt)
                        .frame(minHeight: 32)
                }
                HStack(spacing: LedgerSpacing.md) {
                    TextField("0.00", text: $postings[index].amount)
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .keyboardType(.numbersAndPunctuation)
                        .focused($keyboardFocused)
                        .accessibilityIdentifier("transaction-edit-posting-amount-\(index)")
                    TextField("CNY", text: $postings[index].currency)
                        .font(.system(size: 13, weight: .semibold).monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .frame(width: 72)
                        .focused($keyboardFocused)
                        .accessibilityIdentifier("transaction-edit-posting-currency-\(index)")
                }
            }
            .padding(LedgerSpacing.lg)
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            SectionHeading(title: "元数据", detail: "JSON 对象，与 Web 编辑器一致")
            LedgerPanel {
                TextEditor(text: $metadataText)
                    .font(.system(size: 12, weight: .medium).monospaced())
                    .frame(minHeight: 130)
                    .scrollContentBackground(.hidden)
                    .focused($keyboardFocused)
                    .accessibilityIdentifier("transaction-edit-metadata")
                    .padding(LedgerSpacing.md)
            }
        }
    }

    private func editorTextField(title: String, placeholder: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
            TextField(placeholder, text: text)
                .font(.system(size: 14, weight: .medium))
                .focused($keyboardFocused)
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, LedgerSpacing.lg)
        .padding(.vertical, LedgerSpacing.md)
    }

    private func save() async {
        guard !saving else { return }
        keyboardFocused = false
        do {
            let entry = try makeEntry()
            saving = true
            try await onSave(entry)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }

    private func makeEntry() throws -> LedgerTransactionEntry {
        let cleanedPayee = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPayee.isEmpty else { throw TransactionEditorError.payeeRequired }
        let tags = tagsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? []
            : try LedgerTagRules.parse(tagsText)
        let metadata = try Self.parseMetadata(metadataText)
        for key in metadata.keys where key.range(of: "^[a-z][a-zA-Z0-9_-]*$", options: .regularExpression) == nil {
            throw TransactionEditorError.metadataKeyInvalid(key)
        }
        guard postings.count >= 2 else { throw TransactionEditorError.postingsRequired }
        let cleanedPostings = try postings.enumerated().map { index, posting in
            let account = posting.account.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !account.isEmpty else { throw TransactionEditorError.accountRequired(index) }
            let amount = posting.amount.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawCurrency = posting.currency.trimmingCharacters(in: .whitespacesAndNewlines)
            if amount.isEmpty, rawCurrency.isEmpty {
                return LedgerTransactionEntryPosting(
                    account: account,
                    flag: posting.flag,
                    amount: "",
                    currency: "",
                    costKind: posting.costKind,
                    costAmount: posting.costAmount,
                    costCurrency: posting.costCurrency,
                    costSpec: posting.costSpec,
                    priceKind: posting.priceKind,
                    priceAmount: posting.priceAmount,
                    priceCurrency: posting.priceCurrency
                )
            }
            guard TransactionAmountParser.minorUnits(amount) != nil else { throw TransactionEditorError.amountInvalid(index) }
            let currency = rawCurrency.uppercased()
            guard currency.range(of: "^[A-Z][A-Z0-9._-]*$", options: .regularExpression) != nil else {
                throw TransactionEditorError.currencyInvalid(index)
            }
            return LedgerTransactionEntryPosting(
                account: account,
                flag: posting.flag,
                amount: amount,
                currency: currency,
                costKind: posting.costKind,
                costAmount: posting.costAmount,
                costCurrency: posting.costCurrency,
                costSpec: posting.costSpec,
                priceKind: posting.priceKind,
                priceAmount: posting.priceAmount,
                priceCurrency: posting.priceCurrency
            )
        }
        return LedgerTransactionEntry(
            date: Self.formatDate(date),
            flag: transaction.editableEntry?.flag,
            payee: cleanedPayee,
            narration: narration.trimmingCharacters(in: .whitespacesAndNewlines),
            metadata: metadata,
            tags: tags,
            links: transaction.editableEntry?.links ?? [],
            postings: cleanedPostings
        )
    }

    private static func decimalText(_ minorUnits: Int) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(minorUnits) / 100)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func metadataText(_ metadata: [String: LedgerMetadataValue]) -> String {
        guard !metadata.isEmpty,
              let data = try? JSONEncoder().encode(metadata),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(decoding: pretty, as: UTF8.self)
    }

    private static func parseMetadata(_ raw: String) throws -> [String: LedgerMetadataValue] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        do {
            return try JSONDecoder().decode([String: LedgerMetadataValue].self, from: Data(trimmed.utf8))
        } catch {
            throw TransactionEditorError.metadataInvalid
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
