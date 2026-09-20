import SwiftUI
import UIKit

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

enum TransactionDateHeaderFormatter {
    private static let weekdaySymbols = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    static func format(_ dateString: String) -> String {
        guard let date = LedgerDateRange.parse(dateString) else { return dateString }
        let cal = LedgerDateRange.calendar
        let now = Date()

        let isToday = cal.isDateInToday(date)
        let isYesterday = cal.isDateInYesterday(date)

        let comp = cal.dateComponents([.year, .month, .day, .weekday], from: date)
        let currentYear = cal.component(.year, from: now)

        guard let month = comp.month, let day = comp.day, let weekday = comp.weekday,
              weekday >= 1 && weekday <= 7 else {
            return dateString
        }

        let weekdayStr = weekdaySymbols[weekday - 1]

        if isToday {
            return "今天 · \(month)月\(day)日"
        } else if isYesterday {
            return "昨天 · \(month)月\(day)日"
        } else if comp.year == currentYear {
            return "\(month)月\(day)日 · \(weekdayStr)"
        } else if let year = comp.year {
            return "\(year)年\(month)月\(day)日 · \(weekdayStr)"
        }
        return dateString
    }
}

struct TransactionRow: View {
    let transaction: LedgerTransaction
    var accountLabels: [String: String] = [:]

    private var presentation: TransactionPresentation {
        TransactionPresentation(transaction: transaction)
    }

