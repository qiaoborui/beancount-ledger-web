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
    @State private var page = 0
    @State private var displayedPage = 0
    @State private var reload = 0
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
        var page: Int
    }
    private var request: ReadRequest {
        .init(revision: session.localTransactionPresentationRevision, invalidation: session.localGlobalSearchInvalidation,
            range: session.selectedRange, filter: selectedTab.filter,
            readable: session.phase == .ready && !session.privacyShielded && !session.isRangeLoading
                && !session.isValuationCurrencyLoading && !session.transactionMutationStates.values.contains(.pending),
            active: active, reload: reload, page: page)
    }
    private var windowCurrent: Bool {
        guard let completedRequest else { return false }
        return completedRequest.revision == request.revision && completedRequest.invalidation == request.invalidation
            && completedRequest.range == request.range && completedRequest.filter == request.filter && request.readable
    }
    private var totalCount: Int { session.isLocal ? (windowCurrent ? localWindow?.result.totalCount ?? 0 : 0) : pendingItems.count }
    private var filteredCount: Int { session.isLocal ? (localWindow?.result.counts[selectedTab.filter] ?? 0) : filteredItems.count }

    private var allTransactions: [LedgerTransaction] {
        session.isLocal ? (windowCurrent ? localWindow?.result.transactions ?? [] : []) : session.visibleTransactions
    }

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let actionMessage, !session.isLocal || request.readable {
                    StatusBanner(message: actionMessage, style: actionStyle) {
                        self.actionMessage = nil
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                if session.isLocal, let loadError {
                    Text(loadError).foregroundStyle(.secondary)
                    Button("重新读取待整理账单") { reload += 1 }
                }
                if session.isLocal && !windowCurrent {
                    if loading { ProgressView("正在统计全部待整理账单…") }
                } else if totalCount == 0 {
                    allCleanState
                } else {
                    inboxContent
                }
            }
            .background(LedgerPalette.canvas)
            .navigationTitle("待整理账单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if totalCount > 0 {
                        Text("\(totalCount) 笔待办")
                            .accessibilityIdentifier("pending-inbox-total")
                            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
            }
            .sheet(item: $editingCategoryTarget, onDismiss: revokeAction) { tx in
                QuickCategoryPickerSheet(
                    transaction: tx,
                    availableAccounts: availableExpenseAccounts,
                    accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
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
                        publishFeedback("交易修改已保存", style: .confirmed, token: token)
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
            .onChange(of: selectedTab) { _, _ in page = 0; displayedPage = 0 }
            .onChange(of: session.localTransactionPresentationRevision) { _, _ in page = 0; displayedPage = 0 }
            .onChange(of: session.privacyShielded) { _, hidden in if hidden { clearActions() } }
            .onChange(of: session.phase) { _, phase in if phase != .ready { clearActions() } }
            .overlay(alignment: .top) {
                if actionID != nil { ProgressView("正在读取原始交易…").padding().background(.regularMaterial) }
            }
        }
    }

    private var inboxContent: some View {
        VStack(spacing: 0) {
            // Summary Hero Card
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("账单整理收件箱")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LedgerPalette.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(totalCount)")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(LedgerPalette.ink)
                            Text("笔待确认 / 未分类")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("涉及金额")
                            .font(.system(size: 12))
                            .foregroundStyle(LedgerPalette.secondary)
                        AmountLabel(minorUnits: totalPendingMinorUnits, currency: "CNY")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(LedgerPalette.expense)
                    }
                }

                // Filter tabs
                HStack(spacing: 6) {
                    ForEach(FilterTab.allCases) { tab in
                        let isSelected = selectedTab == tab
                        Button {
                            LedgerFeedback.selection()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                selectedTab = tab
                            }
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.white : LedgerPalette.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    isSelected ? Color.orange : Color(uiColor: .tertiarySystemFill),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
                    }
                    Spacer()
                    Text("\(filteredCount) 笔")
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }
            .padding(16)
            .background(LedgerPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(LedgerPalette.cardBorder, lineWidth: 0.8)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Items List
            if filteredItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(LedgerPalette.success)
                    Text("该类别下没有待整理账单")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LedgerPalette.ink)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredItems, id: \.transaction.id) { item in
                        PendingTransactionCard(
                            transaction: item.transaction,
                            reasons: item.reasons,
                            onChangeCategory: { prepare(item.transaction, action: .category) },
                            onEditPayee: { prepare(item.transaction, action: .payee) },
                            onMarkVerified: { prepare(item.transaction, action: .verify) },
                            onFullEdit: { prepare(item.transaction, action: .full) }
                        )
                        .disabled(updating || actionID != nil || (session.isLocal && loading))
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
            if session.isLocal, windowCurrent, let localWindow {
                HStack {
                    Button("上一页") {
                        let target = max(0, displayedPage - 1)
                        if page == target { reload += 1 } else { page = target }
                    }.disabled(displayedPage == 0 || loading || updating || actionID != nil)
                    Spacer()
                    Text("第 \(displayedPage + 1) 页").font(.caption).accessibilityIdentifier("pending-inbox-page")
                    Spacer()
                    Button("下一页") {
                        let target = displayedPage + 1
                        if page == target { reload += 1 } else { page = target }
                    }.disabled(localWindow.continuation == nil || loading || updating || actionID != nil)
                }.padding()
            }
        }
    }

    private var allCleanState: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 90, height: 90)
                Image(systemName: "sparkles")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.green)
            }

            VStack(spacing: 8) {
                Text("账本全部整理完毕！")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(LedgerPalette.ink)
                Text("没有未明确分类、缺少商户或待核对的交易，账目非常规整。")
                    .font(.system(size: 14))
                    .foregroundStyle(LedgerPalette.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                dismiss()
            } label: {
                Text("完成并返回")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(LedgerPalette.cobalt, in: Capsule())
            }
            .buttonStyle(PressScaleButtonStyle())
            .padding(.top, 12)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadWindow() async {
        guard active, request.readable else { return }
        let key = request
        loading = true; loadError = nil
        defer { if key == request { loading = false } }
        do {
            var previous = completedRequest; previous?.page = key.page
            let forward = previous == key && completedRequest?.page == key.page - 1 && localWindow?.continuation != nil
            var result = try await session.localPendingWindow(filter: key.filter, continuation: forward ? localWindow?.continuation : nil)
            if key.page > 0 && !forward {
                for index in 0..<key.page {
                    guard let next = result.continuation else {
                        if !Task.isCancelled, key == request { page = index }
                        return
                    }
                    result = try await session.localPendingWindow(filter: key.filter, continuation: next)
                }
            }
            guard !Task.isCancelled, key == request, request.readable else { return }
            localWindow = result; completedRequest = key; displayedPage = key.page
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
            publishFeedback(error.localizedDescription + " 请重新打开交易操作后再试。", style: .failure, token: token)
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
            publishFeedback("已分类为：\(newAccount.split(separator: ":").last ?? "")", style: .confirmed, token: token)
            return true
        } catch {
            publishFeedback("更新失败：\(error.localizedDescription)", style: .failure, token: token)
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
            publishFeedback("商户已更新为：\(payee)", style: .confirmed, token: token)
            return true
        } catch {
            publishFeedback("更新失败：\(error.localizedDescription)", style: .failure, token: token)
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
            publishFeedback("已标记为已核对", style: .confirmed, token: token)
        } catch {
            publishFeedback("核对失败：\(error.localizedDescription)", style: .failure, token: token)
        }
    }
}

