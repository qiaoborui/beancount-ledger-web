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
    static func format(_ dateString: String) -> String {
        guard let date = LedgerDateRange.parse(dateString) else { return dateString }
        let cal = LedgerDateRange.calendar
        let now = Date()

        let isToday = cal.isDateInToday(date)
        let isYesterday = cal.isDateInYesterday(date)

        let comp = cal.dateComponents([.year, .weekday], from: date)
        let currentYear = cal.component(.year, from: now)

        guard let weekday = comp.weekday, weekday >= 1 && weekday <= 7 else {
            return dateString
        }

        let weekdayStr = LedgerDateLabel.weekday(number: weekday)

        if isToday {
            return String(localized: "今天 · \(LedgerDateLabel.monthDay(date))")
        } else if isYesterday {
            return String(localized: "昨天 · \(LedgerDateLabel.monthDay(date))")
        } else if comp.year == currentYear {
            return "\(LedgerDateLabel.monthDay(date)) · \(weekdayStr)"
        } else {
            return "\(LedgerDateLabel.yearMonthDay(date)) · \(weekdayStr)"
        }
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
            : String(localized: "金额已隐藏")
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
    @State private var preparation: Task<Void, Never>?
    @State private var preparationID: UUID?
    @State private var preparationError: String?
    @State private var localAuthority: LedgerSession.LocalTransactionAction?

    private enum Kind { case edit, tags, delete, share }
    private struct Action: Identifiable {
        let id = UUID()
        let kind: Kind
        let transaction: LedgerTransaction
        var authority: LedgerSession.LocalTransactionAction? = nil
    }

    private var resolved: LedgerTransaction? {
        guard session.phase == .ready, !session.privacyShielded else { return nil }
        switch session.transactionResolution(for: transaction.source) {
        case .visible(let current): return current
        case .unloaded: return session.isLocal ? transaction : nil
        case .unavailable: return nil
        }
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
                    .disabled(resolved.map { !canWrite($0) || (!session.isLocal && $0.editableEntry == nil) } ?? true)
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
            .overlay(alignment: .trailing) {
                if preparationID != nil { ProgressView().accessibilityLabel("正在读取交易") }
            }
            .alert("无法读取交易", isPresented: Binding(
                get: { preparationError != nil }, set: { if !$0 { preparationError = nil } }
            )) { Button("好", role: .cancel) { preparationError = nil } }
            message: { Text(preparationError ?? "") }
            .sheet(item: $action, onDismiss: cancelPreparation) { action in
                actionSheet(action).ledgerPrivacyProtectedSheet()
            }
            .onDisappear {
                // A presenter can disappear during full-screen sheet adaptation.
                // Presented authority belongs to the sheet, not presenter visibility.
                if action == nil { cancelPreparation() }
            }
            .onChange(of: session.privacyShielded) { _, hidden in
                if hidden { action = nil; cancelPreparation() }
            }
            .onChange(of: session.phase) { _, phase in
                if phase != .ready { action = nil; cancelPreparation() }
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
                if let authority = action.authority {
                    do { try await session.updateLocalTransaction(action: authority, entry: entry) }
                    catch { endFailedAction(error); throw error }
                } else {
                    try await session.updateTransaction(source: action.transaction.source, entry: entry)
                }
                confirmationFeedback &+= 1
            }
        case .tags:
            TransactionTagEditorSheet(selectedCount: 1) { tags in
                if let authority = action.authority {
                    do { try await session.addLocalTransactionTags(action: authority, tags: tags) }
                    catch { endFailedAction(error); throw error }
                } else {
                    try await session.addTransactionTags(sources: [action.transaction.source], tags: tags)
                }
                confirmationFeedback &+= 1
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .delete:
            TransactionDeleteSheet(transaction: action.transaction, localAction: action.authority,
                onFailed: { error in
                    if action.authority != nil { endFailedAction(error) }
                }, onDeleted: { confirmationFeedback &+= 1 })
        }
    }

    private func endFailedAction(_ error: Error) {
        // A submitted nonce is consumed even after rollback. Never offer a retry
        // that silently borrows authority for a potentially newer original.
        action = nil
        cancelPreparation()
        preparationError = error.localizedDescription + String(localized: " 请重新打开交易操作，核对最新内容后再试。")
    }

    private func cancelPreparation() {
        preparationID = nil
        preparation?.cancel()
        preparation = nil
        if let localAuthority { session.cancelLocalTransactionAction(localAuthority) }
        localAuthority = nil
    }

    private func present(_ kind: Kind) {
        guard preparationID == nil, let current = resolved else { return }
        if kind != .share && !canWrite(current) { return }
        guard session.isLocal else {
            if case .edit = kind, current.editableEntry == nil { return }
            action = Action(kind: kind, transaction: current)
            return
        }
        cancelPreparation()
        let id = UUID()
        preparationID = id
        preparation = Task { @MainActor in
            do {
                let detail: LedgerTransaction
                let authority: LedgerSession.LocalTransactionAction?
                if kind == .share {
                    detail = try await session.localTransactionDetail(source: current.source)
                    authority = nil
                } else {
                    let actionKind: LedgerSession.LocalTransactionActionKind
                    switch kind {
                    case .edit: actionKind = .edit
                    case .tags: actionKind = .addTags
                    case .delete: actionKind = .delete
                    case .share: return
                    }
                    let prepared = try await session.prepareLocalTransactionAction(
                        sources: [current.source], kind: actionKind)
                    authority = prepared
                    detail = prepared.originals[0]
                }
                guard !Task.isCancelled, preparationID == id else {
                    if let authority { session.cancelLocalTransactionAction(authority) }
                    return
                }
                if kind == .edit, detail.editableEntry == nil {
                    if let authority { session.cancelLocalTransactionAction(authority) }
                    throw LedgerTransactionMutationError.sourceUnavailable
                }
                localAuthority = authority
                action = Action(kind: kind, transaction: detail, authority: authority)
            } catch {
                if !Task.isCancelled, preparationID == id { preparationError = error.localizedDescription }
            }
            if preparationID == id { preparationID = nil; preparation = nil }
        }
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

/// Records a transaction in one tap from a page header. The fast editor used
/// to sit behind the 流水 overflow menu, three taps from the overview.
struct LedgerQuickEntryButton: View {
    @EnvironmentObject private var session: LedgerSession
    @State private var presented = false
    var accessibilityID = "quick-entry"

    var body: some View {
        if session.isLocal {
            Button {
                LedgerFeedback.light()
                presented = true
            } label: {
                // `.iconbtn`: a bare glyph in a 44pt target, like the sync
                // button beside it. Balanced has no filled or accent controls
                // in the app bar.
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(BalancedPalette.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("记一笔")
            .accessibilityIdentifier(accessibilityID)
            .sheet(isPresented: $presented) {
                TransactionEditorView(
                    accounts: session.ledger?.accounts ?? [],
                    commodities: session.ledger?.commodities ?? []
                ) { entry in
                    try await session.addLocalTransaction(entry)
                }
                .ledgerPrivacyProtectedSheet()
            }
        }
    }
}

struct TransactionFilterBar: View {
    @Binding var kindFilter: TransactionKindFilter

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TransactionKindFilter.allCases) { filter in
                Button { kindFilter = filter } label: {
                    Text(filter.title).terminalFont(size: 13, weight: kindFilter == filter ? .semibold : .regular)
                        .foregroundStyle(kindFilter == filter ? TerminalPalette.accent : TerminalPalette.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(alignment: .bottom) {
                            if kindFilter == filter { Rectangle().fill(TerminalPalette.accent).frame(height: 2) }
                        }
                }.buttonStyle(.plain).accessibilityAddTraits(kindFilter == filter ? .isSelected : [])
            }
        }
        .overlay(alignment: .bottom) { TerminalRule().offset(y: 1) }
        .accessibilityIdentifier("transaction-kind-filter")
    }
}

/// `.seg` — natural-width tabs with a 22px gap, left aligned (not stretched),
/// horizontally scrollable when they overflow. Selected = ink, 600 weight, a
/// 2px ink underline on that tab only; unselected tabs stay ink-3.
private struct BalancedTransactionFilterBar: View {
    @Binding var kindFilter: TransactionKindFilter
    /// nil while the full-range counts are still being computed.
    let counts: [TransactionKindFilter: Int]?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(TransactionKindFilter.allCases) { filter in
                    Button { kindFilter = filter } label: {
                        HStack(spacing: 4) {
                            Text(filter.title).balancedFont(size: 14.5, weight: kindFilter == filter ? .semibold : .regular)
                            Text(counts.map { "\($0[filter, default: 0])" } ?? "…")
                                .balancedFont(size: 11.5).monospacedDigit()
                        }
                        .foregroundStyle(kindFilter == filter ? BalancedPalette.ink : BalancedPalette.meta)
                        .frame(minHeight: 44)
                        .overlay(alignment: .bottom) {
                            if kindFilter == filter { BalancedPalette.ink.frame(height: 2) }
                        }
                    }.buttonStyle(.plain).accessibilityAddTraits(kindFilter == filter ? .isSelected : [])
                }
            }
        }
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
        .accessibilityIdentifier("transaction-kind-filter")
    }
}

/// `.settle` filter-result block (b04) — shown in place of the per-day kind
/// summary once a kind filter narrows the list: rows grouped by category in
/// ink, a single coloured total (the opposed-pair exception for the one
/// verified sum on screen).
private struct BalancedTransactionFilterSettle: View {
    @EnvironmentObject private var session: LedgerSession
    let kind: TransactionKindFilter
    let rows: [(label: String, minorUnits: Int)]
    let total: Int
    let count: Int
    let currency: String

    private var sign: String { kind == .expense ? "−" : kind == .income ? "+" : "" }
    private var totalColor: Color {
        switch kind {
        case .income: BalancedPalette.income
        case .expense: BalancedPalette.expense
        case .all, .transfer: BalancedPalette.ink
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("筛选结果").balancedFont(size: 12.5, weight: .medium).foregroundStyle(BalancedPalette.secondary)
                Spacer(minLength: 12)
                Text("\(count) 笔").balancedFont(size: 12.5).monospacedDigit().foregroundStyle(BalancedPalette.meta)
            }.padding(.bottom, 10)
            VStack(spacing: 0) {
                ForEach(rows, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(row.label).balancedFont(size: 15).foregroundStyle(BalancedPalette.secondary)
                        Spacer(minLength: 8)
                        // No `.minimumScaleFactor` here: inside a List row it can lock
                        // onto an incorrect (far too small) scale from an early
                        // measurement pass. These strings are short and always fit.
                        Text(session.amountsVisible ? sign + MoneyText.format(minorUnits: abs(row.minorUnits), currency: currency, showsCurrency: false) : "••••••")
                            .font(.custom(BalancedWeight.text.sansPostscriptName, size: 15, relativeTo: .body))
                            .monospacedDigit().foregroundStyle(BalancedPalette.ink).lineLimit(1).fixedSize()
                    }.padding(.vertical, 6)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("合计").balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                Spacer(minLength: 8)
                // `.settle-total dd`: 30/500/-0.025em, same as OverviewView's settle total.
                Text(session.amountsVisible ? sign + MoneyText.format(minorUnits: abs(total), currency: currency, showsCurrency: false) : "••••••")
                    .font(.custom(BalancedWeight.medium.sansPostscriptName, size: 30, relativeTo: .title))
                    .tracking(-0.75).monospacedDigit().foregroundStyle(totalColor).lineLimit(1).fixedSize()
            }
            .padding(.top, 14)
            .overlay(alignment: .top) { BalancedPalette.ink.frame(height: 1) }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BalancedPalette.sunken)
    }
}

/// `.daysep` — date (bold, ink-2) + weekday (ink-3) on the left, the day's
/// kind summary (if any), then a 1px rule that grows to fill the rest of the
/// row inline — not a separate rule drawn under the whole header.
private struct BalancedTransactionDayHeader: View {
    let date: String
    let weekday: String
    let summary: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            (Text(date).font(.custom(BalancedWeight.semibold.sansPostscriptName, size: 12.5, relativeTo: .caption)).foregroundColor(BalancedPalette.secondary)
             + Text(" " + weekday).font(.custom(BalancedWeight.regular.sansPostscriptName, size: 12.5, relativeTo: .caption)).foregroundColor(BalancedPalette.meta))
                .monospacedDigit()
            if !summary.isEmpty {
                Text(summary).balancedFont(size: 12.5).monospacedDigit().foregroundStyle(BalancedPalette.secondary)
            }
            BalancedPalette.rule.frame(height: 1)
        }
        .frame(minHeight: 20)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .textCase(nil)
    }
}

private struct BalancedLedgerTransactionRow: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let transaction: LedgerTransaction
    let accountLabels: [String: String]
    let accountCurrency: String

    private var presentation: TransactionPresentation { TransactionPresentation(transaction: transaction) }
    private var visual: TransactionVisualCategory {
        TransactionVisualCategory.resolve(transaction: transaction, presentation: presentation, accountLabels: accountLabels)
    }

    private var transferPath: String? {
        guard presentation.kind == .transfer else { return nil }
        let accounts = transaction.postings.map { accountLabels[$0.account] ?? $0.account }
        guard accounts.count >= 2 else { return nil }
        return accounts[0] + " → " + accounts[1]
    }

    /// No currency symbol on row amounts — only a settle total carries one.
    private var amountText: String {
        guard session.amountsVisible else { return "••••••" }
        let sign = presentation.kind == .expense ? "−" : presentation.kind == .income ? "+" : ""
        return sign + MoneyText.format(minorUnits: abs(presentation.minorUnits), currency: presentation.currency, showsCurrency: presentation.currency != accountCurrency)
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title).balancedFont(size: 15.5, weight: .medium)
                    .foregroundStyle(BalancedPalette.ink).lineLimit(2)
                if let transferPath {
                    Text(transferPath).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta).lineLimit(2)
                } else {
                    Text(presentation.subtitle).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta).lineLimit(2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                // `.txn .val .amt`: 15.5/500, tabular. Only income is drawn in
                // colour; expense and transfers stay ink and carry their meaning
                // in the sign — batch 1's opposed-pair rule.
                Text(amountText)
                    .font(.custom(BalancedWeight.medium.sansPostscriptName, size: 15.5, relativeTo: .body))
                    .monospacedDigit()
                    .foregroundStyle(presentation.kind == .income ? BalancedPalette.income : BalancedPalette.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(presentation.kind == .transfer ? String(localized: "转账") : visual.categoryLabel).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
        .contentShape(Rectangle())
    }
}