    private var categoryVisual: TransactionVisualCategory {
        TransactionVisualCategory.resolve(
            transaction: transaction,
            presentation: presentation,
            accountLabels: accountLabels
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(categoryVisual.color.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: categoryVisual.iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(categoryVisual.color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(1)
                TransactionContextLine(transaction: transaction, accountLabels: accountLabels)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AmountLabel(
                minorUnits: presentation.minorUnits,
                currency: presentation.currency,
                prefix: amountPrefix(presentation.kind),
                font: .system(size: 15.5, weight: .semibold, design: .rounded),
                color: amountColor(presentation.kind)
            )
            .lineLimit(1)
        }
        .padding(.vertical, LedgerLayout.rowVerticalInset)
        .contentShape(Rectangle())
    }
}

extension View {
    func ledgerTransactionActions(_ transaction: LedgerTransaction) -> some View {
        modifier(LedgerTransactionActions(transaction: transaction))
    }
}

/// Copies the same human-readable fields shown in the ledger, without source or metadata.
enum LedgerTransactionCopySummary {
    static func text(for transaction: LedgerTransaction, accounts: [LedgerAccount], amountsVisible: Bool) -> String {
        let presentation = TransactionPresentation(transaction: transaction)
        let labels = TransactionCategoryPresentation.accountLabels(accounts)
        let amount = amountsVisible
            ? amountPrefix(presentation.kind) + MoneyText.format(minorUnits: presentation.minorUnits, currency: presentation.currency)
            : "金额已隐藏"
        var lines = [transaction.date, presentation.title]
        if !presentation.subtitle.isEmpty { lines.append(presentation.subtitle) }
        lines.append(amount)
        let accountNames = transaction.postings.map { labels[$0.account] ?? $0.account }
        lines.append(accountNames.joined(separator: " · "))
        if let tags = transaction.tags, !tags.isEmpty { lines.append(tags.map { "#" + $0 }.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }
}

private struct LedgerTransactionActions: ViewModifier {
    @EnvironmentObject private var session: LedgerSession
    let transaction: LedgerTransaction
    @State private var action: Action?
    @State private var confirmationFeedback = 0

    private enum Kind { case edit, tags, delete, share }
    private struct Action: Identifiable {
        let id = UUID()
        let kind: Kind
        let transaction: LedgerTransaction
    }

    private var resolved: LedgerTransaction? {
        guard session.phase == .ready, !session.privacyShielded,
              case let .visible(current) = session.transactionResolution(for: transaction.source) else { return nil }
        return current
    }

    private func canWrite(_ transaction: LedgerTransaction) -> Bool {
        transaction.source.hash?.isEmpty == false
            && session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites != true
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("分享交易", systemImage: "square.and.arrow.up") { present(.share) }
                    .disabled(resolved == nil)
                    .accessibilityIdentifier("transaction-context-share")
                Button("编辑", systemImage: "pencil") { present(.edit) }
                    .disabled(resolved.map { !canWrite($0) || $0.editableEntry == nil } ?? true)
                    .accessibilityIdentifier("transaction-context-edit")
                Button("复制摘要", systemImage: "doc.on.doc", action: copySummary)
                    .disabled(resolved == nil)
                    .accessibilityIdentifier("transaction-context-copy")
                Button("添加标签", systemImage: "tag") { present(.tags) }
                    .disabled(resolved.map { !canWrite($0) } ?? true)
                    .accessibilityIdentifier("transaction-context-tags")
                Divider()
                Button("删除", systemImage: "trash", role: .destructive) { present(.delete) }
                    .disabled(resolved.map { !canWrite($0) } ?? true)
                    .accessibilityIdentifier("transaction-context-delete")
            }
            .sheet(item: $action) { action in
                actionSheet(action).ledgerPrivacyProtectedSheet()
            }
            .sensoryFeedback(.success, trigger: confirmationFeedback)
    }

    @ViewBuilder
    private func actionSheet(_ action: Action) -> some View {
        switch action.kind {
        case .share:
            TransactionShareSheet(
                transactions: [action.transaction],
                currency: session.ledger?.valuationCurrency ?? "CNY",
                accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
            )
            .environmentObject(session)
        case .edit:
            TransactionEditorView(
                transaction: action.transaction,
                accounts: session.ledger?.accounts ?? [],
                commodities: session.ledger?.commodities ?? []
            ) { entry in
                try await session.updateTransaction(source: action.transaction.source, entry: entry)
                confirmationFeedback &+= 1
            }
        case .tags:
            TransactionTagEditorSheet(selectedCount: 1) { tags in
                try await session.addTransactionTags(sources: [action.transaction.source], tags: tags)
                confirmationFeedback &+= 1
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .delete:
            TransactionDeleteSheet(transaction: action.transaction) { confirmationFeedback &+= 1 }
        }
    }

    private func present(_ kind: Kind) {
        guard let current = resolved else { return }
        if kind != .share && !canWrite(current) { return }
        if case .edit = kind, current.editableEntry == nil { return }
        action = Action(kind: kind, transaction: current)
    }

    private func copySummary() {
        guard let current = resolved else { return }
        let text = LedgerTransactionCopySummary.text(
            for: current, accounts: session.ledger?.accounts ?? [], amountsVisible: session.amountsVisible
        )
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: [
            .localOnly: true,
            .expirationDate: Date().addingTimeInterval(120)
        ])
        confirmationFeedback &+= 1
    }
}

struct CookieTransactionFilterBar: View {
    let filteredCount: Int
    @Binding var kindFilter: TransactionKindFilter

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(TransactionKindFilter.allCases) { filter in
                    let isSelected = kindFilter == filter
                    Button {
                        LedgerFeedback.selection()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            kindFilter = filter
                        }
                    } label: {
                        Text(filter.title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.white : LedgerPalette.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected ? LedgerPalette.cobalt : Color(uiColor: .tertiarySystemFill),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
                    .accessibilityLabel("按\(filter.title)筛选")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            Spacer()

            Text("\(filteredCount) 笔")
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(LedgerPalette.secondary)
        }
        .padding(.vertical, 2)
    }
}


struct TransactionsView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var filters = LedgerTransactionFilter()
    @State private var filterPresented = false
    @State private var creatingTransaction = false
    @State private var duplicateTarget: LedgerTransaction?
    @State private var editingTarget: LedgerTransaction?
    @State private var deletionTarget: LedgerTransaction?
    @State private var isSelecting = false
    @State private var selectedTransactionIDs: Set<String> = []
    @State private var batchSharePresented = false
    @State private var singleShareTarget: LedgerTransaction?
    @State private var tagEditorPresented = false
    @State private var eventTagListPresented = false
    @State private var actionMessage: String?
    @State private var actionMessageStyle: LedgerStatusStyle = .failure
    @State private var confirmationFeedback = 0
    @State private var selectionFeedback = 0

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

    private var selectedTransactions: [LedgerTransaction] {
        filteredTransactions.filter { selectedTransactionIDs.contains($0.id) }
    }

    private var allVisibleSelected: Bool {
        !filteredTransactions.isEmpty && filteredTransactions.allSatisfy { selectedTransactionIDs.contains($0.id) }
    }

    private func toggleAllVisible() {
        if allVisibleSelected {
            selectedTransactionIDs.removeAll()
        } else {
            selectedTransactionIDs = Set(filteredTransactions.map(\.id))
        }
        selectionFeedback &+= 1
    }

    private func toggleSelection(_ transaction: LedgerTransaction) {
        LedgerFeedback.selection()
        if selectedTransactionIDs.contains(transaction.id) {
            selectedTransactionIDs.remove(transaction.id)
        } else {
            selectedTransactionIDs.insert(transaction.id)
        }
    }

    private var accountLabels: [String: String] {
        TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
    }

    private func groupExpense(for transactions: [LedgerTransaction]) -> Int {
        var total = 0
        for tx in transactions {
            let txExpense = tx.postings
                .filter { $0.account.hasPrefix("Expenses:") }
                .reduce(0) { $0 + $1.amount }
            total += txExpense
        }
        return max(0, total)
    }

    var body: some View {
        List {
            Section {
                CookieTransactionFilterBar(
                    filteredCount: filteredTransactions.count,
                    kindFilter: $filters.kind
                )
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if activeStructuredFilterCount > (filters.kind == .all ? 0 : 1) {
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
                        transactionRow(for: transaction)
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(TransactionDateHeaderFormatter.format(group.date))
                            .font(.system(.footnote, design: .rounded, weight: .semibold))
                            .foregroundStyle(LedgerPalette.ink)
                        Spacer()
                        let dayExpense = groupExpense(for: group.transactions)
                        if dayExpense > 0 {
                            HStack(spacing: 3) {
                                Text("支出")
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundStyle(LedgerPalette.secondary)
                                AmountLabel(
                                    minorUnits: dayExpense,
                                    currency: session.ledger?.valuationCurrency ?? "CNY",
                                    font: .system(size: 12, weight: .semibold, design: .rounded),
                                    color: LedgerPalette.secondary
                                )
                            }
                        }
                    }
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
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await session.refresh() }
        .toolbar {
            if session.isLocal {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("记一笔", systemImage: "plus") {
                        LedgerFeedback.light()
                        creatingTransaction = true
                    }
                    .accessibilityIdentifier("transaction-create-local")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button("完成") {
                        isSelecting = false
                        selectedTransactionIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                    .accessibilityLabel("完成多选")
                } else {
                    Menu {
                        Button {
                            filterPresented = true
                        } label: {
                            Label(
                                activeStructuredFilterCount > 0 ? "筛选交易 (\(activeStructuredFilterCount))" : "筛选交易",
                                systemImage: activeStructuredFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                            )
                        }

                        Button {
                            selectedTransactionIDs.removeAll()
                            isSelecting = true
                        } label: {
                            Label("多选流水", systemImage: "checkmark.circle")
                        }
                        .accessibilityIdentifier("transaction-tag-selection")

                        Button {
                            eventTagListPresented = true
                        } label: {
                            Label("事件与项目核算", systemImage: "tag")
                        }
                    } label: {
                        Image(systemName: activeStructuredFilterCount > 0 ? "ellipsis.circle.fill" : "ellipsis")
                    }
                    .accessibilityLabel("流水操作")
                    .accessibilityIdentifier("transaction-actions")
                }
            }
        }
            .sheet(isPresented: $creatingTransaction) {
                TransactionEditorView(accounts: session.ledger?.accounts ?? [], commodities: session.ledger?.commodities ?? []) { entry in
                    try await session.addLocalTransaction(entry)
                }
                .ledgerPrivacyProtectedSheet()
            }
            .sheet(item: $duplicateTarget) { transaction in
                TransactionEditorView(
                    accounts: session.ledger?.accounts ?? [],
                    commodities: session.ledger?.commodities ?? [],
                    prefillPayee: transaction.payee,
                    prefillNarration: transaction.narration,
                    prefillPostings: transaction.postings.map {
                        EditableTransactionPosting(
                            account: $0.account,
                            amount: TransactionEditorView.decimalText($0.amount),
                            currency: $0.currency ?? "CNY"
                        )
                    },
                    onSave: { entry in
                        try await session.addLocalTransaction(entry)
                        actionMessage = "已复制并记录新流水"
                        actionMessageStyle = .confirmed
                        confirmationFeedback &+= 1
                    }
                )
                .ledgerPrivacyProtectedSheet()
            }
            .sheet(item: $editingTarget) { transaction in
                TransactionEditorView(
                    transaction: transaction,
                    accounts: session.ledger?.accounts ?? [],
                    commodities: session.ledger?.commodities ?? [],
                    onSave: { entry in
                        try await session.updateTransaction(source: transaction.source, entry: entry)
                        actionMessage = "交易修改已保存"
                        actionMessageStyle = .confirmed
                        confirmationFeedback &+= 1
                    }
                )
                .ledgerPrivacyProtectedSheet()
            }
            .sheet(item: $deletionTarget) { transaction in
                TransactionDeleteSheet(transaction: transaction) {
                    actionMessage = "交易已从账本删除"
                    actionMessageStyle = .confirmed
                    confirmationFeedback &+= 1
                }
                .ledgerPrivacyProtectedSheet()
            }
            .sheet(isPresented: $filterPresented) {
                TransactionFilterSheet(
                    kind: $filters.kind,
                    account: $filters.account,
                    tags: $filters.tags,
                    accounts: availableAccounts,
                    availableTags: availableTags,
                    onDone: { filterPresented = false },
                    onOpenEventReports: { eventTagListPresented = true }
                )
                .ledgerPrivacyProtectedSheet()
            }
            .sheet(isPresented: $eventTagListPresented) {
                EventTagListView()
                    .ledgerPrivacyProtectedSheet()
            }
            .sheet(isPresented: $tagEditorPresented) {
                TransactionTagEditorSheet(
                    selectedCount: selectedTransactionIDs.count,
                    onApply: { tags in
                        try await applyTags(tags)
                    }
                )
                .ledgerPrivacyProtectedSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $batchSharePresented) {
                TransactionShareSheet(
                    transactions: selectedTransactions,
                    currency: session.ledger?.valuationCurrency ?? "CNY",
                    accountLabels: accountLabels
                )
                .environmentObject(session)
                .ledgerPrivacyProtectedSheet()
            }
            .sheet(item: $singleShareTarget) { tx in
                TransactionShareSheet(
                    transactions: [tx],
                    currency: session.ledger?.valuationCurrency ?? "CNY",
                    accountLabels: accountLabels
                )
                .environmentObject(session)
                .ledgerPrivacyProtectedSheet()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting {
                    TransactionBatchActionBar(
                        selectedCount: selectedTransactionIDs.count,
                        totalCount: filteredTransactions.count,
                        allSelected: allVisibleSelected,
                        onToggleAll: toggleAllVisible,
                        onAddTags: handleAddTags,
                        onShare: handleShare
                    )
                }
            }
            .onChange(of: transactions.map(\.id)) { _, ids in
                selectedTransactionIDs.formIntersection(ids)
            }
            .onChange(of: session.pendingTransactionFilter) { _, newFilter in
                if let newFilter {
                    filters = newFilter
                    session.pendingTransactionFilter = nil
                }
            }
            .onAppear {
                if let pending = session.pendingTransactionFilter {
                    filters = pending
                    session.pendingTransactionFilter = nil
                }
            }
        .sensoryFeedback(.success, trigger: confirmationFeedback)
        .sensoryFeedback(.selection, trigger: selectionFeedback)
    }

    @ViewBuilder
    private func transactionRow(for transaction: LedgerTransaction) -> some View {
        if isSelecting {
            let isSelected = selectedTransactionIDs.contains(transaction.id)
            Button {
                toggleSelection(transaction)
            } label: {
                TransactionSelectableCard(
                    transaction: transaction,
                    selected: isSelected,
                    accountLabels: accountLabels
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(isSelected ? LedgerPalette.cobalt.opacity(0.08) : LedgerPalette.canvas)
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
            .ledgerTransactionActions(transaction)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    LedgerFeedback.light()
                    singleShareTarget = transaction
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .tint(LedgerPalette.cobalt)

                if session.isLocal {
                    Button {
                        LedgerFeedback.light()
                        duplicateTarget = transaction
                    } label: {
                        Label("再记一笔", systemImage: "plus.square.on.square")
                    }
                    .tint(LedgerPalette.gold)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deletionTarget = transaction
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(transaction.source.hash?.isEmpty != false
                    || session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites == true)

                if session.isLocal && transaction.editableEntry != nil {
                    Button {
                        LedgerFeedback.light()
                        editingTarget = transaction
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(.orange)
                    .disabled(transaction.source.hash?.isEmpty != false
                        || session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites == true)
                }

                Button {
                    isSelecting = true
                    selectedTransactionIDs = [transaction.id]
                } label: {
                    Label("多选", systemImage: "checklist")
                }
                .tint(LedgerPalette.cobalt)
            }
        }
    }

    private func isTagEligible(_ transaction: LedgerTransaction) -> Bool {
        transaction.source.hash?.isEmpty == false
            && session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites != true
    }

    private func handleAddTags() {
        let eligible = selectedTransactions.filter(isTagEligible)
        if eligible.isEmpty {
            actionMessageStyle = .failure
            actionMessage = "所选交易缺少并发校验信息，暂无法添加标签。"
            return
        }
        if eligible.count > TransactionTagSelectionRules.maximumCount {
            actionMessageStyle = .failure
            actionMessage = "一次最多为 \(TransactionTagSelectionRules.maximumCount) 笔交易添加标签。"
            return
        }
        tagEditorPresented = true
    }

    private func handleShare() {
        guard !selectedTransactionIDs.isEmpty else { return }
        LedgerFeedback.light()
        batchSharePresented = true
    }

    private func applyTags(_ tags: [String]) async throws {
        let selected = transactions.filter { selectedTransactionIDs.contains($0.id) && isTagEligible($0) }
        guard !selected.isEmpty else { throw LedgerTagValidationError.empty }
        try await session.addTransactionTags(sources: selected.map(\.source), tags: tags)
        selectedTransactionIDs.removeAll()
        isSelecting = false
        confirmationFeedback &+= 1
        actionMessageStyle = .confirmed
        actionMessage = "已验证，并为 \(selected.count) 条交易添加标签。"
    }
}

/// Widget drill-down stays separate from the main list's time range and search state.
struct WidgetDayTransactionsView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    let day: String
    @State private var payload: LedgerBootstrap?
    @State private var loading = true
    @State private var errorMessage: String?

    private var transactions: [LedgerTransaction] {
        (payload?.transactions ?? []).filter {
            $0.date == day && LedgerTransactionFilter(kind: .expense).matches($0)
        }
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }
                }
            }
            if loading && payload == nil {
                ProgressView("正在读取当天支出")
            } else if transactions.isEmpty && errorMessage == nil {
                ContentUnavailableView("当天暂无支出", systemImage: "calendar", description: Text(day))
            }
            Section {
                ForEach(transactions) { transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction, snapshotOnly: true)
                    } label: {
                        TransactionCard(
                            transaction: transaction,
                            accountLabels: TransactionCategoryPresentation.accountLabels(payload?.accounts ?? [])
                        )
                    }
                    .accessibilityIdentifier("transaction-row-\(transaction.source.line)")
                }
            } header: {
                if !transactions.isEmpty { Text("全部支出 · \(transactions.count) 笔") }
            }
        }
        .ledgerReadingList()
        .navigationTitle("\(day) 支出")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .topBarLeading) { PrivacyToolbarButton() }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        errorMessage = nil
        do {
            let result = try await session.widgetDayLedger(day)
            try Task.checkCancellation()
            payload = result
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        loading = false
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
    var onOpenEventReports: (() -> Void)? = nil

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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("选择多个标签时，显示包含其中任一标签的交易。")
                        if let onOpenEventReports {
                            Button {
                                onDone()
                                onOpenEventReports()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chart.bar.doc.horizontal")
                                    Text("打开事件与项目独立核算看板")
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LedgerPalette.cobalt)
                            }
                            .padding(.top, 2)
                        }
                    }
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
            : AnyLayout(HStackLayout(spacing: 4))
        layout {
            Text(category)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LedgerPalette.olive)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .layoutPriority(1)
                .accessibilityIdentifier("transaction-category-\(transaction.source.line)")
            if !note.isEmpty {
                Text("· \(note)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let tags = transaction.tags, !tags.isEmpty {
                Image(systemName: "tag")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(tags.map { "#\($0)" }.joined(separator: " "))
            }
        }
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

    private var categoryVisual: TransactionVisualCategory {
        TransactionVisualCategory.resolve(
            transaction: transaction,
            presentation: presentation,
            accountLabels: accountLabels
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(categoryVisual.color.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: categoryVisual.iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(categoryVisual.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                headingLayout {
                    Text(presentation.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LedgerPalette.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AmountLabel(
                        minorUnits: presentation.minorUnits,
                        currency: presentation.currency,
                        prefix: amountPrefix(presentation.kind),
                        font: .system(size: 15.5, weight: .semibold, design: .rounded),
                        color: amountColor(presentation.kind)
                    )
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityIdentifier("transaction-card-amount-\(transaction.source.line)")

                    if let selectionState {
                        Image(systemName: selectionState ? "checkmark.circle.fill" : "circle")
                            .font(.system(.title3, design: .default, weight: .semibold))
                            .foregroundStyle(selectionState ? LedgerPalette.cobalt : LedgerPalette.secondary)
                            .frame(width: 28, height: 28)
                            .accessibilityIdentifier("transaction-card-selection-\(transaction.source.line)")
                    }
                }

                TransactionContextLine(transaction: transaction, accountLabels: accountLabels)

                if let mutationPhase {
                    TransactionMutationBadge(phase: mutationPhase)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, LedgerLayout.rowVerticalInset)
        .contentShape(Rectangle())
    }
}

private struct TransactionMutationBadge: View {
    let phase: LedgerTransactionMutationPhase

    private var presentation: (title: String, image: String, color: Color) {
        switch phase {
        case .pending: ("正在验证并保存", "clock.arrow.circlepath", LedgerPalette.cobalt)
        case .confirmed: ("已保存 · 正在更新", "checkmark.circle", LedgerPalette.success)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(selected ? "已选择" : "未选择")，\(transaction.payee)")
    }
}

private struct TransactionBatchActionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let allSelected: Bool
    let onToggleAll: () -> Void
    let onAddTags: () -> Void
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: LedgerSpacing.sm) {
            Button(allSelected ? "清空" : "全选") { onToggleAll() }
                .font(.system(.caption, design: .default, weight: .semibold))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(minWidth: 44, minHeight: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("已选 \(selectedCount) 笔")
                    .font(.system(.caption, design: .default, weight: .semibold).monospacedDigit())
                    .foregroundStyle(LedgerPalette.ink)
                Text("当前可选 \(totalCount) 笔")
                    .font(.system(.caption2, design: .default).monospacedDigit())
                    .foregroundStyle(LedgerPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onAddTags) {
                HStack(spacing: 3) {
                    Image(systemName: "tag")
                        .font(.system(size: 11, weight: .semibold))
                    Text("添加标签")
                }
            }
            .font(.system(.footnote, design: .default, weight: .semibold))
            .foregroundStyle(selectedCount > 0 ? LedgerPalette.cobalt : LedgerPalette.secondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 38)
            .background(LedgerPalette.cobalt.opacity(selectedCount > 0 ? 0.12 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
            .disabled(selectedCount == 0)
            .accessibilityIdentifier("transaction-bulk-tag-trigger")

            Button(action: onShare) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                    Text("合并分享")
                }
            }
            .font(.system(.footnote, design: .default, weight: .semibold))
            .foregroundStyle(LedgerPalette.onBrand)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(selectedCount > 0 ? LedgerPalette.cobalt : LedgerPalette.secondary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
            .disabled(selectedCount == 0)
            .accessibilityIdentifier("transaction-batch-share")
        }
        .buttonStyle(PressScaleButtonStyle())
        .padding(.horizontal, LedgerSpacing.lg)
        .padding(.vertical, LedgerSpacing.sm)
        .ledgerFloatingActionSurface()
    }
}

private struct TransactionTagEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selectedCount: Int
    let onApply: ([String]) async throws -> Void

    @State private var input = ""
    @State private var errorMessage: String?
    @State private var applying = false
    @State private var failureFeedback = 0

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
            .navigationTitle(selectedCount == 1 ? "添加标签" : "批量添加标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(applying)
                }
            }
        }
        .interactiveDismissDisabled(applying)
        .sensoryFeedback(.error, trigger: failureFeedback)
    }

    private func apply() async {
        guard !applying else { return }
        do {
            let tags = try LedgerTagRules.parse(input)
            applying = true
            try await onApply(tags)
            dismiss()
        } catch {
            errorMessage = "添加失败，已恢复原有显示。请检查后重试：\(error.localizedDescription)"
            failureFeedback &+= 1
        }
        applying = false
    }
}

struct ReceiptDashedLine: View {
    var body: some View {
        Line()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(LedgerPalette.line.opacity(0.7))
            .frame(height: 1)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
            return path
        }
    }
}

struct TransactionMoneyFlowLeg: Identifiable, Sendable {
    let id: String
    let account: String
    let label: String
    let iconName: String
    let iconColor: Color
    let amount: Int
    let currency: String
}

struct TransactionMoneyFlow: Sendable {
    let fromLegs: [TransactionMoneyFlowLeg]
    let toLegs: [TransactionMoneyFlowLeg]
    let totalAmount: Int
    let currency: String
    let isDirect1to1: Bool