// MARK: - Pending Transaction Card

private struct PendingTransactionCard: View {
    let transaction: LedgerTransaction
    let reasons: [PendingTransactionReason]
    let onChangeCategory: () -> Void
    let onEditPayee: () -> Void
    let onMarkVerified: () async -> Void
    let onFullEdit: () -> Void

    private var presentation: TransactionPresentation {
        TransactionPresentation(transaction: transaction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Date & Amount
            HStack(alignment: .firstTextBaseline) {
                Text(transaction.date)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(LedgerPalette.secondary)
                Spacer()
                AmountLabel(
                    minorUnits: presentation.minorUnits,
                    currency: presentation.currency,
                    prefix: amountPrefix(presentation.kind),
                    font: .system(size: 17, weight: .bold, design: .rounded),
                    color: amountColor(presentation.kind)
                )
            }

            // Payee & Narration
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                if !presentation.subtitle.isEmpty && presentation.subtitle != presentation.title {
                    Text(presentation.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }

            // Reason Badges
            FlowBadgesLayout(spacing: 6) {
                ForEach(reasons) { reason in
                    HStack(spacing: 4) {
                        Image(systemName: reasonIcon(reason))
                            .font(.system(size: 10, weight: .semibold))
                        Text(reason.badgeText)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(badgeColor(reason))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(badgeColor(reason).opacity(0.12), in: Capsule())
                }
            }

            Divider()
                .padding(.vertical, 2)

            // Quick Actions Toolbar
            HStack(spacing: 8) {
                Button(action: onChangeCategory) {
                    HStack(spacing: 4) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 11))
                        Text("改分类")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(LedgerPalette.cobalt)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(LedgerPalette.cobalt.opacity(0.1), in: Capsule())
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))

                Button(action: onEditPayee) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                        Text("补商户")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(LedgerPalette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))

                .accessibilityIdentifier("pending-edit-payee-" + transaction.id)

                let isFlagged = reasons.contains {
                    if case .needsReviewFlag = $0 { return true }
                    if case .pendingTag = $0 { return true }
                    return false
                }
                if isFlagged {
                    Button {
                        Task { await onMarkVerified() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                            Text("标为已核对")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
                }

                Spacer()

                Button(action: onFullEdit) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
            }
        }
        .padding(14)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LedgerPalette.cardBorder, lineWidth: 0.8)
        )
    }

    private func badgeColor(_ reason: PendingTransactionReason) -> Color {
        switch reason {
        case .uncategorized: return Color.orange
        case .needsReviewFlag: return Color.red
        case .pendingTag: return Color.purple
        case .missingPayee: return Color.blue
        }
    }

    private func reasonIcon(_ reason: PendingTransactionReason) -> String {
        switch reason {
        case .uncategorized: return "folder.badge.questionmark"
        case .needsReviewFlag: return "exclamationmark.triangle.fill"
        case .pendingTag: return "tag"
        case .missingPayee: return "questionmark.circle"
        }
    }
}

