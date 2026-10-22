import SwiftUI

struct PendingInboxView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss

    enum FilterTab: String, CaseIterable, Identifiable {
        case all = "全部"
        case uncategorized = "未分类"
        case needsReview = "待核对"
        case missingPayee = "缺商户"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "全部")
            case .uncategorized: String(localized: "未分类")
            case .needsReview: String(localized: "待核对")
            case .missingPayee: String(localized: "缺商户")
            }
        }

        var filter: LedgerPendingFilter {
            switch self {
            case .all: return .all
            case .uncategorized: return .uncategorized
            case .needsReview: return .needsReview
            case .missingPayee: return .missingPayee
            }
        }
    }

    @State private var selectedTab: FilterTab = .all
    @State private var editingPayeeTarget: LedgerTransaction?
    @State private var editingCategoryTarget: LedgerTransaction?
    @State private var fullEditorTarget: LedgerTransaction?
    @State private var actionMessage: String?
    @State private var actionFeedback = 0
    @State private var updating = false
    @State private var localWindow: LedgerSession.LocalPendingWindow?
    @State private var completedRequest: ReadRequest?
    @State private var loading = false
    @State private var loadError: String?
    @State private var reload = 0
    /// Rows appended by scrolling, plus the cursor for the next window. The summary
    /// counts come from `localWindow`, which always describes the whole range.
    @State private var accumulated: [LedgerTransaction] = []
    @State private var loadedIDs: Set<String> = []
    @State private var continuation: LedgerSession.LocalPendingContinuation?
    @State private var reachedRowCap = false
    static let rowCap = 1_000
    @State private var active = false
    @State private var localAction: LedgerSession.LocalTransactionAction?
    @State private var actionTask: Task<Void, Never>?
    @State private var actionID: UUID?
    @State private var actionStyle: LedgerStatusStyle = .confirmed
    @State private var feedbackGeneration = UUID()
    private enum PendingAction { case category, payee, full, verify }
    private struct ReadRequest: Equatable {
        let revision: UUID?
        let invalidation: Int
        let range: LedgerDateRange
        let filter: LedgerPendingFilter
        let readable: Bool
        let active: Bool
        let reload: Int
    }
    private var request: ReadRequest {
        .init(revision: session.localTransactionPresentationRevision, invalidation: session.localGlobalSearchInvalidation,
            range: session.selectedRange, filter: selectedTab.filter,
            readable: session.phase == .ready && !session.privacyShielded && !session.isRangeLoading
                && !session.isValuationCurrencyLoading && !session.transactionMutationStates.values.contains(.pending),
            active: active, reload: reload)
    }
    private var windowCurrent: Bool {
        guard let completedRequest else { return false }
        return completedRequest.revision == request.revision && completedRequest.invalidation == request.invalidation
            && completedRequest.range == request.range && completedRequest.filter == request.filter && request.readable
    }
    private var totalCount: Int { session.isLocal ? (windowCurrent ? localWindow?.result.totalCount ?? 0 : 0) : pendingItems.count }
    private var filteredCount: Int { session.isLocal ? (localWindow?.result.counts[selectedTab.filter] ?? 0) : filteredItems.count }

    private var allTransactions: [LedgerTransaction] {
        session.isLocal ? (windowCurrent ? accumulated : []) : session.visibleTransactions
    }
    private var hasMore: Bool { session.isLocal && continuation != nil && !reachedRowCap }

    private var pendingItems: [(transaction: LedgerTransaction, reasons: [PendingTransactionReason])] {
        allTransactions.compactMap { tx in
            let reasons = tx.pendingReasons
            return reasons.isEmpty ? nil : (tx, reasons)
        }
    }

    private var filteredItems: [(transaction: LedgerTransaction, reasons: [PendingTransactionReason])] {
        switch selectedTab {
        case .all:
            return pendingItems
        case .uncategorized:
            return pendingItems.filter { item in
                item.reasons.contains { if case .uncategorized = $0 { return true }; return false }
            }
        case .needsReview:
            return pendingItems.filter { item in
                item.reasons.contains { if case .needsReviewFlag = $0 { return true }; return false }
                    || item.reasons.contains { if case .pendingTag = $0 { return true }; return false }
            }
        case .missingPayee:
            return pendingItems.filter { item in
                item.reasons.contains { if case .missingPayee = $0 { return true }; return false }
            }
        }
    }

    private var availableExpenseAccounts: [String] {
        if session.isLocal { return localWindow?.result.expenseAccounts ?? [] }
        let accounts = session.ledger?.accounts.map(\.account).filter { $0.hasPrefix("Expenses:") } ?? []
        let transactionAccounts = allTransactions.flatMap { $0.postings.map(\.account) }.filter { $0.hasPrefix("Expenses:") }
        return Array(Set(accounts + transactionAccounts)).sorted()
    }

    private var totalPendingMinorUnits: Int {
        if session.isLocal { return localWindow?.result.totalMinorUnits ?? 0 }
        return pendingItems.reduce(0) { sum, item in
            let p = TransactionPresentation(transaction: item.transaction)
            return sum + p.minorUnits
        }
    }

    private var accountLabels: [String: String] {
        TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
    }

    /// Grouped by date, newest first — matching d09's day separators. Times
    /// aren't part of `LedgerTransaction` (date-only), so unlike the
    /// transactions tab there is no per-row time gutter here.
    private var groupedByDate: [(date: String, items: [(transaction: LedgerTransaction, reasons: [PendingTransactionReason])])] {
        Dictionary(grouping: filteredItems, by: { $0.transaction.date })
            .map { (date: $0.key, items: $0.value) }
            .sorted { $0.date > $1.date }
    }

    private func isFlagged(_ reasons: [PendingTransactionReason]) -> Bool {
        reasons.contains {
            if case .needsReviewFlag = $0 { return true }
            if case .pendingTag = $0 { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.isLocal && !windowCurrent {
                    if loading { ProgressView("正在统计全部待整理账单…") } else { Color.clear }
                } else if totalCount == 0 {
                    allCleanState
                } else {
                    inboxContent
                }
            }
            .scrollContentBackground(.hidden)
            .background(BalancedPalette.page)
            .overlay(alignment: .topLeading) {
                // Hidden marker kept for XCUITest parity — the visible total now
                // lives in the `.band` summary (`涉及笔数`), not a toolbar badge.
                Text("\(totalCount) 笔待办")
                    .font(.system(size: 1)).foregroundStyle(.clear)
                    .accessibilityIdentifier("pending-inbox-total")
            }
            // The frame's title is "待整理"/"完成"; kept as "待整理账单"/"关闭" to
            // match `testLocalPendingInboxHydratesPayeeCancelReopenAndCommit`,
            // which asserts on these exact strings.
            .navigationTitle("待整理账单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .balancedFont(size: 15, weight: .medium)
                        .foregroundStyle(BalancedPalette.ink)
                }
            }
            .tint(BalancedPalette.ink)
            .sheet(item: $editingCategoryTarget, onDismiss: revokeAction) { tx in
                PendingCategorySuggestionSheet(
                    transaction: tx,
                    availableAccounts: availableExpenseAccounts,
                    accountLabels: accountLabels
                ) { newAccount in
                    await updateCategory(for: tx, to: newAccount)
                }
                .ledgerPrivacyProtectedSheet()
            }
            .sheet(item: $editingPayeeTarget, onDismiss: revokeAction) { tx in
                QuickPayeeEditorSheet(transaction: tx) { newPayee, newNarration in
                    await updatePayee(for: tx, payee: newPayee, narration: newNarration)
                }
                .ledgerPrivacyProtectedSheet()
            }
            .sheet(item: $fullEditorTarget, onDismiss: revokeAction) { tx in
                TransactionEditorView(
                    transaction: tx,
                    accounts: session.ledger?.accounts ?? [],
                    commodities: session.ledger?.commodities ?? [],
                    initialMode: session.isLocal ? .advanced : nil,
                    requiresAdvancedEditor: session.isLocal,
                    onSave: { entry in
                        let token = feedbackGeneration
                        try await save(entry, original: tx)
                        publishFeedback(String(localized: "交易修改已保存"), style: .confirmed, token: token)
                    }
                )
                .ledgerPrivacyProtectedSheet()
            }
            .task(id: request) { if session.isLocal { await loadWindow() } }
            .onAppear { active = true }
            .onDisappear {
                active = false
                if editingCategoryTarget == nil && editingPayeeTarget == nil && fullEditorTarget == nil { revokeAction() }
            }
            .onChange(of: selectedTab) { _, _ in resetAccumulation() }
            .onChange(of: session.localTransactionPresentationRevision) { _, _ in resetAccumulation() }
            .onChange(of: session.selectedRange) { _, _ in resetAccumulation() }
            .onChange(of: session.privacyShielded) { _, hidden in if hidden { clearActions() } }
            .onChange(of: session.phase) { _, phase in if phase != .ready { clearActions() } }
            .overlay(alignment: .top) {
                if actionID != nil {
                    Text("正在读取原始交易…").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        .padding(10).background(BalancedPalette.sunken)
                }
            }
        }
    }

    private var inboxContent: some View {
        VStack(spacing: 0) {
            if let actionMessage, !session.isLocal || request.readable {
                StatusBanner(message: actionMessage, style: actionStyle) { self.actionMessage = nil }
                    .padding(.horizontal, 20).padding(.top, 8)
            }
            if session.isLocal, let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loadError).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    Button("重新读取待整理账单") { reload += 1 }.buttonStyle(.balanced(.quiet))
                }
                .padding(.horizontal, 20).padding(.top, 8)
            }

            summaryBand
                .padding(.horizontal, 20)
                .padding(.top, 10)

            statusTabs
                .padding(.horizontal, 20)
                .padding(.top, 14)

            if filteredItems.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "checkmark.circle").font(.system(size: 30, weight: .light)).foregroundStyle(BalancedPalette.meta)
                    Text("该分类下没有待整理账单").balancedFont(size: 16, weight: .medium).foregroundStyle(BalancedPalette.ink)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footerBar
            } else {
                List {
                    ForEach(groupedByDate, id: \.date) { group in
                        Section {
                            ForEach(group.items, id: \.transaction.id) { item in pendingRow(item) }
                        } header: {
                            HStack {
                                Text(group.date).balancedFont(size: 12).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                                Spacer()
                                Text("\(group.items.count) 笔").balancedFont(size: 12).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                            }
                            .padding(.top, 12).padding(.bottom, 5)
                            .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
                            .textCase(nil)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    }
                    if session.isLocal, hasMore {
                        Section {
                            loadMoreFooter
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .listSectionSpacing(0)
                .scrollContentBackground(.hidden)
                // The primary action docks under the list; paging is the list's
                // own tail so rows append in place, the same way `TransactionsView`
                // scrolls through its bounded windows.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    footerBar
                }
            }
        }
    }

    private var footerBar: some View {
        Button("逐条整理") {
            if let first = filteredItems.first { prepare(first.transaction, action: .category) }
        }
        .buttonStyle(.balanced(.primary, disabled: filteredItems.isEmpty))
        .disabled(filteredItems.isEmpty)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(BalancedPalette.page)
        .overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    /// `.band`: 待整理金额 (`--out` — unresolved money), 涉及笔数 (ink), then a
    /// note explaining that classification is incomplete, not the amounts.
    private var summaryBand: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("待整理金额").balancedFont(size: 14).foregroundStyle(BalancedPalette.secondary)
                Spacer()
                BalancedAmount(minorUnits: totalPendingMinorUnits, currency: "CNY", size: 15, color: BalancedPalette.expense)
            }
            .padding(.vertical, 3)
            HStack(alignment: .firstTextBaseline) {
                Text("涉及笔数").balancedFont(size: 14).foregroundStyle(BalancedPalette.secondary)
                Spacer()
                Text("\(totalCount)").balancedFont(size: 15, weight: .text).monospacedDigit().foregroundStyle(BalancedPalette.ink)
            }
            .padding(.vertical, 3)
            Text("这些流水已经写入，只是分类或商户还空着。补全不会改变金额。")
                .balancedFont(size: 12.5)
                .foregroundStyle(BalancedPalette.meta)
                .lineSpacing(2)
                .padding(.top, 8)
        }
        .balancedBand()
    }

    /// `.mark` filter strip with counts, per d09.
    private var statusTabs: some View {
        HStack(spacing: 18) {
            ForEach(FilterTab.allCases) { tab in
                let count = session.isLocal ? (localWindow?.result.counts[tab.filter] ?? 0) : countFor(tab)
                Button {
                    LedgerFeedback.selection()
                    withAnimation(.easeOut(duration: 0.18)) { selectedTab = tab }
                } label: {
                    BalancedMark(title: "\(tab.title) \(count)", selected: selectedTab == tab, size: 14)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
    }

    private func countFor(_ tab: FilterTab) -> Int {
        switch tab {
        case .all: return pendingItems.count
        case .uncategorized: return pendingItems.filter { $0.reasons.contains { if case .uncategorized = $0 { return true }; return false } }.count
        case .needsReview: return pendingItems.filter {
            $0.reasons.contains { if case .needsReviewFlag = $0 { return true }; return false }
                || $0.reasons.contains { if case .pendingTag = $0 { return true }; return false }
        }.count
        case .missingPayee: return pendingItems.filter { $0.reasons.contains { if case .missingPayee = $0 { return true }; return false } }.count
        }
    }

    /// `.txn`: a 34pt-equivalent leading gutter (20pt, since `LedgerTransaction`
    /// carries a date and no time of day), payee over metadata, amount flush to
    /// the right page edge in `--out` with a scaled `¥` and no minus sign.
    ///
    /// The pencil is an app addition the design has no equivalent for, kept
    /// because `testLocalPendingInboxHydratesPayeeCancelReopenAndCommit` taps it
    /// without a swipe. It sits inline after the payee — it edits the payee, so
    /// that is where it belongs — rather than in the trailing flow, which would
    /// push the amount 44pt off the page edge the design puts it on. It stays a
    /// 44×44 target per the hit-target rule.
    private func pendingRow(_ item: (transaction: LedgerTransaction, reasons: [PendingTransactionReason])) -> some View {
        let p = TransactionPresentation(transaction: item.transaction)
        let visual = TransactionVisualCategory.resolve(transaction: item.transaction, presentation: p, accountLabels: accountLabels)
        let tagText = item.reasons.first?.badgeText ?? ""
        let flagged = isFlagged(item.reasons)
        return HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: 20, height: 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text(p.title).balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                    Button { prepare(item.transaction, action: .payee) } label: {
                        Image(systemName: "pencil").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(BalancedPalette.edge)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pending-edit-payee-" + item.transaction.id)
                    .accessibilityLabel("补充商户")
                }
                .frame(height: 22)
                HStack(spacing: 6) {
                    if !tagText.isEmpty { BalancedTag(text: tagText, kind: .pending) }
                    Text(visual.categoryLabel).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                }
            }
            Spacer(minLength: 8)
            // A fixed *minimum* amount column keeps every row's figure on the
            // same right edge (`.txn .amt`), but lets the text grow past it
            // rather than clip when Dynamic Type scales the amount up.
            BalancedAmount(minorUnits: p.minorUnits, currency: p.currency, size: 15, color: amountColor(p.kind), showsCurrency: true, currencyScale: 0.78)
                .frame(minWidth: 78, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { prepare(item.transaction, action: .category) }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .disabled(updating || actionID != nil || (session.isLocal && loading))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("补商户") { prepare(item.transaction, action: .payee) }.tint(BalancedPalette.ink)
            if flagged {
                Button("已核对") { Task { await markVerified(for: item.transaction) } }.tint(BalancedPalette.income)
            }
        }
        .contextMenu {
            Button("改分类") { prepare(item.transaction, action: .category) }
            Button("补商户") { prepare(item.transaction, action: .payee) }
            if flagged { Button("标为已核对") { Task { await markVerified(for: item.transaction) } } }
            Button("完整编辑") { prepare(item.transaction, action: .full) }
        }
    }

    /// Tail of the list. Appearing appends the next window; tapping retries a
    /// stalled fetch. Rows are appended, never replaced, so the scroll position holds.
    private var loadMoreFooter: some View {
        let busy = loading || updating || actionID != nil
        return Button {
            guard !busy else { return }
            Task { await loadWindow() }
        } label: {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(BalancedPalette.meta)
                    Text("正在加载更多待整理账单…")
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
        .disabled(busy)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .onAppear {
            guard !busy else { return }
            Task { await loadWindow() }
        }
        .accessibilityIdentifier("pending-inbox-load-more")
        .accessibilityLabel(busy ? "正在加载更多待整理账单" : "继续加载更多待整理账单")
    }

    private func resetAccumulation() {
        accumulated = []
        loadedIDs = []
        continuation = nil
        reachedRowCap = false
    }

    private var allCleanState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 34, weight: .light)).foregroundStyle(BalancedPalette.meta)
            VStack(spacing: 6) {
                Text("账本全部整理完毕！").balancedFont(size: 16, weight: .medium).foregroundStyle(BalancedPalette.ink)
                Text("没有未明确分类、缺少商户或待核对的交易，账目非常规整。")
                    .balancedFont(size: 13.5)
                    .foregroundStyle(BalancedPalette.meta)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button("完成并返回") { dismiss() }
                .buttonStyle(.balanced(.primary))
                .frame(maxWidth: 220)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Fetch one more window. The first call seeds the accumulated rows; later
    /// calls append the next page in place. `localWindow` keeps the complete counts
    /// so the band summary and tab badges still describe the whole range.
    private func loadWindow() async {
        guard active, request.readable else { return }
        let key = request
        loading = true; loadError = nil
        defer { if key == request { loading = false } }
        do {
            let result = try await session.localPendingWindow(filter: key.filter,
                continuation: key.revision == completedRequest?.revision ? continuation : nil)
            guard !Task.isCancelled, key == request, request.readable else { return }
            if key.revision != completedRequest?.revision || accumulated.isEmpty {
                accumulated = result.result.transactions
                loadedIDs = Set(result.result.transactions.map(\.id))
                reachedRowCap = false
            } else {
                for row in result.result.transactions where !loadedIDs.contains(row.id) {
                    accumulated.append(row)
                    loadedIDs.insert(row.id)
                }
                reachedRowCap = accumulated.count >= Self.rowCap
            }
            continuation = result.continuation
            localWindow = result
            completedRequest = key
        } catch {
            if !Task.isCancelled, key == request { loadError = error.localizedDescription }
        }
    }

    private func revokeAction() {
        actionID = nil
        actionTask?.cancel(); actionTask = nil
        if let localAction { session.cancelLocalTransactionAction(localAction) }
        localAction = nil
    }
    private func clearActions() {
        feedbackGeneration = UUID()
        actionMessage = nil; loadError = nil
        editingCategoryTarget = nil; editingPayeeTarget = nil; fullEditorTarget = nil
        revokeAction()
    }
    private func prepare(_ row: LedgerTransaction, action: PendingAction) {
        guard !updating, actionID == nil else { return }
        guard session.isLocal else {
            switch action {
            case .category: editingCategoryTarget = row
            case .payee: editingPayeeTarget = row
            case .full: fullEditorTarget = row
            case .verify: Task { await markVerified(for: row) }
            }
            return
        }
        revokeAction()
        let id = UUID(), key = request
        actionID = id
        actionTask = Task { @MainActor in
            defer { if actionID == id { actionID = nil; actionTask = nil } }
            do {
                let prepared = try await session.prepareLocalTransactionAction(sources: [row.source], kind: .edit)
                guard !Task.isCancelled, actionID == id, key == request else {
                    session.cancelLocalTransactionAction(prepared); return
                }
                guard let original = prepared.originals.first, original.editableEntry != nil else {
                    session.cancelLocalTransactionAction(prepared)
                    throw LedgerTransactionMutationError.sourceUnavailable
                }
                localAction = prepared
                switch action {
                case .category: editingCategoryTarget = original
                case .payee: editingPayeeTarget = original
                case .full: fullEditorTarget = original
                case .verify: await markVerified(for: original)
                }
            } catch {
                if !Task.isCancelled, actionID == id {
                    actionStyle = .failure; actionMessage = error.localizedDescription
                }
            }
        }
    }

    private func publishFeedback(_ message: String, style: LedgerStatusStyle, token: UUID) {
        guard !session.isLocal || (token == feedbackGeneration && request.readable) else { return }
        actionStyle = style; actionMessage = message
        if style == .confirmed { actionFeedback &+= 1; LedgerFeedback.success() }
    }

    private func save(_ entry: LedgerTransactionEntry, original: LedgerTransaction) async throws {
        guard session.isLocal else { try await session.updateTransaction(source: original.source, entry: entry); return }
        guard let localAction, localAction.originals.first?.source == original.source else { throw CancellationError() }
        let token = feedbackGeneration
        defer { self.localAction = nil; reload += 1 }
        do { try await session.updateLocalTransaction(action: localAction, entry: entry) }
        catch {
            fullEditorTarget = nil; editingPayeeTarget = nil; editingCategoryTarget = nil
            publishFeedback(error.localizedDescription + String(localized: " 请重新打开交易操作后再试。"), style: .failure, token: token)
            throw error
        }
    }

    private func updateCategory(for tx: LedgerTransaction, to newAccount: String) async -> Bool {
        guard !updating else { return false }
        updating = true
        let token = feedbackGeneration
        defer { updating = false }
        do {
            let unknownAcc = tx.postings.first(where: {
                $0.account.lowercased().contains("unknown")
                    || $0.account.lowercased().contains("待分类")
                    || $0.account.lowercased().contains("uncategorized")
            })?.account ?? ""
            try await save(tx.entryReplacingAccount(from: unknownAcc, to: newAccount), original: tx)
            publishFeedback(String(localized: "已分类为：\(String(newAccount.split(separator: ":").last ?? ""))"), style: .confirmed, token: token)
            return true
        } catch {
            publishFeedback(String(localized: "更新失败：\(error.localizedDescription)"), style: .failure, token: token)
            return !session.isLocal
        }
    }

    private func updatePayee(for tx: LedgerTransaction, payee: String, narration: String?) async -> Bool {
        guard !updating else { return false }
        updating = true
        let token = feedbackGeneration
        defer { updating = false }
        do {
            try await save(tx.entryUpdatingPayee(payee, narration: narration), original: tx)
            publishFeedback(String(localized: "商户已更新为：\(payee)"), style: .confirmed, token: token)
            return true
        } catch {
            publishFeedback(String(localized: "更新失败：\(error.localizedDescription)"), style: .failure, token: token)
            return !session.isLocal
        }
    }

    private func markVerified(for tx: LedgerTransaction) async {
        guard !updating else { return }
        updating = true
        let token = feedbackGeneration
        defer { updating = false }
        do {
            try await save(tx.entryMarkingVerified(), original: tx)
            publishFeedback(String(localized: "已标记为已核对"), style: .confirmed, token: token)
        } catch {
            publishFeedback(String(localized: "核对失败：\(error.localizedDescription)"), style: .failure, token: token)
        }
    }
}

// MARK: - 补分类浮层 (d10)

/// A short sheet: the transaction's amount/account/date as `.key` rows, the
/// current category, a disclosure to the full account list, and 跳过/保存.
/// There is no history-backed recommendation engine for pending categories —
/// showing a ranked subset of `availableAccounts` would be an invented
/// suggestion, so this sheet only states the current category and links to
/// the full picker rather than fabricating a ranking.
private struct PendingCategorySuggestionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let transaction: LedgerTransaction
    let availableAccounts: [String]
    let accountLabels: [String: String]
    let onSelect: (String) async -> Bool

    @State private var submitting = false
    @State private var showingFullPicker = false

    private var presentation: TransactionPresentation { TransactionPresentation(transaction: transaction) }
    private var currentAccount: String? {
        transaction.postings.first(where: { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") })?.account
    }
    private var currentLabel: String {
        currentAccount.flatMap { accountLabels[$0] } ?? String(localized: "未分类")
    }

    private func submit(_ account: String) async {
        guard !submitting else { return }
        submitting = true
        defer { submitting = false }
        if await onSelect(account) { dismiss() }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("这条流水的分类").balancedFont(size: 15, weight: .medium).foregroundStyle(BalancedPalette.ink)
                        Spacer()
                        Text(currentLabel).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.expense)
                    }
                    .padding(.top, 8).padding(.bottom, 14)

                    VStack(spacing: 0) {
                        BalancedKeyRow(label: String(localized: "金额"), minorUnits: presentation.minorUnits, currency: presentation.currency,
                            prefix: amountPrefix(presentation.kind), color: amountColor(presentation.kind))
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("账户").balancedFont(size: 14).foregroundStyle(BalancedPalette.secondary)
                            Spacer()
                            Text(currentAccount ?? "—").balancedMono(size: 11.5).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                        }
                        .padding(.vertical, 3)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("日期").balancedFont(size: 14).foregroundStyle(BalancedPalette.secondary)
                            Spacer()
                            Text(transaction.date).balancedFont(size: 14, weight: .text).monospacedDigit().foregroundStyle(BalancedPalette.ink)
                        }
                        .padding(.vertical, 3)
                    }
                    .balancedBand()

                    Text("当前分类").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        .padding(.top, 4).padding(.bottom, 2)

                    if let currentAccount {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(accountLabels[currentAccount] ?? currentAccount.split(separator: ":").last.map(String.init) ?? currentAccount)
                                    .balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink)
                                Text(currentAccount).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(BalancedPalette.ink)
                        }
                        .padding(.vertical, 11)
                        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                    } else {
                        Text("尚未分类").balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.meta)
                            .padding(.vertical, 11)
                            .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                    }

                    Button {
                        showingFullPicker = true
                    } label: {
                        HStack {
                            Text("选择其它分类…").balancedFont(size: 14).foregroundStyle(BalancedPalette.secondary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(BalancedPalette.edge)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }

                    HStack(spacing: 12) {
                        Button("跳过") { dismiss() }.buttonStyle(.balanced(.quiet))
                        Button("保存") { Task { if let acc = currentAccount { await submit(acc) } } }
                            .buttonStyle(.balanced(.primary, disabled: submitting || currentAccount == nil))
                            .disabled(submitting || currentAccount == nil)
                    }
                    .padding(.top, 24)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .background(BalancedPalette.page)
            .navigationBarHidden(true)
            .disabled(submitting)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showingFullPicker) {
            QuickCategoryPickerSheet(transaction: transaction, availableAccounts: availableAccounts, accountLabels: accountLabels) { account in
                await submit(account)
                return true
            }
        }
        .interactiveDismissDisabled(submitting)
    }
}