    static func build(
        transaction: LedgerTransaction,
        accountLabels: [String: String],
        defaultCurrency: String
    ) -> TransactionMoneyFlow {
        let p = TransactionPresentation(transaction: transaction)
        let mainCurr = p.currency.isEmpty ? defaultCurrency : p.currency

        var outflows: [TransactionMoneyFlowLeg] = []
        var inflows: [TransactionMoneyFlowLeg] = []

        for (i, posting) in transaction.postings.enumerated() {
            let acct = posting.account
            let label = accountLabels[acct] ?? acct.split(separator: ":").last.map(String.init) ?? acct
            let visual = TransactionVisualCategory.resolve(account: acct, label: label)
            let curr = posting.currency ?? mainCurr
            let amt = abs(posting.amount)
            let leg = TransactionMoneyFlowLeg(
                id: "\(acct)-\(i)",
                account: acct,
                label: label,
                iconName: visual.iconName,
                iconColor: visual.color,
                amount: amt,
                currency: curr
            )

            if p.isRefund {
                if posting.amount < 0 {
                    outflows.append(leg)
                } else {
                    inflows.append(leg)
                }
            } else if p.kind == .income {
                if posting.amount < 0 {
                    outflows.append(leg)
                } else {
                    inflows.append(leg)
                }
            } else {
                if posting.amount < 0 {
                    outflows.append(leg)
                } else {
                    inflows.append(leg)
                }
            }
        }

        if outflows.isEmpty && !inflows.isEmpty {
            outflows = [inflows.removeFirst()]
        } else if inflows.isEmpty && !outflows.isEmpty {
            inflows = [outflows.removeFirst()]
        }

        let total = outflows.reduce(0) { $0 + $1.amount }
        let is1to1 = outflows.count == 1 && inflows.count == 1

        return TransactionMoneyFlow(
            fromLegs: outflows,
            toLegs: inflows,
            totalAmount: total > 0 ? total : p.minorUnits,
            currency: mainCurr,
            isDirect1to1: is1to1
        )
    }
}

struct TransactionMoneyFlowView: View {
    let flow: TransactionMoneyFlow
    var compact: Bool = false

    var body: some View {
        if flow.fromLegs.isEmpty && flow.toLegs.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerPalette.cobalt)
                    Text("资金流向")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                    Spacer()
                }

                if flow.isDirect1to1, let from = flow.fromLegs.first, let to = flow.toLegs.first {
                    direct1to1Flow(from: from, to: to)
                } else {
                    multiLegFlow
                }
            }
            .padding(compact ? 10 : 12)
            .background(Color(uiColor: .tertiarySystemGroupedBackground).opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func direct1to1Flow(from: TransactionMoneyFlowLeg, to: TransactionMoneyFlowLeg) -> some View {
        // ViewThatFits tries the horizontal layout first; if either account name is
        // too long to fit, it automatically falls back to the vertical stacked layout.
        ViewThatFits(in: .horizontal) {
            horizontalFlow(from: from, to: to)
            verticalFlow(from: from, to: to)
        }
    }

    private func horizontalFlow(from: TransactionMoneyFlowLeg, to: TransactionMoneyFlowLeg) -> some View {
        HStack(spacing: 6) {
            legBox(leg: from, title: "流出 / 来源", alignment: .leading)

            VStack(spacing: 3) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LedgerPalette.cobalt)

                Text(MoneyText.format(minorUnits: flow.totalAmount, currency: flow.currency))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(LedgerPalette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 68)

            legBox(leg: to, title: "流入 / 去向", alignment: .trailing)
        }
    }

    private func verticalFlow(from: TransactionMoneyFlowLeg, to: TransactionMoneyFlowLeg) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                iconBadge(leg: from)
                VStack(alignment: .leading, spacing: 1) {
                    Text("流出 / 来源")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                    Text(from.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(shortAccount(from.account))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LedgerPalette.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            HStack {
                Rectangle().fill(LedgerPalette.line.opacity(0.6)).frame(height: 0.5)
                VStack(spacing: 2) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LedgerPalette.cobalt)
                    Text(MoneyText.format(minorUnits: flow.totalAmount, currency: flow.currency))
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 6)
                Rectangle().fill(LedgerPalette.line.opacity(0.6)).frame(height: 0.5)
            }

            HStack(spacing: 8) {
                iconBadge(leg: to)
                VStack(alignment: .leading, spacing: 1) {
                    Text("流入 / 去向")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                    Text(to.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(shortAccount(to.account))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LedgerPalette.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
    }

    private func legBox(leg: TransactionMoneyFlowLeg, title: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(LedgerPalette.secondary)

            HStack(spacing: 6) {
                if alignment == .leading {
                    iconBadge(leg: leg)
                }

                VStack(alignment: alignment, spacing: 1) {
                    Text(leg.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(shortAccount(leg.account))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LedgerPalette.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if alignment == .trailing {
                    iconBadge(leg: leg)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func iconBadge(leg: TransactionMoneyFlowLeg) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(leg.iconColor.opacity(0.15))
                .frame(width: 28, height: 28)
            Image(systemName: leg.iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(leg.iconColor)
        }
    }

    private func shortAccount(_ acct: String) -> String {
        let parts = acct.split(separator: ":")
        if parts.count >= 2 {
            return parts.suffix(2).joined(separator: ":")
        }
        return acct
    }

    private var multiLegFlow: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("资金来源")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
                ForEach(flow.fromLegs) { leg in
                    legRow(leg: leg, isOutflow: true)
                }
            }

            HStack {
                Rectangle().fill(LedgerPalette.line.opacity(0.6)).frame(height: 0.5)
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LedgerPalette.cobalt)
                    .padding(.horizontal, 4)
                Rectangle().fill(LedgerPalette.line.opacity(0.6)).frame(height: 0.5)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("资金去向")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
                ForEach(flow.toLegs) { leg in
                    legRow(leg: leg, isOutflow: false)
                }
            }
        }
    }

    private func legRow(leg: TransactionMoneyFlowLeg, isOutflow: Bool) -> some View {
        HStack(spacing: 8) {
            iconBadge(leg: leg)
            VStack(alignment: .leading, spacing: 1) {
                Text(leg.label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(1)
                Text(shortAccount(leg.account))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(LedgerPalette.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text((isOutflow ? "-" : "+") + MoneyText.format(minorUnits: leg.amount, currency: leg.currency))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(isOutflow ? LedgerPalette.expense : LedgerPalette.income)
        }
    }
}

struct TransactionDetailView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss

    @State private var transaction: LedgerTransaction
    @State private var editorPresented = false
    @State private var deletionPresented = false
    @State private var duplicatePresented = false
    @State private var savedMessage: String?
    @State private var confirmationFeedback = 0
    @State private var confirmedEntry: LedgerTransactionEntry?
    @State private var confirmedSourceFile: String?
    @State private var sourceUnavailable = false
    @State private var sharePresented = false
    @State private var selectedEventTag: String?
    private let snapshotOnly: Bool

    init(transaction: LedgerTransaction, snapshotOnly: Bool = false) {
        _transaction = State(initialValue: transaction)
        self.snapshotOnly = snapshotOnly
    }

    private var presentation: TransactionPresentation {
        TransactionPresentation(transaction: transaction)
    }

    private var categoryVisual: TransactionVisualCategory {
        TransactionVisualCategory.resolve(
            transaction: transaction,
            presentation: presentation,
            accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let savedMessage {
                    StatusBanner(message: savedMessage, style: .confirmed) { self.savedMessage = nil }
                }

                if transaction.isPendingReview {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("待核对交易")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.orange)
                            Text(transaction.pendingReasons.map(\.label).joined(separator: " · "))
                                .font(.system(size: 12))
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // Cookie Receipt Voucher Card
                VStack(spacing: 16) {
                    // Category & Kind Header
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(categoryVisual.color.opacity(0.14))
                                .frame(width: 42, height: 42)
                            Image(systemName: categoryVisual.iconName)
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(categoryVisual.color)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(categoryVisual.categoryLabel)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(LedgerPalette.ink)
                            Text(transaction.date)
                                .font(.system(size: 12))
                                .foregroundStyle(LedgerPalette.secondary)
                        }

                        Spacer()

                        Text(kindBadgeText(presentation))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(amountColor(presentation.kind))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(amountColor(presentation.kind).opacity(0.12), in: Capsule())
                    }

                    // Hero Amount
                    VStack(spacing: 6) {
                        AmountLabel(
                            minorUnits: presentation.minorUnits,
                            currency: presentation.currency,
                            prefix: amountPrefix(presentation.kind),
                            font: .system(size: 36, weight: .bold, design: .rounded),
                            color: amountColor(presentation.kind)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                        Text(presentation.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(LedgerPalette.ink)
                            .multilineTextAlignment(.center)

                        if !presentation.subtitle.isEmpty {
                            Text(presentation.subtitle)
                                .font(.system(size: 14))
                                .foregroundStyle(LedgerPalette.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.vertical, 6)

                    // Receipt Dashed Divider
                    ReceiptDashedLine()
                        .frame(height: 1)
                        .padding(.horizontal, -4)

                    // Money Flow
                    let moneyFlow = TransactionMoneyFlow.build(
                        transaction: transaction,
                        accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? []),
                        defaultCurrency: session.ledger?.valuationCurrency ?? "CNY"
                    )
                    TransactionMoneyFlowView(flow: moneyFlow)

                    ReceiptDashedLine()
                        .frame(height: 1)
                        .padding(.horizontal, -4)

                    // Info Rows
                    VStack(spacing: 10) {
                        receiptInfoRow(title: "交易时间", value: TransactionDateHeaderFormatter.format(transaction.date))

                        if let tags = transaction.tags, !tags.isEmpty {
                            HStack(alignment: .center) {
                                Text("交易标签")
                                    .font(.system(size: 13))
                                    .foregroundStyle(LedgerPalette.secondary)
                                Spacer()
                                HStack(spacing: 4) {
                                    ForEach(tags, id: \.self) { tag in
                                        Button {
                                            selectedEventTag = tag
                                        } label: {
                                            HStack(spacing: 3) {
                                                Text("#\(tag)")
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 7, weight: .bold))
                                            }
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(LedgerPalette.cobalt)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(LedgerPalette.cobalt.opacity(0.1), in: Capsule())
                                        }
                                        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
                                    }
                                }
                            }
                        }
                    }
                }
                .ledgerFrostedCard(cornerRadius: 18, padding: 18)

                // Double Entry Breakdown Card
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("复式分录")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LedgerPalette.ink)
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                            Text("借贷平衡")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(LedgerPalette.success)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(LedgerPalette.success.opacity(0.12), in: Capsule())
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(transaction.postings.enumerated()), id: \.offset) { index, posting in
                            NavigationLink {
                                AccountDetailView(account: posting.account, currency: posting.currency ?? presentation.currency)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(accountLabel(posting.account))
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(LedgerPalette.ink)
                                        if accountLabel(posting.account) != posting.account {
                                            Text(posting.account)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(LedgerPalette.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    AmountLabel(
                                        minorUnits: posting.amount,
                                        currency: posting.currency ?? presentation.currency,
                                        font: .system(size: 14.5, weight: .semibold, design: .rounded),
                                        color: posting.amount >= 0 ? LedgerPalette.ink : LedgerPalette.expense
                                    )
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(LedgerPalette.secondary)
                                }
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(PressScaleButtonStyle())

                            if index < transaction.postings.count - 1 {
                                Divider().overlay(LedgerPalette.line.opacity(0.5))
                            }
                        }
                    }
                }
                .ledgerFrostedCard(cornerRadius: 18, padding: 18)

                // Ledger File Source Card
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("来源文件", value: transaction.source.file)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        LabeledContent("行号", value: String(transaction.source.line))
                            .font(.system(size: 12))
                        if let h = transaction.source.hash, !h.isEmpty {
                            LabeledContent("哈希指纹", value: String(h.prefix(12)))
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 12))
                        Text("账本源码来源")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(LedgerPalette.secondary)
                }
                .ledgerFrostedCard(cornerRadius: 14, padding: 14)

                // Bottom Action Buttons
                if !snapshotOnly {
                    HStack(spacing: 12) {
                        // Share Receipt Button
                        Button {
                            LedgerFeedback.light()
                            sharePresented = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(LedgerPalette.cobalt)
                                .frame(width: 46, height: 46)
                                .background(LedgerPalette.cobalt.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .accessibilityLabel("分享记账凭证")

                        // Duplicate ("再记一笔")
                        Button {
                            LedgerFeedback.light()
                            duplicatePresented = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.square.on.square")
                                Text("再记一笔")
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(LedgerPalette.cobalt)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(LedgerPalette.cobalt.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressScaleButtonStyle())

                        // Edit
                        Button {
                            LedgerFeedback.light()
                            editorPresented = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "pencil")
                                Text("编辑交易")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(LedgerPalette.cobalt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .disabled(
                            transaction.source.hash?.isEmpty != false
                                || transaction.editableEntry == nil
                                || sourceUnavailable
                                || session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites == true
                        )
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, LedgerSpacing.lg)
            .padding(.vertical, LedgerSpacing.md)
            .ledgerAdaptivePageWidth()
        }
        .background(LedgerPalette.canvas)
        .accessibilityHidden(sourceUnavailable)
        .overlay {
            if sourceUnavailable {
                ContentUnavailableView {
                    Label("交易来源已变化", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("交易版本已变化。账本原数据已保留，请返回流水列表重新打开。")
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    LedgerFeedback.light()
                    sharePresented = true
                } label: {
                    Label("分享凭证", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("transaction-share")
            }
            if !snapshotOnly {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { deletionPresented = true } label: {
                        Label("删除交易", systemImage: "trash")
                    }
                    .disabled(transaction.source.hash?.isEmpty != false || sourceUnavailable
                        || session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites == true)
                    .accessibilityIdentifier("transaction-delete")
                }
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
        }
        .sheet(isPresented: $sharePresented) {
            TransactionShareSheet(
                transactions: [transaction],
                currency: session.ledger?.valuationCurrency ?? presentation.currency,
                accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
            )
            .environmentObject(session)
            .ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: $deletionPresented) {
            TransactionDeleteSheet(transaction: transaction) { dismiss() }
                .ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: $duplicatePresented) {
            TransactionEditorView(
                accounts: session.ledger?.accounts ?? [],
                commodities: session.ledger?.commodities ?? [],
                prefillPayee: transaction.payee,
                prefillNarration: transaction.narration,
                prefillPostings: transaction.postings.map {
                    EditableTransactionPosting(
                        account: $0.account,
                        amount: TransactionEditorView.decimalText($0.amount),
                        currency: $0.currency ?? "CNY"
                    )
                },
                onSave: { entry in
                    try await session.addLocalTransaction(entry)
                }
            )
            .ledgerPrivacyProtectedSheet()
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
                    savedMessage = "已验证并保存，正在更新账本。"
                }
            )
            .ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: Binding(
            get: { selectedEventTag != nil },
            set: { if !$0 { selectedEventTag = nil } }
        )) {
            if let tag = selectedEventTag {
                NavigationStack {
                    EventTagReportView(tag: tag)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("关闭") { selectedEventTag = nil }
                            }
                        }
                }
                .ledgerPrivacyProtectedSheet()
            }
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

    private func receiptInfoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(LedgerPalette.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LedgerPalette.ink)
        }
    }

    private func kindBadgeText(_ presentation: TransactionPresentation) -> String {
        if presentation.isRefund {
            return "退款"
        }
        switch presentation.kind {
        case .expense: return "支出"
        case .income: return "收入"
        case .transfer: return "转账"
        }
    }

    private func accountLabel(_ path: String) -> String {
        session.ledger?.accounts.first(where: { $0.account == path })?.displayLabel ?? path
    }

    private func synchronizeTransaction(with ledger: LedgerBootstrap?) {
        guard !snapshotOnly, let ledger else { return }
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

private struct TransactionDeleteSheet: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    let transaction: LedgerTransaction
    let onDeleted: () -> Void
    @State private var reason = ""
    @State private var isDeleting = false
    @State private var failureFeedback = 0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TransactionRow(transaction: transaction)
                } header: {
                    Text("确认删除这笔交易")
                } footer: {
                    Text("确认后从流水和统计中移除，原交易会作为注释保留在账本文件中。")
                }
                Section("删除原因（可选）") {
                    TextField("例如：重复导入", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                }
                if let errorMessage {
                    Section { StatusBanner(message: errorMessage) { self.errorMessage = nil } }
                }
                Section {
                    Button(role: .destructive) {
                        isDeleting = true
                        errorMessage = nil
                        Task {
                            do {
                                try await session.deleteTransaction(
                                    source: transaction.source,
                                    reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)
                                )
                                dismiss()
                                onDeleted()
                            } catch {
                                errorMessage = error.localizedDescription
                                failureFeedback &+= 1
                            }
                            isDeleting = false
                        }
                    } label: {
                        HStack {
                            Label("确认删除", systemImage: "trash")
                            if isDeleting { Spacer(); ProgressView() }
                        }
                    }
                    .accessibilityIdentifier("transaction-delete-confirm")
                }
            }
            .disabled(isDeleting)
            .navigationTitle("删除交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isDeleting)
                }
            }
        }
        .interactiveDismissDisabled(isDeleting)
        .sensoryFeedback(.error, trigger: failureFeedback)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct EditableTransactionPosting: Identifiable, Equatable {
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

// MARK: - Cookie Fast Bookkeeping Components

enum CookieEntryKind: String, CaseIterable, Identifiable {
    case expense = "支出"
    case income = "收入"
    case transfer = "转账"

    var id: String { rawValue }

    var themeColor: Color {
        switch self {
        case .expense: LedgerPalette.expense
        case .income: LedgerPalette.income
        case .transfer: LedgerPalette.cobalt
        }
    }
}

struct CookieCategoryItem: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let color: Color
    let defaultAccountPrefix: String

    static let expenseCategories: [CookieCategoryItem] = [
        CookieCategoryItem(id: "food", name: "餐饮", icon: "fork.knife", color: Color(red: 0.96, green: 0.55, blue: 0.18), defaultAccountPrefix: "Expenses:Food"),
        CookieCategoryItem(id: "transport", name: "交通", icon: "car.fill", color: Color(red: 0.16, green: 0.54, blue: 0.95), defaultAccountPrefix: "Expenses:Transport"),
        CookieCategoryItem(id: "shopping", name: "购物", icon: "bag.fill", color: Color(red: 0.92, green: 0.32, blue: 0.55), defaultAccountPrefix: "Expenses:Shopping"),
        CookieCategoryItem(id: "daily", name: "居家日常", icon: "house.fill", color: Color(red: 0.12, green: 0.66, blue: 0.72), defaultAccountPrefix: "Expenses:Housing"),
        CookieCategoryItem(id: "digital", name: "数码电子", icon: "antenna.radiowaves.left.and.right", color: Color(red: 0.35, green: 0.45, blue: 0.88), defaultAccountPrefix: "Expenses:Digital"),
        CookieCategoryItem(id: "entertainment", name: "休闲娱乐", icon: "popcorn.fill", color: Color(red: 0.65, green: 0.36, blue: 0.88), defaultAccountPrefix: "Expenses:Entertainment"),
        CookieCategoryItem(id: "health", name: "医疗健康", icon: "heart.fill", color: Color(red: 0.92, green: 0.28, blue: 0.28), defaultAccountPrefix: "Expenses:Health"),
        CookieCategoryItem(id: "education", name: "学习提升", icon: "book.fill", color: Color(red: 0.72, green: 0.48, blue: 0.28), defaultAccountPrefix: "Expenses:Education"),
        CookieCategoryItem(id: "other", name: "其它支出", icon: "cart.fill", color: Color(red: 0.95, green: 0.45, blue: 0.22), defaultAccountPrefix: "Expenses:Other")
    ]

    static let incomeCategories: [CookieCategoryItem] = [
        CookieCategoryItem(id: "salary", name: "工资薪水", icon: "banknote.fill", color: Color(red: 0.12, green: 0.68, blue: 0.36), defaultAccountPrefix: "Income:Salary"),
        CookieCategoryItem(id: "investment", name: "理财收益", icon: "chart.line.uptrend.xyaxis", color: Color(red: 0.08, green: 0.68, blue: 0.55), defaultAccountPrefix: "Income:Investment"),
        CookieCategoryItem(id: "bonus", name: "奖金福利", icon: "gift.fill", color: Color(red: 0.92, green: 0.28, blue: 0.28), defaultAccountPrefix: "Income:Bonus"),
        CookieCategoryItem(id: "reimbursement", name: "报销返还", icon: "arrow.uturn.left.circle.fill", color: Color(red: 0.16, green: 0.54, blue: 0.95), defaultAccountPrefix: "Income:Reimbursement"),
        CookieCategoryItem(id: "other_income", name: "其它收入", icon: "arrow.down.circle.fill", color: Color(red: 0.12, green: 0.68, blue: 0.36), defaultAccountPrefix: "Income:Other")
    ]
}