// MARK: - Flow Layout for Badges

private struct FlowBadgesLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
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
            FrequentCategory(account: "Expenses:Food:Dining", label: "餐饮美食", icon: "fork.knife", color: Color.orange),
            FrequentCategory(account: "Expenses:Food:Takeout", label: "外卖订餐", icon: "bag", color: Color.orange),
            FrequentCategory(account: "Expenses:Food:Groceries", label: "买菜生鲜", icon: "cart", color: Color.green),
            FrequentCategory(account: "Expenses:Shopping:Daily", label: "日用百货", icon: "basket", color: Color.pink),
            FrequentCategory(account: "Expenses:Shopping:Digital", label: "数码科技", icon: "laptopcomputer", color: Color.blue),
            FrequentCategory(account: "Expenses:Transport:Transit", label: "交通出行", icon: "car.fill", color: Color.blue),
            FrequentCategory(account: "Expenses:Transport:Taxi", label: "打车出行", icon: "car.side.fill", color: Color.teal),
            FrequentCategory(account: "Expenses:Entertainment:Recreation", label: "休闲娱乐", icon: "popcorn.fill", color: Color.purple),
            FrequentCategory(account: "Expenses:Housing:Utilities", label: "水电物业", icon: "bolt.fill", color: Color.yellow),
            FrequentCategory(account: "Expenses:Housing:Rent", label: "房租月结", icon: "house.fill", color: Color.indigo),
            FrequentCategory(account: "Expenses:Health:Medical", label: "医疗健康", icon: "heart.fill", color: Color.red),
            FrequentCategory(account: "Expenses:Communication:Phone", label: "通讯话费", icon: "phone.fill", color: Color.cyan),
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
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(cat.color.opacity(0.14))
                                                .frame(width: 44, height: 44)
                                            Image(systemName: cat.icon)
                                                .font(.system(size: 18, weight: .semibold))
                                                .foregroundStyle(cat.color)
                                        }
                                        Text(cat.label)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(LedgerPalette.ink)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(LedgerPalette.panel)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("常用分类")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(LedgerPalette.secondary)
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
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(LedgerPalette.ink)
                                    Text(account)
                                        .font(.system(size: 12))
                                        .foregroundStyle(LedgerPalette.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("所有支出账户 (\(filteredAccounts.count))")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }
            .disabled(submitting)
            .searchable(text: $searchQuery, prompt: "搜索分类或账户名称")
            .navigationTitle("选择分类")
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
            Form {
                Section {
                    TextField("商户 / 收款方名称", text: $payee)
                        .accessibilityIdentifier("pending-payee-input")
                        .font(.system(size: 16))
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
