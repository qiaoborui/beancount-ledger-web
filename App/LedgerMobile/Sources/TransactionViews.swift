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
    var accountLabels: [String: String] = [:]

    private var presentation: TransactionPresentation {
        TransactionPresentation(transaction: transaction)
    }

    var body: some View {
        HStack(spacing: LedgerSpacing.md) {
            Text(LedgerDateText.shortDate(transaction.date))
                .font(.system(.caption2, design: .default, weight: .medium).monospacedDigit())
                .foregroundStyle(LedgerPalette.secondary)
                .frame(width: 44, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(1)
                TransactionContextLine(transaction: transaction, accountLabels: accountLabels)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AmountLabel(
                minorUnits: presentation.minorUnits,
                currency: presentation.currency,
                prefix: amountPrefix(presentation.kind),
                font: .system(.footnote, design: .default, weight: .semibold),
                color: amountColor(presentation.kind)
            )
            .lineLimit(1)
        }
        .padding(.vertical, LedgerLayout.transactionVerticalInset)
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
    @State private var actionMessageStyle: LedgerStatusStyle = .failure
    @State private var confirmationFeedback = 0

    private var transactions: [LedgerTransaction] {
        session.visibleTransactions
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

    var isRoot = true

    private var groupedTransactions: [(date: String, transactions: [LedgerTransaction])] {
        Dictionary(grouping: filteredTransactions, by: \.date)
            .map { (date: $0.key, transactions: $0.value) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        let accountLabels = TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
        List {
            if activeStructuredFilterCount > 0 {
                Section {
                    TransactionFilterChips(filters: $filters)
                }
            }
            if let error = session.errorMessage {
                Section { StatusBanner(message: error, onDismiss: session.dismissError) }
            }
            if let actionMessage {
                Section {
                    StatusBanner(message: actionMessage, style: actionMessageStyle) { self.actionMessage = nil }
                }
            }
            if filteredTransactions.isEmpty {
                ContentUnavailableView(
                    filters.query.isEmpty && activeStructuredFilterCount == 0 ? "所选范围暂无流水" : "没有匹配的交易",
                    systemImage: "list.bullet.rectangle",
                    description: Text("调整时间范围或搜索条件。")
                )
            }
            ForEach(groupedTransactions, id: \.date) { group in
                Section {
                    ForEach(group.transactions) { transaction in
                        if selectingTags {
                            Button {
                                toggleTagSelection(transaction)
                            } label: {
                                TransactionSelectableCard(
                                    transaction: transaction,
                                    selected: selectedTransactionIDs.contains(transaction.id),
                                    accountLabels: accountLabels
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("transaction-select-row-\(transaction.source.line)")
                        } else {
                            NavigationLink {
                                TransactionDetailView(transaction: transaction)
                            } label: {
                                TransactionCard(
                                    transaction: transaction,
                                    accountLabels: accountLabels,
                                    mutationPhase: session.transactionMutationPhase(for: transaction)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("transaction-row-\(transaction.source.line)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    selectingTags = true
                                    toggleTagSelection(transaction)
                                } label: {
                                    Label("添加标签", systemImage: "tag")
                                }
                                .tint(LedgerPalette.cobalt)
                                .disabled(!isTagEligible(transaction))
                            }
                        }
                    }
                } header: {
                    Text(group.date)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .textCase(nil)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            if !filteredTransactions.isEmpty {
                Section {
                    Text("\(filteredTransactions.count) / \(transactions.count) 笔")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
        }
        .ledgerReadingList()
        .ledgerNavigation("流水", isRoot: isRoot, showsTimeRange: true)
        .searchable(text: $filters.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "收付款对象、说明、账户或标签")
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await session.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if selectingTags {
                    Button("完成") {
                        selectingTags = false
                        selectedTransactionIDs.removeAll()
                    }
                    .accessibilityLabel("完成标签选择")
                } else {
                    Menu {
                        Button("选择交易添加标签", systemImage: "checkmark.circle") {
                            selectingTags = true
                        }
                        .accessibilityIdentifier("transaction-tag-selection")
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("流水操作")
                    .accessibilityIdentifier("transaction-actions")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { filterPresented = true } label: {
                    Image(systemName: activeStructuredFilterCount > 0
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("筛选交易")
                .accessibilityValue("\(activeStructuredFilterCount) 个筛选条件")
            }
        }
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
        .sensoryFeedback(.success, trigger: confirmationFeedback)
    }

    private var allVisibleEligibleSelected: Bool {
        let eligible = filteredTransactions.filter(isTagEligible).prefix(TransactionTagSelectionRules.maximumCount)
        return !eligible.isEmpty && eligible.allSatisfy { selectedTransactionIDs.contains($0.id) }
    }

    private func isTagEligible(_ transaction: LedgerTransaction) -> Bool {
        transaction.source.hash?.isEmpty == false
            && session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites != true
    }

    private func toggleTagSelection(_ transaction: LedgerTransaction) {
        guard isTagEligible(transaction) else {
            actionMessageStyle = .failure
            actionMessage = "该交易缺少并发校验信息，请刷新后重试。"
            return
        }
        if selectedTransactionIDs.contains(transaction.id) {
            selectedTransactionIDs.remove(transaction.id)
        } else if selectedTransactionIDs.count < TransactionTagSelectionRules.maximumCount {
            selectedTransactionIDs.insert(transaction.id)
        } else {
            actionMessageStyle = .failure
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
                actionMessageStyle = .failure
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
        confirmationFeedback &+= 1
        actionMessageStyle = .confirmed
        actionMessage = "服务器已验证，并为 \(selected.count) 条交易添加标签。"
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
                .font(.system(.caption2, design: .default, weight: .semibold))
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
                    .font(.system(.caption2, design: .default, weight: .bold))
            }
            .font(.system(.caption2, design: .default, weight: .semibold))
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

struct TransactionContextLine: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let transaction: LedgerTransaction
    let accountLabels: [String: String]

    var body: some View {
        let category = TransactionCategoryPresentation(transaction: transaction, accountLabels: accountLabels).label
        let note = transaction.payee.isEmpty ? "" : transaction.narration
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 5))
        layout {
            Text(category)
                .foregroundStyle(LedgerPalette.olive)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .layoutPriority(1)
                .accessibilityIdentifier("transaction-category-\(transaction.source.line)")
            if !note.isEmpty {
                Text("· \(note)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let tags = transaction.tags, !tags.isEmpty {
                Image(systemName: "tag")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(tags.map { "#\($0)" }.joined(separator: " "))
            }
        }
        .font(.caption)
    }
}

private struct TransactionCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let transaction: LedgerTransaction
    let accountLabels: [String: String]
    let selectionState: Bool?
    let mutationPhase: LedgerTransactionMutationPhase?

    init(
        transaction: LedgerTransaction,
        accountLabels: [String: String] = [:],
        selectionState: Bool? = nil,
        mutationPhase: LedgerTransactionMutationPhase? = nil
    ) {
        self.transaction = transaction
        self.accountLabels = accountLabels
        self.selectionState = selectionState
        self.mutationPhase = mutationPhase
    }

    private var presentation: TransactionPresentation {
        TransactionPresentation(transaction: transaction)
    }

    private var headingLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headingLayout {
                Text(presentation.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AmountLabel(
                    minorUnits: presentation.minorUnits,
                    currency: presentation.currency,
                    prefix: amountPrefix(presentation.kind),
                    font: .subheadline.weight(.semibold),
                    color: amountColor(presentation.kind)
                )
                .lineLimit(1)
                .layoutPriority(1)
                .accessibilityIdentifier("transaction-card-amount-\(transaction.source.line)")

                if let selectionState {
                    Image(systemName: selectionState ? "checkmark.circle.fill" : "circle")
                        .font(.system(.title3, design: .default, weight: .semibold))
                        .foregroundStyle(selectionState ? LedgerPalette.cobalt : LedgerPalette.secondary)
                        .frame(width: 32, height: 32)
                        .accessibilityIdentifier("transaction-card-selection-\(transaction.source.line)")
                }
            }

            TransactionContextLine(transaction: transaction, accountLabels: accountLabels)

            if let mutationPhase {
                TransactionMutationBadge(phase: mutationPhase)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, LedgerLayout.transactionVerticalInset)
        .contentShape(Rectangle())
    }
}

private struct TransactionMutationBadge: View {
    let phase: LedgerTransactionMutationPhase

    private var presentation: (title: String, image: String, color: Color) {
        switch phase {
        case .pending: ("等待服务器确认", "clock.arrow.circlepath", LedgerPalette.cobalt)
        case .confirmed: ("服务器已确认 · 同步中", "checkmark.circle", LedgerPalette.success)
        case .failed: ("未保存 · 已恢复", "arrow.uturn.backward.circle", LedgerPalette.risk)
        }
    }

    var body: some View {
        Label(presentation.title, systemImage: presentation.image)
            .font(.system(.caption2, design: .default, weight: .semibold))
            .foregroundStyle(presentation.color)
            .accessibilityIdentifier("transaction-mutation-state")
    }
}

private struct TransactionSelectableCard: View {
    let transaction: LedgerTransaction
    let selected: Bool
    let accountLabels: [String: String]

    var body: some View {
        TransactionCard(transaction: transaction, accountLabels: accountLabels, selectionState: selected)
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
                .font(.system(.caption, design: .default, weight: .semibold))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(minWidth: 48, minHeight: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("已选 \(selectedCount) 条")
                    .font(.system(.caption, design: .default, weight: .semibold).monospacedDigit())
                    .foregroundStyle(LedgerPalette.ink)
                Text("当前可选 \(totalCount) 条")
                    .font(.system(.caption2, design: .default).monospacedDigit())
                    .foregroundStyle(LedgerPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("取消", action: onCancel)
                .font(.system(.caption, design: .default, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
                .frame(minHeight: 44)
            Button("添加标签", action: onAddTags)
                .font(.system(.footnote, design: .default, weight: .semibold))
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
                    .font(.system(.subheadline, design: .default, weight: .medium))
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
                        .font(.system(.caption2, design: .default, weight: .medium))
                        .foregroundStyle(LedgerPalette.expense)
                }
                Button {
                    Task { await apply() }
                } label: {
                    PrimaryButtonLabel(title: applying ? "正在验证标签" : "添加标签", loading: applying)
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
            errorMessage = "添加失败，已恢复服务器数据。请检查后重试：\(error.localizedDescription)"
        }
        applying = false
    }
}

struct TransactionDetailView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss

    @State private var transaction: LedgerTransaction
    @State private var editorPresented = false
    @State private var savedMessage: String?
    @State private var confirmationFeedback = 0
    @State private var confirmedEntry: LedgerTransactionEntry?
    @State private var confirmedSourceFile: String?
    @State private var sourceUnavailable = false

    init(transaction: LedgerTransaction) {
        _transaction = State(initialValue: transaction)
    }

    private var presentation: TransactionPresentation {
        TransactionPresentation(transaction: transaction)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(presentation.title).font(.headline)
                    if !presentation.subtitle.isEmpty {
                        Text(presentation.subtitle).foregroundStyle(.secondary)
                    }
                    AmountLabel(
                        minorUnits: presentation.minorUnits,
                        currency: presentation.currency,
                        prefix: amountPrefix(presentation.kind),
                        font: .title2.weight(.semibold),
                        color: amountColor(presentation.kind)
                    )
                }
                .padding(.vertical, 12)
                LabeledContent("日期", value: transaction.date)
            }
            Section("分录") {
                ForEach(Array(transaction.postings.enumerated()), id: \.offset) { _, posting in
                    NavigationLink {
                        AccountDetailView(account: posting.account, currency: posting.currency ?? presentation.currency)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(posting.account).font(.subheadline).foregroundStyle(.primary)
                            AmountLabel(
                                minorUnits: posting.amount,
                                currency: posting.currency ?? presentation.currency,
                                font: .body.weight(.medium)
                            )
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            if let tags = transaction.tags, !tags.isEmpty {
                Section("标签") {
                    Text(tags.map { "#\($0)" }.joined(separator: "  "))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section {
                DisclosureGroup("账本来源") {
                    Text(transaction.source.file).font(.footnote).textSelection(.enabled)
                    LabeledContent("行号", value: String(transaction.source.line))
                }
            }
            if let savedMessage {
                Section { StatusBanner(message: savedMessage, style: .confirmed) { self.savedMessage = nil } }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityHidden(sourceUnavailable)
        .background(LedgerPalette.canvas)
        .overlay {
            if sourceUnavailable {
                ContentUnavailableView {
                    Label("交易来源已变化", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("无法安全确认这仍是同一笔交易。服务器数据已保留，请返回流水列表重新打开。")
                } actions: {
                    Button("返回流水列表") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LedgerPalette.canvas)
            }
        }
        .navigationTitle("交易详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(LedgerPalette.panel, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { editorPresented = true }
                    .fontWeight(.semibold)
                    .disabled(
                        transaction.source.hash?.isEmpty != false
                            || transaction.editableEntry == nil
                            || sourceUnavailable
                            || session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites == true
                    )
                    .accessibilityIdentifier("transaction-edit")
            }
        }
        .sheet(isPresented: $editorPresented) {
            TransactionEditorView(
                transaction: transaction,
                accounts: session.ledger?.accounts ?? [],
                commodities: session.ledger?.commodities ?? [],
                onSave: { entry in
                    let sourceFile = transaction.source.file
                    try await session.updateTransaction(source: transaction.source, entry: entry)
                    confirmedEntry = entry
                    confirmedSourceFile = sourceFile
                    transaction = transaction.projecting(entry: entry)
                    synchronizeTransaction(with: session.ledger)
                    confirmationFeedback &+= 1
                    savedMessage = "服务器已验证并保存，正在同步最新账本版本。"
                }
            )
            .ledgerPrivacyProtectedSheet()
        }
        // Resolution reads the session, so observe values after @Published's willSet emission.
        .onChange(of: session.ledger?.transactions, initial: true) { _, _ in
            synchronizeTransaction(with: session.ledger)
        }
        .onChange(of: session.transactionMutationStates) { _, _ in
            synchronizeTransaction(with: session.ledger)
        }
        .sensoryFeedback(.success, trigger: confirmationFeedback)
    }

    private func synchronizeTransaction(with ledger: LedgerBootstrap?) {
        guard let ledger else { return }
        if case let .visible(resolved) = session.transactionResolution(for: transaction.source) {
            transaction = resolved
            sourceUnavailable = false
            return
        }
        if let confirmedEntry, let confirmedSourceFile {
            let matches = ledger.transactions.filter {
                $0.source.file == confirmedSourceFile && $0.represents(confirmedEntry)
            }
            if matches.count == 1 {
                transaction = matches[0]
                self.confirmedEntry = nil
                self.confirmedSourceFile = nil
                sourceUnavailable = false
                return
            }
        }
        sourceUnavailable = true
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

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section { StatusBanner(message: errorMessage) { self.errorMessage = nil } }
                }
                Section("交易信息") {
                    TextField("交易对方", text: $payee)
                        .focused($keyboardFocused)
                        .accessibilityIdentifier("transaction-edit-payee")
                    TextField("说明", text: $narration)
                        .focused($keyboardFocused)
                        .accessibilityIdentifier("transaction-edit-narration")
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                }
                Section {
                    TextField("空格或逗号分隔", text: $tagsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($keyboardFocused)
                        .accessibilityIdentifier("transaction-edit-tags")
                } header: {
                    Text("标签")
                } footer: {
                    Text("最多 50 个标签")
                }
                ForEach(postings.indices, id: \.self) { index in
                    Section("分录 \(index + 1)") {
                        NavigationLink {
                            LedgerAccountPicker(
                                title: "选择账户",
                                accounts: accountChoices.map {
                                    LedgerAccountChoice(account: $0.account, label: $0.displayLabel, group: $0.group, active: $0.active)
                                },
                                selection: $postings[index].account
                            )
                        } label: {
                            LabeledContent("账户", value: postings[index].account)
                                .font(.subheadline)
                        }
                        TextField("账户路径", text: $postings[index].account)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($keyboardFocused)
                            .accessibilityIdentifier("transaction-edit-posting-account-\(index)")
                        LabeledContent("金额") {
                            TextField("0.00", text: $postings[index].amount)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .keyboardType(.numbersAndPunctuation)
                                .focused($keyboardFocused)
                                .accessibilityIdentifier("transaction-edit-posting-amount-\(index)")
                        }
                        LabeledContent("币种") {
                            TextField("CNY", text: $postings[index].currency)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .focused($keyboardFocused)
                                .accessibilityIdentifier("transaction-edit-posting-currency-\(index)")
                        }
                        if postings.count > 2 {
                            Button("删除分录", role: .destructive) { postings.remove(at: index) }
                        }
                    }
                }
                Section {
                    Button("添加分录") {
                        postings.append(EditableTransactionPosting(account: "", amount: "0.00", currency: commodities.first ?? "CNY"))
                    }
                }
                Section {
                    DisclosureGroup("元数据") {
                        TextEditor(text: $metadataText)
                            .font(.footnote.monospaced())
                            .frame(minHeight: 130)
                            .focused($keyboardFocused)
                            .accessibilityIdentifier("transaction-edit-metadata")
                    }
                } footer: {
                    Text("保存时会检查分录平衡与账本格式。")
                }
            }
            .disabled(saving)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("编辑交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView("正在验证并保存") } else { Text("保存修改") }
                    }
                    .disabled(saving)
                    .accessibilityLabel(saving ? "正在验证并保存" : "保存修改")
                    .accessibilityIdentifier("transaction-edit-save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { keyboardFocused = false }
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .privacySensitive()
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
            errorMessage = "保存失败，已恢复服务器数据。请检查后重试：\(error.localizedDescription)"
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
