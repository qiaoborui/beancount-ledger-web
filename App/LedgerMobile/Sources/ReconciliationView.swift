import SwiftUI

enum ReconciliationStatusFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case pending = "待对账"
    case error = "异常"
    case asserted = "已核平"

    var id: String { rawValue }
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
        case "green": "已核平"
        case "red": "异常"
        case "yellow": "待对账"
        default: "未断言"
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
    @Environment(\.dismiss) private var dismiss

    @State private var selectedCategory: AccountFilterCategory = .all
    @State private var selectedStatus: ReconciliationStatusFilter = .all
    @State private var searchText = ""
    @State private var expandedAccountID: String? = ProcessInfo.processInfo.arguments.contains("--expand-first-reconcile") ? "Assets:Bank:Daily" : nil
    @State private var successFeedback = 0
    @State private var errorFeedback = 0
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
            // Category filter
            if selectedCategory != .all {
                let section = AccountBalanceSection(
                    id: row.account.hasPrefix("Liabilities:") ? "liability" : (row.account.contains("Wealth") || row.account.contains("Invest") ? "wealth" : "cash"),
                    title: row.label,
                    rows: []
                )
                if !selectedCategory.matches(section: section) { return false }
            }

            // Status filter
            let rowStatus = status(for: row)
            let statusIsError = rowStatus?.hasIssue == true
            let statusIsAsserted = row.status == "asserted" || rowStatus?.isReconciled == true
            switch selectedStatus {
            case .all:
                break
            case .pending:
                if rowStatus?.isReconciled == true { return false }
            case .error:
                if !statusIsError { return false }
            case .asserted:
                if !statusIsAsserted { return false }
            }

            // Search filter
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

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // Summary Metrics Hero Card
                if !session.isLocal || localRowsCurrent {
                    ReconciliationSummaryHero(
                        metrics: summaryMetrics,
                        currency: session.ledger?.valuationCurrency ?? "CNY"
                    )
                }

                // Category & Status Filters
                VStack(spacing: 10) {
                    // Category Pills
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(AccountFilterCategory.allCases) { cat in
                                let isSelected = selectedCategory == cat
                                Button {
                                    LedgerFeedback.selection()
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                        selectedCategory = cat
                                    }
                                } label: {
                                    Text(cat.rawValue)
                                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                        .foregroundStyle(isSelected ? Color.white : LedgerPalette.ink)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6.5)
                                        .background {
                                            if isSelected {
                                                Capsule().fill(LedgerPalette.cobalt)
                                            } else {
                                                Capsule().fill(LedgerPalette.panel)
                                                    .overlay(Capsule().stroke(LedgerPalette.cardBorder.opacity(0.6), lineWidth: 0.5))
                                            }
                                        }
                                }
                                .buttonStyle(PressScaleButtonStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // Status Filters
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ReconciliationStatusFilter.allCases) { filter in
                                let isSelected = selectedStatus == filter
                                Button {
                                    LedgerFeedback.selection()
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                        selectedStatus = filter
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        if filter == .asserted {
                                            Circle().fill(LedgerPalette.income).frame(width: 6, height: 6)
                                        } else if filter == .pending {
                                            Circle().fill(LedgerPalette.gold).frame(width: 6, height: 6)
                                        } else if filter == .error {
                                            Circle().fill(LedgerPalette.expense).frame(width: 6, height: 6)
                                        }
                                        Text(filter.rawValue)
                                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                    }
                                    .foregroundStyle(isSelected ? LedgerPalette.cobalt : LedgerPalette.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4.5)
                                    .background {
                                        if isSelected {
                                            Capsule().fill(LedgerPalette.cobalt.opacity(0.12))
                                        } else {
                                            Capsule().fill(Color.clear)
                                        }
                                    }
                                }
                                .buttonStyle(PressScaleButtonStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if let successMessage, !session.isLocal || localReadable {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(LedgerPalette.income)
                        Text(successMessage)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(LedgerPalette.ink)
                        Spacer()
                    }
                    .padding(14)
                    .background(LedgerPalette.income.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Account Cards
                if localReadable, let localError {
                    Text("对账读取失败：" + localError).foregroundStyle(.secondary)
                    Button("重试") { Task { await loadLocalRows() } }
                } else if session.isLocal && !localRowsCurrent {
                    ProgressView("正在读取对账账户…")
                } else if filteredRows.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 36))
                            .foregroundStyle(LedgerPalette.secondary)
                        Text(allRows.isEmpty ? "暂无可对账账户" : "当前筛选下无匹配账户")
                            .font(.subheadline)
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(filteredRows) { row in
                            let isExpanded = expandedAccountID == row.account
                            ReconciliationCard(
                                row: row,
                                accountStatus: status(for: row),
                                isExpanded: isExpanded,
                                onToggleExpand: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        expandedAccountID = isExpanded ? nil : row.account
                                    }
                                },
                                onReconcileSuccess: { message in
                                    guard !session.isLocal || localReadable else { return }
                                    successFeedback += 1
                                    withAnimation {
                                        successMessage = message
                                        expandedAccountID = nil
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                        withAnimation { successMessage = nil }
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 16)
        }
        .background(LedgerPalette.canvas.ignoresSafeArea())
        .navigationTitle("账户对账")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索账户名或路径")
        .toolbar {
            if !isRoot {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        isRefreshing = true
                        await session.refresh()
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView().tint(LedgerPalette.cobalt)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .sensoryFeedback(.success, trigger: successFeedback)
        .sensoryFeedback(.error, trigger: errorFeedback)
        .task(id: localReadKey) { await loadLocalRows() }
        .onChange(of: localReadable) { _, allowed in
            if session.isLocal && !allowed {
                localReadID = UUID(); localRows = nil; completedLocalReadKey = nil
                localError = nil; localReadLoading = false; successMessage = nil
            }
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

// MARK: - 对账概览卡片

private struct ReconciliationSummaryHero: View {
    let metrics: (total: Int, asserted: Int, pending: Int, error: Int)
    let currency: String

    private var progressRatio: Double {
        guard metrics.total > 0 else { return 1.0 }
        return Double(metrics.asserted) / Double(metrics.total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("对账健康度")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(progressRatio * 100))")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(progressRatio >= 0.8 ? LedgerPalette.income : LedgerPalette.ink)
                        Text("%")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(LedgerPalette.secondary)
                        Text("已核平")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                            .padding(.leading, 4)
                    }
                }
                Spacer()

                // Radial or Circular Badge
                ZStack {
                    Circle()
                        .stroke(LedgerPalette.line, lineWidth: 6)
                        .frame(width: 52, height: 52)
                    Circle()
                        .trim(from: 0, to: progressRatio)
                        .stroke(
                            progressRatio >= 0.8 ? LedgerPalette.income : LedgerPalette.cobalt,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 52, height: 52)
                    Image(systemName: progressRatio >= 1.0 ? "checkmark" : "shield.checkered")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(progressRatio >= 0.8 ? LedgerPalette.income : LedgerPalette.cobalt)
                }
            }

            // Progress Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LedgerPalette.line.opacity(0.8))
                        .frame(height: 6)
                    Capsule()
                        .fill(progressRatio >= 0.8 ? LedgerPalette.income : LedgerPalette.cobalt)
                        .frame(width: max(6, geo.size.width * progressRatio), height: 6)
                }
            }
            .frame(height: 6)

            Divider().overlay(LedgerPalette.line.opacity(0.6))

            // Metric Counters
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(LedgerPalette.income).frame(width: 6, height: 6)
                        Text("已核平")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    Text("\(metrics.asserted) 个")
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(LedgerPalette.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(LedgerPalette.gold).frame(width: 6, height: 6)
                        Text("待对账")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    Text("\(metrics.pending) 个")
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(LedgerPalette.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if metrics.error > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Circle().fill(LedgerPalette.expense).frame(width: 6, height: 6)
                            Text("断言差额")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                        Text("\(metrics.error) 个")
                            .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(LedgerPalette.expense)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .ledgerFrostedCard(cornerRadius: 18, padding: 18)
        .padding(.horizontal, 16)
    }
}

