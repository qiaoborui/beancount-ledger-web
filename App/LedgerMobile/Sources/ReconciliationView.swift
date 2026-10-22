import SwiftUI

enum ReconciliationStatusFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case pending = "待对账"
    case error = "异常"
    case asserted = "已核平"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "全部")
        case .pending: String(localized: "待对账")
        case .error: String(localized: "异常")
        case .asserted: String(localized: "已核平")
        }
    }
}

enum LedgerReconciliationDates {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }

    static func todayString() -> String {
        formatter.string(from: Date())
    }

    static func previousDay(from dateString: String) -> String {
        guard let d = date(from: dateString),
              let prev = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: d) else {
            return dateString
        }
        return formatter.string(from: prev)
    }
}

extension LedgerAccountStatus {
    var statusColor: Color {
        switch status {
        case "green": LedgerPalette.income
        case "red": LedgerPalette.expense
        case "yellow": LedgerPalette.gold
        default: LedgerPalette.secondary.opacity(0.6)
        }
    }

    var statusLabel: String {
        switch status {
        case "green": String(localized: "已核平")
        case "red": String(localized: "异常")
        case "yellow": String(localized: "待对账")
        default: String(localized: "未断言")
        }
    }

    var statusIcon: String {
        switch status {
        case "green": "checkmark.circle.fill"
        case "red": "exclamationmark.circle.fill"
        case "yellow": "clock.arrow.circlepath"
        default: "circle.dashed"
        }
    }
}

// MARK: - 全账户对账工作台

struct ReconciliationView: View {
    @EnvironmentObject private var session: LedgerSession

    @State private var selectedStatus: ReconciliationStatusFilter = .all
    @State private var searchText = ""
    @State private var successFeedback = 0
    @State private var successMessage: String?
    @State private var isRefreshing = false
    @State private var localRows: [LedgerReconciliationRow]?
    @State private var localError: String?
    @State private var completedLocalReadKey: String?
    @State private var localReadID = UUID()
    @State private var localReadLoading = false
    private var localReadable: Bool {
        session.isLocal && session.phase == .ready && !session.privacyShielded && !session.isRangeLoading
            && !session.isValuationCurrencyLoading && !session.transactionMutationStates.values.contains(.pending)
    }
    private var localReadKey: String {
        "\(session.localTransactionPresentationRevision?.uuidString ?? "")/\(session.localGlobalSearchInvalidation)/\(session.selectedRange.start)/\(session.selectedRange.end)/\(localReadable)"
    }

    private var localRowsCurrent: Bool {
        localReadable && !localReadLoading && completedLocalReadKey == localReadKey && localRows != nil
    }
    private func status(for row: LedgerReconciliationRow) -> LedgerAccountStatus? {
        session.isLocal ? row.snapshotStatus : session.accountStatus(for: row.account)
    }

    var isRoot = false

    private var allRows: [LedgerReconciliationRow] {
        if session.isLocal { return localRowsCurrent ? (localRows ?? []) : [] }
        if let rows = session.ledger?.reconciliationRows, !rows.isEmpty {
            return rows
        }
        // Fallback to building rows from account balances if reconciliationRows is empty
        guard let ledger = session.ledger else { return [] }
        return ledger.accounts.compactMap { acct -> LedgerReconciliationRow? in
            guard acct.active, (acct.account.hasPrefix("Assets:") || acct.account.hasPrefix("Liabilities:")) else { return nil }
            let bal = ledger.accountBalances.first { $0.account == acct.account }?.amount ?? 0
            let status = session.accountStatus(for: acct.account)
            return LedgerReconciliationRow(
                account: acct.account,
                alias: acct.alias,
                label: acct.label,
                currency: acct.currency,
                ledgerBalance: bal,
                status: status?.isReconciled == true ? "asserted" : "pending",
                lastAssertion: status?.assertionAmount.map {
                    LedgerBalanceAssertion(date: status?.lastEntryDate ?? "", account: acct.account, amount: $0, currency: acct.currency)
                }
            )
        }
    }