struct TransactionsView: View {
    static let localWindowLimits = LocalTransactionWindow.Limits(maxRows: LocalTransactionWindow.listPageRows)

    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var filters = LedgerTransactionFilter()
    @State private var filterPresented = false
    @State private var storagePresented = false
    @State private var duplicateTarget: LedgerTransaction?
    @State private var editingTarget: LedgerTransaction?
    @State private var deletionTarget: LedgerTransaction?
    @State private var isSelecting = false
    @State private var selectedTransactionIDs: Set<String> = []
    @State private var localSelection: LocalTransactionSelection?
    @State private var localSelectionFacts: LocalTransactionSelectionScan.Result?
    @State private var batchSharePresented = false
    @State private var singleShareTarget: LedgerTransaction?
    @State private var tagEditorPresented = false
    @State private var eventTagListPresented = false
    @State private var actionMessage: String?
    @State private var actionMessageStyle: LedgerStatusStyle = .failure
    @State private var confirmationFeedback = 0
    @State private var selectionFeedback = 0
    @State private var localAction: LedgerSession.LocalTransactionAction?
    @State private var actionTask: Task<Void, Never>?
    @State private var actionRequestID: UUID?
    @State private var preparingTags = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportRequestID: UUID?
    @State private var preparingLegacyShare = false
    @State private var fileExport: LocalTransactionShareExport?
    @State private var fileExportOwner: LocalTransactionShareExport?

    private struct WindowRequestKey: Equatable {
        let revision: UUID?
        let reload: Int
        let range: LedgerDateRange
        let filter: LedgerTransactionFilter
        let readable: Bool
    }

    private var windowRequestKey: WindowRequestKey {
        .init(revision: session.localTransactionPresentationRevision, reload: session.localTransactionReloadID, range: session.selectedRange,
              filter: filters, readable: session.isLocal && session.phase == .ready && !session.privacyShielded
                && !session.isRangeLoading && !session.isValuationCurrencyLoading
                && !session.transactionMutationStates.values.contains(.pending))
    }

    private struct SelectionReadKey: Equatable {
        let selection: LocalTransactionSelection?
        let filter: LedgerTransactionFilter
        let readable: Bool
    }

    private var selectionReadKey: SelectionReadKey {
        .init(selection: isSelecting && session.isLocal ? localSelection : nil,
              filter: filters, readable: windowRequestKey.readable)
    }

    private var currentLocalSelection: LocalTransactionSelection? {
        guard let localSelection,
              localSelection.revisionID == session.localTransactionPresentationRevision,
              localSelection.start == session.selectedRange.start,
              localSelection.end == session.selectedRange.queryEndExclusive else { return nil }
        return localSelection
    }

    private var displayedTransactions: [LedgerTransaction] {
        if session.isLocal {
            return (session.localTransactionAccumulatedRows.isEmpty
                ? session.localBootstrapTransactions
                : session.localTransactionAccumulatedRows)
                .filter(filters.matches)
        }
        return filteredTransactions
    }

    /// Same scope as `displayedTransactions` but ignores the active kind
    /// filter (search/account/tags still apply) — used only to compute the
    /// `.seg` tab counts, which must stay stable as the kind tab changes
    /// rather than collapsing to the active tab's own count.
    private var kindAgnosticDisplayedTransactions: [LedgerTransaction] {
        var kindAgnostic = filters
        kindAgnostic.kind = .all
        if session.isLocal {
            return (session.localTransactionAccumulatedRows.isEmpty
                ? session.localBootstrapTransactions
                : session.localTransactionAccumulatedRows)
                .filter(kindAgnostic.matches)
        }
        return transactions.filter(kindAgnostic.matches)
    }

    private var displayedCount: Int? {
        session.isLocal ? session.localTransactionSummary?.matchedCount : filteredTransactions.count
    }

    private var transactions: [LedgerTransaction] {
        session.visibleTransactions
    }

    private var filteredTransactions: [LedgerTransaction] {
        transactions.filter(filters.matches)
    }