// MARK: - 单账户对账卡片

struct ReconciliationCard: View {
    @EnvironmentObject private var session: LedgerSession

    let row: LedgerReconciliationRow
    let accountStatus: LedgerAccountStatus?
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onReconcileSuccess: (String) -> Void

    @State private var actualAmount: String = ""
    @State private var balanceDate: String = LedgerReconciliationDates.todayString()
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var currency: String {
        row.currency.isEmpty ? "CNY" : row.currency
    }

    private var accountIcon: (name: String, color: Color) {
        let act = row.account.lowercased()
        if act.contains("alipay") || row.label.contains("支付宝") {
            return ("a.square.fill", Color(red: 0.08, green: 0.52, blue: 0.95))
        }
        if act.contains("wechat") || act.contains("wx") || row.label.contains("微信") {
            return ("message.fill", Color(red: 0.12, green: 0.75, blue: 0.38))
        }
        if act.contains("card") || act.contains("credit") || row.label.contains("信用卡") {
            return ("creditcard.fill", Color(red: 0.96, green: 0.55, blue: 0.18))
        }
        if act.contains("bank") || row.label.contains("银行") || row.label.contains("储蓄") {
            return ("building.columns.fill", Color(red: 0.16, green: 0.54, blue: 0.95))
        }
        if act.contains("cash") || row.label.contains("现金") {
            return ("banknote.fill", Color(red: 0.12, green: 0.68, blue: 0.36))
        }
        if act.contains("invest") || act.contains("stock") || act.contains("fund") || row.label.contains("基金") || row.label.contains("股票") {
            return ("chart.line.uptrend.xyaxis", Color(red: 0.65, green: 0.36, blue: 0.88))
        }
        return ("wallet.bifold", LedgerPalette.cobalt)
    }