    private var filteredRows: [LedgerReconciliationRow] {
        allRows.filter { row in
            let rowStatus = status(for: row)
            let statusIsError = rowStatus?.hasIssue == true
            let statusIsAsserted = row.status == "asserted" || rowStatus?.isReconciled == true
            switch selectedStatus {
            case .all:
                break
            case .pending:
                if rowStatus?.isReconciled == true || statusIsError { return false }
            case .error:
                if !statusIsError { return false }
            case .asserted:
                if !statusIsAsserted || statusIsError { return false }
            }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                let match = row.label.lowercased().contains(q)
                    || row.account.lowercased().contains(q)
                    || (row.alias?.lowercased().contains(q) ?? false)
                if !match { return false }
            }
            return true
        }
    }

    /// `资产` then `负债`, matching d11 — a simple binary split is enough to
    /// group the flat row list the way the frame does.
    private var groupedRows: [(title: String, rows: [LedgerReconciliationRow])] {
        let asset = filteredRows.filter { !$0.account.hasPrefix("Liabilities:") }
        let liability = filteredRows.filter { $0.account.hasPrefix("Liabilities:") }
        var groups: [(String, [LedgerReconciliationRow])] = []
        if !asset.isEmpty { groups.append((String(localized: "资产"), asset)) }
        if !liability.isEmpty { groups.append((String(localized: "负债"), liability)) }
        return groups
    }

    private var summaryMetrics: (total: Int, asserted: Int, pending: Int, error: Int) {
        let total = allRows.count
        var asserted = 0
        var pending = 0
        var error = 0
        for row in allRows {
            let rowStatus = status(for: row)
            let statusError = rowStatus?.hasIssue == true
            if statusError {
                error += 1
            } else if row.status == "asserted" || rowStatus?.isReconciled == true {
                asserted += 1
            } else {
                pending += 1
            }
        }
        return (total, asserted, pending, error)
    }

    private func count(for filter: ReconciliationStatusFilter) -> Int {
        switch filter {
        case .all: allRows.count
        case .pending: summaryMetrics.pending
        case .error: summaryMetrics.error
        case .asserted: summaryMetrics.asserted
        }
    }

    var body: some View {
        List {
            Section {
                summaryBand
                    .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                statusTabs
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let successMessage, !session.isLocal || localReadable {
                Section {
                    Text(successMessage)
                        .balancedFont(size: 13).foregroundStyle(BalancedPalette.income)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if localReadable, let localError {
                Section {
                    Text("对账读取失败：" + localError).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    Button("重试") { Task { await loadLocalRows() } }.buttonStyle(.balanced(.quiet))
                }
                .listRowBackground(Color.clear)
            } else if session.isLocal && !localRowsCurrent {
                Section { ProgressView("正在读取对账账户…") }
                    .listRowBackground(Color.clear)
            } else if filteredRows.isEmpty {
                Section {
                    BalancedEmptyState(
                        glyph: "checkmark.seal",
                        title: allRows.isEmpty ? String(localized: "暂无可对账账户") : String(localized: "没有匹配的账户"),
                        detail: String(localized: "调整筛选条件后再试一次。")
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(groupedRows, id: \.title) { group in
                    Section {
                        ForEach(group.rows) { row in reconciliationRow(row) }
                    } header: {
                        HStack {
                            Text(group.title).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                            Spacer()
                            Text("\(group.rows.count) 个").balancedFont(size: 12).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                        }
                        .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .background(BalancedPalette.page)
        .accessibilityIdentifier("reconciliation-list")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索账户名或路径")
        .terminalPageChrome(String(localized: "对账"), isRoot: isRoot, showsSync: false, actions: AnyView(
            Button {
                Task { isRefreshing = true; await session.refresh(); isRefreshing = false }
            } label: {
                if isRefreshing {
                    ProgressView().tint(BalancedPalette.ink).frame(width: 44, height: 44)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 18)).foregroundStyle(BalancedPalette.ink).frame(width: 44, height: 44)
                }
            }
            .accessibilityLabel("刷新对账状态")
        ))
        .sensoryFeedback(.success, trigger: successFeedback)
        .task(id: localReadKey) { await loadLocalRows() }
        .onChange(of: localReadable) { _, allowed in
            if session.isLocal && !allowed {
                localReadID = UUID(); localRows = nil; completedLocalReadKey = nil
                localError = nil; localReadLoading = false; successMessage = nil
            }
        }
    }

    /// `.band` with three `.key` rows: 已核平 in `--in`, 待对账 in ink (neutral —
    /// not yet classified one way or the other), 异常 in `--out`.
    private var summaryBand: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow(title: String(localized: "已核平"), count: summaryMetrics.asserted, color: BalancedPalette.income)
            summaryRow(title: String(localized: "待对账"), count: summaryMetrics.pending, color: BalancedPalette.ink)
            summaryRow(title: String(localized: "异常"), count: summaryMetrics.error, color: BalancedPalette.expense)
        }
        .balancedBand()
    }

    private func summaryRow(title: String, count: Int, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).balancedFont(size: 14).foregroundStyle(BalancedPalette.secondary)
            Spacer()
            Text("\(count) 个账户").balancedFont(size: 15, weight: .text).monospacedDigit().foregroundStyle(color)
        }
        .padding(.vertical, 3)
    }

    /// `.mark` status filter strip.
    private var statusTabs: some View {
        HStack(spacing: 20) {
            ForEach(ReconciliationStatusFilter.allCases) { filter in
                let title = filter == .all ? filter.title : "\(filter.title) \(count(for: filter))"
                Button {
                    LedgerFeedback.selection()
                    withAnimation(.easeOut(duration: 0.18)) { selectedStatus = filter }
                } label: {
                    BalancedMark(title: title, selected: selectedStatus == filter, size: 14)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reconciliation-filter-\(filter.rawValue)")
                .accessibilityAddTraits(selectedStatus == filter ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
    }

    /// `.row--stack`: label + (date/diff · status tag) meta line, amount
    /// right-aligned. Liability amounts are always `--out`; asset amounts are
    /// `--out` only when the account has an unresolved discrepancy.
    private func reconciliationRow(_ row: LedgerReconciliationRow) -> some View {
        let st = status(for: row)
        let isLiability = row.account.hasPrefix("Liabilities:")
        let hasError = st?.hasIssue == true
        let isAsserted = (row.status == "asserted" || st?.isReconciled == true) && !hasError
        let amountColor: Color = (hasError || isLiability) ? BalancedPalette.expense : BalancedPalette.ink
        let cur = row.currency.isEmpty ? "CNY" : row.currency

        let leadText: String
        let tagText: String
        if hasError, let assertionAmount = st?.assertionAmount {
            leadText = String(localized: "差异 ") + MoneyText.format(minorUnits: row.ledgerBalance - assertionAmount, currency: cur, showSign: true)
            tagText = String(localized: "异常")
        } else if let last = row.lastAssertion {
            leadText = String(localized: "\(last.date) 断言")
            tagText = isAsserted ? String(localized: "已核平") : String(localized: "待对账")
        } else {
            leadText = String(localized: "尚未断言")
            tagText = String(localized: "待对账")
        }

        return NavigationLink {
            ReconciliationAccountDetailPage(row: row, accountStatus: st, onReconcileSuccess: handleReconcileSuccess)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.label).balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(leadText).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).lineLimit(1)
                        Text("·").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                        BalancedTag(text: tagText, kind: tagText == String(localized: "已核平") ? .ok : .pending)
                    }
                }
                Spacer(minLength: 8)
                BalancedAmount(minorUnits: row.ledgerBalance, currency: cur, size: 15, color: amountColor, showsCurrency: true, currencyScale: 0.78)
            }
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
            .contentShape(Rectangle())
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .accessibilityIdentifier("reconciliation-row-" + row.account)
    }

    private func handleReconcileSuccess(_ message: String) {
        guard !session.isLocal || localReadable else { return }
        successFeedback += 1
        withAnimation { successMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { successMessage = nil }
        }
    }

    private func loadLocalRows() async {
        guard localReadable else {
            localReadID = UUID(); localRows = nil; completedLocalReadKey = nil
            localError = nil; localReadLoading = false; return
        }
        let key = localReadKey
        let id = UUID(); localReadID = id; localReadLoading = true; localRows = nil; localError = nil
        defer { if localReadID == id { localReadLoading = false } }
        do {
            let rows = try await session.localReconciliationRows(start: session.selectedRange.start, end: session.selectedRange.queryEndExclusive)
            guard !Task.isCancelled, localReadID == id, key == localReadKey, localReadable else { return }
            localRows = rows; completedLocalReadKey = key; localError = nil
        } catch {
            if !Task.isCancelled, localReadID == id, key == localReadKey { localError = error.localizedDescription; localRows = nil }
        }
    }
}

/// A pushed destination wrapping the reconcile form in the list's own chrome
/// (back chevron + account label as the title, per d12).
private struct ReconciliationAccountDetailPage: View {
    let row: LedgerReconciliationRow
    let accountStatus: LedgerAccountStatus?
    let onReconcileSuccess: (String) -> Void

    var body: some View {
        ScrollView {
            ReconciliationFormBody(row: row, accountStatus: accountStatus, onReconcileSuccess: onReconcileSuccess).id("\(row.account)-\(row.ledgerBalance)")
        }
        .scrollContentBackground(.hidden)
        .background(BalancedPalette.page)
        .terminalPageChrome(row.label, isRoot: false, showsSync: false)
    }
}

// MARK: - 单账户对账表单 (d12)

/// Shared by the pushed detail page and the modal sheet: 账本余额/实际余额/差异 as
/// `.key` rows, 断言后余额 closes the column with the real `.settle` double rule
/// (the book and the counted balance now agree), the 实际余额/对账日期 fields, the
/// beancount preview in mono, and the 稍后/写入断言 button pair.
struct ReconciliationFormBody: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss

    let row: LedgerReconciliationRow
    let accountStatus: LedgerAccountStatus?
    let onReconcileSuccess: (String) -> Void

    /// Seeded at init, not `.onAppear` — a `List`/`ScrollView` row's `.onAppear`
    /// is not a reliable place to seed `@State`, and leaving it empty makes the
    /// field (and the derived 差异) read as a full payoff to zero on first frame.
    @State private var actualAmount: String
    @State private var balanceDate: String = LedgerReconciliationDates.todayString()
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showingDatePicker = false

    init(row: LedgerReconciliationRow, accountStatus: LedgerAccountStatus?, onReconcileSuccess: @escaping (String) -> Void) {
        self.row = row
        self.accountStatus = accountStatus
        self.onReconcileSuccess = onReconcileSuccess
        _actualAmount = State(initialValue: String(format: "%.2f", Double(row.ledgerBalance) / 100.0))
    }

    private var currency: String { row.currency.isEmpty ? "CNY" : row.currency }

    private var actualCents: Int? {
        let trimmed = actualAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let d = Double(trimmed) else { return nil }
        return Int(round(d * 100))
    }

    private var diffCents: Int? {
        guard let actual = actualCents else { return nil }
        return actual - row.ledgerBalance
    }

    private var adjustmentDate: String { LedgerReconciliationDates.previousDay(from: balanceDate) }

    /// Mirrors the server's `reconciliationAdjustment` (reconciliation.go): the
    /// adjustment target depends on the account's actual `group` metadata, not
    /// on a guess from the account path's spelling.
    private var adjustmentTargetAccount: String {
        let isWealth = session.ledger?.accounts.first { $0.account == row.account }?.group == "wealth"
        guard isWealth else { return "Equity:Balance-Adjustments" }
        return (diffCents ?? 0) > 0 ? "Income:Other" : "Expenses:Unknown"
    }

    /// Describes what the write actually does — no adjustment entry at all
    /// when the figures already agree, and the real target account (not a
    /// fixed placeholder) when one is written.
    private var noteText: String {
        guard let diff = diffCents, diff != 0 else {
            return String(localized: "账实一致，仅写入余额断言，不记任何调整分录。")
        }
        return String(localized: "差异会记成一笔 \(adjustmentTargetAccount) 的调整分录，不会改动已有流水。")
    }

    private var previewLines: [String] {
        guard let diff = diffCents else { return [] }
        if diff == 0 {
            return ["\(balanceDate) balance \(row.account) \(actualAmount) \(currency)"]
        }
        let sign = diff > 0 ? "+" : ""
        return [
            "\(adjustmentDate) * \"余额差额调整\"",
            "  \(row.account)  \(sign)\(MoneyText.format(minorUnits: diff, currency: currency, showsCurrency: false))",
            "  \(adjustmentTargetAccount)  \(diff > 0 ? "-" : "+")\(MoneyText.format(minorUnits: abs(diff), currency: currency, showsCurrency: false))",
            "\(balanceDate) balance \(row.account) \(actualAmount) \(currency)"
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(row.account)
                .balancedMono(size: 11.5)
                .foregroundStyle(BalancedPalette.meta)
                .padding(.bottom, 14)

            VStack(spacing: 0) {
                BalancedKeyRow(label: String(localized: "账本余额"), minorUnits: row.ledgerBalance, currency: currency, color: BalancedPalette.ink)
                BalancedKeyRow(label: String(localized: "实际余额"), minorUnits: actualCents ?? row.ledgerBalance, currency: currency, color: BalancedPalette.ink)
                BalancedKeyRow(label: String(localized: "差异"), minorUnits: abs(diffCents ?? 0), currency: currency,
                    prefix: (diffCents ?? 0) > 0 ? "+" : (diffCents ?? 0) < 0 ? "−" : "",
                    color: (diffCents ?? 0) == 0 ? BalancedPalette.meta : ((diffCents ?? 0) > 0 ? BalancedPalette.income : BalancedPalette.expense))
                Rectangle().fill(BalancedPalette.rule).frame(height: 1).padding(.vertical, 12)
                BalancedKeyRow(label: String(localized: "断言后余额"), minorUnits: actualCents ?? row.ledgerBalance, currency: currency,
                    color: BalancedPalette.ink, isTotal: true, settle: true)
            }
            .balancedBand()

            Text(noteText)
                .balancedFont(size: 12.5)
                .foregroundStyle(BalancedPalette.meta)
                .lineSpacing(2)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 4) {
                Text("实际余额").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                TextField("输入实际金额", text: $actualAmount)
                    .keyboardType(.decimalPad)
                    .balancedFont(size: 15)
                    .foregroundStyle(BalancedPalette.ink)
            }
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
            .padding(.bottom, 18)
            .accessibilityIdentifier("reconciliation-actual-amount")

            VStack(alignment: .leading, spacing: 4) {
                Text("对账日期").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                Button {
                    showingDatePicker = true
                } label: {
                    HStack {
                        Text(balanceDate).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(BalancedPalette.edge)
                    }
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reconciliation-balance-date")
            }
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
            .padding(.bottom, 20)
            .sheet(isPresented: $showingDatePicker) {
                ReconciliationDatePickerSheet(
                    selection: Binding(
                        get: { LedgerReconciliationDates.date(from: balanceDate) ?? Date() },
                        set: { balanceDate = LedgerReconciliationDates.string(from: $0) }
                    )
                )
                .presentationDetents([.medium])
            }

            if !previewLines.isEmpty {
                BalancedSectionLabel(text: String(localized: "将写入"), aside: "main.bean")
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(previewLines, id: \.self) { line in
                        Text(line).balancedMono(size: 11, weight: .regular).foregroundStyle(BalancedPalette.ink)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .balancedBand()
            }

            if let errorMessage {
                Text(errorMessage).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.expense).padding(.top, 10)
            }

            HStack(spacing: 12) {
                Button("稍后") { dismiss() }
                    .buttonStyle(.balanced(.quiet))
                Button(isSubmitting ? "正在写入…" : "写入断言") { Task { await submit() } }
                    .buttonStyle(.balanced(.primary, disabled: diffCents == nil || isSubmitting))
                    .disabled(diffCents == nil || isSubmitting)
                    .accessibilityIdentifier("reconciliation-submit")
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 32)
        .accessibilityIdentifier("reconciliation-card-" + row.account)
    }

    private func submit() async {
        guard let diff = diffCents else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            try await session.reconcileAccount(
                account: row.account,
                actualAmount: actualAmount,
                balanceDate: balanceDate,
                adjustmentDate: adjustmentDate
            )
            isSubmitting = false
            let msg = diff == 0 ? String(localized: "\(row.label) 余额断言已成功记录！") : String(localized: "\(row.label) 平账调整与断言已成功写入！")
            onReconcileSuccess(msg)
            dismiss()
        } catch {
            isSubmitting = false
            errorMessage = error.localizedDescription
            LedgerFeedback.warning()
        }
    }
}

/// Presented by the `对账日期` `.field` row: a graphical DatePicker with a
/// `完成` toolbar button, replacing the native compact DatePicker's grey
/// capsule, which does not exist in this design language.
private struct ReconciliationDatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Date

    var body: some View {
        NavigationStack {
            DatePicker("对账日期", selection: $selection, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(BalancedPalette.ink)
                .labelsHidden()
                .padding(.horizontal, 20)
                .background(BalancedPalette.page)
                .navigationTitle("对账日期")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .tint(BalancedPalette.ink)
    }
}

// MARK: - 单账户对账专用弹窗

struct SingleAccountReconciliationSheet: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss

    let account: String
    let label: String?
    let currency: String?

    @State private var localRow: LedgerReconciliationRow?
    @State private var completedKey: String?
    @State private var readID = UUID()
    @State private var readError: String?
    @State private var reload = 0
    private var readable: Bool {
        session.phase == .ready && !session.privacyShielded && !session.isRangeLoading
            && !session.isValuationCurrencyLoading && !session.transactionMutationStates.values.contains(.pending)
    }
    private var readKey: String {
        "\(account)/\(session.localTransactionPresentationRevision?.uuidString ?? "")/\(session.localGlobalSearchInvalidation)/\(session.selectedRange.start)/\(session.selectedRange.end)/\(readable)/\(reload)"
    }
    private var resolvedRow: LedgerReconciliationRow {
        if let existing = session.reconciliationRow(for: account) {
            return existing
        }
        let bal = session.ledger?.accountBalances.first { $0.account == account }?.amount ?? 0
        return LedgerReconciliationRow(
            account: account,
            alias: label,
            label: label ?? account.split(separator: ":").last.map(String.init) ?? account,
            currency: currency ?? "CNY",
            ledgerBalance: bal,
            status: "pending",
            lastAssertion: nil
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if session.isLocal {
                    if readable, completedKey == readKey, let localRow {
                        ReconciliationFormBody(row: localRow, accountStatus: localRow.snapshotStatus, onReconcileSuccess: { _ in dismiss() }).id("\(localRow.account)-\(localRow.ledgerBalance)")
                    } else if readable, let readError {
                        Text(readError).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta).padding(20)
                        Button("重试") { reload += 1 }.buttonStyle(.balanced(.quiet)).padding(.horizontal, 20)
                    } else {
                        ProgressView("正在读取账户对账快照…").padding(20)
                    }
                } else {
                    ReconciliationFormBody(row: resolvedRow, accountStatus: session.accountStatus(for: account), onReconcileSuccess: { _ in dismiss() }).id("\(resolvedRow.account)-\(resolvedRow.ledgerBalance)")
                }
            }
            .scrollContentBackground(.hidden)
            .background(BalancedPalette.page)
            .navigationTitle("校对余额")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .tint(BalancedPalette.ink)
        .ledgerPrivacyProtectedSheet()
        .task(id: readKey) { if session.isLocal { await loadSnapshot() } }
        .onChange(of: readable) { _, allowed in
            if session.isLocal && !allowed { readID = UUID(); localRow = nil; completedKey = nil; readError = nil }
        }
    }
    private func loadSnapshot() async {
        let id = UUID(), key = readKey
        readID = id; localRow = nil; completedKey = nil; readError = nil
        guard readable else { return }
        do {
            let rows = try await session.localReconciliationRows(start: session.selectedRange.start, end: session.selectedRange.queryEndExclusive)
            guard !Task.isCancelled, readID == id, key == readKey, readable else { return }
            guard let row = rows.first(where: { $0.account == account }) else {
                readError = String(localized: "当前账本中没有可对账的此账户。"); return
            }
            localRow = row; completedKey = key
        } catch {
            if !Task.isCancelled, readID == id, key == readKey, readable { readError = error.localizedDescription }
        }
    }
}
