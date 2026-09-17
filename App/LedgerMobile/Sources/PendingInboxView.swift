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
    }

    @State private var selectedTab: FilterTab = .all
    @State private var editingPayeeTarget: LedgerTransaction?
    @State private var editingCategoryTarget: LedgerTransaction?
    @State private var fullEditorTarget: LedgerTransaction?
    @State private var actionMessage: String?
    @State private var actionFeedback = 0
    @State private var updating = false

    private var allTransactions: [LedgerTransaction] {
        session.visibleTransactions
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
        let accounts = session.ledger?.accounts.map(\.account).filter { $0.hasPrefix("Expenses:") } ?? []
        let transactionAccounts = allTransactions.flatMap { $0.postings.map(\.account) }.filter { $0.hasPrefix("Expenses:") }
        return Array(Set(accounts + transactionAccounts)).sorted()
    }

    private var totalPendingMinorUnits: Int {
        pendingItems.reduce(0) { sum, item in
            let p = TransactionPresentation(transaction: item.transaction)
            return sum + p.minorUnits
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let actionMessage {
                    StatusBanner(message: actionMessage, style: .confirmed) {
                        self.actionMessage = nil
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                if pendingItems.isEmpty {
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
                    if !pendingItems.isEmpty {
                        Text("\(pendingItems.count) 笔待办")
                            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
            }
            .sheet(item: $editingCategoryTarget) { tx in
                QuickCategoryPickerSheet(
                    transaction: tx,
                    availableAccounts: availableExpenseAccounts,
                    accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
                ) { newAccount in
                    await updateCategory(for: tx, to: newAccount)
                }
                .ledgerPrivacyProtectedSheet()
            }
            .sheet(item: $editingPayeeTarget) { tx in
                QuickPayeeEditorSheet(transaction: tx) { newPayee, newNarration in
                    await updatePayee(for: tx, payee: newPayee, narration: newNarration)
                }
                .ledgerPrivacyProtectedSheet()
            }
            .sheet(item: $fullEditorTarget) { tx in
                TransactionEditorView(
                    transaction: tx,
                    accounts: session.ledger?.accounts ?? [],
                    commodities: session.ledger?.commodities ?? [],
                    onSave: { entry in
                        try await session.updateTransaction(source: tx.source, entry: entry)
                        actionMessage = "交易修改已保存"
                        actionFeedback &+= 1
                        LedgerFeedback.success()
                    }
                )
                .ledgerPrivacyProtectedSheet()
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
                            Text("\(pendingItems.count)")
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
                        Text(MoneyText.format(minorUnits: totalPendingMinorUnits, currency: "CNY"))
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
                    Text("\(filteredItems.count) 笔")
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
                            onChangeCategory: { editingCategoryTarget = item.transaction },
                            onEditPayee: { editingPayeeTarget = item.transaction },
                            onMarkVerified: { await markVerified(for: item.transaction) },
                            onFullEdit: { fullEditorTarget = item.transaction }
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
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

    private func updateCategory(for tx: LedgerTransaction, to newAccount: String) async {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        do {
            let unknownAcc = tx.postings.first(where: {
                $0.account.lowercased().contains("unknown")
                    || $0.account.lowercased().contains("待分类")
                    || $0.account.lowercased().contains("uncategorized")
            })?.account ?? ""

            let entry = tx.entryReplacingAccount(from: unknownAcc, to: newAccount)
            try await session.updateTransaction(source: tx.source, entry: entry)
            actionMessage = "已分类为：\(newAccount.split(separator: ":").last ?? "")"
            LedgerFeedback.success()
        } catch {
            actionMessage = "更新失败：\(error.localizedDescription)"
        }
    }

    private func updatePayee(for tx: LedgerTransaction, payee: String, narration: String?) async {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        do {
            let entry = tx.entryUpdatingPayee(payee, narration: narration)
            try await session.updateTransaction(source: tx.source, entry: entry)
            actionMessage = "商户已更新为：\(payee)"
            LedgerFeedback.success()
        } catch {
            actionMessage = "更新失败：\(error.localizedDescription)"
        }
    }

    private func markVerified(for tx: LedgerTransaction) async {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        do {
            let entry = tx.entryMarkingVerified()
            try await session.updateTransaction(source: tx.source, entry: entry)
            actionMessage = "已标记为已核对"
            LedgerFeedback.success()
        } catch {
            actionMessage = "核对失败：\(error.localizedDescription)"
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
    let onSelect: (String) async -> Void

    @State private var searchQuery = ""

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
                                        await onSelect(cat.account)
                                        dismiss()
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
                                await onSelect(account)
                                dismiss()
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
            .searchable(text: $searchQuery, prompt: "搜索分类或账户名称")
            .navigationTitle("选择分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Quick Payee Editor Sheet

struct QuickPayeeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let transaction: LedgerTransaction
    let onSave: (String, String?) async -> Void

    @State private var payee: String
    @State private var narration: String

    init(transaction: LedgerTransaction, onSave: @escaping (String, String?) async -> Void) {
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
            .navigationTitle("补全商户与备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        Task {
                            await onSave(payee, narration.isEmpty ? nil : narration)
                            dismiss()
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .disabled(payee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