struct CookieKeypadCalculator {
    private(set) var expression: String = "0"

    var displayText: String {
        expression.isEmpty ? "0" : expression
    }

    var pendingOperation: String? {
        if let lastOpIndex = expression.lastIndex(where: { $0 == "+" || $0 == "-" }),
           lastOpIndex != expression.startIndex {
            return String(expression[lastOpIndex])
        }
        return nil
    }

    var evaluatedResult: Decimal? {
        evaluate(expression)
    }

    var isCalculationPending: Bool {
        guard pendingOperation != nil else { return false }
        let parts = expression.components(separatedBy: CharacterSet(charactersIn: "+-"))
        return parts.count >= 2 && !(parts.last?.isEmpty ?? true)
    }

    mutating func appendDigit(_ digit: String) {
        if expression == "0" && digit != "." {
            expression = digit
        } else {
            if digit == "." {
                let currentNumberPart = expression.components(separatedBy: CharacterSet(charactersIn: "+-")).last ?? ""
                if currentNumberPart.contains(".") { return }
                if currentNumberPart.isEmpty {
                    expression += "0."
                    return
                }
            } else {
                let currentNumberPart = expression.components(separatedBy: CharacterSet(charactersIn: "+-")).last ?? ""
                if let dotIndex = currentNumberPart.firstIndex(of: ".") {
                    let decimals = currentNumberPart[currentNumberPart.index(after: dotIndex)...]
                    if decimals.count >= 2 { return }
                }
            }
            expression += digit
        }
    }

    mutating func appendOperator(_ op: String) {
        guard !expression.isEmpty else { return }
        if let last = expression.last, last == "+" || last == "-" {
            expression.removeLast()
            expression.append(contentsOf: op)
            return
        }
        if isCalculationPending, let result = evaluatedResult {
            expression = formatDecimal(result) + op
        } else {
            expression += op
        }
    }

    mutating func deleteLast() {
        if expression.count <= 1 {
            expression = "0"
        } else {
            expression.removeLast()
            if expression.isEmpty {
                expression = "0"
            }
        }
    }

    mutating func clear() {
        expression = "0"
    }

    mutating func evaluateToResult() {
        if let result = evaluatedResult {
            expression = formatDecimal(result)
        }
    }