    private var statusBadge: (title: String, color: Color, icon: String) {
        if accountStatus?.hasIssue == true {
            return ("断言差额", LedgerPalette.expense, "exclamationmark.circle.fill")
        }
        if row.status == "asserted" || accountStatus?.isReconciled == true {
            return ("已核平", LedgerPalette.income, "checkmark.circle.fill")
        }
        return ("待核对", LedgerPalette.gold, "clock.arrow.circlepath")
    }

    private var actualCents: Int? {
        let trimmed = actualAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let d = Double(trimmed) else { return nil }
        return Int(round(d * 100))
    }

    private var diffCents: Int? {
        guard let actual = actualCents else { return nil }
        return actual - row.ledgerBalance
    }

    private var adjustmentDate: String {
        LedgerReconciliationDates.previousDay(from: balanceDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header (Always Visible, Tappable to Expand)
            Button(action: onToggleExpand) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accountIcon.color.opacity(0.14))
                            .frame(width: 40, height: 40)
                        Image(systemName: accountIcon.name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(accountIcon.color)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.label)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(LedgerPalette.ink)
                                .lineLimit(1)
                                .layoutPriority(1)
                            HStack(spacing: 3) {
                                Image(systemName: statusBadge.icon)
                                    .font(.system(size: 10))
                                Text(statusBadge.title)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(statusBadge.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusBadge.color.opacity(0.12), in: Capsule())
                            .fixedSize()
                        }

                        Text(row.account)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LedgerPalette.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(MoneyText.format(minorUnits: row.ledgerBalance, currency: currency))
                            .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(LedgerPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text("账面余额")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                        .padding(.leading, 4)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())

            // Last Assertion Date Bar
            HStack {
                if let last = row.lastAssertion {
                    Text("上次核对：\(last.date) (\(MoneyText.format(minorUnits: last.amount, currency: last.currency)))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(LedgerPalette.secondary)
                } else {
                    Text("暂无历史核对断言记录")
                        .font(.system(size: 11.5))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                Spacer()
                if !isExpanded {
                    Text("点击校对")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(LedgerPalette.cobalt)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, isExpanded ? 6 : 12)

            // Expanded Reconciliation Form
            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    Divider().overlay(LedgerPalette.line.opacity(0.6))

                    // Input Row
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("实际余额")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(LedgerPalette.secondary)
                            Spacer()
                            Button("填入账面金额") {
                                LedgerFeedback.selection()
                                let val = Double(row.ledgerBalance) / 100.0
                                actualAmount = String(format: "%.2f", val)
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(LedgerPalette.cobalt)
                        }

                        HStack(spacing: 8) {
                            Text(MoneyText.currencySymbol(for: currency))
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(LedgerPalette.secondary)

                            TextField("输入银行/钱包当前实际金额", text: $actualAmount)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(LedgerPalette.ink)
                                .onAppear {
                                    if actualAmount.isEmpty {
                                        let val = Double(row.ledgerBalance) / 100.0
                                        actualAmount = String(format: "%.2f", val)
                                    }
                                }

                            if !actualAmount.isEmpty {
                                Button {
                                    actualAmount = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(LedgerPalette.secondary)
                                }
                            }
                        }
                        .padding(12)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    }

                    // Balance Date Input
                    VStack(alignment: .leading, spacing: 6) {
                        Text("对账基准日期")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(LedgerPalette.secondary)

                        DatePicker(
                            "选择日期",
                            selection: Binding(
                                get: { LedgerReconciliationDates.date(from: balanceDate) ?? Date() },
                                set: { balanceDate = LedgerReconciliationDates.string(from: $0) }
                            ),
                            displayedComponents: .date
                        )
                        .datePickerStyle(.compact)
                        .padding(.vertical, 2)
                    }

                    // Diff Preview Section
                    if let diff = diffCents {
                        if diff == 0 {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(LedgerPalette.income)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("账实完全相符")
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(LedgerPalette.income)
                                    Text("实际余额与账面余额完全一致，将写入 \(balanceDate) balance 断言。")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(LedgerPalette.secondary)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LedgerPalette.income.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(LedgerPalette.expense)
                                    Text("存在差额：\(diff > 0 ? "+" : "")\(MoneyText.format(minorUnits: diff, currency: currency))")
                                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                                        .foregroundStyle(LedgerPalette.expense)
                                }

                                Text("将自动生成平账调整交易并写入断言：")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(LedgerPalette.secondary)

                                // Code Preview
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(adjustmentDate) * \"余额差额调整\"")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(LedgerPalette.secondary)
                                    HStack {
                                        Text("  \(row.account)")
                                            .font(.system(size: 11, design: .monospaced))
                                        Spacer()
                                        Text("\(diff > 0 ? "+" : "")\(MoneyText.format(minorUnits: diff, currency: currency))")
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(LedgerPalette.gold)
                                    }
                                    HStack {
                                        Text("  \(adjustmentTargetAccount)")
                                            .font(.system(size: 11, design: .monospaced))
                                        Spacer()
                                        Text("\(diff > 0 ? "-" : "+")\(MoneyText.format(minorUnits: abs(diff), currency: currency))")
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(LedgerPalette.income)
                                    }
                                    Text("\(balanceDate) balance \(row.account) \(actualAmount) \(currency)")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(LedgerPalette.cobalt)
                                        .padding(.top, 2)
                                }
                                .padding(10)
                                .background(LedgerPalette.canvas, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LedgerPalette.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(LedgerPalette.expense)
                    }

                    // Submit Button
                    Button {
                        Task { await submitReconciliation() }
                    } label: {
                        HStack(spacing: 8) {
                            if isSubmitting {
                                ProgressView().tint(.white)
                                Text("正在写入对账记录...")
                            } else {
                                Image(systemName: diffCents == 0 ? "checkmark.seal.fill" : "wand.and.stars")
                                Text(diffCents == 0 ? "写入余额断言 (balance)" : "平账并写入断言")
                            }
                        }
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            (diffCents == nil || isSubmitting) ? LedgerPalette.secondary.opacity(0.5) : LedgerPalette.cobalt,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                    .disabled(diffCents == nil || isSubmitting)
                    .buttonStyle(PressScaleButtonStyle())
                }
                .padding(14)
            }
        }
        .accessibilityIdentifier("reconciliation-card-" + row.account)
        .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LedgerPalette.cardBorder.opacity(0.6), lineWidth: 0.5)
        )
    }

    private var adjustmentTargetAccount: String {
        if row.account.contains("Wealth") || row.account.contains("Invest") || row.account.contains("Fund") {
            return (diffCents ?? 0) > 0 ? "Income:Other" : "Expenses:Unknown"
        }
        return "Equity:Balance-Adjustments"
    }

    private func submitReconciliation() async {
        guard let diff = diffCents else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            let result = try await session.reconcileAccount(
                account: row.account,
                actualAmount: actualAmount,
                balanceDate: balanceDate,
                adjustmentDate: adjustmentDate
            )
            isSubmitting = false
            let msg = diff == 0 ? "\(row.label) 余额断言已成功记录！" : "\(row.label) 平账调整与断言已成功写入！"
            onReconcileSuccess(msg)
        } catch {
            isSubmitting = false
            errorMessage = error.localizedDescription
            LedgerFeedback.warning()
        }
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
                VStack(spacing: 16) {
                    if session.isLocal {
                        if readable, completedKey == readKey, let localRow {
                            ReconciliationCard(row: localRow, accountStatus: localRow.snapshotStatus,
                                isExpanded: true, onToggleExpand: {}, onReconcileSuccess: { _ in dismiss() })
                        } else if readable, let readError {
                            Text(readError).foregroundStyle(.secondary)
                            Button("重试") { reload += 1 }
                        } else {
                            ProgressView("正在读取账户对账快照…")
                        }
                    } else {
                        ReconciliationCard(row: resolvedRow, accountStatus: session.accountStatus(for: account),
                            isExpanded: true, onToggleExpand: {}, onReconcileSuccess: { _ in dismiss() })
                    }
                }
                .padding(16)
            }
            .background(LedgerPalette.canvas.ignoresSafeArea())
            .navigationTitle("校对余额")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
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
                readError = "当前账本中没有可对账的此账户。"; return
            }
            localRow = row; completedKey = key
        } catch {
            if !Task.isCancelled, readID == id, key == readKey, readable { readError = error.localizedDescription }
        }
    }
}
