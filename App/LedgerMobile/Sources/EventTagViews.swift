import SwiftUI
import Charts

// MARK: - Event Tag List View

struct EventTagListView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss

    enum SortOrder: String, CaseIterable, Identifiable {
        case recent = "最新活跃"
        case spend = "消费最高"
        case count = "交易最多"

        var id: String { rawValue }
    }

    @State private var sortOrder: SortOrder = .recent
    @State private var searchQuery = ""
    @State private var selectedTag: String?

    private var allTransactions: [LedgerTransaction] {
        session.visibleTransactions
    }

    private var accountLabels: [String: String] {
        TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
    }

    private var tagSummaries: [EventTagSummary] {
        if session.isLocal { return session.localEventTagSummaries ?? [] }
        return EventTagCalculator.summarizeAllTags(from: allTransactions, accountLabels: accountLabels)
    }
    private var readKey: String {
        "\(session.localGlobalSearchInvalidation)/\(session.phase)/\(session.privacyShielded)/\(session.isRangeLoading)/\(session.isValuationCurrencyLoading)/\(session.transactionMutationStates.values.contains(.pending))"
    }

    private var filteredSummaries: [EventTagSummary] {
        var list = tagSummaries
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchQuery.lowercased()
            list = list.filter { $0.tag.lowercased().contains(q) }
        }

        switch sortOrder {
        case .recent:
            return list.sorted { ($0.endDate ?? "") > ($1.endDate ?? "") }
        case .spend:
            return list.sorted { $0.netSpend > $1.netSpend }
        case .count:
            return list.sorted { $0.transactionCount > $1.transactionCount }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if session.isLocal, let error = session.localEventTagSummaryError {
                    ContentUnavailableView("标签汇总读取失败", systemImage: "exclamationmark.triangle", description: Text(error))
                    Button("重试") { Task { await session.loadLocalEventTagSummaries(force: true) } }
                } else if session.isLocal && session.localEventTagSummaries == nil {
                    ProgressView("正在统计全部标签…")
                } else if tagSummaries.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .background(LedgerPalette.canvas)
            .task(id: readKey) { if session.isLocal { await session.loadLocalEventTagSummaries() } }
            .navigationTitle("事件与项目核算")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedTag != nil },
                set: { if !$0 { selectedTag = nil } }
            )) {
                if let tag = selectedTag {
                    EventTagReportView(tag: tag)
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Sort Toolbar
            HStack(spacing: 6) {
                ForEach(SortOrder.allCases) { order in
                    let isSelected = sortOrder == order
                    Button {
                        LedgerFeedback.selection()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            sortOrder = order
                        }
                    } label: {
                        Text(order.rawValue)
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
                }
                Spacer()
                Text("\(filteredSummaries.count) 个标签")
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(LedgerPalette.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            List {
                ForEach(filteredSummaries) { summary in
                    Button {
                        selectedTag = summary.tag
                    } label: {
                        EventTagSummaryCard(summary: summary)
                    }
                    .accessibilityIdentifier("event-tag-summary-" + summary.tag)
                    .buttonStyle(PressScaleButtonStyle(pressedScale: 0.98))
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchQuery, prompt: "搜索标签名称")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(LedgerPalette.cobalt.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "tag.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(LedgerPalette.cobalt)
            }

            VStack(spacing: 6) {
                Text("暂无事件或标签")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(LedgerPalette.ink)
                Text("为交易添加标签（如 #2026-日本旅行、#装修、#搬家），即可在这里生成独立项目核算与报表。")
                    .font(.system(size: 14))
                    .foregroundStyle(LedgerPalette.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Event Tag Summary Card

private struct EventTagSummaryCard: View {
    let summary: EventTagSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Text("#" + summary.tag)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(LedgerPalette.cobalt)
                    Text("\(summary.transactionCount) 笔")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                Spacer()
                AmountLabel(
                    minorUnits: summary.netSpend,
                    currency: summary.currency,
                    font: .system(size: 18, weight: .bold, design: .rounded),
                    color: LedgerPalette.expense
                )
            }

            HStack {
                if let start = summary.startDate, let end = summary.endDate {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11))
                        Text(start == end ? start : "\(start) ~ \(end)")
                            .font(.system(size: 12, design: .rounded))
                        Text("(\(summary.daysCount)天)")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(LedgerPalette.secondary)
                }

                Spacer()

                if summary.daysCount > 1 && summary.netSpend > 0 {
                    Text("日均 \(MoneyText.format(minorUnits: summary.dailyAverage, currency: summary.currency))")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(LedgerPalette.secondary)
                }
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
}

// MARK: - Event Tag Report View (独立核算报表详情)

struct EventTagReportView: View {
    @EnvironmentObject private var session: LedgerSession
    let tag: String

    @State private var sharePresented = false
    @State private var selectedDailyDate: String? = nil
    @State private var aggregate: LocalEventTagReportScan.Result?
    @State private var selectedTransaction: LedgerTransaction?
    @State private var window: LocalTransactionWindow.Window?
    @State private var aggregateScope: ReadScope?
    @State private var windowScope: ReadScope?
    @State private var aggregateError: String?
    @State private var windowError: String?
    @State private var aggregateLoading = false
    @State private var windowLoading = false
    @State private var active = false
    @State private var page = 0
    @State private var displayedPage = 0
    @State private var reload = 0
    @State private var export: LocalEventReportExport?
    @State private var exportOwner: LocalEventReportExport?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportID: UUID?
    @State private var exportError: String?

    private struct ReadScope: Equatable {
        let tag: String
        let revision: UUID?
        let invalidation: Int
        let range: LedgerDateRange
        let readable: Bool
        let reload: Int
    }
    private struct ReadRequest: Equatable {
        let scope: ReadScope
        let active: Bool
        let page: Int
    }
    private var scope: ReadScope {
        .init(tag: tag, revision: session.localTransactionPresentationRevision,
            invalidation: session.localGlobalSearchInvalidation, range: session.selectedRange,
            readable: session.phase == .ready && !session.privacyShielded && !session.isRangeLoading
                && !session.isValuationCurrencyLoading && !session.transactionMutationStates.values.contains(.pending),
            reload: reload)
    }
    private var request: ReadRequest { .init(scope: scope, active: active, page: page) }
    private var aggregateRequest: ReadRequest { .init(scope: scope, active: active, page: 0) }
    private var aggregateCurrent: Bool { aggregate != nil && aggregateScope == scope && scope.readable }
    private var windowCurrent: Bool { window != nil && windowScope == scope && scope.readable }
    private var completeCount: Int { session.isLocal ? (aggregate?.summary.transactionCount ?? 0) : report.transactions.count }

    private var allTransactions: [LedgerTransaction] {
        session.visibleTransactions
    }

    private var accountLabels: [String: String] {
        TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
    }

    private var report: EventTagReport {
        guard session.isLocal else {
            return EventTagCalculator.generateReport(tag: tag, from: allTransactions, accountLabels: accountLabels)
        }
        // Only the row window is partial. Totals, categories and daily rhythm
        // are complete EOF aggregates; no caller exports this as a full report.
        let summary = aggregate?.summary
        return EventTagReport(tag: tag, transactions: windowCurrent ? (window?.transactions ?? []) : [],
            totalExpense: summary?.totalExpense ?? 0, totalIncome: summary?.totalIncome ?? 0,
            netSpend: summary?.netSpend ?? 0, currency: summary?.currency ?? "CNY",
            startDate: summary?.startDate, endDate: summary?.endDate,
            daysCount: summary?.daysCount ?? 0, dailyAverage: summary?.dailyAverage ?? 0,
            categoryBreakdown: aggregate?.categoryBreakdown ?? [], dailySeries: aggregate?.dailySeries ?? [])
    }

    private var groupedTransactions: [(date: String, transactions: [LedgerTransaction])] {
        Dictionary(grouping: report.transactions, by: \.date)
            .map { (date: $0.key, transactions: $0.value) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if session.isLocal, let aggregateError, aggregateCurrent {
                    Text("事件汇总刷新失败：" + aggregateError).foregroundStyle(.secondary)
                    Button("重试汇总") { reload += 1 }
                }
                if !session.isLocal || aggregateCurrent {
                    eventHeroCard
                    if !report.categoryBreakdown.isEmpty { categoryBreakdownCard }
                    if report.dailySeries.count > 1 { dailyRhythmCard }
                } else if let aggregateError {
                    Text("事件汇总读取失败：" + aggregateError).foregroundStyle(.secondary)
                    Button("重试汇总") { reload += 1 }
                } else if aggregateLoading {
                    ProgressView("正在核算完整事件…")
                } else {
                    Button("读取完整事件汇总") { reload += 1 }
                }
                if session.isLocal {
                    if let windowError {
                        Text("事件流水读取失败：" + windowError).foregroundStyle(.secondary)
                        Button("重试流水") { reload += 1 }
                    }
                    if windowLoading { ProgressView("正在读取事件流水…") }
                    if windowCurrent {
                        transactionsSection
                        HStack {
                            Button("上一页") {
                                let target = max(0, displayedPage - 1)
                                if page == target { reload += 1 } else { page = target }
                            }.disabled(displayedPage == 0 || windowLoading)
                            Spacer()
                            Text("第 \(displayedPage + 1) 页").font(.caption)
                                .accessibilityIdentifier("event-report-page")
                            Spacer()
                            Button("下一页") {
                                let target = displayedPage + 1
                                if page == target { reload += 1 } else { page = target }
                            }.disabled(window?.isComplete != false || windowLoading)
                        }
                    }
                } else { transactionsSection }
                if let exportError {
                    Text(exportError).foregroundStyle(.secondary)
                }
                if exportID != nil { ProgressView("正在生成完整事件文件…") }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(LedgerPalette.canvas)
        .navigationTitle("#\(tag)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if session.isLocal {
                    Menu {
                        Button("导出完整 Markdown 文件", action: prepareExport)
                            .disabled(exportID != nil || !scope.readable)
                        Button("图片与剪贴板导出") { sharePresented = true }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityIdentifier("event-report-export-menu")
                    .disabled(!scope.readable)
                } else {
                    Button { sharePresented = true } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
            }
        }
        .sheet(isPresented: $sharePresented) {
            // Preserve existing full clipboard/image semantics until that API
            // can consume a file. Never pass the current page as a complete list.
            EventReportShareSheet(report: session.isLocal
                ? EventTagCalculator.generateReport(tag: tag, from: allTransactions, accountLabels: accountLabels)
                : report, accountLabels: accountLabels)
                .ledgerPrivacyProtectedSheet()
        }
        .sheet(item: $export, onDismiss: cancelExport) { value in
            NavigationStack {
                VStack(spacing: 16) {
                    Text("完整事件 Markdown").font(.headline)
                    Text("共 \(value.count) 笔流水，包含全部分类与核算结果。")
                    ShareLink(item: value.url) { Label("分享完整文件", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("event-report-file-share")
                }
                .padding()
                .navigationTitle("事件文件导出")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { export = nil } } }
            }
            .ledgerPrivacyProtectedSheet()
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedTransaction != nil },
            set: { if !$0 { selectedTransaction = nil } }
        )) {
            if let selectedTransaction { TransactionDetailView(transaction: selectedTransaction) }
        }
        .task(id: aggregateRequest) { if session.isLocal { await loadAggregate() } }
        .task(id: request) { if session.isLocal { await loadWindow() } }
        .onAppear { active = true }
        .onDisappear {
            active = false
            if export == nil { cancelExport() }
        }
        .onChange(of: scope) { _, value in
            cancelExport()
            if !value.readable {
                aggregate = nil; window = nil; aggregateScope = nil; windowScope = nil
                sharePresented = false
            }
        }
        .onChange(of: tag) { _, _ in page = 0; displayedPage = 0; selectedDailyDate = nil }
        .onChange(of: session.selectedRange) { _, _ in page = 0; displayedPage = 0; selectedDailyDate = nil }
        .onChange(of: session.localTransactionPresentationRevision) { _, _ in page = 0; displayedPage = 0 }
    }

    private func loadAggregate() async {
        guard active, scope.readable else { return }
        let key = aggregateRequest
        aggregateLoading = true; aggregateError = nil
        defer { if key == aggregateRequest { aggregateLoading = false } }
        do {
            let result = try await session.localEventTagReport(tag)
            guard !Task.isCancelled, key == aggregateRequest, scope.readable else { return }
            aggregate = result; aggregateScope = key.scope
        } catch {
            if !Task.isCancelled, key == aggregateRequest { aggregateError = error.localizedDescription }
        }
    }
    private func loadWindow() async {
        guard active, scope.readable else { return }
        let key = request
        windowLoading = true; windowError = nil
        defer { if key == request { windowLoading = false } }
        do {
            let result = try await session.localEventTagWindow(tag, index: key.page)
            guard !Task.isCancelled, key == request, scope.readable else { return }
            window = result; windowScope = key.scope; displayedPage = key.page
        } catch {
            if !Task.isCancelled, key == request { windowError = error.localizedDescription }
        }
    }
    private func cancelExport() {
        exportID = nil
        exportTask?.cancel(); exportTask = nil
        if let exportOwner { session.discardLocalEventReportExport(exportOwner) }
        exportOwner = nil; export = nil
    }
    private func prepareExport() {
        guard session.isLocal, scope.readable, exportID == nil else { return }
        cancelExport()
        let id = UUID(), captured = scope
        exportID = id; exportError = nil
        exportTask = Task { @MainActor in
            defer { if exportID == id { exportID = nil; exportTask = nil } }
            do {
                let result = try await session.prepareLocalEventReportExport(tag)
                guard !Task.isCancelled, exportID == id, captured == scope else {
                    session.discardLocalEventReportExport(result); return
                }
                exportOwner = result; export = result
            } catch {
                if !Task.isCancelled, exportID == id { exportError = error.localizedDescription }
            }
        }
    }

    private var eventHeroCard: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("事件独立核算")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                    Text("#" + tag)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(LedgerPalette.ink)
                }
                Spacer()
                Text("\(completeCount) 笔流水")
                    .accessibilityIdentifier("event-report-count")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(LedgerPalette.cobalt)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(LedgerPalette.cobalt.opacity(0.12), in: Capsule())
            }

            VStack(spacing: 4) {
                Text("净支出金额")
                    .font(.system(size: 12))
                    .foregroundStyle(LedgerPalette.secondary)
                AmountLabel(
                    minorUnits: report.netSpend,
                    currency: report.currency,
                    font: .system(size: 32, weight: .bold, design: .rounded),
                    color: LedgerPalette.expense
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            Divider()

            // Sub-metrics grid
            HStack(spacing: 0) {
                metricColumn(
                    title: "总支出",
                    value: MoneyText.format(minorUnits: report.totalExpense, currency: report.currency),
                    color: LedgerPalette.expense
                )
                Divider().frame(height: 30)
                metricColumn(
                    title: "收入 / 退款",
                    value: MoneyText.format(minorUnits: report.totalIncome, currency: report.currency),
                    color: LedgerPalette.income
                )
                Divider().frame(height: 30)
                metricColumn(
                    title: "日均开销",
                    value: MoneyText.format(minorUnits: report.dailyAverage, currency: report.currency),
                    color: LedgerPalette.ink
                )
            }

            if let s = report.startDate, let e = report.endDate {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                    Text(s == e ? s : "\(s) 至 \(e)")
                        .font(.system(size: 12, design: .rounded))
                    Text("· 共 \(report.daysCount) 天")
                        .font(.system(size: 12))
                }
                .foregroundStyle(LedgerPalette.secondary)
                .padding(.top, 2)
            }
        }
        .padding(16)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(LedgerPalette.cardBorder, lineWidth: 0.8)
        )
    }

    private func metricColumn(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(LedgerPalette.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    private var categoryBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("分类构成占比")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                Spacer()
                Text("\(report.categoryBreakdown.count) 个分类")
                    .font(.system(size: 12))
                    .foregroundStyle(LedgerPalette.secondary)
            }

            VStack(spacing: 10) {
                ForEach(report.categoryBreakdown) { cat in
                    VStack(spacing: 5) {
                        HStack {
                            Text(cat.label)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(LedgerPalette.ink)
                            Spacer()
                            Text(String(format: "%.1f%%", cat.percentage * 100))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(LedgerPalette.secondary)
                            Text(MoneyText.format(minorUnits: cat.amount, currency: report.currency))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(LedgerPalette.ink)
                        }

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color(uiColor: .tertiarySystemFill))
                                    .frame(height: 6)
                                Capsule()
                                    .fill(LedgerPalette.cobalt)
                                    .frame(width: max(4, proxy.size.width * CGFloat(cat.percentage)), height: 6)
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
        .padding(16)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LedgerPalette.cardBorder, lineWidth: 0.8)
        )
    }

    private var dailyRhythmCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("每日支出节奏")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                Spacer()
                if let selectedDate = selectedDailyDate,
                   let point = report.dailySeries.first(where: { $0.date == selectedDate }) {
                    Text("\(formatShortDate(selectedDate)) · \(MoneyText.format(minorUnits: point.amount, currency: report.currency))")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(LedgerPalette.cobalt)
                } else {
                    Text("共 \(report.dailySeries.count) 天有消费")
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }

            Chart(report.dailySeries) { point in
                let isSelected = selectedDailyDate == point.date
                BarMark(
                    x: .value("日期", point.date),
                    y: .value("金额", Double(point.amount) / 100.0)
                )
                .foregroundStyle(
                    isSelected
                        ? LedgerPalette.cobalt
                        : (selectedDailyDate == nil ? LedgerPalette.cobalt : LedgerPalette.cobalt.opacity(0.45))
                )
                .cornerRadius(4)
            }
            .frame(height: 120)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let intVal = value.as(Double.self) {
                            Text("¥\(Int(intVal))")
                                .font(.system(size: 10))
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                let tickDates = xAxisLabels(for: report.dailySeries)
                AxisMarks(values: tickDates) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(LedgerPalette.line)
                    AxisTick().foregroundStyle(LedgerPalette.lineStrong)
                    AxisValueLabel {
                        if let dateStr = value.as(String.self) {
                            Text(formatShortDate(dateStr))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let frame = geometry[plotFrame]
                                    let x = value.location.x - frame.minX
                                    guard x >= 0, x <= frame.width,
                                          let dateStr: String = proxy.value(atX: x) else { return }
                                    selectedDailyDate = dateStr
                                }
                        )
                }
            }
        }
        .padding(16)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LedgerPalette.cardBorder, lineWidth: 0.8)
        )
    }

    private func xAxisLabels(for points: [EventTagDailyPoint]) -> [String] {
        guard !points.isEmpty else { return [] }
        if points.count <= 5 {
            return points.map(\.date)
        }
        let count = 5
        let last = Double(points.count - 1)
        var selected: [String] = []
        for offset in 0..<count {
            let index = Int((Double(offset) * last / Double(count - 1)).rounded())
            let date = points[index].date
            if !selected.contains(date) {
                selected.append(date)
            }
        }
        return selected
    }

    private func formatShortDate(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-")
        if parts.count == 3 {
            let m = Int(parts[1]) ?? 0
            let d = Int(parts[2]) ?? 0
            return "\(m)/\(d)"
        }
        return String(dateStr.suffix(5))
    }

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("交易明细")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LedgerPalette.ink)
                .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(groupedTransactions, id: \.date) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(TransactionDateHeaderFormatter.format(group.date))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LedgerPalette.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 4)

                        VStack(spacing: 0) {
                            ForEach(group.transactions) { tx in
                                Button {
                                    selectedTransaction = tx
                                } label: {
                                    TransactionRow(transaction: tx, accountLabels: accountLabels)
                                }
                                .buttonStyle(.plain)
                                .disabled(session.isLocal && windowLoading)
                                .accessibilityIdentifier("event-report-row-" + tx.id)
                                .padding(.horizontal, 12)

                                if tx.id != group.transactions.last?.id {
                                    Divider().padding(.leading, 62)
                                }
                            }
                        }
                        .background(LedgerPalette.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(LedgerPalette.cardBorder, lineWidth: 0.8)
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Event Report Share Sheet

struct EventReportShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: EventTagReport
    let accountLabels: [String: String]

    @State private var renderedImage: UIImage?
    @State private var isRendering = false
    @State private var copiedFeedback = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Export Card Preview
                    EventReportShareCard(report: report, accountLabels: accountLabels)
                        .padding(16)

                    // Action buttons
                    VStack(spacing: 10) {
                        Button {
                            renderAndShare()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                Text("分享 / 保存结算单长图")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(LedgerPalette.cobalt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressScaleButtonStyle())

                        Button {
                            copyMarkdown()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                                Text(copiedFeedback ? "已复制文本明细" : "复制 Markdown 文本清单")
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(LedgerPalette.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressScaleButtonStyle())
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
            .background(LedgerPalette.canvas)
            .navigationTitle("事件核算单导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @MainActor
    private func renderAndShare() {
        let card = EventReportShareCard(report: report, accountLabels: accountLabels)
            .frame(width: 380)
            .background(Color(uiColor: .systemBackground))
        let renderer = ImageRenderer(content: card)
        renderer.scale = UIScreen.main.scale
        if let uiImage = renderer.uiImage {
            let activityVC = UIActivityViewController(activityItems: [uiImage], applicationActivities: nil)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                var topVC = rootVC
                while let presented = topVC.presentedViewController {
                    topVC = presented
                }
                topVC.present(activityVC, animated: true)
            }
        }
    }

    private func copyMarkdown() {
        var lines: [String] = []
        lines.append("# 事件核算报告：#\(report.tag)")
        if let s = report.startDate, let e = report.endDate {
            lines.append("时间跨度：\(s) ~ \(e)（共 \(report.daysCount) 天）")
        }
        lines.append("净支出：\(MoneyText.format(minorUnits: report.netSpend, currency: report.currency))")
        lines.append("总支出：\(MoneyText.format(minorUnits: report.totalExpense, currency: report.currency))，收入/退款：\(MoneyText.format(minorUnits: report.totalIncome, currency: report.currency))")
        lines.append("日均消费：\(MoneyText.format(minorUnits: report.dailyAverage, currency: report.currency))")
        lines.append("")
        lines.append("## 分类支出")
        for cat in report.categoryBreakdown {
            lines.append("- \(cat.label)：\(MoneyText.format(minorUnits: cat.amount, currency: report.currency)) (\(String(format: "%.1f%%", cat.percentage * 100)))")
        }
        lines.append("")
        lines.append("## 交易清单 (\(report.transactions.count) 笔)")
        for tx in report.transactions {
            let p = TransactionPresentation(transaction: tx)
            lines.append("- \(tx.date) | \(p.title) | \(amountPrefix(p.kind))\(MoneyText.format(minorUnits: p.minorUnits, currency: p.currency))")
        }

        UIPasteboard.general.string = lines.joined(separator: "\n")
        copiedFeedback = true
        LedgerFeedback.success()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedFeedback = false
        }
    }
}

// MARK: - Event Report Share Card (结算长图卡片)

struct EventReportShareCard: View {
    let report: EventTagReport
    let accountLabels: [String: String]

    var body: some View {
        VStack(spacing: 0) {
            // Receipt Header Notch
            VStack(spacing: 12) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(LedgerPalette.cobalt)
                        Text("#" + report.tag)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(LedgerPalette.ink)
                    }
                    Spacer()
                    Text("事件财务结算单")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }

                VStack(spacing: 4) {
                    Text("结算总支出")
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerPalette.secondary)
                    AmountLabel(
                        minorUnits: report.netSpend,
                        currency: report.currency,
                        font: .system(size: 32, weight: .bold, design: .rounded),
                        color: LedgerPalette.expense
                    )
                }
                .padding(.vertical, 4)

                // Date & Days
                if let s = report.startDate, let e = report.endDate {
                    Text(s == e ? s : "\(s) 至 \(e) · 共 \(report.daysCount) 天 · 日均 \(MoneyText.format(minorUnits: report.dailyAverage, currency: report.currency))")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }
            .padding(18)
            .background(Color(uiColor: .secondarySystemGroupedBackground))

            // Receipt Jagged Divider
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 0.8)

            // Category Breakdown Section
            if !report.categoryBreakdown.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("分类构成")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)

                    ForEach(Array(report.categoryBreakdown.prefix(5))) { cat in
                        HStack {
                            Text(cat.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(LedgerPalette.ink)
                            Spacer()
                            Text(String(format: "%.1f%%", cat.percentage * 100))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(LedgerPalette.secondary)
                            Text(MoneyText.format(minorUnits: cat.amount, currency: report.currency))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(LedgerPalette.ink)
                        }
                    }
                }
                .padding(18)
                .background(Color(uiColor: .secondarySystemGroupedBackground))

                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(height: 0.8)
            }

            // Key Transactions Preview
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("精选流水")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                    Spacer()
                    Text("共 \(report.transactions.count) 笔")
                        .font(.system(size: 11))
                        .foregroundStyle(LedgerPalette.secondary)
                }

                ForEach(Array(report.transactions.prefix(6))) { tx in
                    let p = TransactionPresentation(transaction: tx)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(LedgerPalette.ink)
                                .lineLimit(1)
                            Text(tx.date)
                                .font(.system(size: 10))
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                        Spacer()
                        AmountLabel(
                            minorUnits: p.minorUnits,
                            currency: p.currency,
                            prefix: amountPrefix(p.kind),
                            font: .system(size: 13, weight: .semibold, design: .rounded),
                            color: amountColor(p.kind)
                        )
                    }
                }
            }
            .padding(18)
            .background(Color(uiColor: .secondarySystemGroupedBackground))

            // Footer
            VStack(spacing: 4) {
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(height: 0.8)
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 10))
                        Text("Beancount Ledger Web")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(LedgerPalette.secondary)
                    Spacer()
                    Text(Date().formatted(.dateTime.year().month().day()))
                        .font(.system(size: 10))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LedgerPalette.cardBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 10, x: 0, y: 4)
    }
}