    private var availableAccounts: [String] {
        if session.isLocal { return session.localTransactionSummary?.availableAccounts ?? [] }
        return Array(Set(transactions.flatMap { $0.postings.map(\.account) }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var availableTags: [String] {
        if session.isLocal { return session.localTransactionSummary?.availableTags ?? [] }
        return Array(Set(transactions.flatMap { $0.tags ?? [] }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var activeStructuredFilterCount: Int {
        (filters.kind == .all ? 0 : 1)
            + (filters.account == nil ? 0 : 1)
            + (filters.tags.isEmpty ? 0 : 1)
    }

    /// Local lists load lazily, so tab counts come from the full-range scan, not
    /// from the windows scrolled so far. nil while that scan is still running.
    private var displayedKindCounts: [TransactionKindFilter: Int]? {
        guard session.isLocal else { return balancedKindCounts(for: kindAgnosticDisplayedTransactions) }
        // The local window is read with the kind filter applied, so its rows
        // cannot produce counts for the other tabs either.
        guard let counts = session.localTransactionSummary?.kindCounts else { return nil }
        return Dictionary(uniqueKeysWithValues: TransactionKindFilter.allCases.map { ($0, counts[$0]) })
    }

    private func balancedKindCounts(for transactions: [LedgerTransaction]) -> [TransactionKindFilter: Int] {
        var counts = Dictionary(uniqueKeysWithValues: TransactionKindFilter.allCases.map { ($0, 0) })
        for transaction in transactions {
            counts[.all, default: 0] += 1
            switch TransactionPresentation(transaction: transaction).kind {
            case .expense: counts[.expense, default: 0] += 1
            case .income: counts[.income, default: 0] += 1
            case .transfer: counts[.transfer, default: 0] += 1
            }
        }
        return counts
    }

    var isRoot = true


    private func balancedDate(_ raw: String) -> (date: String, weekday: String) {
        guard let date = LedgerDateRange.parse(raw) else { return (raw, "") }
        let components = LedgerDateRange.calendar.dateComponents([.month, .day, .weekday], from: date)
        guard let month = components.month, let day = components.day, let weekday = components.weekday else { return (raw, "") }
        return (String(format: "%02d/%02d", month, day), LedgerDateLabel.weekday(number: weekday))
    }

    /// Only shown in the unfiltered (全部) tab — once a kind filter narrows the
    /// list the per-day total is redundant with the settle block above it.
    ///
    /// Local lists load lazily, so a day can be split across windows; prefer the
    /// full-range day totals from the summary scan when they exist.
    private func balancedDaySummary(_ transactions: [LedgerTransaction], day: LocalTransactionScan.Day? = nil) -> String {
        guard filters.kind == .all else { return "" }
        var income = day?.incomeTotal ?? 0
        var expense = day?.expenseTotal ?? 0
        var transfers = day?.hasTransfer ?? false
        for transaction in transactions where day == nil {
            let presentation = TransactionPresentation(transaction: transaction)
            switch presentation.kind {
            case .income: income += abs(presentation.minorUnits)
            case .expense: expense += abs(presentation.minorUnits)
            case .transfer: transfers = true
            }
        }
        if income > 0 { return String(localized: "收入 \(MoneyText.format(minorUnits: income, currency: session.ledger?.summary.currency ?? "CNY", showsCurrency: false))") }
        if expense > 0 { return String(localized: "支出 \(MoneyText.format(minorUnits: expense, currency: session.ledger?.summary.currency ?? "CNY", showsCurrency: false))") }
        return transfers ? String(localized: "转账，不计收支") : ""
    }

    /// `.settle` filter-result block (b04) — only once a kind filter narrows
    /// the list. Rows group by the leaf category within the current range.
    private func balancedFilterSettle(_ transactions: [LedgerTransaction], accountLabels: [String: String]) -> (rows: [(label: String, minorUnits: Int)], total: Int, count: Int)? {
        guard filters.kind != .all else { return nil }
        if session.isLocal {
            // Loaded rows are only the windows scrolled so far; totals must come
            // from the full-range scan, so show nothing until it finishes.
            guard let summary = session.localTransactionSummary else { return nil }
            return balancedFilterSettle(summary, accountLabels: accountLabels)
        }
        return balancedFilterSettleRows(transactions, accountLabels: accountLabels)
    }

    private func balancedFilterSettle(_ summary: LocalTransactionScan.Result, accountLabels: [String: String]) -> (rows: [(label: String, minorUnits: Int)], total: Int, count: Int)? {
        guard summary.matchedCount > 0 else { return nil }
        var totals: [String: Int] = [:]
        var total = 0
        for category in summary.categories {
            let label = TransactionCategoryPresentation(key: category.key, accountLabels: accountLabels).label
            let leaf = label.split(separator: "›").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? label
            totals[leaf, default: 0] &+= category.total
            total &+= category.total
        }
        let rows = totals.map { (label: $0.key, minorUnits: $0.value) }.sorted { lhs, rhs in
            if lhs.minorUnits != rhs.minorUnits { return lhs.minorUnits > rhs.minorUnits }
            return lhs.label < rhs.label
        }
        return (rows, total, summary.matchedCount)
    }

    private func balancedFilterSettleRows(_ transactions: [LedgerTransaction], accountLabels: [String: String]) -> (rows: [(label: String, minorUnits: Int)], total: Int, count: Int)? {
        guard !transactions.isEmpty else { return nil }
        var totals: [String: Int] = [:]
        var order: [String] = []
        var total = 0
        for transaction in transactions {
            let presentation = TransactionPresentation(transaction: transaction)
            let visual = TransactionVisualCategory.resolve(transaction: transaction, presentation: presentation, accountLabels: accountLabels)
            let parts = visual.categoryLabel.split(separator: "›")
            let leaf: String
            if let lastPart = parts.last {
                leaf = lastPart.trimmingCharacters(in: .whitespaces)
            } else {
                leaf = visual.categoryLabel
            }
            let amount = abs(presentation.minorUnits)
            if totals[leaf] == nil { order.append(leaf) }
            totals[leaf, default: 0] += amount
            total += amount
        }
        var rows: [(label: String, minorUnits: Int)] = []
        for label in order { rows.append((label: label, minorUnits: totals[label] ?? 0)) }
        rows.sort { lhs, rhs in
            if lhs.minorUnits != rhs.minorUnits { return lhs.minorUnits > rhs.minorUnits }
            return lhs.label < rhs.label
        }
        return (rows, total, transactions.count)
    }

    private var selectedTransactions: [LedgerTransaction] {
        if session.isLocal {
            guard let selection = currentLocalSelection else { return [] }
            return session.visibleGlobalTransactions.filter { filters.matches($0) && selection.contains($0) }
        }
        return filteredTransactions.filter { selectedTransactionIDs.contains($0.id) }
    }

    private var selectedCount: Int {
        session.isLocal
            ? (localSelectionFacts?.selectedCount ?? currentLocalSelection?.explicitSelectedCount ?? 0)
            : selectedTransactionIDs.count
    }

    private var allVisibleSelected: Bool {
        if session.isLocal { return localSelectionFacts?.allMatchingSelected ?? false }
        return !filteredTransactions.isEmpty && filteredTransactions.allSatisfy { selectedTransactionIDs.contains($0.id) }
    }

    private func toggleAllVisible() {
        if session.isLocal {
            guard var selection = currentLocalSelection,
                  selection.explicitSelectedCount != nil || localSelectionFacts != nil,
                  (session.localTransactionSummary?.matchedCount ?? 0) > 0 else { return }
            selection.setAll(matching: filters, selected: !allVisibleSelected)
            localSelection = selection
            localSelectionFacts = nil
            selectionFeedback &+= 1
            return
        }
        if allVisibleSelected {
            selectedTransactionIDs.removeAll()
        } else {
            selectedTransactionIDs = Set(filteredTransactions.map(\.id))
        }
        selectionFeedback &+= 1
    }

    private func toggleSelection(_ transaction: LedgerTransaction) {
        LedgerFeedback.selection()
        if session.isLocal {
            guard var selection = currentLocalSelection else { return }
            selection.toggle(transaction)
            localSelection = selection
            localSelectionFacts = nil
            return
        }
        if selectedTransactionIDs.contains(transaction.id) {
            selectedTransactionIDs.remove(transaction.id)
        } else {
            selectedTransactionIDs.insert(transaction.id)
        }
    }

    private func beginSelection(with transaction: LedgerTransaction? = nil) {
        if session.isLocal {
            guard let revision = session.localTransactionPresentationRevision else {
                actionMessageStyle = .failure
                actionMessage = String(localized: "账本版本尚未就绪，请刷新后重试。")
                return
            }
            var selection = LocalTransactionSelection(revisionID: revision,
                start: session.selectedRange.start, end: session.selectedRange.queryEndExclusive)
            if let transaction { selection.set(transaction, selected: true) }
            localSelection = selection
            localSelectionFacts = nil
        } else {
            selectedTransactionIDs = Set(transaction.map { [$0.id] } ?? [])
        }
        isSelecting = true
    }

    private func endSelection() {
        isSelecting = false
        localSelection = nil
        localSelectionFacts = nil
        selectedTransactionIDs.removeAll()
    }

    private func loadSelectionFacts(_ key: SelectionReadKey) async {
        localSelectionFacts = nil
        guard key.readable, let selection = key.selection, selection.hasDecisions,
              currentLocalSelection == selection else { return }
        do {
            let facts = try await session.localTransactionSelectionFacts(filter: key.filter, selection: selection)
            guard !Task.isCancelled, selectionReadKey == key else { return }
            localSelectionFacts = facts
        } catch {
            guard !Task.isCancelled, selectionReadKey == key else { return }
            actionMessageStyle = .failure
            actionMessage = error.localizedDescription
        }
    }

    private var accountLabels: [String: String] {
        TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
    }

    private var transactionList: some View {
        let labels = accountLabels
        let displayed = displayedTransactions
        let filtered = filteredTransactions
        let grouped = Dictionary(grouping: displayed, by: \.date)
            .map { (date: $0.key, transactions: $0.value) }
            .sorted { $0.date > $1.date }
        let kindCounts = displayedKindCounts
        let filterSettle = balancedFilterSettle(displayed, accountLabels: labels)
        let summaryDays: [String: LocalTransactionScan.Day] = session.isLocal
            ? Dictionary(session.localTransactionSummary?.days.map { ($0.date, $0) } ?? [], uniquingKeysWith: { first, _ in first })
            : [:]
        return List {
            Section {
                VStack(spacing: 0) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").font(.system(size: 15))
                        TextField("商户、备注或标签", text: $filters.query)
                            .balancedFont(size: 14.5).autocorrectionDisabled()
                            .accessibilityIdentifier("transaction-quick-search")
                        if !filters.query.isEmpty {
                            Button { filters.query = "" } label: { Image(systemName: "xmark.circle") }
                                .frame(width: 44, height: 44).accessibilityLabel("清除流水搜索")
                        }
                    }
                    .foregroundStyle(BalancedPalette.meta).padding(.horizontal, 12)
                    .frame(minHeight: 40).background(BalancedPalette.sunken)
                    .padding(.bottom, 14)
                    BalancedTransactionFilterBar(kindFilter: $filters.kind, counts: kindCounts)
                    HStack {
                        Text((filters.account.flatMap { labels[$0] ?? $0 } ?? String(localized: "全部账户")) + " · " + (displayedCount.map { String(localized: "\($0) 笔") } ?? String(localized: "统计中")))
                            .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        Spacer(minLength: 8)
                        Button("筛选", systemImage: "line.3.horizontal.decrease") { filterPresented = true }
                            .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.ink).frame(minHeight: 44)
                    }
                    .padding(.top, 10)
                }
                .padding(.top, 4)
                .id("transaction-list-top")
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if let filterSettle {
                Section {
                    BalancedTransactionFilterSettle(kind: filters.kind, rows: filterSettle.rows, total: filterSettle.total,
                        count: filterSettle.count, currency: session.ledger?.summary.currency ?? "CNY")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

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
            if session.isLocal {
                if let error = session.localTransactionWindowError {
                    Section {
                        StatusBanner(message: error, onDismiss: {})
                        Button("重新读取流水") { Task { await loadWindow() } }
                    }
                }
                if let error = session.localTransactionSummaryError {
                    Section {
                        StatusBanner(message: error, onDismiss: {})
                        Button("重新统计完整范围") { Task { await session.loadLocalTransactionSummary() } }
                    }
                }
            }
            if displayed.isEmpty && (!session.isLocal || !session.localTransactionHasMore) {
                ContentUnavailableView(
                    filters.query.isEmpty && activeStructuredFilterCount == 0 ? "所选范围暂无流水" : "没有匹配的交易",
                    systemImage: "list.bullet.rectangle",
                    description: Text("调整时间范围或搜索条件。")
                )
            }
            if displayed.isEmpty && session.isLocal && session.localTransactionHasMore {
                // The current window matched nothing but the reader still has rows to
                // check, so keep the spinner reachable instead of stranding the list.
                Section {
                    infiniteScrollFooter
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            ForEach(grouped, id: \.date) { group in
                let parts = balancedDate(group.date)
                Section {
                    ForEach(group.transactions) { transaction in
                        transactionRow(for: transaction, accountLabels: labels)
                    }
                } header: {
                    BalancedTransactionDayHeader(date: parts.date, weekday: parts.weekday, summary: balancedDaySummary(group.transactions, day: summaryDays[group.date]))
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(BalancedPalette.page)
            }
            if !displayed.isEmpty {
                Section {
                    if session.isLocal && session.localTransactionHasMore {
                        infiniteScrollFooter
                    } else {
                        Text(balancedListFootnote)
                            .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                            .padding(.top, 12).padding(.bottom, 20)
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if !session.isLocal && !filtered.isEmpty {
                Section {
                    Text("\(filtered.count) / \(transactions.count) 笔")
                        .balancedFont(size: 12.5).monospacedDigit()
                        .foregroundStyle(BalancedPalette.meta)
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    /// Tail of the scrolling list. Appearing on screen appends the next bounded
    /// window; the row is also a button so a stalled fetch has an explicit retry.
    /// Because windows are appended (never replaced), the reading position holds.
    private var infiniteScrollFooter: some View {
        let loading = session.isLocalTransactionWindowLoading
        return Button {
            guard !loading else { return }
            Task { await session.loadNextLocalTransactionWindow() }
        } label: {
            HStack(spacing: 8) {
                if loading {
                    ProgressView().controlSize(.small).tint(BalancedPalette.meta)
                    Text("正在加载更多流水…")
                } else {
                    Image(systemName: "arrow.down.circle").font(.system(size: 14))
                    Text("继续加载")
                }
            }
            .balancedFont(size: 12)
            .foregroundStyle(BalancedPalette.meta)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .onAppear {
            guard session.localTransactionHasMore, !session.isLocalTransactionWindowLoading else { return }
            Task { await session.loadNextLocalTransactionWindow() }
        }
        .accessibilityIdentifier("transaction-load-more")
        .accessibilityLabel(loading ? "正在加载更多流水" : "继续加载更多流水")
    }

    /// `.note` under the list — the filtered tab points at the settle block
    /// above it instead of repeating the "fully loaded" footnote.
    private var balancedListFootnote: String {
        guard filters.kind == .all else { return String(localized: "筛选只作用于当前区间，其余账目未被隐藏。") }
        let count = displayedTransactions.count
        if session.isLocal, session.localTransactionReachedRowCap {
            return String(localized: "已加载 \(count) 笔，收窄时间范围可以看得更远。长按可多选，左滑显示改分类与对账。")
        }
        return String(localized: "已全部加载 \(count) 笔。长按可多选，左滑显示改分类与对账。")
    }

    private var navigationContent: some View {
        // No ScrollViewReader: appended windows extend the list in place, so the
        // reading position never resets when more rows arrive.
        transactionList
        .listStyle(.plain)
        .listSectionSpacing(0)
        .tint(TerminalPalette.accent)
        .terminalPageChrome(String(localized: "流水"), isRoot: isRoot, showsTimeRange: true, actions: AnyView(transactionActions), balanced: true)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await session.refresh() }
        .task(id: windowRequestKey) {
            if windowRequestKey.readable { await loadWindow(reuseCurrent: true) }
        }
    }

    @ViewBuilder
    private var transactionActions: some View {
        if isSelecting {
            Button("完成") { endSelection() }
                .font(.system(size: 13)).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("完成多选")
        } else if actionRequestID != nil {
            ProgressView().frame(width: 44, height: 44).accessibilityLabel("准备交易操作")
        } else {
            LedgerQuickEntryButton(accessibilityID: "transaction-create-local")
            Menu {
                Button("筛选交易", systemImage: "line.3.horizontal.decrease") { filterPresented = true }
                Button("多选流水", systemImage: "checkmark.circle") { beginSelection() }
                    .accessibilityIdentifier("transaction-tag-selection")
                if session.isLocal {
                    Button("存储与同步", systemImage: "internaldrive") { storagePresented = true }
                        .accessibilityIdentifier("transaction-storage")
                }
                Button("事件与项目核算", systemImage: "tag") { eventTagListPresented = true }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 44, height: 44)
                    .foregroundStyle(TerminalPalette.accent)
            }
            .accessibilityLabel("流水操作")
            .accessibilityIdentifier("transaction-actions")
        }
    }

    private var presentedContent: some View {
        navigationContent
            .sheet(isPresented: $storagePresented) {
                LedgerStorageSheet().ledgerPrivacyProtectedSheet()
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
                        actionMessage = String(localized: "已复制并记录新流水")
                        actionMessageStyle = .confirmed
                        confirmationFeedback &+= 1
                    }
                )
                .ledgerPrivacyProtectedSheet()
            }
            .sheet(item: $editingTarget, onDismiss: revokeListAction) { transaction in
                TransactionEditorView(
                    transaction: transaction,
                    accounts: session.ledger?.accounts ?? [],
                    commodities: session.ledger?.commodities ?? [],
                    onSave: { entry in
                        if session.isLocal {
                            guard let localAction else { throw CancellationError() }
                            do { try await session.updateLocalTransaction(action: localAction, entry: entry) }
                            catch { failListAction(error); throw error }
                        } else {
                            try await session.updateTransaction(source: transaction.source, entry: entry)
                        }
                        actionMessage = String(localized: "交易修改已保存")
                        actionMessageStyle = .confirmed
                        confirmationFeedback &+= 1
                    }
                )
                .ledgerPrivacyProtectedSheet()
            }
            .sheet(item: $deletionTarget, onDismiss: revokeListAction) { transaction in
                TransactionDeleteSheet(transaction: transaction, localAction: localAction,
                    onFailed: { error in if localAction != nil { failListAction(error) } }) {
                    actionMessage = String(localized: "交易已从账本删除")
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
                    onOpenEventReports: { eventTagListPresented = true },
                    facetsReady: !session.isLocal || session.localTransactionSummary != nil,
                    facetsError: session.isLocal ? session.localTransactionSummaryError : nil,
                    onRetryFacets: { Task { await session.loadLocalTransactionSummary() } }
                )
                .ledgerPrivacyProtectedSheet()
            }
            .sheet(isPresented: $eventTagListPresented) {
                EventTagListView()
                    .ledgerPrivacyProtectedSheet()
            }
            .sheet(isPresented: $tagEditorPresented, onDismiss: revokeListAction) {
                TransactionTagEditorSheet(
                    selectedCount: localAction?.originals.count ?? selectedCount,
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
            .sheet(item: $fileExport, onDismiss: cancelFileExport) { export in
                TransactionTextExportSheet(export: export)
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
    }

    var body: some View {
        presentedContent
            .task(id: selectionReadKey) { await loadSelectionFacts(selectionReadKey) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if isSelecting {
                        TransactionBatchActionBar(
                            selectedCount: selectedCount,
                            totalCount: session.isLocal ? (session.localTransactionSummary?.matchedCount ?? 0) : filteredTransactions.count,
                            allSelected: allVisibleSelected,
                            allSelectedTitle: session.isLocal ? String(localized: "取消当前") : String(localized: "清空"),
                            isCounting: session.isLocal && currentLocalSelection?.hasDecisions == true
                                && currentLocalSelection?.explicitSelectedCount == nil && localSelectionFacts == nil,
                            canToggleAll: !session.isLocal || (session.localTransactionSummary != nil
                                && (currentLocalSelection?.explicitSelectedCount != nil || localSelectionFacts != nil)),
                            onToggleAll: toggleAllVisible,
                            onAddTags: handleAddTags,
                            onShare: handleShare,
                            onExport: session.isLocal ? { prepareFileExport() } : nil,
                            isExporting: exportRequestID != nil || preparingLegacyShare
                        )
                    }
                }
            }
            .onChange(of: session.isLocal ? [] : transactions.map(\.id)) { _, ids in
                if !session.isLocal { selectedTransactionIDs.formIntersection(ids) }
            }
            .onChange(of: session.localTransactionPresentationRevision) { _, _ in
                if session.isLocal && isSelecting {
                    endSelection()
                    actionMessageStyle = .failure
                    actionMessage = String(localized: "账本已更新，多选已清空，请重新选择。")
                }
            }
            .onChange(of: session.selectedRange) { _, _ in
                if session.isLocal && isSelecting {
                    endSelection()
                    actionMessageStyle = .failure
                    actionMessage = String(localized: "时间范围已更改，多选已清空，请重新选择。")
                }
            }
            .onChange(of: selectionReadKey) { _, _ in localSelectionFacts = nil }
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
        .onChange(of: windowRequestKey) { _, _ in
            cancelFileExport()
            if preparingTags { revokeListAction() }
        }
        .onChange(of: selectedTransactionIDs) { _, _ in
            cancelFileExport()
            if preparingTags { revokeListAction() }
        }
        .onChange(of: localSelection) { _, _ in
            cancelFileExport()
            if preparingTags { revokeListAction() }
        }
        .onChange(of: isSelecting) { _, selected in
            if !selected { cancelFileExport() }
            if !selected && preparingTags { revokeListAction() }
        }
        .onDisappear {
            if editingTarget == nil && deletionTarget == nil && !tagEditorPresented { revokeListAction() }
            if fileExport == nil { cancelFileExport() }
        }
        .onChange(of: session.privacyShielded) { _, hidden in
            if hidden {
                clearListActionPresentation()
                if session.isLocal { endSelection() }
            }
        }
        .onChange(of: session.phase) { _, phase in
            if phase != .ready {
                clearListActionPresentation()
                if session.isLocal { endSelection() }
            }
        }
        .sensoryFeedback(.success, trigger: confirmationFeedback)
        .sensoryFeedback(.selection, trigger: selectionFeedback)
    }

    @ViewBuilder
    private func transactionRow(for transaction: LedgerTransaction,
                                accountLabels: [String: String]) -> some View {
        if isSelecting {
            let isSelected = session.isLocal
                ? (currentLocalSelection?.contains(transaction) ?? false)
                : selectedTransactionIDs.contains(transaction.id)
            Button {
                toggleSelection(transaction)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(TerminalPalette.accent)
                    BalancedLedgerTransactionRow(transaction: transaction, accountLabels: accountLabels,
                        accountCurrency: session.ledger?.valuationCurrency ?? "CNY")
                }
            }
            .buttonStyle(.plain)
            .listRowBackground(isSelected ? TerminalPalette.panel : TerminalPalette.page)
            .accessibilityIdentifier("transaction-select-row-\(transaction.source.line)")
            .accessibilityValue(isSelected ? "已选择" : "未选择")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            NavigationLink {
                TransactionDetailView(transaction: transaction)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    BalancedLedgerTransactionRow(transaction: transaction, accountLabels: accountLabels,
                        accountCurrency: session.ledger?.valuationCurrency ?? "CNY")
                    if let phase = session.transactionMutationPhase(for: transaction) {
                        TransactionMutationBadge(phase: phase)
                    }
                }
            }
            .buttonStyle(.plain)
            .navigationLinkIndicatorVisibility(.hidden)
            .accessibilityIdentifier("transaction-row-\(transaction.source.line)")
            .listRowBackground(TerminalPalette.page)
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
                    if session.isLocal { prepareListAction([transaction], kind: .delete) }
                    else { deletionTarget = transaction }
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(transaction.source.hash?.isEmpty != false
                    || session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites == true)

                if session.isLocal {
                    Button {
                        LedgerFeedback.light()
                        prepareListAction([transaction], kind: .edit)
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(.orange)
                    .disabled(transaction.source.hash?.isEmpty != false
                        || session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites == true)
                }

                Button {
                    beginSelection(with: transaction)
                } label: {
                    Label("多选", systemImage: "checklist")
                }
                .tint(LedgerPalette.cobalt)
            }
        }
    }

    private func loadWindow(reuseCurrent: Bool = false) async {
        guard session.isLocal, session.phase == .ready, !session.privacyShielded else { return }
        if reuseCurrent {
            await session.ensureLocalTransactionWindow(filter: filters, limits: Self.localWindowLimits)
        } else {
            await session.loadLocalTransactionWindow(filter: filters, limits: Self.localWindowLimits)
        }
        guard !Task.isCancelled else { return }
        await session.loadLocalTransactionSummary()
    }

    private func revokeListAction() {
        preparingTags = false
        actionRequestID = nil
        actionTask?.cancel()
        actionTask = nil
        if let localAction { session.cancelLocalTransactionAction(localAction) }
        localAction = nil
    }

    private func clearListActionPresentation() {
        editingTarget = nil
        deletionTarget = nil
        tagEditorPresented = false
        revokeListAction()
    }

    private func failListAction(_ error: Error) {
        clearListActionPresentation()
        actionMessageStyle = .failure
        actionMessage = error.localizedDescription + String(localized: " 请重新打开交易操作，核对最新内容后再试。")
    }

    private func prepareListAction(_ rows: [LedgerTransaction], kind: LedgerSession.LocalTransactionActionKind) {
        guard actionRequestID == nil, !rows.isEmpty else { return }
        revokeListAction()
        let id = UUID()
        let selection = selectedTransactionIDs
        preparingTags = kind == .addTags
        actionRequestID = id
        actionTask = Task { @MainActor in
            do {
                let prepared = try await session.prepareLocalTransactionAction(sources: rows.map(\.source), kind: kind)
                guard !Task.isCancelled, actionRequestID == id,
                      kind != .addTags || TransactionTagSelectionRules.canPresentPreparedBatch(
                        captured: selection, current: selectedTransactionIDs, isSelecting: isSelecting) else {
                    session.cancelLocalTransactionAction(prepared)
                    return
                }
                if kind == .edit, prepared.originals[0].editableEntry == nil {
                    session.cancelLocalTransactionAction(prepared)
                    throw LedgerTransactionMutationError.sourceUnavailable
                }
                localAction = prepared
                switch kind {
                case .edit: editingTarget = prepared.originals[0]
                case .delete: deletionTarget = prepared.originals[0]
                case .addTags: tagEditorPresented = true
                }
            } catch {
                if !Task.isCancelled, actionRequestID == id {
                    actionMessageStyle = .failure
                    actionMessage = error.localizedDescription
                }
            }
            if actionRequestID == id { preparingTags = false; actionRequestID = nil; actionTask = nil }
        }
    }

    private func isTagEligible(_ transaction: LedgerTransaction) -> Bool {
        transaction.source.hash?.isEmpty == false
            && session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites != true
    }

    private func prepareLocalSelectedTags() {
        guard actionRequestID == nil, isSelecting, selectedCount > 0,
              let selection = currentLocalSelection else { return }
        revokeListAction()
        let id = UUID(), key = windowRequestKey
        preparingTags = true
        actionRequestID = id
        actionTask = Task { @MainActor in
            defer {
                if actionRequestID == id { preparingTags = false; actionRequestID = nil; actionTask = nil }
            }
            @MainActor func stillCurrent() -> Bool {
                !Task.isCancelled && actionRequestID == id && windowRequestKey == key
                    && isSelecting && currentLocalSelection == selection
            }
            do {
                let facts = try await session.localTransactionSelectionFacts(filter: key.filter, selection: selection)
                guard stillCurrent() else { return }
                let sources = try facts.sourcesForTagPreparation()
                let prepared = try await session.prepareLocalTransactionAction(sources: sources, kind: .addTags)
                guard stillCurrent() else {
                    session.cancelLocalTransactionAction(prepared)
                    return
                }
                localAction = prepared
                tagEditorPresented = true
            } catch {
                if stillCurrent() {
                    actionMessageStyle = .failure
                    actionMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleAddTags() {
        if session.isLocal { prepareLocalSelectedTags(); return }
        let eligible = selectedTransactions.filter(isTagEligible)
        if eligible.isEmpty {
            actionMessageStyle = .failure
            actionMessage = String(localized: "所选交易缺少并发校验信息，暂无法添加标签。")
            return
        }
        if eligible.count > TransactionTagSelectionRules.maximumCount {
            actionMessageStyle = .failure
            actionMessage = String(localized: "一次最多为 \(TransactionTagSelectionRules.maximumCount) 笔交易添加标签。")
            return
        }
        tagEditorPresented = true
    }

    private func cancelFileExport() {
        exportRequestID = nil
        exportTask?.cancel()
        exportTask = nil
        if let fileExportOwner { session.discardLocalTransactionShare(fileExportOwner) }
        fileExportOwner = nil
        fileExport = nil
    }

    private func prepareFileExport() {
        guard session.isLocal, isSelecting, selectedCount > 0, exportRequestID == nil,
              let selection = currentLocalSelection else { return }
        cancelFileExport()
        let id = UUID(), key = windowRequestKey
        exportRequestID = id
        exportTask = Task { @MainActor in
            do {
                let export = try await session.prepareLocalTransactionShare(filter: key.filter, selection: selection)
                guard !Task.isCancelled, exportRequestID == id, windowRequestKey == key,
                      isSelecting, currentLocalSelection == selection else {
                    session.discardLocalTransactionShare(export)
                    return
                }
                fileExportOwner = export
                fileExport = export
            } catch {
                if !Task.isCancelled, exportRequestID == id {
                    actionMessageStyle = .failure
                    actionMessage = error.localizedDescription
                }
            }
            if exportRequestID == id { exportRequestID = nil; exportTask = nil }
        }
    }

    private func handleShare() {
        guard selectedCount > 0 else { return }
        LedgerFeedback.light()
        if session.isLocal {
            guard let selection = currentLocalSelection, !preparingLegacyShare else { return }
            preparingLegacyShare = true
            let key = windowRequestKey
            Task { @MainActor in
                defer { preparingLegacyShare = false }
                do {
                    try await session.loadGlobalTransactions()
                    guard isSelecting, currentLocalSelection == selection, windowRequestKey == key else { return }
                    batchSharePresented = true
                } catch {
                    guard isSelecting, currentLocalSelection == selection, windowRequestKey == key else { return }
                    actionMessageStyle = .failure
                    actionMessage = error.localizedDescription
                }
            }
            return
        }
        batchSharePresented = true
    }

    private func applyTags(_ tags: [String]) async throws {
        let appliedCount: Int
        if session.isLocal {
            guard let localAction else { throw CancellationError() }
            appliedCount = localAction.originals.count
            do { try await session.addLocalTransactionTags(action: localAction, tags: tags) }
            catch { failListAction(error); throw error }
        } else {
            let selected = transactions.filter { selectedTransactionIDs.contains($0.id) && isTagEligible($0) }
            guard !selected.isEmpty else { throw LedgerTagValidationError.empty }
            appliedCount = selected.count
            try await session.addTransactionTags(sources: selected.map(\.source), tags: tags)
        }
        endSelection()
        confirmationFeedback &+= 1
        actionMessageStyle = .confirmed
        actionMessage = String(localized: "已验证，并为 \(appliedCount) 条交易添加标签。")
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
    @State private var window: LocalTransactionWindow.Window?
    @State private var summary: LocalTransactionScan.Result?
    @State private var summaryError: String?
    @State private var page = 0
    @State private var displayedPage = 0
    @State private var reload = 0
    @State private var active = false
    @State private var summaryLoading = false
    private struct Request: Equatable {
        let day: String
        let revision: UUID?
        let invalidation: Int
        let readable: Bool
        let active: Bool
        let reload: Int
        var page: Int
    }
    private var readable: Bool {
        session.phase == .ready && !session.privacyShielded && !session.isRangeLoading
            && !session.isValuationCurrencyLoading && !session.transactionMutationStates.values.contains(.pending)
    }
    private var request: Request {
        .init(day: day, revision: session.localTransactionPresentationRevision,
            invalidation: session.localGlobalSearchInvalidation, readable: readable, active: active, reload: reload, page: page)
    }
    private var summaryRequest: Request { var key = request; key.page = 0; return key }
    @State private var completedSummary: Request?
    @State private var completedWindow: Request?
    private var windowMatchesScope: Bool {
        guard let completedWindow else { return false }
        return completedWindow.day == request.day && completedWindow.revision == request.revision
            && completedWindow.invalidation == request.invalidation && readable
    }

    private var transactions: [LedgerTransaction] {
        if session.isLocal { return windowMatchesScope ? (window?.transactions ?? []) : [] }
        return (payload?.transactions ?? []).filter {
            $0.date == day && LedgerTransactionFilter(kind: .expense).matches($0)
        }
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("重试") {
                        if session.isLocal { reload += 1 } else { Task { await load() } }
                    }
                }
            }
            if session.isLocal, let summaryError {
                Text("支出汇总读取失败：" + summaryError).foregroundStyle(.secondary)
                Button("重试汇总") { reload += 1 }
            }
            if loading && transactions.isEmpty {
                ProgressView("正在读取当天支出")
            } else if transactions.isEmpty && errorMessage == nil && (!session.isLocal || (window != nil && windowMatchesScope)) {
                ContentUnavailableView("当天暂无支出", systemImage: "calendar", description: Text(day))
            }
            Section {
                ForEach(transactions) { transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction, snapshotOnly: true)
                    } label: {
                        TransactionRow(
                            transaction: transaction,
                            accountLabels: TransactionCategoryPresentation.accountLabels(session.isLocal ? (session.ledger?.accounts ?? []) : (payload?.accounts ?? []))
                        )
                    }
                    .accessibilityIdentifier("transaction-row-\(transaction.source.line)")
                    .disabled(session.isLocal && loading)
                }
            } header: {
                Group {
                    if session.isLocal {
                        if completedSummary == summaryRequest, let summary { TerminalSectionLabel(text: String(localized: "全部支出 · \(summary.matchedCount) 笔")) }
                        else if summaryLoading { TerminalSectionLabel(text: String(localized: "正在统计全部支出…")) }
                    } else if !transactions.isEmpty { TerminalSectionLabel(text: String(localized: "全部支出 · \(transactions.count) 笔")) }
                }
                .listRowBackground(BalancedPalette.page)
            }
            if session.isLocal, windowMatchesScope, let window {
                HStack {
                    Button("上一页") {
                        let target = max(0, displayedPage - 1)
                        if page == target { reload += 1 } else { page = target }
                    }
                    .balancedFont(size: 13.5)
                    .foregroundStyle(BalancedPalette.ink)
                    .disabled(displayedPage == 0 || loading)
                    Spacer()
                    Text("第 \(displayedPage + 1) 页").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).accessibilityIdentifier("widget-day-page")
                    Spacer()
                    Button("下一页") {
                        let target = displayedPage + 1
                        if page == target { reload += 1 } else { page = target }
                    }
                    .balancedFont(size: 13.5)
                    .foregroundStyle(BalancedPalette.ink)
                    .disabled(window.isComplete || loading)
                }
                .listRowBackground(Color.clear)
            }
        }
        .ledgerReadingList()
        .navigationTitle("\(day) 支出")
        .terminalNativeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .topBarLeading) { PrivacyToolbarButton() }
        }
        .task(id: request) {
            if session.isLocal { await loadLocalWindow() }
            else { await load() }
        }
        .task(id: summaryRequest) { if session.isLocal { await loadLocalSummary() } }
        .onAppear { active = true }
        .onDisappear { active = false }
        .onChange(of: readable) { _, allowed in
            if session.isLocal && !allowed { window = nil; completedWindow = nil; summary = nil; completedSummary = nil }
        }
        .onChange(of: session.localTransactionPresentationRevision) { _, _ in page = 0; displayedPage = 0 }
        .onChange(of: day) { _, _ in page = 0; displayedPage = 0 }
        .refreshable {
            if session.isLocal { page = 0; reload += 1 } else { await load() }
        }
    }

    private func loadLocalWindow() async {
        guard active, readable else { return }
        let key = request
        loading = true; errorMessage = nil
        defer { if key == request { loading = false } }
        do {
            let result = try await session.localWidgetDayWindow(day, index: key.page)
            guard !Task.isCancelled, key == request, readable else { return }
            window = result; completedWindow = key; displayedPage = key.page
        } catch {
            if !Task.isCancelled, key == request { errorMessage = error.localizedDescription }
        }
    }

    private func loadLocalSummary() async {
        guard active, readable else { return }
        let key = summaryRequest
        summaryLoading = true; summaryError = nil
        defer { if key == summaryRequest { summaryLoading = false } }
        do {
            let result = try await session.localWidgetDaySummary(day)
            guard !Task.isCancelled, key == summaryRequest, readable else { return }
            summary = result; completedSummary = key
        } catch {
            if !Task.isCancelled, key == summaryRequest {
                summary = nil; completedSummary = nil; summaryError = error.localizedDescription
            }
        }
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
                .balancedFont(size: 12.5, weight: .medium)
                .foregroundStyle(BalancedPalette.ink)
                .frame(minHeight: 32)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, LedgerSpacing.lg)
        }
    }

    /// `.mark` — an underline, no filled pill.
    private func filterChip(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .balancedFont(size: 12.5)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(BalancedPalette.secondary)
            .padding(.bottom, 6)
            .frame(minHeight: 32, alignment: .bottom)
            .overlay(alignment: .bottom) { BalancedPalette.ink.frame(height: 2) }
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
    var facetsReady = true
    var facetsError: String? = nil
    var onRetryFacets: (() -> Void)? = nil

    private var pickerAccounts: [String] {
        Array(Set(accounts).union(account.map { [$0] } ?? [])).sorted()
    }

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
            List {
                if !facetsReady {
                    Section {
                        if let facetsError {
                            StatusBanner(message: facetsError, onDismiss: {})
                            Button("重新读取筛选项") { onRetryFacets?() }
                        } else { ProgressView("正在读取完整范围筛选项") }
                    }
                }
                Section {
                    Picker("交易类型", selection: $kind) {
                        ForEach(TransactionKindFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: { TerminalSectionLabel(text: String(localized: "交易类型")).listRowBackground(BalancedPalette.page) }

                Section {
                    Picker("账户", selection: $account) {
                        Text("全部账户").tag(Optional<String>.none)
                        ForEach(pickerAccounts, id: \.self) { value in
                            Text(value).tag(Optional(value))
                        }
                    }
                } header: { TerminalSectionLabel(text: String(localized: "账户")).listRowBackground(BalancedPalette.page) }

                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(BalancedPalette.meta)
                        TextField("搜索标签", text: $tagQuery)
                            .balancedFont(size: 15)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if !facetsReady && availableTags.isEmpty && tags.isEmpty {
                        Text("完整标签列表尚未读取").balancedFont(size: 13.5).foregroundStyle(BalancedPalette.meta)
                    } else if availableTags.isEmpty, tags.isEmpty {
                        Text("当前范围没有标签")
                            .balancedFont(size: 13.5).foregroundStyle(BalancedPalette.meta)
                    } else if displayedTags.isEmpty {
                        Text("没有匹配标签")
                            .balancedFont(size: 13.5).foregroundStyle(BalancedPalette.meta)
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
                                    Text("#\(tag)").balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                                    Spacer()
                                    if tags.contains(tag) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(BalancedPalette.ink)
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
                        Text("标签").balancedFont(size: 12.5, weight: .medium).foregroundStyle(BalancedPalette.meta)
                        if !tags.isEmpty {
                            Text("已选 \(tags.count)").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        }
                    }
                    .listRowBackground(BalancedPalette.page)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("选择多个标签时，显示包含其中任一标签的交易。")
                            .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        if let onOpenEventReports {
                            Button {
                                onDone()
                                onOpenEventReports()
                            } label: {
                                Text("打开事件与项目独立核算看板")
                                    .balancedFont(size: 13, weight: .medium)
                                    .foregroundStyle(BalancedPalette.ink)
                                    .padding(.bottom, 1)
                                    .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
                            }
                            .padding(.top, 2)
                        }
                    }
                    .listRowBackground(BalancedPalette.page)
                }

                if kind != .all || account != nil || !tags.isEmpty {
                    Section {
                        Button("重置筛选") {
                            kind = .all
                            account = nil
                            tags.removeAll()
                        }
                        .buttonStyle(.balanced(.risk))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(BalancedPalette.page)
            .navigationTitle("筛选交易")
            .terminalNativeChrome()
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

struct TransactionRow: View {
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
                RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
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
                        font: .system(size: 15.5, weight: .semibold, design: .monospaced),
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
        case .pending: (String(localized: "正在验证并保存"), "clock.arrow.circlepath", LedgerPalette.cobalt)
        case .confirmed: (String(localized: "已保存 · 正在更新"), "checkmark.circle", LedgerPalette.success)
        case .failed: (String(localized: "未保存 · 已恢复"), "arrow.uturn.backward.circle", LedgerPalette.risk)
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
        TransactionRow(transaction: transaction, accountLabels: accountLabels, selectionState: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(selected ? String(localized: "已选择") : String(localized: "未选择"))，\(transaction.payee)")
    }
}

private struct TransactionBatchActionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let allSelected: Bool
    var allSelectedTitle = String(localized: "清空")
    var isCounting = false
    var canToggleAll = true
    let onToggleAll: () -> Void
    let onAddTags: () -> Void
    let onShare: () -> Void
    var onExport: (() -> Void)? = nil
    var isExporting = false

    var body: some View {
        HStack(spacing: LedgerSpacing.sm) {
            Button(allSelected ? allSelectedTitle : String(localized: "全选")) { onToggleAll() }
                .font(.system(.caption, design: .default, weight: .semibold))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(minWidth: 44, minHeight: 40)
                .disabled(!canToggleAll || totalCount == 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(isCounting ? "正在统计已选" : "已选 \(selectedCount) 笔")
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
                    Text("标签")
                }
            }
            .font(.system(.footnote, design: .default, weight: .semibold))
            .foregroundStyle(selectedCount > 0 ? LedgerPalette.cobalt : LedgerPalette.secondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 38)
            .background(LedgerPalette.cobalt.opacity(selectedCount > 0 ? 0.12 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
            .disabled(selectedCount == 0)
            .accessibilityLabel("添加标签")
            .accessibilityIdentifier("transaction-bulk-tag-trigger")

            Menu {
                Button("合并分享（长图与文字）", action: onShare)
                if let onExport { Button("导出完整文字文件", action: onExport).disabled(isExporting) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                    if isExporting { ProgressView().tint(.white) } else { Text("分享") }
                }
            } primaryAction: { onShare() }
            .font(.system(.footnote, design: .default, weight: .semibold))
            .foregroundStyle(LedgerPalette.onBrand)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(selectedCount > 0 ? LedgerPalette.cobalt : LedgerPalette.secondary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
            .disabled(selectedCount == 0)
            .accessibilityLabel("合并分享")
            .accessibilityIdentifier("transaction-batch-share")
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .buttonStyle(PressScaleButtonStyle())
        .padding(.horizontal, LedgerSpacing.lg)
        .padding(.vertical, LedgerSpacing.sm)
        .ledgerFloatingActionSurface()
    }
}

/// d20 look: a `.note`, the batch it applies to, then the tags as `.row`s
/// carrying a `.tag`-style mark. Restyle only — the sheet still takes a
/// free-text tag list from the field below, exactly as before; the frame's
/// per-tag counts would need a data source this sheet does not have.
private struct TransactionTagEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selectedCount: Int
    let onApply: ([String]) async throws -> Void

    @State private var input = ""
    @State private var errorMessage: String?
    @State private var applying = false
    @State private var failureFeedback = 0

    /// The tags typed so far, so the field's contents read as rows while typing.
    private var typedTags: [String] {
        (try? LedgerTagRules.parse(input)) ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("使用空格或逗号分隔多个标签。选中的标签会加到这批流水上，用来做跨月的事件报表。")
                        .balancedFont(size: 12.5)
                        .foregroundStyle(BalancedPalette.meta)
                        .padding(.top, 2)
                        .padding(.bottom, 14)

                    HStack {
                        Text("将添加到")
                            .balancedFont(size: 14)
                            .foregroundStyle(BalancedPalette.secondary)
                        Spacer()
                        Text("\(selectedCount) 条流水")
                            .balancedFont(size: 14, weight: .text)
                            .monospacedDigit()
                            .foregroundStyle(BalancedPalette.ink)
                    }
                    .frame(minHeight: 44)
                    .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }

                    if !typedTags.isEmpty {
                        BalancedSectionLabel(text: String(localized: "将应用"))
                        ForEach(typedTags, id: \.self) { tag in
                            HStack {
                                Text("#" + tag)
                                    .balancedFont(size: 15, weight: .text)
                                    .foregroundStyle(BalancedPalette.ink)
                                Spacer()
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(BalancedPalette.ink)
                            }
                            .frame(minHeight: 44)
                            .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                        }
                    }

                    BalancedSectionLabel(text: String(localized: "新建标签"))
                    TextField("#", text: $input)
                        .balancedMono(size: 15)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(BalancedPalette.ink)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
                        .accessibilityIdentifier("transaction-bulk-tag-input")

                    if let errorMessage {
                        Text(errorMessage)
                            .balancedFont(size: 12.5)
                            .foregroundStyle(BalancedPalette.expense)
                            .padding(.top, 8)
                    }

                    HStack(spacing: 12) {
                        Button("取消") { dismiss() }
                            .buttonStyle(.balanced(.quiet))
                            .disabled(applying)
                        Button(applying ? "正在验证标签" : "应用 \(typedTags.count) 个标签") {
                            Task { await apply() }
                        }
                        .buttonStyle(.balanced(.primary, disabled: applying || typedTags.isEmpty))
                        .disabled(applying || typedTags.isEmpty)
                        .accessibilityIdentifier("transaction-bulk-tag-apply")
                    }
                    .padding(.top, 24)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .background(BalancedPalette.page)
            .navigationTitle(selectedCount == 1 ? "添加标签" : "批量添加标签")
            .terminalNativeChrome()
            .navigationBarTitleDisplayMode(.inline)
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
            errorMessage = String(localized: "添加失败，已恢复原有显示。请检查后重试：\(error.localizedDescription)")
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

    static func build(
        transaction: LedgerTransaction,
        accountLabels: [String: String],
        defaultCurrency: String
    ) -> TransactionMoneyFlow {
        var outflows: [TransactionMoneyFlowLeg] = []
        var inflows: [TransactionMoneyFlowLeg] = []
        for (index, posting) in transaction.postings.enumerated() where posting.amount != 0 {
            let alias = accountLabels[posting.account].flatMap { $0 == posting.account ? nil : $0 }
            let label = alias ?? posting.account.split(separator: ":").last.map(String.init) ?? posting.account
            let visual = TransactionVisualCategory.resolve(account: posting.account, label: label)
            let leg = TransactionMoneyFlowLeg(
                id: "\(posting.account)-\(index)", account: posting.account, label: label,
                iconName: visual.iconName, iconColor: visual.color,
                amount: posting.amount, currency: posting.currency ?? defaultCurrency)
            if posting.amount < 0 { outflows.append(leg) }
            else { inflows.append(leg) }
        }
        return TransactionMoneyFlow(fromLegs: outflows, toLegs: inflows)
    }
}

/// Stable columns for both simple and split transactions. Each leg keeps its
/// own currency; unrelated currencies must never be added into a flow total.
struct TransactionMoneyFlowView: View {
    let flow: TransactionMoneyFlow
    var compact: Bool = false
    var isShareReceipt: Bool = false
    @State private var selectedLeg: TransactionMoneyFlowLeg?

    var body: some View {
        if !flow.fromLegs.isEmpty || !flow.toLegs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("资金流向").balancedFont(size: 12.5, weight: .medium).foregroundStyle(BalancedPalette.meta)
                HStack(alignment: .top, spacing: 12) {
                    column(String(localized: "来源"), legs: flow.fromLegs)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BalancedPalette.edge)
                        .padding(.top, 38)
                        .accessibilityHidden(true)
                    column(String(localized: "去向"), legs: flow.toLegs)
                }
            }
            .accessibilityIdentifier("transaction-money-flow")
            .sheet(item: $selectedLeg) { leg in
                NavigationStack {
                    List {
                        Section {
                            Text(leg.label).balancedFont(size: 15)
                            Text(leg.account).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta).textSelection(.enabled)
                        } header: { TerminalSectionLabel(text: String(localized: "账户")) }
                        Section {
                            AmountLabel(minorUnits: leg.amount, currency: leg.currency,
                                font: .custom(BalancedWeight.text.sansPostscriptName, size: 15))
                                .monospacedDigit()
                        } header: { TerminalSectionLabel(text: String(localized: "本笔金额")) }
                    }
                    .navigationTitle("资金分录")
                    .terminalNativeChrome()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { selectedLeg = nil }
                    } }
                }
                .presentationDetents([.medium, .large])
                .ledgerPrivacyProtectedSheet()
            }
        }
    }

    private func column(_ title: String, legs: [TransactionMoneyFlowLeg]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
            ForEach(legs) { leg in
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: outlineGlyph(leg.iconName))
                        .font(.system(size: 15, weight: .light))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(BalancedPalette.ink)
                        .frame(width: 28, height: 28)
                        .overlay {
                            Circle().stroke(BalancedPalette.edge, lineWidth: 1)
                        }
                    Text(leg.label)
                        .balancedFont(size: 14, weight: .medium)
                        .foregroundStyle(BalancedPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(leg.account)
                        .balancedMono(size: 11)
                        .foregroundStyle(BalancedPalette.meta)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Group {
                        if isShareReceipt {
                            // ImageRenderer has no LedgerSession environment. Explicit exports
                            // use the same standalone amount presentation as the receipt header.
                            ShareAmountText(minorUnits: leg.amount, currency: leg.currency,
                                font: .custom(BalancedWeight.medium.sansPostscriptName, size: 14))
                        } else {
                            AmountLabel(minorUnits: leg.amount, currency: leg.currency,
                                font: .custom(BalancedWeight.medium.sansPostscriptName, size: 14),
                                color: BalancedPalette.ink)
                        }
                    }
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .contentShape(Rectangle())
                .onTapGesture { if !compact { selectedLeg = leg } }
                .accessibilityAddTraits(compact ? [] : .isButton)
                .accessibilityHint(compact ? "" : "查看账户全称与金额")
            }
            if legs.isEmpty {
                Text("无对应分录").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
    @State private var detailTask: Task<Void, Never>?
    @State private var detailRequestID: UUID?
    @State private var localAction: LedgerSession.LocalTransactionAction?
    @State private var detailError: String?
    @State private var localEditCompleted = false
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
            VStack(alignment: .leading, spacing: 0) {
                if let savedMessage {
                    StatusBanner(message: savedMessage, style: .confirmed) { self.savedMessage = nil }
                        .padding(.bottom, 12)
                }

                if transaction.isPendingReview {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(BalancedPalette.expense)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("待核对交易").balancedFont(size: 13, weight: .medium).foregroundStyle(BalancedPalette.expense)
                            Text(transaction.pendingReasons.map(\.label).joined(separator: " · "))
                                .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 16)
                }

                // Hero: kind + date, amount, title, money flow, info rows — one `.band`.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(categoryVisual.categoryLabel).balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink)
                            Text(transaction.date).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                        }
                        Spacer()
                        BalancedTag(text: kindBadgeText(presentation), kind: {
                            switch presentation.kind {
                            case .expense: .pending
                            case .income: .ok
                            case .transfer: .neutral
                            }
                        }())
                    }
                    .padding(.bottom, 16)

                    VStack(spacing: 4) {
                        AmountLabel(
                            minorUnits: presentation.minorUnits,
                            currency: presentation.currency,
                            prefix: amountPrefix(presentation.kind),
                            font: .custom(BalancedWeight.medium.sansPostscriptName, size: 28),
                            color: amountColor(presentation.kind)
                        )
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                        Text(presentation.title)
                            .balancedFont(size: 17, weight: .medium)
                            .foregroundStyle(BalancedPalette.ink)
                            .multilineTextAlignment(.center)

                        if !presentation.subtitle.isEmpty {
                            Text(presentation.subtitle)
                                .balancedFont(size: 14)
                                .foregroundStyle(BalancedPalette.meta)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .padding(.bottom, 10)

                    BalancedPalette.rule.frame(height: 1).padding(.bottom, 14)

                    // Money Flow
                    let moneyFlow = TransactionMoneyFlow.build(
                        transaction: transaction,
                        accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? []),
                        defaultCurrency: session.ledger?.valuationCurrency ?? "CNY"
                    )
                    TransactionMoneyFlowView(flow: moneyFlow)
                        .padding(.bottom, 14)

                    BalancedPalette.rule.frame(height: 1).padding(.bottom, 10)

                    // Info Rows
                    VStack(spacing: 10) {
                        receiptInfoRow(title: String(localized: "交易时间"), value: TransactionDateHeaderFormatter.format(transaction.date))

                        if let tags = transaction.tags, !tags.isEmpty {
                            HStack(alignment: .center) {
                                Text("交易标签").balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                                Spacer()
                                HStack(spacing: 10) {
                                    ForEach(tags, id: \.self) { tag in
                                        Button {
                                            selectedEventTag = tag
                                        } label: {
                                            Text("#\(tag)")
                                                .balancedFont(size: 12.5)
                                                .foregroundStyle(BalancedPalette.ink)
                                                .padding(.bottom, 1)
                                                .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
                                        }
                                        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
                                    }
                                }
                            }
                        }
                    }
                }
                .balancedBand(lead: true)
                .padding(.bottom, 18)

                // Double Entry Breakdown
                BalancedSectionLabel(text: String(localized: "复式分录"), aside: nil)
                HStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        Text("借贷平衡").balancedFont(size: 11.5)
                    }
                    .foregroundStyle(BalancedPalette.income)
                }
                .padding(.bottom, 4)
                VStack(spacing: 0) {
                    ForEach(Array(transaction.postings.enumerated()), id: \.offset) { index, posting in
                        NavigationLink {
                            AccountDetailView(account: posting.account, currency: posting.currency ?? presentation.currency)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(accountLabel(posting.account))
                                        .balancedFont(size: 15, weight: .text)
                                        .foregroundStyle(BalancedPalette.ink)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(posting.account).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta).lineLimit(1)
                                }
                                Spacer()
                                AmountLabel(
                                    minorUnits: abs(posting.amount),
                                    currency: posting.currency ?? presentation.currency,
                                    prefix: posting.amount < 0 ? "−" : "",
                                    font: .custom(BalancedWeight.text.sansPostscriptName, size: 15),
                                    color: posting.amount >= 0 ? BalancedPalette.ink : BalancedPalette.expense
                                )
                                .monospacedDigit()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(BalancedPalette.edge)
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                    }
                }
                .padding(.bottom, 18)

                // Ledger File Source
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(transaction.source.file):\(transaction.source.line)")
                            .balancedMono(size: 11.5).foregroundStyle(BalancedPalette.secondary)
                            .textSelection(.enabled)
                        if let h = transaction.source.hash, !h.isEmpty {
                            Text("哈希指纹 \(h.prefix(12))").balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                } label: {
                    Text("账本源码来源").balancedFont(size: 13).foregroundStyle(BalancedPalette.secondary)
                }
                .balancedBand()
                .padding(.bottom, 18)

                // Bottom Action Buttons
                if !snapshotOnly {
                    HStack(spacing: 10) {
                        Button {
                            LedgerFeedback.light()
                            sharePresented = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 48, height: 48)
                        }
                        .buttonStyle(.balanced(.outline))
                        .accessibilityLabel("分享记账凭证")

                        Button("再记一笔") {
                            LedgerFeedback.light()
                            duplicatePresented = true
                        }
                        .buttonStyle(.balanced(.outline))

                        Button("编辑交易") {
                            LedgerFeedback.light()
                            prepareAction(.edit)
                        }
                        .buttonStyle(.balanced(.primary, disabled:
                            transaction.source.hash?.isEmpty != false
                                || (!session.isLocal && transaction.editableEntry == nil)
                                || sourceUnavailable || detailRequestID != nil
                                || session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites == true
                        ))
                        .disabled(
                            transaction.source.hash?.isEmpty != false
                                || (!session.isLocal && transaction.editableEntry == nil)
                                || sourceUnavailable || detailRequestID != nil
                                || session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites == true
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .ledgerAdaptivePageWidth()
        }
        .background(BalancedPalette.page)
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
        .terminalNativeChrome()
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
                    Button(role: .destructive) { prepareAction(.delete) } label: {
                        Label("删除交易", systemImage: "trash")
                    }
                    .disabled(transaction.source.hash?.isEmpty != false || sourceUnavailable || detailRequestID != nil
                        || session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites == true)
                    .accessibilityIdentifier("transaction-delete")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("编辑") { prepareAction(.edit) }
                        .fontWeight(.semibold)
                        .disabled(
                            transaction.source.hash?.isEmpty != false
                                || (!session.isLocal && transaction.editableEntry == nil)
                                || sourceUnavailable || detailRequestID != nil
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
        .sheet(isPresented: $deletionPresented, onDismiss: revokeAction) {
            TransactionDeleteSheet(transaction: transaction, localAction: localAction,
                onFailed: { error in if localAction != nil { finishFailedAction(error) } },
                onDeleted: { dismiss() })
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
        .sheet(isPresented: $editorPresented, onDismiss: revokeAction) {
            TransactionEditorView(
                transaction: transaction,
                accounts: session.ledger?.accounts ?? [],
                commodities: session.ledger?.commodities ?? [],
                onSave: { entry in
                    let sourceFile = transaction.source.file
                    if session.isLocal {
                        guard let localAction else { throw CancellationError() }
                        do { try await session.updateLocalTransaction(action: localAction, entry: entry) }
                        catch { finishFailedAction(error); throw error }
                        // The original source is consumed. Never hydrate or offer
                        // another action against its optimistic projection while
                        // range-independent replacement resolution is unavailable.
                        localEditCompleted = true
                        editorPresented = false
                        dismiss()
                        return
                    } else {
                        try await session.updateTransaction(source: transaction.source, entry: entry)
                    }
                    confirmedEntry = entry
                    confirmedSourceFile = sourceFile
                    transaction = transaction.projecting(entry: entry)
                    synchronizeTransaction(with: session.ledger)
                    confirmationFeedback &+= 1
                    savedMessage = String(localized: "已验证并保存，正在更新账本。")
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
        .task { await hydrateDetail() }
        .onDisappear {
            if !editorPresented && !deletionPresented { cancelDetail(); revokeAction() }
        }
        .onChange(of: session.privacyShielded) { _, hidden in
            if hidden { editorPresented = false; deletionPresented = false; cancelDetail(); revokeAction() }
        }
        .onChange(of: session.phase) { _, phase in
            if phase != .ready { editorPresented = false; deletionPresented = false; cancelDetail(); revokeAction() }
        }
        .alert("交易操作未完成", isPresented: Binding(
            get: { detailError != nil }, set: { if !$0 { detailError = nil } }
        )) { Button("好", role: .cancel) { detailError = nil } }
        message: { Text(detailError ?? "") }
        .sensoryFeedback(.success, trigger: confirmationFeedback)
    }

    private func revokeAction() {
        if let localAction { session.cancelLocalTransactionAction(localAction) }
        localAction = nil
    }

    private func cancelDetail() {
        detailRequestID = nil
        detailTask?.cancel()
        detailTask = nil
    }

    private func finishFailedAction(_ error: Error) {
        editorPresented = false
        deletionPresented = false
        revokeAction()
        detailError = error.localizedDescription + String(localized: " 请重新打开交易操作，核对最新内容后再试。")
    }

    private func hydrateDetail() async {
        guard session.isLocal, !localEditCompleted, detailRequestID == nil,
              session.transactionMutationPhase(for: transaction)?.blocksFurtherWrites != true else { return }
        let id = UUID()
        detailRequestID = id
        defer { if detailRequestID == id { detailRequestID = nil } }
        do {
            let detail = try await session.localTransactionDetail(source: transaction.source)
            guard !Task.isCancelled, detailRequestID == id else { return }
            transaction = detail
            sourceUnavailable = false
        } catch {
            if !Task.isCancelled, detailRequestID == id {
                detailError = error.localizedDescription
            }
        }
    }

    private func prepareAction(_ kind: LedgerSession.LocalTransactionActionKind) {
        guard !snapshotOnly, detailRequestID == nil else { return }
        guard session.isLocal else {
            if kind == .edit { editorPresented = true } else { deletionPresented = true }
            return
        }
        revokeAction()
        let id = UUID()
        detailRequestID = id
        detailTask = Task { @MainActor in
            do {
                let prepared = try await session.prepareLocalTransactionAction(sources: [transaction.source], kind: kind)
                guard !Task.isCancelled, detailRequestID == id else {
                    session.cancelLocalTransactionAction(prepared)
                    return
                }
                let detail = prepared.originals[0]
                if kind == .edit, detail.editableEntry == nil {
                    session.cancelLocalTransactionAction(prepared)
                    throw LedgerTransactionMutationError.sourceUnavailable
                }
                transaction = detail
                localAction = prepared
                if kind == .edit { editorPresented = true } else { deletionPresented = true }
            } catch {
                if !Task.isCancelled, detailRequestID == id { detailError = error.localizedDescription }
            }
            if detailRequestID == id { detailRequestID = nil; detailTask = nil }
        }
    }

    private func receiptInfoRow(title: String, value: String) -> some View {
        HStack {
            Text(title).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
            Spacer()
            Text(value).balancedFont(size: 13, weight: .medium).foregroundStyle(BalancedPalette.ink)
        }
    }

    private func kindBadgeText(_ presentation: TransactionPresentation) -> String {
        if presentation.isRefund {
            return String(localized: "退款")
        }
        switch presentation.kind {
        case .expense: return String(localized: "支出")
        case .income: return String(localized: "收入")
        case .transfer: return String(localized: "转账")
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
        // An evicted/not-yet-loaded local row needs explicit detail hydration,
        // not a false deletion conclusion from the session's current arrays.
        if case .unloaded = session.transactionResolution(for: transaction.source) { return }
        sourceUnavailable = true
    }
}

private struct TransactionDeleteSheet: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    let transaction: LedgerTransaction
    var localAction: LedgerSession.LocalTransactionAction? = nil
    var onFailed: ((Error) -> Void)? = nil
    let onDeleted: () -> Void
    @State private var reason = ""
    @State private var isDeleting = false
    @State private var failureFeedback = 0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TransactionRow(transaction: transaction)
                } header: {
                    TerminalSectionLabel(text: String(localized: "确认删除这笔交易")).listRowBackground(BalancedPalette.page)
                } footer: {
                    Text("确认后从流水和统计中移除，原交易会作为注释保留在账本文件中。")
                        .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        .listRowBackground(BalancedPalette.page)
                }
                Section {
                    TextField("例如：重复导入", text: $reason, axis: .vertical)
                        .balancedFont(size: 15)
                        .lineLimit(2...4)
                } header: { TerminalSectionLabel(text: String(localized: "删除原因（可选）")).listRowBackground(BalancedPalette.page) }
                if let errorMessage {
                    Section { StatusBanner(message: errorMessage) { self.errorMessage = nil } }
                }
                Section {
                    Button {
                        isDeleting = true
                        errorMessage = nil
                        Task {
                            do {
                                let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                                if let localAction {
                                    try await session.deleteLocalTransaction(action: localAction, reason: trimmedReason)
                                } else {
                                    try await session.deleteTransaction(source: transaction.source, reason: trimmedReason)
                                }
                                dismiss()
                                onDeleted()
                            } catch {
                                errorMessage = error.localizedDescription
                                failureFeedback &+= 1
                                onFailed?(error)
                            }
                            isDeleting = false
                        }
                    } label: {
                        HStack {
                            Text("确认删除")
                            if isDeleting { Spacer(); ProgressView() }
                        }
                    }
                    .buttonStyle(.balanced(.risk))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("transaction-delete-confirm")
                }
            }
            .scrollContentBackground(.hidden)
            .background(BalancedPalette.page)
            .disabled(isDeleting)
            .navigationTitle("删除交易")
            .terminalNativeChrome()
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

    var title: String {
        switch self {
        case .expense: String(localized: "支出")
        case .income: String(localized: "收入")
        case .transfer: String(localized: "转账")
        }
    }

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
        CookieCategoryItem(id: "food", name: String(localized: "餐饮"), icon: "fork.knife", color: Color(red: 0.96, green: 0.55, blue: 0.18), defaultAccountPrefix: "Expenses:Food"),
        CookieCategoryItem(id: "transport", name: String(localized: "交通"), icon: "car.fill", color: Color(red: 0.16, green: 0.54, blue: 0.95), defaultAccountPrefix: "Expenses:Transport"),
        CookieCategoryItem(id: "shopping", name: String(localized: "购物"), icon: "bag.fill", color: Color(red: 0.92, green: 0.32, blue: 0.55), defaultAccountPrefix: "Expenses:Shopping"),
        CookieCategoryItem(id: "daily", name: String(localized: "居家日常"), icon: "house.fill", color: Color(red: 0.12, green: 0.66, blue: 0.72), defaultAccountPrefix: "Expenses:Housing"),
        CookieCategoryItem(id: "digital", name: String(localized: "数码电子"), icon: "antenna.radiowaves.left.and.right", color: Color(red: 0.35, green: 0.45, blue: 0.88), defaultAccountPrefix: "Expenses:Digital"),
        CookieCategoryItem(id: "entertainment", name: String(localized: "休闲娱乐"), icon: "popcorn.fill", color: Color(red: 0.65, green: 0.36, blue: 0.88), defaultAccountPrefix: "Expenses:Entertainment"),
        CookieCategoryItem(id: "health", name: String(localized: "医疗健康"), icon: "heart.fill", color: Color(red: 0.92, green: 0.28, blue: 0.28), defaultAccountPrefix: "Expenses:Health"),
        CookieCategoryItem(id: "education", name: String(localized: "学习提升"), icon: "book.fill", color: Color(red: 0.72, green: 0.48, blue: 0.28), defaultAccountPrefix: "Expenses:Education"),
        CookieCategoryItem(id: "other", name: String(localized: "其它支出"), icon: "cart.fill", color: Color(red: 0.95, green: 0.45, blue: 0.22), defaultAccountPrefix: "Expenses:Other")
    ]

    static let incomeCategories: [CookieCategoryItem] = [
        CookieCategoryItem(id: "salary", name: String(localized: "工资薪水"), icon: "banknote.fill", color: Color(red: 0.12, green: 0.68, blue: 0.36), defaultAccountPrefix: "Income:Salary"),
        CookieCategoryItem(id: "investment", name: String(localized: "理财收益"), icon: "chart.line.uptrend.xyaxis", color: Color(red: 0.08, green: 0.68, blue: 0.55), defaultAccountPrefix: "Income:Investment"),
        CookieCategoryItem(id: "bonus", name: String(localized: "奖金福利"), icon: "gift.fill", color: Color(red: 0.92, green: 0.28, blue: 0.28), defaultAccountPrefix: "Income:Bonus"),
        CookieCategoryItem(id: "reimbursement", name: String(localized: "报销返还"), icon: "arrow.uturn.left.circle.fill", color: Color(red: 0.16, green: 0.54, blue: 0.95), defaultAccountPrefix: "Income:Reimbursement"),
        CookieCategoryItem(id: "other_income", name: String(localized: "其它收入"), icon: "arrow.down.circle.fill", color: Color(red: 0.12, green: 0.68, blue: 0.36), defaultAccountPrefix: "Income:Other")
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
        // `.band`: the keypad is the screen's one sunken well. Keys are square
        // cells split by 1px `--rule` hairlines rather than separate tiles.
        VStack(spacing: 1) {
            HStack(spacing: 1) {
                keypadButton("7") { calculator.appendDigit("7") }
                keypadButton("8") { calculator.appendDigit("8") }
                keypadButton("9") { calculator.appendDigit("9") }
                keypadDeleteButton()
            }
            HStack(spacing: 1) {
                keypadButton("4") { calculator.appendDigit("4") }
                keypadButton("5") { calculator.appendDigit("5") }
                keypadButton("6") { calculator.appendDigit("6") }
                keypadOperatorButton("+") { calculator.appendOperator("+") }
            }
            HStack(spacing: 1) {
                keypadButton("1") { calculator.appendDigit("1") }
                keypadButton("2") { calculator.appendDigit("2") }
                keypadButton("3") { calculator.appendDigit("3") }
                keypadOperatorButton("-") { calculator.appendOperator("-") }
            }
            HStack(spacing: 1) {
                keypadButton(".") { calculator.appendDigit(".") }
                keypadButton("0") { calculator.appendDigit("0") }
                keypadButton("=") { calculator.evaluateToResult() }
                keypadActionButton()
            }
        }
        .padding(.top, 1)
        .background(BalancedPalette.rule)
        .background(BalancedPalette.sunken.ignoresSafeArea(edges: .bottom))
    }

    private func keypadButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            LedgerFeedback.selection()
            action()
        } label: {
            Text(label)
                .balancedFont(size: 22, weight: .text)
                .monospacedDigit()
                .foregroundStyle(BalancedPalette.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(BalancedPalette.sunken)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityIdentifier("keypad-\(label)")
    }

    private func keypadOperatorButton(_ op: String, action: @escaping () -> Void) -> some View {
        Button {
            LedgerFeedback.selection()
            action()
        } label: {
            // U+2212 for the displayed minus (display only — the expression
            // the calculator parses stays ASCII `-`).
            Text(op == "-" ? "−" : op)
                .balancedFont(size: 22, weight: .text)
                .foregroundStyle(BalancedPalette.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(BalancedPalette.sunken)
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
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(BalancedPalette.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(BalancedPalette.sunken)
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
                        .tint(BalancedPalette.page)
                } else {
                    Text(actionTitle)
                        .balancedFont(size: 17, weight: .medium)
                        .foregroundStyle(BalancedPalette.page)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(BalancedPalette.ink)

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
    // onAppear re-fires after the account picker / preview covers dismiss;
    // setup must run once or it clobbers the user's selections.
    @State private var didSetup = false

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
            return String(localized: "支出分类")
        } else if kind == .income {
            if let custom = customIncomeAccount, !custom.isEmpty {
                return accounts.first(where: { $0.account == custom })?.displayLabel ?? custom.components(separatedBy: ":").last ?? custom
            }
            if let item = CookieCategoryItem.incomeCategories.first(where: { $0.id == selectedCategoryID }) {
                return item.name
            }
            return String(localized: "收入分类")
        }
        return String(localized: "分类")
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

                typeSwitcher
                    .padding(.horizontal, LedgerSpacing.lg)
                    .padding(.top, LedgerSpacing.xs)

                heroAmountDisplay
                    .padding(.horizontal, LedgerSpacing.lg)
                    .padding(.top, 18)

                if isSplitMode {
                    splitPostingsView
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            if kind != .transfer {
                                categoryGrid
                            }
                            entryFields
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .frame(maxHeight: .infinity)
                }

                entryFooter
                    .padding(.horizontal, LedgerSpacing.lg)

                if focusedField == nil {
                    CookieKeypadView(
                        calculator: $calculator,
                        actionTitle: calculator.isCalculationPending ? "=" : (transaction == nil ? String(localized: "保存") : String(localized: "完成")),
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: focusedField != nil)
            .background(BalancedPalette.page)
            .contentShape(Rectangle())
            .onTapGesture {
                if focusedField != nil {
                    focusedField = nil
                }
            }
            .navigationTitle(transaction == nil ? "记一笔" : "编辑交易")
            .terminalNativeChrome()
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
                        .foregroundStyle(BalancedPalette.ink)
                    } else if focusedField == .narration {
                        Button("切换到商户") {
                            focusedField = .payee
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BalancedPalette.ink)
                    }
                    Spacer()
                    Button("收起键盘") {
                        focusedField = nil
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BalancedPalette.ink)
                }
            }
            .sheet(item: $activeAccountPickerPurpose) { purpose in
                accountPickerSheet(for: purpose)
            }
            .sheet(isPresented: $showDatePickerSheet) {
                datePickerSheet
            }
            .sensoryFeedback(.error, trigger: failureFeedback)
            .fullScreenCover(isPresented: $naturalLanguagePresented) {
                NaturalLanguageBookkeepingView { dismiss() }
            }
            .fullScreenCover(item: $preparedBookkeeping) { preview in
                BookkeepingPreviewView(preview: preview) { _ in dismiss() }
            }
            .onAppear {
                guard !didSetup else { return }
                didSetup = true
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
                    Text("多分录拆分模式")
                        .balancedFont(size: 14, weight: .medium)
                        .foregroundStyle(BalancedPalette.ink)

                    Spacer()

                    Button {
                        LedgerFeedback.light()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            isSplitMode = false
                        }
                    } label: {
                        Text("返回单分类")
                            .balancedFont(size: 12.5)
                            .foregroundStyle(BalancedPalette.ink)
                            .padding(.bottom, 1)
                            .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            } else {
                HStack(spacing: 0) {
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
                            BalancedMark(title: entryKind.title, selected: kind == entryKind)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
            }
        }
    }

    /// Direction is the one thing chroma means in Balanced, so the draft amount
    /// takes `--out` / `--in`; a transfer or a split has no single direction.
    private var amountColor: Color {
        guard !isSplitMode else { return BalancedPalette.ink }
        switch kind {
        case .expense: return BalancedPalette.expense
        case .income: return BalancedPalette.income
        case .transfer: return BalancedPalette.ink
        }
    }

    private var heroAmountDisplay: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center) {
                Text(isSplitMode && splitPostings.indices.contains(activePostingIndex)
                     ? "分录 \(activePostingIndex + 1) / \(splitPostings.count)" : "金额")
                    .balancedFont(size: 12.5, weight: .medium)
                    .tracking(0.375)
                    .foregroundStyle(BalancedPalette.meta)
                Spacer()
                currencyMenu
            }

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                // `.key--total`: the currency symbol at 0.62em in `--ink-3`, so
                // the figure reads as a number first and a currency second.
                Text(currencySymbol)
                    .balancedFont(size: 25, weight: .text, relativeTo: .title)
                    .foregroundStyle(BalancedPalette.meta)
                // U+2212 for the displayed minus; the calculator's own expression
                // stays ASCII so parsing is unaffected.
                Text(calculator.displayText.replacingOccurrences(of: "-", with: "−"))
                    .balancedFont(size: 40, weight: .medium, relativeTo: .largeTitle)
                    .monospacedDigit()
                    .tracking(-0.4)
                    .foregroundStyle(amountColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 8)
                if !isSplitMode, calculator.isCalculationPending, let res = calculator.evaluatedResult {
                    Text(verbatim: "= \(res)")
                        .balancedFont(size: 15)
                        .monospacedDigit()
                        .foregroundStyle(BalancedPalette.meta)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("金额 \(calculator.displayText) \(selectedCurrency)")
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
    }

    private var currencyMenu: some View {
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
            HStack(spacing: 4) {
                Text(selectedCurrency)
                    .balancedFont(size: 12.5)
                    .foregroundStyle(BalancedPalette.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(BalancedPalette.edge)
            }
            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .padding(.vertical, -10)
        .accessibilityLabel("选择货币，当前\(selectedCurrency)")
    }

    /// Split postings as plain ledger rows: label over mono path, the amount
    /// flush right. The active posting — the one the keypad edits — carries
    /// the `.mark` underline on its amount and a 2px ink bar at the edge.
    private var splitPostingsView: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("分录")
                        .balancedFont(size: 12.5, weight: .medium)
                        .tracking(0.375)
                        .foregroundStyle(BalancedPalette.meta)
                    Spacer()
                    let sum = splitBalanceSum
                    if abs(sum) < 0.001 {
                        BalancedTag(text: String(localized: "已配平"), kind: .ok)
                    } else {
                        Text("差额 \(formattedDecimal(-sum))")
                            .balancedFont(size: 12.5)
                            .monospacedDigit()
                            .foregroundStyle(BalancedPalette.expense)
                        Button {
                            autoBalanceSplit()
                        } label: {
                            linkLabel(String(localized: "配平"), color: BalancedPalette.ink)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minHeight: 44)
                .padding(.horizontal, LedgerSpacing.lg)

                ForEach(Array(splitPostings.enumerated()), id: \.offset) { index, posting in
                    let isSelected = index == activePostingIndex
                    let amount = posting.amount.isEmpty ? "0.00" : posting.amount

                    HStack(spacing: 12) {
                        Button {
                            LedgerFeedback.light()
                            activeAccountPickerPurpose = .splitPosting(index)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(posting.account.isEmpty ? String(localized: "选择账户") : accountDisplayName(posting.account))
                                    .balancedFont(size: 15, weight: .text)
                                    .foregroundStyle(posting.account.isEmpty ? BalancedPalette.expense : BalancedPalette.ink)
                                    .lineLimit(1)
                                if !posting.account.isEmpty {
                                    Text(posting.account)
                                        .balancedMono(size: 11.5)
                                        .foregroundStyle(BalancedPalette.meta)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            selectPosting(index: index)
                        } label: {
                            Text(amount.replacingOccurrences(of: "-", with: "−"))
                                .balancedFont(size: 15, weight: isSelected ? .medium : .text)
                                .monospacedDigit()
                                .foregroundStyle(BalancedPalette.ink)
                                .padding(.bottom, 5)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(isSelected ? BalancedPalette.ink : Color.clear).frame(height: 2)
                                }
                                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])

                        if splitPostings.count > 2 {
                            Button {
                                removePosting(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundStyle(BalancedPalette.meta)
                                    .frame(width: 32, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除第 \(index + 1) 条分录")
                        }
                    }
                    .frame(minHeight: 56)
                    .padding(.horizontal, LedgerSpacing.lg)
                    .overlay(alignment: .leading) {
                        if isSelected { BalancedPalette.ink.frame(width: 2) }
                    }
                    .overlay(alignment: .bottom) {
                        BalancedPalette.rule.frame(height: 1).padding(.leading, LedgerSpacing.lg)
                    }
                }

                Button {
                    addSplitPosting()
                } label: {
                    linkLabel(String(localized: "添加分录"), color: BalancedPalette.ink)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, LedgerSpacing.lg)
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

            if splitPostings.isEmpty || splitPostingsMatchSimpleDraft {
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

    /// Categories as words, not icons: four columns of labels, the active one
    /// carrying the `.mark` underline. A custom account picked through 更多
    /// takes the last cell, so the choice stays visible in the grid.
    private var categoryGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 4)
        let customName = customCategoryDisplayName

        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(currentCategories) { cat in
                let isSelected = customName == nil && selectedCategoryID == cat.id
                Button {
                    LedgerFeedback.selection()
                    focusedField = nil
                    selectedCategoryID = cat.id
                    customExpenseAccount = nil
                    customIncomeAccount = nil
                } label: {
                    BalancedMark(title: cat.name, selected: isSelected, size: 14)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottom)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }

            Button {
                LedgerFeedback.light()
                focusedField = nil
                activeAccountPickerPurpose = .customCategory
            } label: {
                BalancedMark(title: customName ?? String(localized: "更多…"), selected: customName != nil, size: 14)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottom)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择分类，当前\(currentCategoryDisplayName)")
            .accessibilityIdentifier("CookieFastCategoryButton")
        }
        .padding(.horizontal, LedgerSpacing.md)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
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

    /// `.field-row`: the label in `--ink-2` on the left, the value flush right,
    /// a 1px `--rule` under each row. The same rows the Balanced 记一笔 frame uses.
    private func fieldRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .balancedFont(size: 14)
                .foregroundStyle(BalancedPalette.secondary)
                .fixedSize()
            Spacer(minLength: 8)
            value()
        }
        .frame(minHeight: 44)
        .padding(.horizontal, LedgerSpacing.lg)
        .overlay(alignment: .bottom) {
            BalancedPalette.rule.frame(height: 1).padding(.leading, LedgerSpacing.lg)
        }
    }

    private func pickerRow(_ label: String, value: String, identifier: String, accessibility: String, action: @escaping () -> Void) -> some View {
        Button {
            LedgerFeedback.light()
            focusedField = nil
            action()
        } label: {
            fieldRow(label) {
                HStack(spacing: 8) {
                    Text(value)
                        .balancedFont(size: 15, weight: .text)
                        .foregroundStyle(BalancedPalette.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BalancedPalette.edge)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(accessibility)，当前\(value)")
        .accessibilityIdentifier(identifier)
    }

    private func textRow(_ label: String, text: Binding<String>, field: FocusedField, identifier: String) -> some View {
        fieldRow(label) {
            TextField("选填", text: text)
                .balancedFont(size: 15, weight: .text)
                .foregroundStyle(BalancedPalette.ink)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .submitLabel(field == .payee ? .next : .done)
                .onSubmit { focusedField = field == .payee ? .narration : nil }
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
        }
        .contentShape(Rectangle())
        .onTapGesture { focusedField = field }
    }

    private var entryFields: some View {
        VStack(spacing: 0) {
            if kind == .transfer {
                pickerRow(String(localized: "转出"), value: accountDisplayName(transferSourceAccount),
                          identifier: "CookieFastTransferSourceButton", accessibility: String(localized: "选择转出账户")) {
                    activeAccountPickerPurpose = .transferSource
                }
                pickerRow(String(localized: "转入"), value: accountDisplayName(transferTargetAccount),
                          identifier: "CookieFastTransferTargetButton", accessibility: String(localized: "选择转入账户")) {
                    activeAccountPickerPurpose = .transferTarget
                }
            } else {
                pickerRow(kind == .expense ? String(localized: "付款账户") : String(localized: "收款账户"), value: accountDisplayName(assetAccount),
                          identifier: "CookieFastAccountButton",
                          accessibility: kind == .expense ? String(localized: "选择付款账户") : String(localized: "选择收款账户")) {
                    activeAccountPickerPurpose = .funding
                }
            }
            pickerRow(String(localized: "日期"), value: dateChipLabel, identifier: "CookieFastDateButton", accessibility: String(localized: "选择日期")) {
                showDatePickerSheet = true
            }
            textRow(kind == .income ? String(localized: "付款方") : String(localized: "商户"), text: $payee, field: .payee, identifier: "CookieFastPayeeField")
            textRow(String(localized: "备注"), text: $narration, field: .narration, identifier: "CookieFastNarrationField")
        }
    }

    /// `.link`: 12.5px text over a 1px `--rule-strong` underline.
    private func linkLabel(_ title: String, color: Color = BalancedPalette.secondary) -> some View {
        Text(title)
            .balancedFont(size: 12.5)
            .foregroundStyle(color)
            .padding(.bottom, 1)
            .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
    }

    private var entryFooter: some View {
        HStack(spacing: 20) {
            if transaction == nil {
                Button {
                    LedgerFeedback.light()
                    naturalLanguagePresented = true
                } label: {
                    linkLabel(String(localized: "用一句话记账"))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bookkeeping-natural-entry")
            }
            Spacer(minLength: 0)
            if !isSplitMode {
                Button {
                    LedgerFeedback.selection()
                    focusedField = nil
                    withAnimation(.easeInOut(duration: 0.2)) { toggleSplitMode() }
                } label: {
                    linkLabel(String(localized: "拆分成多条分录"))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("开启分录拆分")
                .accessibilityIdentifier("CookieFastSplitButton")
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
            case .funding: return kind == .expense ? String(localized: "选择付款账户") : String(localized: "选择收款账户")
            case .transferSource: return String(localized: "选择转出账户")
            case .transferTarget: return String(localized: "选择转入账户")
            case .customCategory: return kind == .expense ? String(localized: "选择支出分类") : String(localized: "选择收入分类")
            case .splitPosting(let idx): return String(localized: "选择第 \(idx + 1) 条分录账户")
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
                        case .transferSource: return transferSourceAccount.isEmpty ? assetAccount : transferSourceAccount
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

    /// 记账日期 — `.seg`-style quick-date strip over the page, no panel card.
    private var datePickerSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    quickDateButton(title: String(localized: "今天"), targetDate: Date())
                    quickDateButton(title: String(localized: "昨天"), targetDate: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
                    quickDateButton(title: String(localized: "前天"), targetDate: Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date())
                }
                .padding(.top, 16)

                DatePicker("选择日期", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(BalancedPalette.ink)
                    .padding(.horizontal)

                Spacer()
            }
            .background(BalancedPalette.page)
            .navigationTitle("记账日期")
            .terminalNativeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showDatePickerSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// `.seg-inline`: 1px `--edge` border, `--ink` fill only on the active item.
    private func quickDateButton(title: String, targetDate: Date) -> some View {
        let isSameDay = Calendar.current.isDate(date, inSameDayAs: targetDate)
        return Button {
            LedgerFeedback.selection()
            date = targetDate
            showDatePickerSheet = false
        } label: {
            Text(title)
                .balancedFont(size: 13, weight: isSameDay ? .medium : .regular)
                .foregroundStyle(isSameDay ? BalancedPalette.page : BalancedPalette.secondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(isSameDay ? BalancedPalette.ink : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(BalancedPalette.edge, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var currencySymbol: String {
        Self.currencySymbol(for: selectedCurrency)
    }

    private var dateChipLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "今天") }
        if cal.isDateInYesterday(date) { return String(localized: "昨天") }
        return LedgerDateLabel.monthDay(date)
    }

    private func accountDisplayName(_ path: String) -> String {
        guard !path.isEmpty else { return String(localized: "选择账户") }
        return accounts.first(where: { $0.account == path })?.displayLabel ?? path.components(separatedBy: ":").last ?? path
    }

    private func setupFromInitialValues() {
        date = initialDate
        if CookieCategoryItem.expenseCategories.contains(where: { $0.name == initialPayee })
            || CookieCategoryItem.incomeCategories.contains(where: { $0.name == initialPayee })
            || initialPayee == String(localized: "记账") || initialPayee == String(localized: "拆分账单") || initialPayee == String(localized: "转账") {
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
                // The negative posting is the source regardless of posting order.
                // An elided (blank) amount balances the other posting, so it is
                // the source when the other one is positive.
                let a1 = p1.amount.trimmingCharacters(in: .whitespaces)
                let a2 = p2.amount.trimmingCharacters(in: .whitespaces)
                let p1IsSource = a1.hasPrefix("-") || (a1.isEmpty && !a2.hasPrefix("-"))
                transferSourceAccount = p1IsSource ? p1.account : p2.account
                transferTargetAccount = p1IsSource ? p2.account : p1.account
            }
        }
        if initialPostings.isEmpty {
            selectedCurrency = TransactionEditorView.defaultCurrency(
                valuation: session.ledger?.valuationCurrency, commodities: commodities)
        }

        if transferSourceAccount.isEmpty && transferTargetAccount.isEmpty {
            let remembered = CookieTransferMemory.load(validAccounts: Set(assetAccounts.map(\.account)))
            transferSourceAccount = remembered.source ?? ""
            transferTargetAccount = remembered.target ?? ""
        }

        if assetAccount.isEmpty, let remembered = CookieFundingMemory.load(validAccounts: Set(assetAccounts.map(\.account))) {
            assetAccount = remembered
        }
        if assetAccount.isEmpty {
            assetAccount = assetAccounts.first(where: { $0.account.contains("Wechat") || $0.account.contains("Alipay") || $0.account.contains("Bank") })?.account
                ?? assetAccounts.first?.account ?? "Assets:CN:Bank:Checking"
        }
        if transferSourceAccount.isEmpty {
            transferSourceAccount = assetAccount
        }
        if transferTargetAccount.isEmpty || transferTargetAccount == transferSourceAccount {
            transferTargetAccount = assetAccounts.first(where: { $0.account != transferSourceAccount })?.account
                ?? assetAccounts.last?.account ?? "Assets:CN:Wechat:Balance"
        }
    }

    /// Two-posting splits are just a copy of the simple draft; rebuild them
    /// from the currently selected accounts so they never go stale. Splits
    /// with extra postings are user work and are kept.
    private var splitPostingsMatchSimpleDraft: Bool {
        splitPostings.count <= 2
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
                cleanNarration = String(localized: "拆分账单")
            } else if kind == .transfer {
                cleanNarration = String(localized: "转账")
            } else {
                let item = currentCategories.first(where: { $0.id == selectedCategoryID })
                cleanNarration = item?.name ?? (kind == .expense ? String(localized: "支出") : String(localized: "收入"))
            }
        }

        let parsedTags: [String] = (try? LedgerTagRules.parse(tagsText)) ?? []

        let postings: [LedgerTransactionEntryPosting]

        if isSplitMode {
            updateActivePostingAmount()
            for (idx, p) in splitPostings.enumerated() {
                if p.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errorMessage = String(localized: "第 \(idx + 1) 条分录请选择账户")
                    failureFeedback &+= 1
                    return
                }
            }
            let sum = splitBalanceSum
            if abs(sum) >= 0.01 {
                errorMessage = String(localized: "分录尚未平衡，借贷差额为 \(formattedDecimal(sum))，请点击「配平」")
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
                errorMessage = String(localized: "请输入有效金额")
                failureFeedback &+= 1
                return
            }

            let amountText = ExactBookkeepingAmount.text(amountVal)
            let negativeAmountText = ExactBookkeepingAmount.text(-amountVal)

            if kind == .transfer && transferSourceAccount == transferTargetAccount {
                errorMessage = String(localized: "转出和转入账户不能相同")
                failureFeedback &+= 1
                return
            }

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

        if !isSplitMode && kind == .transfer {
            CookieTransferMemory.save(source: transferSourceAccount, target: transferTargetAccount)
        } else if !isSplitMode {
            CookieFundingMemory.save(assetAccount)
        }

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
        case .payeeRequired: String(localized: "请输入交易说明或交易对方")
        case .metadataInvalid: String(localized: "元数据需要使用 JSON 对象格式")
        case let .metadataKeyInvalid(key): String(localized: "元数据键 \(key) 格式无效")
        case .postingsRequired: String(localized: "交易至少需要两条分录")
        case let .accountRequired(index): String(localized: "第 \(index + 1) 条分录缺少账户")
        case let .amountInvalid(index): String(localized: "第 \(index + 1) 条分录金额格式无效")
        case let .currencyInvalid(index): String(localized: "第 \(index + 1) 条分录币种格式无效")
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
    private var requiresAdvancedEditor = false
    /// A new entry with nothing prefilled. The advanced form still needs
    /// placeholder postings, but the fast editor picks its own defaults
    /// (common category, last-used funding account) instead of whichever
    /// Expenses/Assets account happens to sort first.
    private var fastEditorStartsBlank = false

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
        requiresAdvancedEditor: Bool = false,
        onSave: @escaping (LedgerTransactionEntry) async throws -> Void
    ) {
        let baseline = transaction.editableEntry
        self.transaction = transaction
        self.accounts = accounts
        self.commodities = commodities
        self.onSave = onSave
        self.requiresAdvancedEditor = requiresAdvancedEditor

        let hasComplexCostOrPrice = baseline?.postings.contains(where: { $0.costKind != nil || $0.priceKind != nil }) ?? false
        _mode = State(initialValue: requiresAdvancedEditor ? .advanced : (initialMode ?? (hasComplexCostOrPrice ? .advanced : .fast)))

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
            fastEditorStartsBlank = prefillPayee.isEmpty && prefillNarration.isEmpty
            _postings = State(initialValue: [
                EditableTransactionPosting(account: accounts.first(where: { $0.active && $0.account.hasPrefix("Expenses:") })?.account ?? "Expenses:Other", amount: "", currency: Self.defaultCurrency(valuation: nil, commodities: commodities)),
                EditableTransactionPosting(account: accounts.first(where: { $0.active && $0.account.hasPrefix("Assets:") })?.account ?? "Assets:Cash", amount: "", currency: "")
            ])
        }
    }

    /// The currency a blank entry starts in. `commodities` is sorted, so its
    /// first entry is often a ticker like AAPL; prefer the ledger's valuation
    /// currency, then a common fiat code the ledger declares, then CNY.
    static func defaultCurrency(valuation: String?, commodities: [String]) -> String {
        if let valuation, !valuation.isEmpty { return valuation }
        let fiat = ["CNY", "USD", "EUR", "HKD", "JPY", "GBP"]
        return fiat.first(where: commodities.contains) ?? "CNY"
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
                    initialPostings: fastEditorStartsBlank ? [] : postings,
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
        .fullScreenCover(isPresented: $naturalLanguagePresented) {
            NaturalLanguageBookkeepingView { dismiss() }
        }
        .fullScreenCover(item: $preparedBookkeeping) { preview in
            BookkeepingPreviewView(preview: preview) { _ in dismiss() }
        }
    }

    private var advancedFormView: some View {
        NavigationStack {
            List {
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
                            quickDateChip(title: String(localized: "今天"), targetDate: Date())
                            quickDateChip(
                                title: String(localized: "昨天"),
                                targetDate: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                            )
                            quickDateChip(
                                title: String(localized: "前天"),
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
                                title: String(localized: "选择账户"),
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
                        postings.append(EditableTransactionPosting(account: "", amount: "0.00", currency: Self.defaultCurrency(
                            valuation: session.ledger?.valuationCurrency, commodities: commodities)))
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
            .terminalNativeChrome()
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
                    .disabled(saving || requiresAdvancedEditor)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text(transaction == nil ? "预览" : "保存") }
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
                            LabeledContent(posting.account, value: posting.amount.isEmpty ? String(localized: "自动配平") : "\(posting.amount) \(posting.currency)")
                                .font(.subheadline.monospaced())
                        }
                        if !entry.tags.isEmpty { Text(entry.tags.map { "#" + $0 }.joined(separator: " ")) }
                        if !entry.metadata.isEmpty { Text(Self.metadataText(entry.metadata)).font(.footnote.monospaced()) }
                    }
                }
                .navigationTitle("交易预览")
                .terminalNativeChrome()
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
            errorMessage = String(localized: "保存失败，账本保留原版本：\(error.localizedDescription)")
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
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .monospaced))
                .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.primary : Color(uiColor: .tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm))
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

/// Category/account preset data bakes in filled SF Symbol names
/// (`cart.fill`, `house.fill`, …) for the terminal design's chroma icon
/// tiles. Balanced reserves chroma for direction only and draws every
/// glyph as a 1px stroke, so every call site here strips the `.fill`
/// suffix rather than touching the shared preset data other screens still
/// render filled.
func outlineGlyph(_ name: String) -> String {
    name.hasSuffix(".fill") ? String(name.dropLast(5)) : name
}

/// The account the last fast expense or income was paid from or into, so the
/// next entry starts there instead of on a guessed asset account.
enum CookieFundingMemory {
    private static let key = "ledger.fastEntry.lastFundingAccount"

    static func load(validAccounts: Set<String>, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key).flatMap { validAccounts.contains($0) ? $0 : nil }
    }

    static func save(_ account: String, defaults: UserDefaults = .standard) {
        guard !account.isEmpty else { return }
        defaults.set(account, forKey: key)
    }
}

/// Remembers the last transfer route so new transfers start from the accounts
/// the user actually moves money between instead of the first asset account.
enum CookieTransferMemory {
    private static let sourceKey = "ledger.fastEntry.lastTransferSource"
    private static let targetKey = "ledger.fastEntry.lastTransferTarget"

    static func load(
        validAccounts: Set<String>,
        defaults: UserDefaults = .standard
    ) -> (source: String?, target: String?) {
        let source = defaults.string(forKey: sourceKey).flatMap { validAccounts.contains($0) ? $0 : nil }
        var target = defaults.string(forKey: targetKey).flatMap { validAccounts.contains($0) ? $0 : nil }
        if target == source { target = nil }
        return (source, target)
    }

    static func save(source: String, target: String, defaults: UserDefaults = .standard) {
        guard !source.isEmpty, !target.isEmpty, source != target else { return }
        defaults.set(source, forKey: sourceKey)
        defaults.set(target, forKey: targetKey)
    }
}