// MARK: - Quick Category Picker Sheet

struct QuickCategoryPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let transaction: LedgerTransaction
    let availableAccounts: [String]
    let accountLabels: [String: String]
    let onSelect: (String) async -> Bool

    @State private var searchQuery = ""
    @State private var submitting = false

    private func submit(_ account: String) async {
        guard !submitting else { return }
        submitting = true
        defer { submitting = false }
        if await onSelect(account) { dismiss() }
    }

    private struct FrequentCategory: Identifiable {
        let account: String
        let label: String
        let icon: String
        let color: Color
        var id: String { account }
    }

    private var presets: [FrequentCategory] {
        [
            FrequentCategory(account: "Expenses:Food:Dining", label: String(localized: "餐饮美食"), icon: "fork.knife", color: Color.orange),
            FrequentCategory(account: "Expenses:Food:Takeout", label: String(localized: "外卖订餐"), icon: "bag", color: Color.orange),
            FrequentCategory(account: "Expenses:Food:Groceries", label: String(localized: "买菜生鲜"), icon: "cart", color: Color.green),
            FrequentCategory(account: "Expenses:Shopping:Daily", label: String(localized: "日用百货"), icon: "basket", color: Color.pink),
            FrequentCategory(account: "Expenses:Shopping:Digital", label: String(localized: "数码科技"), icon: "laptopcomputer", color: Color.blue),
            FrequentCategory(account: "Expenses:Transport:Transit", label: String(localized: "交通出行"), icon: "car.fill", color: Color.blue),
            FrequentCategory(account: "Expenses:Transport:Taxi", label: String(localized: "打车出行"), icon: "car.side.fill", color: Color.teal),
            FrequentCategory(account: "Expenses:Entertainment:Recreation", label: String(localized: "休闲娱乐"), icon: "popcorn.fill", color: Color.purple),
            FrequentCategory(account: "Expenses:Housing:Utilities", label: String(localized: "水电物业"), icon: "bolt.fill", color: Color.yellow),
            FrequentCategory(account: "Expenses:Housing:Rent", label: String(localized: "房租月结"), icon: "house.fill", color: Color.indigo),
            FrequentCategory(account: "Expenses:Health:Medical", label: String(localized: "医疗健康"), icon: "heart.fill", color: Color.red),
            FrequentCategory(account: "Expenses:Communication:Phone", label: String(localized: "通讯话费"), icon: "phone.fill", color: Color.cyan),
        ]
    }

    private var filteredAccounts: [String] {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return availableAccounts
        }
        let q = searchQuery.lowercased()
        return availableAccounts.filter {
            $0.lowercased().contains(q) || (accountLabels[$0]?.lowercased().contains(q) == true)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if searchQuery.isEmpty {
                    Section {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(presets) { cat in
                                Button {
                                    Task {
                                        await submit(cat.account)
                                    }
                                } label: {
                                    VStack(spacing: 6) {
                                        ZStack {
                                            Rectangle().fill(BalancedPalette.sunken).frame(width: 44, height: 44)
                                            Image(systemName: cat.icon)
                                                .font(.system(size: 16, weight: .regular))
                                                .foregroundStyle(BalancedPalette.ink)
                                        }
                                        Text(cat.label)
                                            .balancedFont(size: 12)
                                            .foregroundStyle(BalancedPalette.ink)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("常用分类").balancedFont(size: 12.5, weight: .medium).foregroundStyle(BalancedPalette.meta)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                Section {
                    ForEach(filteredAccounts, id: \.self) { account in
                        Button {
                            Task {
                                await submit(account)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(accountLabels[account] ?? account.split(separator: ":").last.map(String.init) ?? account)
                                        .balancedFont(size: 15, weight: .text)
                                        .foregroundStyle(BalancedPalette.ink)
                                    Text(account).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(BalancedPalette.edge)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("所有支出账户 (\(filteredAccounts.count))").balancedFont(size: 12.5, weight: .medium).foregroundStyle(BalancedPalette.meta)
                }
            }
            .disabled(submitting)
            .searchable(text: $searchQuery, prompt: "搜索分类或账户名称")
            .navigationTitle("选择分类")
            .terminalNativeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }.disabled(submitting)
                }
            }
        }
        .interactiveDismissDisabled(submitting)
    }
}

// MARK: - Quick Payee Editor Sheet

struct QuickPayeeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let transaction: LedgerTransaction
    let onSave: (String, String?) async -> Bool

    @State private var payee: String
    @State private var narration: String
    @State private var submitting = false

    init(transaction: LedgerTransaction, onSave: @escaping (String, String?) async -> Bool) {
        self.transaction = transaction
        self.onSave = onSave
        _payee = State(initialValue: transaction.payee)
        _narration = State(initialValue: transaction.narration)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("商户 / 收款方名称", text: $payee)
                        .accessibilityIdentifier("pending-payee-input")
                        .balancedFont(size: 16)
                } header: {
                    Text("商户名称 (Payee)")
                } footer: {
                    Text("填写清晰的商户名称（如：美团外卖、瑞幸咖啡、青禾餐厅）有助于消费分析和自动归类。")
                }

                Section {
                    TextField("交易备注说明（可选）", text: $narration)
                        .font(.system(size: 15))
                } header: {
                    Text("交易备注 (Narration)")
                }
            }
            .disabled(submitting)
            .navigationTitle("补全商户与备注")
            .terminalNativeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }.disabled(submitting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        Task {
                            guard !submitting else { return }
                            submitting = true
                            defer { submitting = false }
                            if await onSave(payee, narration.isEmpty ? nil : narration) { dismiss() }
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .disabled(submitting || payee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(submitting)
    }
}