    private func evaluate(_ expr: String) -> Decimal? {
        var trimmed = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("+") || trimmed.hasSuffix("-") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else { return nil }

        var tokens: [String] = []
        var currentToken = ""
        for (idx, char) in trimmed.enumerated() {
            if (char == "+" || char == "-") && idx > 0 {
                tokens.append(currentToken)
                tokens.append(String(char))
                currentToken = ""
            } else {
                currentToken.append(char)
            }
        }
        if !currentToken.isEmpty { tokens.append(currentToken) }

        guard !tokens.isEmpty, let firstDecimal = Decimal(string: tokens[0], locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        var total = firstDecimal
        var i = 1
        while i + 1 < tokens.count {
            let op = tokens[i]
            if let val = Decimal(string: tokens[i + 1], locale: Locale(identifier: "en_US_POSIX")) {
                if op == "+" { total += val }
                else if op == "-" { total -= val }
            }
            i += 2
        }
        return total
    }

    private func formatDecimal(_ dec: Decimal) -> String {
        let number = NSDecimalNumber(decimal: dec)
        let handler = NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 2,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        let rounded = number.rounding(accordingToBehavior: handler)
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.decimalSeparator = "."
        formatter.groupingSeparator = ""
        formatter.numberStyle = .decimal
        return formatter.string(from: rounded) ?? "\(rounded)"
    }
}

struct CookieKeypadView: View {
    @Binding var calculator: CookieKeypadCalculator
    let actionTitle: String
    let actionColor: Color
    let saving: Bool
    let onCommit: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                keypadButton("7") { calculator.appendDigit("7") }
                keypadButton("8") { calculator.appendDigit("8") }
                keypadButton("9") { calculator.appendDigit("9") }
                keypadDeleteButton()
            }
            HStack(spacing: 6) {
                keypadButton("4") { calculator.appendDigit("4") }
                keypadButton("5") { calculator.appendDigit("5") }
                keypadButton("6") { calculator.appendDigit("6") }
                keypadOperatorButton("+") { calculator.appendOperator("+") }
            }
            HStack(spacing: 6) {
                keypadButton("1") { calculator.appendDigit("1") }
                keypadButton("2") { calculator.appendDigit("2") }
                keypadButton("3") { calculator.appendDigit("3") }
                keypadOperatorButton("-") { calculator.appendOperator("-") }
            }
            HStack(spacing: 6) {
                keypadButton(".") { calculator.appendDigit(".") }
                keypadButton("0") { calculator.appendDigit("0") }
                keypadButton("=") { calculator.evaluateToResult() }
                keypadActionButton()
            }
        }
        .padding(.horizontal, LedgerSpacing.md)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func keypadButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            LedgerFeedback.selection()
            action()
        } label: {
            Text(label)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(LedgerPalette.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(LedgerPalette.panel)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityIdentifier("keypad-\(label)")
    }

    private func keypadOperatorButton(_ op: String, action: @escaping () -> Void) -> some View {
        Button {
            LedgerFeedback.selection()
            action()
        } label: {
            Text(op)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color(uiColor: .tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityIdentifier("keypad-op-\(op)")
    }

    private func keypadDeleteButton() -> some View {
        Button {
            LedgerFeedback.selection()
            calculator.deleteLast()
        } label: {
            Image(systemName: "delete.backward")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(LedgerPalette.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color(uiColor: .tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                LedgerFeedback.medium()
                calculator.clear()
            }
        )
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityIdentifier("keypad-delete")
    }

    private func keypadActionButton() -> some View {
        Button(action: onCommit) {
            ZStack {
                if saving {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(actionTitle)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(actionColor)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: actionColor.opacity(0.35), radius: 4, x: 0, y: 2)
        }
        .disabled(saving)
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityIdentifier("fast-entry-save-button")
    }
}

struct CookieFastTransactionEditorBody: View {
    @EnvironmentObject private var session: LedgerSession
    @State private var preparedBookkeeping: PreparedBookkeepingChange?
    @State private var naturalLanguagePresented = false
    @Environment(\.dismiss) private var dismiss

    let transaction: LedgerTransaction?
    let accounts: [LedgerAccount]
    let commodities: [String]
    let initialDate: Date
    let initialPayee: String
    let initialNarration: String
    let initialTags: String
    let initialPostings: [EditableTransactionPosting]
    let onSave: (LedgerTransactionEntry) async throws -> Void
    let onSwitchToAdvanced: (Date, String, String, [EditableTransactionPosting]) -> Void

    @State private var kind: CookieEntryKind = .expense
    @State private var calculator = CookieKeypadCalculator()
    @State private var selectedCategoryID: String = "food"
    @State private var customExpenseAccount: String?
    @State private var customIncomeAccount: String?

    @State private var assetAccount: String = ""
    @State private var transferSourceAccount: String = ""
    @State private var transferTargetAccount: String = ""

    @State private var date: Date = Date()
    @State private var payee: String = ""
    @State private var narration: String = ""
    @State private var tagsText: String = ""
    @State private var selectedCurrency: String = "CNY"

    private enum FocusedField: Hashable {
        case payee
        case narration
    }
    @FocusState private var focusedField: FocusedField?

    // Multi-posting / Split mode
    @State private var isSplitMode: Bool = false
    @State private var splitPostings: [EditableTransactionPosting] = []
    @State private var activePostingIndex: Int = 0

    @State private var saving = false
    @State private var errorMessage: String?
    @State private var activeAccountPickerPurpose: AccountPickerPurpose?
    @State private var showDatePickerSheet = false
    @State private var failureFeedback = 0

    private var currentCategoryDisplayName: String {
        if kind == .expense {
            if let custom = customExpenseAccount, !custom.isEmpty {
                return accounts.first(where: { $0.account == custom })?.displayLabel ?? custom.components(separatedBy: ":").last ?? custom
            }
            if let item = CookieCategoryItem.expenseCategories.first(where: { $0.id == selectedCategoryID }) {
                return item.name
            }
            return "支出分类"
        } else if kind == .income {
            if let custom = customIncomeAccount, !custom.isEmpty {
                return accounts.first(where: { $0.account == custom })?.displayLabel ?? custom.components(separatedBy: ":").last ?? custom
            }
            if let item = CookieCategoryItem.incomeCategories.first(where: { $0.id == selectedCategoryID }) {
                return item.name
            }
            return "收入分类"
        }
        return "分类"
    }

    private enum AccountPickerPurpose: Identifiable, Equatable {
        case funding
        case transferSource
        case transferTarget
        case customCategory
        case splitPosting(Int)

        var id: String {
            switch self {
            case .funding: return "funding"
            case .transferSource: return "transferSource"
            case .transferTarget: return "transferTarget"
            case .customCategory: return "customCategory"
            case .splitPosting(let idx): return "splitPosting_\(idx)"
            }
        }
    }

    private var availableCurrencies: [String] {
        var list = ["CNY", "USD", "EUR", "HKD", "JPY", "GBP"]
        for c in commodities where !list.contains(c) && !c.isEmpty {
            list.append(c)
        }
        if !list.contains(selectedCurrency) && !selectedCurrency.isEmpty {
            list.append(selectedCurrency)
        }
        return list
    }

    static func currencySymbol(for code: String) -> String {
        switch code {
        case "CNY", "RMB": return "¥"
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "HKD": return "HK$"
        case "JPY": return "¥"
        default: return code
        }
    }

    private var activePostings: [EditableTransactionPosting] {
        if isSplitMode {
            return splitPostings
        }
        let amt = calculator.displayText.replacingOccurrences(of: "-", with: "")
        let amtStr = (amt.isEmpty || amt == "0") ? "0.00" : amt
        let negAmtStr = "-\(amtStr)"
        switch kind {
        case .expense:
            return [
                EditableTransactionPosting(account: resolveExpenseAccount(), amount: amtStr, currency: selectedCurrency),
                EditableTransactionPosting(account: assetAccount, amount: negAmtStr, currency: selectedCurrency)
            ]
        case .income:
            return [
                EditableTransactionPosting(account: resolveIncomeAccount(), amount: negAmtStr, currency: selectedCurrency),
                EditableTransactionPosting(account: assetAccount, amount: amtStr, currency: selectedCurrency)
            ]
        case .transfer:
            return [
                EditableTransactionPosting(account: transferTargetAccount, amount: amtStr, currency: selectedCurrency),
                EditableTransactionPosting(account: transferSourceAccount, amount: negAmtStr, currency: selectedCurrency)
            ]
        }
    }

    private var currentCategories: [CookieCategoryItem] {
        kind == .income ? CookieCategoryItem.incomeCategories : CookieCategoryItem.expenseCategories
    }

    private var activeAccounts: [LedgerAccount] {
        accounts.filter(\.active)
    }

    private var assetAccounts: [LedgerAccount] {
        let matching = activeAccounts.filter {
            $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:CN:CreditCard") || $0.account.hasPrefix("Liabilities:CreditCard")
        }
        return matching.isEmpty ? activeAccounts : matching
    }

    private var expenseAccounts: [LedgerAccount] {
        activeAccounts.filter { $0.account.hasPrefix("Expenses:") }
    }

    private var incomeAccounts: [LedgerAccount] {
        activeAccounts.filter { $0.account.hasPrefix("Income:") }
    }

    private var splitBalanceSum: Decimal {
        splitPostings.reduce(Decimal.zero) { sum, p in
            sum + (Decimal(string: p.amount) ?? Decimal.zero)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let errorMessage {
                    StatusBanner(message: errorMessage) { self.errorMessage = nil }
                        .padding(.horizontal, LedgerSpacing.md)
                        .padding(.top, LedgerSpacing.xs)
                }

                if transaction == nil {
                    Button {
                        LedgerFeedback.light()
                        naturalLanguagePresented = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(LedgerPalette.cobalt)
                            Text("用一句话记账")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(LedgerPalette.ink)
                        }
                        .padding(.horizontal, LedgerSpacing.md)
                        .padding(.vertical, 6)
                        .background(LedgerPalette.panel)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(LedgerPalette.cobalt.opacity(0.35), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bookkeeping-natural-entry")
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                }
                typeSwitcher
                    .padding(.horizontal, LedgerSpacing.lg)
                    .padding(.top, LedgerSpacing.xs)
                    .padding(.bottom, LedgerSpacing.sm)

                heroAmountDisplay
                    .padding(.horizontal, LedgerSpacing.lg)
                    .padding(.bottom, LedgerSpacing.xs)

                if isSplitMode {
                    splitPostingsView
                        .frame(maxHeight: .infinity)
                } else if kind == .transfer {
                    transferRouteCard
                        .padding(.horizontal, LedgerSpacing.lg)
                        .padding(.vertical, LedgerSpacing.sm)
                        .frame(maxHeight: .infinity, alignment: .center)
                } else {
                    categoryGrid
                        .frame(maxHeight: .infinity)
                }

                controlBar
                    .padding(.horizontal, LedgerSpacing.lg)
                    .padding(.vertical, LedgerSpacing.xs)

                if focusedField == nil {
                    Divider()
                        .overlay(LedgerPalette.line)

                    CookieKeypadView(
                        calculator: $calculator,
                        actionTitle: calculator.isCalculationPending ? "=" : (transaction == nil ? "保存" : "完成"),
                        actionColor: kind.themeColor,
                        saving: saving,
                        onCommit: {
                            if calculator.isCalculationPending {
                                calculator.evaluateToResult()
                                updateActivePostingAmount()
                                LedgerFeedback.selection()
                            } else {
                                Task { await save() }
                            }
                        }
                    )
                    .background(LedgerPalette.canvas)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: focusedField != nil)
            .background(LedgerPalette.canvas)
            .contentShape(Rectangle())
            .onTapGesture {
                if focusedField != nil {
                    focusedField = nil
                }
            }
            .navigationTitle(transaction == nil ? "记一笔" : "编辑交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("高级") {
                        LedgerFeedback.light()
                        onSwitchToAdvanced(date, payee, narration, activePostings)
                    }
                    .font(.system(size: 15, weight: .medium))
                    .disabled(saving)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if focusedField == .payee {
                        Button("切换到备注") {
                            focusedField = .narration
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LedgerPalette.cobalt)
                    } else if focusedField == .narration {
                        Button("切换到商户") {
                            focusedField = .payee
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LedgerPalette.cobalt)
                    }
                    Spacer()
                    Button("收起键盘") {
                        focusedField = nil
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LedgerPalette.cobalt)
                }
            }
            .sheet(item: $activeAccountPickerPurpose) { purpose in
                accountPickerSheet(for: purpose)
            }
            .sheet(isPresented: $showDatePickerSheet) {
                datePickerSheet
            }
            .sensoryFeedback(.error, trigger: failureFeedback)
            .sheet(isPresented: $naturalLanguagePresented) {
                NaturalLanguageBookkeepingView { dismiss() }
            }
            .sheet(item: $preparedBookkeeping) { preview in
                BookkeepingPreviewView(preview: preview) { _ in dismiss() }
            }
            .onAppear {
                setupFromInitialValues()
            }
            .onChange(of: calculator.displayText) { _, _ in
                if isSplitMode {
                    updateActivePostingAmount()
                }
            }
        }
    }

    private var typeSwitcher: some View {
        Group {
            if isSplitMode {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.forwardslash.minus")
                            .font(.system(size: 13, weight: .bold))
                        Text("多分录拆分模式")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(LedgerPalette.cobalt)

                    Spacer()

                    Button {
                        LedgerFeedback.light()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            isSplitMode = false
                        }
                    } label: {
                        Text("返回单分类")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            } else {
                HStack(spacing: 6) {
                    ForEach(CookieEntryKind.allCases) { entryKind in
                        Button {
                            LedgerFeedback.selection()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                kind = entryKind
                                if entryKind == .income && !CookieCategoryItem.incomeCategories.contains(where: { $0.id == selectedCategoryID }) {
                                    selectedCategoryID = CookieCategoryItem.incomeCategories.first?.id ?? "salary"
                                } else if entryKind == .expense && !CookieCategoryItem.expenseCategories.contains(where: { $0.id == selectedCategoryID }) {
                                    selectedCategoryID = CookieCategoryItem.expenseCategories.first?.id ?? "food"
                                }
                            }
                        } label: {
                            Text(entryKind.rawValue)
                                .font(.system(size: 15, weight: kind == entryKind ? .semibold : .medium))
                                .foregroundStyle(kind == entryKind ? Color.white : LedgerPalette.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background {
                                    if kind == entryKind {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(entryKind.themeColor)
                                            .shadow(color: entryKind.themeColor.opacity(0.3), radius: 4, x: 0, y: 2)
                                    } else {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(LedgerPalette.panel)
                                    }
                                }
                        }
                        .buttonStyle(PressScaleButtonStyle())
                    }
                }
                .padding(4)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var heroAmountDisplay: some View {
        HStack(alignment: .lastTextBaseline, spacing: 5) {
            // Interactive Currency Picker
            HStack(alignment: .center, spacing: 2) {
                Text(currencySymbol)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(kind.themeColor.opacity(0.55))
            }
            .foregroundStyle(kind.themeColor)
            .contentShape(Rectangle())
            .overlay {
                Menu {
                    ForEach(availableCurrencies, id: \.self) { curr in
                        Button {
                            selectedCurrency = curr
                            LedgerFeedback.selection()
                        } label: {
                            if curr == selectedCurrency {
                                Label("\(curr) (\(Self.currencySymbol(for: curr)))", systemImage: "checkmark")
                            } else {
                                Text("\(curr) (\(Self.currencySymbol(for: curr)))")
                            }
                        }
                    }
                } label: {
                    Color.white.opacity(0.001)
                        .contentShape(Rectangle())
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("选择货币，当前\(selectedCurrency)")

            Text(calculator.displayText)
                .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(LedgerPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Spacer()

            if isSplitMode && splitPostings.indices.contains(activePostingIndex) {
                Text("分录 \(activePostingIndex + 1)/\(splitPostings.count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(LedgerPalette.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            } else if calculator.isCalculationPending, let res = calculator.evaluatedResult {
                Text(verbatim: "= \(res)")
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(LedgerPalette.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(LedgerPalette.panel, in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var splitPostingsView: some View {
        ScrollView {
            VStack(spacing: 10) {
                // Header with balance info
                HStack {
                    Text("拆分分录明细")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                    Spacer()
                    let sum = splitBalanceSum
                    if abs(sum) < 0.001 {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                            Text("借贷平衡")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(LedgerPalette.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(LedgerPalette.success.opacity(0.12), in: Capsule())
                    } else {
                        HStack(spacing: 6) {
                            Text("差额: \(formattedDecimal(-sum))")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.orange)
                            Button("配平") {
                                autoBalanceSplit()
                            }
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange, in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, LedgerSpacing.lg)
                .padding(.top, 4)

                // Postings list
                ForEach(Array(splitPostings.enumerated()), id: \.offset) { index, posting in
                    let isSelected = index == activePostingIndex
                    let isPositive = !posting.amount.hasPrefix("-")
                    let visual = TransactionVisualCategory.resolve(account: posting.account, label: accountDisplayName(posting.account))

                    HStack(spacing: 10) {
                        // Account Selector Button
                        Button {
                            LedgerFeedback.light()
                            activeAccountPickerPurpose = .splitPosting(index)
                        } label: {
                            HStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(visual.color.opacity(0.15))
                                        .frame(width: 32, height: 32)
                                    Image(systemName: visual.iconName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(visual.color)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(posting.account.isEmpty ? "选择账户" : accountDisplayName(posting.account))
                                        .font(.system(size: 13.5, weight: .medium))
                                        .foregroundStyle(posting.account.isEmpty ? Color.orange : LedgerPalette.ink)
                                        .lineLimit(1)
                                    if !posting.account.isEmpty {
                                        Text(posting.account)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(LedgerPalette.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        // Amount Button
                        Button {
                            selectPosting(index: index)
                        } label: {
                            Text(posting.amount.isEmpty ? "0.00" : posting.amount)
                                .font(.system(size: 15, weight: isSelected ? .bold : .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(isPositive ? LedgerPalette.ink : LedgerPalette.expense)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    isSelected ? kind.themeColor.opacity(0.14) : Color(uiColor: .tertiarySystemFill).opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(isSelected ? kind.themeColor : Color.clear, lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)

                        // Delete button
                        if splitPostings.count > 2 {
                            Button {
                                removePosting(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(LedgerPalette.secondary)
                                    .padding(4)
                            }
                            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.9))
                        }
                    }
                    .padding(10)
                    .background(
                        isSelected ? LedgerPalette.panel : Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isSelected ? kind.themeColor.opacity(0.4) : LedgerPalette.cardBorder, lineWidth: 0.8)
                    )
                    .padding(.horizontal, LedgerSpacing.lg)
                }

                // Add Posting Button
                Button {
                    addSplitPosting()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                        Text("添加分录")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(LedgerPalette.cobalt)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(LedgerPalette.cobalt.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
                .padding(.horizontal, LedgerSpacing.lg)
                .padding(.top, 4)
            }
        }
    }

    private func updateActivePostingAmount() {
        guard isSplitMode, splitPostings.indices.contains(activePostingIndex) else { return }
        let amtStr = calculator.displayText
        let clean = amtStr.replacingOccurrences(of: "-", with: "")
        let isNegative = splitPostings[activePostingIndex].amount.hasPrefix("-")
        splitPostings[activePostingIndex].amount = (isNegative ? "-" : "") + clean
    }

    private func selectPosting(index: Int) {
        guard splitPostings.indices.contains(index) else { return }
        activePostingIndex = index
        let rawAmt = splitPostings[index].amount.replacingOccurrences(of: "-", with: "")
        var newCalc = CookieKeypadCalculator()
        for ch in rawAmt {
            newCalc.appendDigit(String(ch))
        }
        calculator = newCalc
        LedgerFeedback.selection()
    }

    private func toggleSplitMode() {
        if !isSplitMode {
            calculator.evaluateToResult()
            let amt = calculator.evaluatedResult ?? Decimal.zero
            let amtStr = String(format: "%.2f", NSDecimalNumber(decimal: amt).doubleValue)
            let negAmtStr = String(format: "-%.2f", NSDecimalNumber(decimal: amt).doubleValue)

            if splitPostings.isEmpty {
                switch kind {
                case .expense:
                    splitPostings = [
                        EditableTransactionPosting(account: resolveExpenseAccount(), amount: amtStr, currency: selectedCurrency),
                        EditableTransactionPosting(account: assetAccount, amount: negAmtStr, currency: selectedCurrency)
                    ]
                case .income:
                    splitPostings = [
                        EditableTransactionPosting(account: resolveIncomeAccount(), amount: negAmtStr, currency: selectedCurrency),
                        EditableTransactionPosting(account: assetAccount, amount: amtStr, currency: selectedCurrency)
                    ]
                case .transfer:
                    splitPostings = [
                        EditableTransactionPosting(account: transferTargetAccount, amount: amtStr, currency: selectedCurrency),
                        EditableTransactionPosting(account: transferSourceAccount, amount: negAmtStr, currency: selectedCurrency)
                    ]
                }
            }
            isSplitMode = true
            selectPosting(index: 0)
        } else {
            isSplitMode = false
        }
    }

    private func addSplitPosting() {
        let diff = -splitBalanceSum
        let diffStr = String(format: "%.2f", NSDecimalNumber(decimal: diff).doubleValue)
        let newPosting = EditableTransactionPosting(
            account: "",
            amount: diffStr,
            currency: selectedCurrency
        )
        splitPostings.append(newPosting)
        selectPosting(index: splitPostings.count - 1)
        LedgerFeedback.selection()
    }

    private func removePosting(at index: Int) {
        guard splitPostings.count > 2 else { return }
        splitPostings.remove(at: index)
        if activePostingIndex >= splitPostings.count {
            activePostingIndex = splitPostings.count - 1
        }
        selectPosting(index: activePostingIndex)
        LedgerFeedback.light()
    }

    private func autoBalanceSplit() {
        let sum = splitBalanceSum
        guard abs(sum) >= 0.001 else { return }
        let diff = -sum
        if splitPostings.indices.contains(activePostingIndex) {
            let current = Decimal(string: splitPostings[activePostingIndex].amount) ?? Decimal.zero
            let balanced = current + diff
            splitPostings[activePostingIndex].amount = String(format: "%.2f", NSDecimalNumber(decimal: balanced).doubleValue)
            selectPosting(index: activePostingIndex)
        } else {
            addSplitPosting()
        }
        LedgerFeedback.success()
    }

    private func formattedDecimal(_ val: Decimal) -> String {
        String(format: "%.2f", NSDecimalNumber(decimal: val).doubleValue)
    }

    private var categoryGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

        return ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(currentCategories) { cat in
                    let isSelected = selectedCategoryID == cat.id && customExpenseAccount == nil && customIncomeAccount == nil
                    Button {
                        LedgerFeedback.selection()
                        focusedField = nil
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                            selectedCategoryID = cat.id
                            customExpenseAccount = nil
                            customIncomeAccount = nil
                        }
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(isSelected ? cat.color : cat.color.opacity(0.12))
                                    .frame(width: 48, height: 48)
                                    .shadow(color: isSelected ? cat.color.opacity(0.35) : .clear, radius: 6, x: 0, y: 3)

                                Image(systemName: cat.icon)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(isSelected ? Color.white : cat.color)
                            }
                            .scaleEffect(isSelected ? 1.08 : 1.0)

                            Text(cat.name)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? LedgerPalette.ink : LedgerPalette.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleButtonStyle())
                }

                let isCustomActive = (kind == .expense && customExpenseAccount != nil) || (kind == .income && customIncomeAccount != nil)
                Button {
                    LedgerFeedback.light()
                    focusedField = nil
                    activeAccountPickerPurpose = .customCategory
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(isCustomActive ? kind.themeColor : Color(uiColor: .tertiarySystemFill))
                                .frame(width: 48, height: 48)
                                .shadow(color: isCustomActive ? kind.themeColor.opacity(0.35) : .clear, radius: 6, x: 0, y: 3)

                            Image(systemName: isCustomActive ? "tag.fill" : "ellipsis")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(isCustomActive ? Color.white : LedgerPalette.secondary)
                        }
                        .scaleEffect(isCustomActive ? 1.08 : 1.0)

                        Text(customCategoryDisplayName ?? "更多分类")
                            .font(.system(size: 12, weight: isCustomActive ? .semibold : .regular))
                            .foregroundStyle(isCustomActive ? LedgerPalette.ink : LedgerPalette.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleButtonStyle())
            }
            .padding(.horizontal, LedgerSpacing.lg)
            .padding(.vertical, LedgerSpacing.sm)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var customCategoryDisplayName: String? {
        if kind == .expense, let custom = customExpenseAccount {
            return accounts.first(where: { $0.account == custom })?.displayLabel ?? custom.components(separatedBy: ":").last
        }
        if kind == .income, let custom = customIncomeAccount {
            return accounts.first(where: { $0.account == custom })?.displayLabel ?? custom.components(separatedBy: ":").last
        }
        return nil
    }

    private var transferRouteCard: some View {
        VStack(spacing: 16) {
            Button {
                focusedField = nil
                activeAccountPickerPurpose = .transferSource
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(LedgerPalette.expense)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("转出账户")
                            .font(.caption)
                            .foregroundStyle(LedgerPalette.secondary)
                        Text(accountDisplayName(transferSourceAccount))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(LedgerPalette.ink)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .padding(14)
                .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressScaleButtonStyle())

            Image(systemName: "arrow.down")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(LedgerPalette.cobalt)

            Button {
                focusedField = nil
                activeAccountPickerPurpose = .transferTarget
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(LedgerPalette.income)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("转入账户")
                            .font(.caption)
                            .foregroundStyle(LedgerPalette.secondary)
                        Text(accountDisplayName(transferTargetAccount))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(LedgerPalette.ink)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .padding(14)
                .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressScaleButtonStyle())
        }
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            // Row 1: Action pills with category and account clearly distinguished
            HStack(spacing: 6) {
                if !isSplitMode && kind != .transfer {
                    // Category Selector Pill
                    Button {
                        LedgerFeedback.light()
                        focusedField = nil
                        activeAccountPickerPurpose = .customCategory
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: kind == .expense ? "tag.fill" : "banknote.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(kind.themeColor)
                            Text(currentCategoryDisplayName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                        .foregroundStyle(LedgerPalette.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(LedgerPalette.panel, in: Capsule())
                        .overlay(Capsule().stroke(LedgerPalette.cardBorder.opacity(0.6), lineWidth: 0.5))
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .accessibilityLabel("选择分类，当前\(currentCategoryDisplayName)")
                    .accessibilityIdentifier("CookieFastCategoryButton")

                    // Account Selector Pill
                    Button {
                        LedgerFeedback.light()
                        focusedField = nil
                        activeAccountPickerPurpose = .funding
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: kind == .expense ? "creditcard.fill" : "building.columns.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(kind == .expense ? LedgerPalette.expense : LedgerPalette.income)
                            Text(kind == .expense ? "付: \(accountDisplayName(assetAccount))" : "收: \(accountDisplayName(assetAccount))")
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                        .foregroundStyle(LedgerPalette.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(LedgerPalette.panel, in: Capsule())
                        .overlay(Capsule().stroke(LedgerPalette.cardBorder.opacity(0.6), lineWidth: 0.5))
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .accessibilityLabel(kind == .expense ? "选择付款账户，当前\(accountDisplayName(assetAccount))" : "选择收款账户，当前\(accountDisplayName(assetAccount))")
                    .accessibilityIdentifier("CookieFastAccountButton")
                }

                Button {
                    LedgerFeedback.light()
                    focusedField = nil
                    showDatePickerSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10))
                        Text(dateChipLabel)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(LedgerPalette.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(LedgerPalette.panel, in: Capsule())
                    .overlay(Capsule().stroke(LedgerPalette.cardBorder.opacity(0.6), lineWidth: 0.5))
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel("选择日期，当前\(dateChipLabel)")
                .accessibilityIdentifier("CookieFastDateButton")

                // Split mode toggle
                Button {
                    LedgerFeedback.selection()
                    focusedField = nil
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        toggleSplitMode()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isSplitMode ? "list.bullet.rectangle.fill" : "plus.forwardslash.minus")
                            .font(.system(size: 10))
                        Text(isSplitMode ? "分录 (\(splitPostings.count))" : "拆分")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(isSplitMode ? Color.white : LedgerPalette.cobalt)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(isSplitMode ? LedgerPalette.cobalt : LedgerPalette.cobalt.opacity(0.1), in: Capsule())
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel(isSplitMode ? "关闭分录拆分" : "开启分录拆分")
                .accessibilityIdentifier("CookieFastSplitButton")

                Spacer(minLength: 0)
            }

            // Row 2: Merchant / Payee + Narration Inputs
            HStack(spacing: 8) {
                // Payee
                HStack(spacing: 6) {
                    Image(systemName: "storefront")
                        .font(.system(size: 11))
                        .foregroundStyle(focusedField == .payee ? LedgerPalette.cobalt : LedgerPalette.secondary)
                    TextField(kind == .income ? "付款方/单位" : "商户/对方", text: $payee)
                        .font(.system(size: 13))
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .payee)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .narration }
                        .accessibilityIdentifier("CookieFastPayeeField")
                    if !payee.isEmpty {
                        Button { payee = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(focusedField == .payee ? LedgerPalette.cobalt : LedgerPalette.cardBorder.opacity(0.6), lineWidth: focusedField == .payee ? 1.5 : 0.5)
                )

                // Narration
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(focusedField == .narration ? LedgerPalette.cobalt : LedgerPalette.secondary)
                    TextField("备注说明", text: $narration)
                        .font(.system(size: 13))
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .narration)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .accessibilityIdentifier("CookieFastNarrationField")
                    if !narration.isEmpty {
                        Button { narration = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(focusedField == .narration ? LedgerPalette.cobalt : LedgerPalette.cardBorder.opacity(0.6), lineWidth: focusedField == .narration ? 1.5 : 0.5)
                )
            }
        }
    }

    private func accountPickerSheet(for purpose: AccountPickerPurpose) -> some View {
        let choices: [LedgerAccountChoice] = {
            switch purpose {
            case .funding, .transferSource, .transferTarget:
                return assetAccounts.map {
                    LedgerAccountChoice(account: $0.account, label: $0.displayLabel, group: $0.group, active: $0.active)
                }
            case .customCategory:
                if kind == .expense {
                    if !expenseAccounts.isEmpty {
                        return expenseAccounts.map {
                            LedgerAccountChoice(account: $0.account, label: $0.displayLabel, group: $0.group, active: $0.active)
                        }
                    }
                    return CookieCategoryItem.expenseCategories.map {
                        LedgerAccountChoice(account: $0.defaultAccountPrefix, label: $0.name, group: "Expenses", active: true)
                    }
                } else {
                    if !incomeAccounts.isEmpty {
                        return incomeAccounts.map {
                            LedgerAccountChoice(account: $0.account, label: $0.displayLabel, group: $0.group, active: $0.active)
                        }
                    }
                    return CookieCategoryItem.incomeCategories.map {
                        LedgerAccountChoice(account: $0.defaultAccountPrefix, label: $0.name, group: "Income", active: true)
                    }
                }
            case .splitPosting:
                return activeAccounts.map {
                    LedgerAccountChoice(account: $0.account, label: $0.displayLabel, group: $0.group, active: $0.active)
                }
            }
        }()

        let title: String = {
            switch purpose {
            case .funding: return kind == .expense ? "选择付款账户" : "选择收款账户"
            case .transferSource: return "选择转出账户"
            case .transferTarget: return "选择转入账户"
            case .customCategory: return kind == .expense ? "选择支出分类" : "选择收入分类"
            case .splitPosting(let idx): return "选择第 \(idx + 1) 条分录账户"
            }
        }()

        return NavigationStack {
            LedgerAccountPicker(
                title: title,
                accounts: choices,
                selection: Binding(
                    get: {
                        switch purpose {
                        case .funding: return assetAccount
                        case .transferSource: transferSourceAccount = transferSourceAccount.isEmpty ? assetAccount : transferSourceAccount; return transferSourceAccount
                        case .transferTarget: return transferTargetAccount
                        case .customCategory:
                            return (kind == .expense ? customExpenseAccount : customIncomeAccount) ?? ""
                        case .splitPosting(let idx):
                            return splitPostings.indices.contains(idx) ? splitPostings[idx].account : ""
                        }
                    },
                    set: { newAcc in
                        switch purpose {
                        case .funding: assetAccount = newAcc
                        case .transferSource: transferSourceAccount = newAcc
                        case .transferTarget: transferTargetAccount = newAcc
                        case .customCategory:
                            if kind == .expense {
                                customExpenseAccount = newAcc
                                if let matchedCat = CookieCategoryItem.expenseCategories.first(where: { newAcc.hasPrefix($0.defaultAccountPrefix) }) {
                                    selectedCategoryID = matchedCat.id
                                } else {
                                    selectedCategoryID = ""
                                }
                            } else {
                                customIncomeAccount = newAcc
                                if let matchedCat = CookieCategoryItem.incomeCategories.first(where: { newAcc.hasPrefix($0.defaultAccountPrefix) }) {
                                    selectedCategoryID = matchedCat.id
                                } else {
                                    selectedCategoryID = ""
                                }
                            }
                        case .splitPosting(let idx):
                            if splitPostings.indices.contains(idx) {
                                splitPostings[idx].account = newAcc
                            }
                        }
                        activeAccountPickerPurpose = nil
                    }
                )
            )
        }
    }

    private var datePickerSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    quickDateButton(title: "今天", targetDate: Date())
                    quickDateButton(title: "昨天", targetDate: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
                    quickDateButton(title: "前天", targetDate: Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date())
                }
                .padding(.top, 16)

                DatePicker("选择日期", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                    .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)

                Spacer()
            }
            .background(LedgerPalette.canvas)
            .navigationTitle("记账日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showDatePickerSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func quickDateButton(title: String, targetDate: Date) -> some View {
        let isSameDay = Calendar.current.isDate(date, inSameDayAs: targetDate)
        return Button {
            LedgerFeedback.selection()
            date = targetDate
            showDatePickerSheet = false
        } label: {
            Text(title)
                .font(.system(size: 14, weight: isSameDay ? .semibold : .medium))
                .foregroundStyle(isSameDay ? Color.white : LedgerPalette.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSameDay ? LedgerPalette.cobalt : LedgerPalette.panel, in: Capsule())
        }
        .buttonStyle(PressScaleButtonStyle())
    }

    private var currencySymbol: String {
        Self.currencySymbol(for: selectedCurrency)
    }

    private var dateChipLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        let comp = cal.dateComponents([.month, .day], from: date)
        if let m = comp.month, let d = comp.day {
            return "\(m)月\(d)日"
        }
        return Self.formatDate(date)
    }

    private func accountDisplayName(_ path: String) -> String {
        guard !path.isEmpty else { return "选择账户" }
        return accounts.first(where: { $0.account == path })?.displayLabel ?? path.components(separatedBy: ":").last ?? path
    }

    private func setupFromInitialValues() {
        date = initialDate
        if CookieCategoryItem.expenseCategories.contains(where: { $0.name == initialPayee })
            || CookieCategoryItem.incomeCategories.contains(where: { $0.name == initialPayee })
            || initialPayee == "记账" || initialPayee == "拆分账单" || initialPayee == "转账" {
            payee = ""
            if initialNarration.isEmpty {
                narration = initialPayee
            } else {
                narration = initialNarration
            }
        } else {
            payee = initialPayee
            narration = initialNarration
        }
        tagsText = initialTags

        if initialPostings.count > 2 {
            isSplitMode = true
            splitPostings = initialPostings
            if let first = initialPostings.first, !first.currency.isEmpty {
                selectedCurrency = first.currency
            }
            selectPosting(index: 0)
        } else if initialPostings.count == 2 {
            let p1 = initialPostings[0]
            let p2 = initialPostings[1]

            selectedCurrency = p1.currency.isEmpty ? (p2.currency.isEmpty ? "CNY" : p2.currency) : p1.currency

            let rawAmt = (p1.amount.isEmpty || p1.amount == "0" || p1.amount == "0.00") ? p2.amount : p1.amount
            let amtStr = rawAmt.replacingOccurrences(of: "-", with: "")
            if !amtStr.isEmpty && amtStr != "0" && amtStr != "0.00" {
                var calc = CookieKeypadCalculator()
                for ch in amtStr { calc.appendDigit(String(ch)) }
                calculator = calc
            }

            let isP1Expense = p1.account.hasPrefix("Expenses:")
            let isP2Expense = p2.account.hasPrefix("Expenses:")
            let isP1Income = p1.account.hasPrefix("Income:")
            let isP2Income = p2.account.hasPrefix("Income:")

            if isP1Expense || isP2Expense {
                kind = .expense
                let expensePosting = isP1Expense ? p1 : p2
                let fundingPosting = isP1Expense ? p2 : p1
                let acc = expensePosting.account

                if let matchedCat = CookieCategoryItem.expenseCategories.first(where: { acc.hasPrefix($0.defaultAccountPrefix) || acc == $0.defaultAccountPrefix }) {
                    selectedCategoryID = matchedCat.id
                    if resolveExpenseAccount() == acc {
                        customExpenseAccount = nil
                    } else {
                        customExpenseAccount = acc
                    }
                } else {
                    selectedCategoryID = ""
                    customExpenseAccount = acc
                }
                assetAccount = fundingPosting.account
            } else if isP1Income || isP2Income {
                kind = .income
                let incomePosting = isP1Income ? p1 : p2
                let fundingPosting = isP1Income ? p2 : p1
                let acc = incomePosting.account

                if let matchedCat = CookieCategoryItem.incomeCategories.first(where: { acc.hasPrefix($0.defaultAccountPrefix) || acc == $0.defaultAccountPrefix }) {
                    selectedCategoryID = matchedCat.id
                    if resolveIncomeAccount() == acc {
                        customIncomeAccount = nil
                    } else {
                        customIncomeAccount = acc
                    }
                } else {
                    selectedCategoryID = ""
                    customIncomeAccount = acc
                }
                assetAccount = fundingPosting.account
            } else {
                kind = .transfer
                transferTargetAccount = p1.account
                transferSourceAccount = p2.account
            }
        }

        if assetAccount.isEmpty {
            assetAccount = assetAccounts.first(where: { $0.account.contains("Wechat") || $0.account.contains("Alipay") || $0.account.contains("Bank") })?.account
                ?? assetAccounts.first?.account ?? "Assets:CN:Bank:Checking"
        }
        if transferSourceAccount.isEmpty {
            transferSourceAccount = assetAccount
        }
        if transferTargetAccount.isEmpty {
            transferTargetAccount = assetAccounts.first(where: { $0.account != transferSourceAccount })?.account
                ?? assetAccounts.last?.account ?? "Assets:CN:Wechat:Balance"
        }
    }

    private func resolveExpenseAccount() -> String {
        if let custom = customExpenseAccount, !custom.isEmpty { return custom }
        guard let item = CookieCategoryItem.expenseCategories.first(where: { $0.id == selectedCategoryID }) else {
            return expenseAccounts.first?.account ?? "Expenses:Food:Meals"
        }
        if let exact = expenseAccounts.first(where: { $0.account == item.defaultAccountPrefix }) {
            return exact.account
        }
        if let matched = expenseAccounts.first(where: { $0.account.hasPrefix(item.defaultAccountPrefix) }) {
            return matched.account
        }
        if let byName = expenseAccounts.first(where: { $0.displayLabel == item.name }) {
            return byName.account
        }
        return expenseAccounts.first?.account ?? item.defaultAccountPrefix
    }

    private func resolveIncomeAccount() -> String {
        if let custom = customIncomeAccount, !custom.isEmpty { return custom }
        guard let item = CookieCategoryItem.incomeCategories.first(where: { $0.id == selectedCategoryID }) else {
            return incomeAccounts.first?.account ?? "Income:Salary"
        }
        if let exact = incomeAccounts.first(where: { $0.account == item.defaultAccountPrefix }) {
            return exact.account
        }
        if let matched = incomeAccounts.first(where: { $0.account.hasPrefix(item.defaultAccountPrefix) }) {
            return matched.account
        }
        if let byName = incomeAccounts.first(where: { $0.displayLabel == item.name }) {
            return byName.account
        }
        return incomeAccounts.first?.account ?? item.defaultAccountPrefix
    }

    private func save() async {
        guard !saving else { return }
        calculator.evaluateToResult()

        let cleanPayee = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanNarration = narration.trimmingCharacters(in: .whitespacesAndNewlines)

        // If neither payee nor narration was entered, provide a default narration based on category/type
        if cleanPayee.isEmpty && cleanNarration.isEmpty {
            if isSplitMode {
                cleanNarration = "拆分账单"
            } else if kind == .transfer {
                cleanNarration = "转账"
            } else {
                let item = currentCategories.first(where: { $0.id == selectedCategoryID })
                cleanNarration = item?.name ?? (kind == .expense ? "支出" : "收入")
            }
        }

        let parsedTags: [String] = (try? LedgerTagRules.parse(tagsText)) ?? []

        let postings: [LedgerTransactionEntryPosting]

        if isSplitMode {
            updateActivePostingAmount()
            for (idx, p) in splitPostings.enumerated() {
                if p.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errorMessage = "第 \(idx + 1) 条分录请选择账户"
                    failureFeedback &+= 1
                    return
                }
            }
            let sum = splitBalanceSum
            if abs(sum) >= 0.01 {
                errorMessage = "分录尚未平衡，借贷差额为 \(formattedDecimal(sum))，请点击「配平」"
                failureFeedback &+= 1
                return
            }
            postings = splitPostings.map { p in
                LedgerTransactionEntryPosting(
                    account: p.account,
                    amount: p.amount,
                    currency: p.currency.isEmpty ? selectedCurrency : p.currency
                )
            }
        } else {
            guard let amountVal = calculator.evaluatedResult, amountVal > 0 else {
                errorMessage = "请输入有效金额"
                failureFeedback &+= 1
                return
            }

            let amountText = ExactBookkeepingAmount.text(amountVal)
            let negativeAmountText = ExactBookkeepingAmount.text(-amountVal)

            switch kind {
            case .expense:
                let expAcc = resolveExpenseAccount()
                let fundingAcc = assetAccount
                postings = [
                    LedgerTransactionEntryPosting(account: expAcc, amount: amountText, currency: selectedCurrency),
                    LedgerTransactionEntryPosting(account: fundingAcc, amount: negativeAmountText, currency: selectedCurrency)
                ]
            case .income:
                let incAcc = resolveIncomeAccount()
                let receivingAcc = assetAccount
                postings = [
                    LedgerTransactionEntryPosting(account: incAcc, amount: negativeAmountText, currency: selectedCurrency),
                    LedgerTransactionEntryPosting(account: receivingAcc, amount: amountText, currency: selectedCurrency)
                ]
            case .transfer:
                postings = [
                    LedgerTransactionEntryPosting(account: transferTargetAccount, amount: amountText, currency: selectedCurrency),
                    LedgerTransactionEntryPosting(account: transferSourceAccount, amount: negativeAmountText, currency: selectedCurrency)
                ]
            }
        }

        let entry = LedgerTransactionEntry(
            date: Self.formatDate(date),
            flag: transaction?.editableEntry?.flag,
            payee: cleanPayee,
            narration: cleanNarration,
            metadata: [:],
            tags: parsedTags,
            links: [],
            postings: postings
        )

        saving = true
        do {
            if transaction == nil, let repository = session.localRepository {
                preparedBookkeeping = try await repository.prepareBookkeeping(.manual(entry))
                saving = false
                return
            }
            try await onSave(entry)
            LedgerFeedback.success()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            failureFeedback &+= 1
        }
        saving = false
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Transaction Editor View

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
        case .payeeRequired: "请输入交易说明或交易对方"
        case .metadataInvalid: "元数据需要使用 JSON 对象格式"
        case let .metadataKeyInvalid(key): "元数据键 \(key) 格式无效"
        case .postingsRequired: "交易至少需要两条分录"
        case let .accountRequired(index): "第 \(index + 1) 条分录缺少账户"
        case let .amountInvalid(index): "第 \(index + 1) 条分录金额格式无效"
        case let .currencyInvalid(index): "第 \(index + 1) 条分录币种格式无效"
        }
    }
}

struct TransactionEditorView: View {
    @EnvironmentObject private var session: LedgerSession
    @State private var preparedBookkeeping: PreparedBookkeepingChange?
    @State private var naturalLanguagePresented = false
    @Environment(\.dismiss) private var dismiss

    enum EditorMode {
        case fast
        case advanced
    }

    let transaction: LedgerTransaction?
    let accounts: [LedgerAccount]
    let commodities: [String]
    let onSave: (LedgerTransactionEntry) async throws -> Void

    @State private var mode: EditorMode
    @State private var date: Date
    @State private var payee: String
    @State private var narration: String
    @State private var tagsText: String
    @State private var metadataText: String
    @State private var postings: [EditableTransactionPosting]
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var failureFeedback = 0
    @State private var initialDraft: Draft?
    @State private var discardPresented = false
    @State private var newEntryPreview: EntryPreview?
    @FocusState private var keyboardFocused: Bool

    init(
        transaction: LedgerTransaction,
        accounts: [LedgerAccount],
        commodities: [String],
        initialMode: EditorMode? = nil,
        onSave: @escaping (LedgerTransactionEntry) async throws -> Void
    ) {
        let baseline = transaction.editableEntry
        self.transaction = transaction
        self.accounts = accounts
        self.commodities = commodities
        self.onSave = onSave

        let hasComplexCostOrPrice = baseline?.postings.contains(where: { $0.costKind != nil || $0.priceKind != nil }) ?? false
        _mode = State(initialValue: initialMode ?? (hasComplexCostOrPrice ? .advanced : .fast))

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

    init(
        accounts: [LedgerAccount],
        commodities: [String],
        initialMode: EditorMode? = nil,
        prefillPayee: String = "",
        prefillNarration: String = "",
        prefillPostings: [EditableTransactionPosting]? = nil,
        onSave: @escaping (LedgerTransactionEntry) async throws -> Void
    ) {
        self.transaction = nil
        self.accounts = accounts
        self.commodities = commodities
        self.onSave = onSave
        _mode = State(initialValue: initialMode ?? .fast)
        _date = State(initialValue: Date())
        _payee = State(initialValue: prefillPayee)
        _narration = State(initialValue: prefillNarration)
        _tagsText = State(initialValue: "")
        _metadataText = State(initialValue: "{}")
        if let prefillPostings, !prefillPostings.isEmpty {
            _postings = State(initialValue: prefillPostings)
        } else {
            _postings = State(initialValue: [
                EditableTransactionPosting(account: accounts.first(where: { $0.active && $0.account.hasPrefix("Expenses:") })?.account ?? "Expenses:Other", amount: "", currency: commodities.first ?? "CNY"),
                EditableTransactionPosting(account: accounts.first(where: { $0.active && $0.account.hasPrefix("Assets:") })?.account ?? "Assets:Cash", amount: "", currency: "")
            ])
        }
    }

    private struct Draft: Equatable {
        let date: Date
        let payee: String
        let narration: String
        let tags: String
        let metadata: String
        let postings: [EditableTransactionPosting]
    }

    private struct EntryPreview: Identifiable {
        let id = UUID()
        let entry: LedgerTransactionEntry
    }

    private var currentDraft: Draft {
        Draft(date: date, payee: payee, narration: narration, tags: tagsText,
              metadata: metadataText, postings: postings)
    }

    private var hasChanges: Bool {
        initialDraft.map { $0 != currentDraft } ?? false
    }

    private func requestDismiss() {
        guard !saving else { return }
        keyboardFocused = false
        if hasChanges { discardPresented = true } else { dismiss() }
    }

    private var accountChoices: [LedgerAccount] {
        accounts.sorted { left, right in
            if left.active != right.active { return left.active && !right.active }
            return left.displayLabel.localizedStandardCompare(right.displayLabel) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if mode == .fast {
                CookieFastTransactionEditorBody(
                    transaction: transaction,
                    accounts: accounts,
                    commodities: commodities,
                    initialDate: date,
                    initialPayee: payee,
                    initialNarration: narration,
                    initialTags: tagsText,
                    initialPostings: postings,
                    onSave: onSave,
                    onSwitchToAdvanced: { newDate, newPayee, newNarration, newPostings in
                        date = newDate
                        payee = newPayee
                        narration = newNarration
                        if !newPostings.isEmpty {
                            postings = newPostings
                        }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            mode = .advanced
                        }
                    }
                )
            } else {
                advancedFormView
            }
        }
        .sheet(isPresented: $naturalLanguagePresented) {
            NaturalLanguageBookkeepingView { dismiss() }
        }
        .sheet(item: $preparedBookkeeping) { preview in
            BookkeepingPreviewView(preview: preview) { _ in dismiss() }
        }
    }

    private var advancedFormView: some View {
        NavigationStack {
            Form {
                if transaction == nil {
                    Section {
                        Button {
                            LedgerFeedback.light()
                            naturalLanguagePresented = true
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("用一句话记账")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(LedgerPalette.ink)
                                    Text("输入日常口语描述，自动拆分多账户分录与金额")
                                        .font(.caption2)
                                        .foregroundStyle(LedgerPalette.secondary)
                                }
                            } icon: {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(LedgerPalette.cobalt)
                            }
                        }
                        .accessibilityIdentifier("bookkeeping-natural-entry")
                    }
                }
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

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            quickDateChip(title: "今天", targetDate: Date())
                            quickDateChip(
                                title: "昨天",
                                targetDate: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                            )
                            quickDateChip(
                                title: "前天",
                                targetDate: Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()
                            )
                        }
                        .padding(.top, 2)

                        DatePicker("日期", selection: $date, displayedComponents: .date)
                    }
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
            .navigationTitle(transaction == nil ? "记一笔 (高级)" : "编辑交易 (高级)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: requestDismiss).disabled(saving)
                        .accessibilityIdentifier("transaction-edit-cancel")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("极速") {
                        LedgerFeedback.light()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            mode = .fast
                        }
                    }
                    .font(.system(size: 15, weight: .medium))
                    .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView("正在验证并保存") } else { Text(transaction == nil ? "预览" : "保存修改") }
                    }
                    .disabled(saving)
                    .accessibilityLabel(saving ? "正在验证并保存" : (transaction == nil ? "预览" : "保存修改"))
                    .accessibilityIdentifier("transaction-edit-save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { keyboardFocused = false }
                }
            }
        }
        .onAppear { if initialDraft == nil { initialDraft = currentDraft } }
        .interactiveDismissDisabled(saving || hasChanges)
        .alert("放弃未保存的修改？", isPresented: $discardPresented) {
            Button("放弃修改", role: .destructive) { dismiss() }
                .accessibilityIdentifier("transaction-edit-discard")
            Button("继续编辑", role: .cancel) { }
                .accessibilityIdentifier("transaction-edit-continue")
        } message: {
            Text("已修改的内容会保留，直到保存或确认放弃。")
        }
        .sensoryFeedback(.error, trigger: failureFeedback)
        .sheet(item: $newEntryPreview) { preview in
            let entry = preview.entry
            NavigationStack {
                List {
                    Section("确认交易") {
                        LabeledContent("日期", value: entry.date)
                        LabeledContent("交易对方", value: entry.payee)
                        LabeledContent("说明", value: entry.narration)
                        ForEach(Array(entry.postings.enumerated()), id: \.offset) { _, posting in
                            LabeledContent(posting.account, value: posting.amount.isEmpty ? "自动配平" : "\(posting.amount) \(posting.currency)")
                                .font(.subheadline.monospaced())
                        }
                        if !entry.tags.isEmpty { Text(entry.tags.map { "#" + $0 }.joined(separator: " ")) }
                        if !entry.metadata.isEmpty { Text(Self.metadataText(entry.metadata)).font(.footnote.monospaced()) }
                    }
                }
                .navigationTitle("交易预览")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("返回编辑") { newEntryPreview = nil }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "正在校验" : "确认保存") { Task { await commitNewEntry(entry) } }
                            .disabled(saving).accessibilityIdentifier("transaction-create-confirm")
                    }
                }
            }
            .interactiveDismissDisabled(saving)
        }
        .privacySensitive()
    }

    static func decimalText(_ minorUnits: Int) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(minorUnits) / 100)
    }

    private func save() async {
        guard !saving else { return }
        keyboardFocused = false
        do {
            let entry = try makeEntry()
            if transaction == nil {
                if let repository = session.localRepository {
                    saving = true
                    preparedBookkeeping = try await repository.prepareBookkeeping(.manual(entry))
                    saving = false
                } else {
                    newEntryPreview = EntryPreview(entry: entry)
                }
                return
            }
            saving = true
            try await onSave(entry)
            dismiss()
        } catch {
            errorMessage = "保存失败，账本保留原版本：\(error.localizedDescription)"
            failureFeedback &+= 1
        }
        saving = false
    }

    private func commitNewEntry(_ entry: LedgerTransactionEntry) async {
        guard !saving else { return }
        saving = true
        do {
            try await onSave(entry)
            newEntryPreview = nil
            dismiss()
        } catch {
            newEntryPreview = nil
            errorMessage = error.localizedDescription
            failureFeedback &+= 1
        }
        saving = false
    }

    private func makeEntry() throws -> LedgerTransactionEntry {
        let cleanedPayee = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedNarration = narration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPayee.isEmpty || !cleanedNarration.isEmpty else { throw TransactionEditorError.payeeRequired }
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
            flag: transaction?.editableEntry?.flag,
            payee: cleanedPayee,
            narration: cleanedNarration,
            metadata: metadata,
            tags: tags,
            links: transaction?.editableEntry?.links ?? [],
            postings: cleanedPostings
        )
    }

    private func quickDateChip(title: String, targetDate: Date) -> some View {
        let isSelected = Calendar.current.isDate(date, inSameDayAs: targetDate)
        return Button {
            LedgerFeedback.selection()
            withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                date = targetDate
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
                .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.primary : Color(uiColor: .tertiarySystemFill))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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

func amountPrefix(_ kind: TransactionKind) -> String {
    switch kind {
    case .expense: return "−"
    case .income: return "+"
    case .transfer: return ""
    }
}

func amountColor(_ kind: TransactionKind) -> Color {
    switch kind {
    case .expense: return LedgerPalette.expense
    case .income: return LedgerPalette.income
    case .transfer: return LedgerPalette.gold
    }
}
