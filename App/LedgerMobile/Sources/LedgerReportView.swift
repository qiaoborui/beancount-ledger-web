import Charts
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// 周报 / 月报. The page computes its period from the on-device ledger every
// time it opens, through the same repository reads as 收支分析, so a report
// always includes what was just imported. Periods, comparisons and the receipt
// contents come from the pure functions in `LedgerReport.swift`.

struct LedgerReportView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var initialTarget: LedgerReportRouteTarget? = nil
    var isRoot = false
    /// Set when the page is a sheet over the current tab.
    var onClose: (() -> Void)? = nil

    @State private var settings = LedgerReportSettings.load()
    @State private var period: LedgerReportPeriod?
    @State private var data: LedgerReportData?
    @State private var loadedKey: ReportLoadKey?
    @State private var errorMessage: String?
    @State private var customPresented = false
    @State private var settingsPresented = false
    @State private var exportPresented = false
    @State private var offerWeekly = false

    private var reportCalendar: LedgerReportCalendar { settings.reportCalendar() }

    private var currentPeriod: LedgerReportPeriod {
        period ?? reportCalendar.lastCompleted(.week, at: Date())
    }

    private var key: ReportLoadKey {
        ReportLoadKey(period: currentPeriod, firstWeekday: settings.firstWeekday,
            revision: session.localTransactionPresentationRevision,
            currency: session.ledger?.valuationCurrency ?? "CNY",
            available: session.phase == .ready && !session.privacyShielded)
    }

    var body: some View {
        content
            .background(BalancedPalette.page)
            .terminalPageChrome(String(localized: "周报 / 月报"), isRoot: isRoot, showsSync: false, actions: AnyView(actions), balanced: true)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", action: onClose).accessibilityIdentifier("report-close")
                    }
                }
            }
            .task(id: key) { await load() }
            .onAppear {
                if period == nil {
                    period = initialTarget.flatMap { reportCalendar.period(for: $0) }
                        ?? reportCalendar.lastCompleted(.week, at: Date())
                }
                if session.isLocal, !settings.hasOfferedWeekly, !settings.anyEnabled {
                    offerWeekly = true
                }
            }
            .onChange(of: initialTarget) { _, target in
                if let target, let next = reportCalendar.period(for: target) { period = next }
            }
            .sheet(isPresented: $customPresented) {
                LedgerReportCustomRangeSheet(calendar: reportCalendar, period: currentPeriod) { period = $0 }
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $settingsPresented, onDismiss: { settings = LedgerReportSettings.load() }) {
                NavigationStack { LedgerReportSettingsView() }
            }
            .sheet(isPresented: $exportPresented) {
                if let data, loadedKey == key {
                    LedgerReportReceiptSheet(data: data, periodLabel: reportCalendar.label(data.period),
                        sections: settings.visibleSections.filter(\.appearsOnReceipt))
                        .ledgerPrivacyProtectedSheet()
                }
            }
            .alert("每周自动出一份周报？", isPresented: $offerWeekly) {
                Button("开启周报") { updateSettings { $0.weekly.isEnabled = true; $0.hasOfferedWeekly = true } }
                Button("以后再说", role: .cancel) { updateSettings { $0.hasOfferedWeekly = true } }
            } message: {
                Text("每周一 09:00 提醒你看上周的收支，前一天晚上提醒导入账单。可以在报告设置里改时间。")
            }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button { exportPresented = true } label: {
                Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
            }
            .disabled(data == nil || loadedKey != key)
            .accessibilityLabel("导出小票")
            .accessibilityIdentifier("report-export")
            Button { settingsPresented = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }
            .accessibilityLabel("报告设置")
            .accessibilityIdentifier("report-settings")
        }
        .foregroundStyle(BalancedPalette.ink)
    }

    @ViewBuilder
    private var content: some View {
        if !session.isLocal {
            EmptyLedgerState(icon: "doc.text.magnifyingglass", title: String(localized: "仅支持本机账本"),
                detail: String(localized: "周报 / 月报在本机账本上计算，远程账本暂不提供。"))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    periodHeader
                    if let errorMessage {
                        StatusBanner(message: errorMessage) { self.errorMessage = nil }
                    }
                    if session.phase != .ready || session.privacyShielded {
                        ReportPlaceholder(text: String(localized: "解锁账本后查看报告"))
                    } else if let data, loadedKey == key {
                        ForEach(settings.visibleSections) { section in
                            sectionView(section, data: data)
                        }
                        if data.isTruncated {
                            Text("本期交易较多，最大几笔和记账情况只统计了前 10,000 笔。")
                                .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                        }
                    } else if errorMessage == nil {
                        ProgressView().tint(BalancedPalette.ink).frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
                .padding(.horizontal, horizontalSizeClass == .regular ? 0 : 20)
                .padding(.bottom, 24)
                .ledgerAdaptivePageWidth()
            }
            .refreshable { await load(force: true) }
            .accessibilityIdentifier("report-content")
        }
    }

    // MARK: Header

    private var periodHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(LedgerReportPeriodKind.allCases) { kind in
                    Button { select(kind) } label: {
                        BalancedMark(title: kind.title, selected: currentPeriod.kind == kind)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("report-kind-\(kind.rawValue)")
                }
            }
            .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }

            HStack {
                Button { period = reportCalendar.shifted(currentPeriod, by: -1) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }
                .accessibilityLabel("上一期")
                .accessibilityIdentifier("report-previous")
                Spacer()
                Button {
                    if currentPeriod.kind == .custom { customPresented = true }
                } label: {
                    Text(reportCalendar.label(currentPeriod))
                        .balancedFont(size: 15, weight: .medium)
                        .foregroundStyle(BalancedPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("report-period-label")
                Spacer()
                Button { period = reportCalendar.shifted(currentPeriod, by: 1) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44)
                }
                .disabled(!canAdvance)
                .accessibilityLabel("下一期")
                .accessibilityIdentifier("report-next")
            }
            .foregroundStyle(BalancedPalette.ink)
        }
    }

    /// No period that starts after today.
    private var canAdvance: Bool {
        reportCalendar.shifted(currentPeriod, by: 1).start <= reportCalendar.text(Date())
    }

    private func select(_ kind: LedgerReportPeriodKind) {
        guard kind != currentPeriod.kind || kind == .custom else { return }
        switch kind {
        case .week, .month:
            period = reportCalendar.lastCompleted(kind, at: Date())
        case .custom:
            if currentPeriod.kind != .custom,
               let custom = reportCalendar.custom(currentPeriod.start, currentPeriod.end) {
                period = custom
            }
            customPresented = true
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func sectionView(_ section: LedgerReportSection, data: LedgerReportData) -> some View {
        switch section {
        case .overview:
            ReportSection(title: section.title) { ReportOverview(data: data) }
        case .categories:
            ReportSection(title: section.title) { ReportCategories(data: data) }
        case .daily:
            ReportSection(title: section.title) { ReportDailyChart(data: data, calendar: reportCalendar) }
        case .largest:
            ReportSection(title: section.title) { ReportLargest(data: data, calendar: reportCalendar) }
        case .coverage:
            ReportSection(title: section.title) {
                ReportCoverageView(coverage: data.coverage, onRecord: openRecord, onImport: openImports)
            }
        case .assistant:
            if session.agentFloatsInTabBar {
                Button(action: askAssistant) {
                    Label("问账本助手：总结这一期", systemImage: "sparkles")
                }
                .buttonStyle(.balanced(.outline))
                .accessibilityIdentifier("report-ask-agent")
            }
        }
    }

    // MARK: Actions

    /// A sheet over this one would be dropped while this one is still going
    /// away, so a report shown as a sheet closes first.
    private func afterClosing(_ action: @escaping @MainActor () -> Void) {
        guard let onClose else { action(); return }
        onClose()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            action()
        }
    }

    private func openRecord() {
        afterClosing { session.quickEntry = LedgerQuickEntryRequest(kind: .record) }
    }

    private func openImports() {
        afterClosing { session.openWidgetURL(URL(string: "ledger://imports")!) }
    }

    private func askAssistant() {
        let question = String(localized: "帮我总结一下 \(reportCalendar.label(currentPeriod)) 的收支，有什么值得注意的")
        var components = URLComponents()
        components.scheme = "ledger"
        components.host = "agent"
        components.queryItems = [URLQueryItem(name: "q", value: question)]
        guard let url = components.url else { return }
        afterClosing { session.openWidgetURL(url) }
    }

    private func updateSettings(_ change: (inout LedgerReportSettings) -> Void) {
        var next = LedgerReportSettings.load()
        change(&next)
        next.save()
        settings = next
        LedgerReportReminders.settingsChanged()
    }

    // MARK: Loading

    private func load(force: Bool = false) async {
        let key = self.key
        guard key.available, session.isLocal, let repository = session.localRepository,
              let revision = key.revision else { return }
        if !force, loadedKey == key, data != nil { return }
        errorMessage = nil
        do {
            let loaded = try await Self.compute(period: key.period, calendar: reportCalendar, currency: key.currency,
                revision: revision, repository: repository)
            guard !Task.isCancelled, key == self.key else { return }
            data = loaded
            loadedKey = key
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, key == self.key else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// The most transactions read for 最大几笔 and 记账情况.
    static let transactionScanLimit = 10_000

    private static func compute(period: LedgerReportPeriod, calendar: LedgerReportCalendar, currency: String,
                                revision: UUID, repository: LocalLedgerRepository) async throws -> LedgerReportData {
        let previous = calendar.previous(period)
        let end = calendar.endExclusive(period)
        let statement = try await repository.incomeStatement(start: period.start, end: end, valuationCurrency: currency)
        try Task.checkCancellation()
        let prior = try await repository.incomeStatement(start: previous.start, end: calendar.endExclusive(previous),
            valuationCurrency: currency)
        try Task.checkCancellation()
        let home = try await repository.homeReport(start: period.start, end: end, valuationCurrency: currency)
        try Task.checkCancellation()

        // Raw candidates: this read never moves the revision that authorizes writes.
        var rows: [LedgerTransaction] = []
        var cursor: String?
        var truncated = false
        repeat {
            let page = try await repository.candidatePage(start: period.start, end: end, cursor: cursor,
                limit: 500, expectedRevisionID: revision)
            try Task.checkCancellation()
            rows += page.transactions
            cursor = page.nextCursor
            if rows.count >= transactionScanLimit, cursor != nil {
                truncated = true
                break
            }
        } while cursor != nil

        let categoryItems: [(label: String, amount: Int)] = statement.expenseAnalytics.isEmpty
            ? statement.expense.map { (label: $0.label, amount: $0.amount) }
            : statement.expenseAnalytics.map { (label: $0.label, amount: $0.amount) }
        var daily: [String: (amount: Int, count: Int)] = [:]
        for point in home.dailyExpenseSeries { daily[point.date] = (amount: point.amount, count: point.txCount) }
        return LedgerReportData(
            period: period, previousPeriod: previous, currency: statement.valuationCurrency,
            income: abs(statement.totalIncome), expense: abs(statement.totalExpense),
            previousIncome: abs(prior.totalIncome), previousExpense: abs(prior.totalExpense),
            categories: LedgerReportMath.ranking(categoryItems),
            buckets: LedgerReportMath.buckets(period, daily: daily, calendar: calendar),
            largest: LedgerReportMath.largestExpenses(rows, currency: statement.valuationCurrency),
            coverage: LedgerReportMath.coverage(period, recordedDays: Set(rows.map(\.date)),
                today: calendar.text(Date()), calendar: calendar),
            isTruncated: truncated)
    }
}

private struct ReportLoadKey: Hashable {
    let period: LedgerReportPeriod
    let firstWeekday: Int
    let revision: UUID?
    let currency: String
    let available: Bool
}

// MARK: - Section views

private struct ReportSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TerminalSectionLabel(text: title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .balancedBand()
    }
}

private struct ReportPlaceholder: View {
    let text: String
    var body: some View {
        Text(text)
            .balancedFont(size: 14)
            .foregroundStyle(BalancedPalette.meta)
            .frame(maxWidth: .infinity, minHeight: 120)
    }
}

/// 「↓12%」 against the previous period. For spending, less is good.
private struct ReportChangeText: View {
    let ratio: Double?
    var lowerIsBetter = false

    var body: some View {
        if let ratio {
            let arrow = ratio > 0 ? "↑" : ratio < 0 ? "↓" : "→"
            let good = lowerIsBetter ? ratio < 0 : ratio > 0
            Text(verbatim: "\(arrow)\(Int((abs(ratio) * 100).rounded()))%")
                .balancedFont(size: 12, weight: .medium)
                .foregroundStyle(ratio == 0 ? BalancedPalette.meta : good ? BalancedPalette.income : BalancedPalette.expense)
        } else {
            Text(verbatim: "—").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
        }
    }
}

private struct ReportOverview: View {
    @EnvironmentObject private var session: LedgerSession
    let data: LedgerReportData

    var body: some View {
        VStack(spacing: 10) {
            row(String(localized: "支出"), data.expense, color: BalancedPalette.expense, change: data.expenseChange, lowerIsBetter: true)
            row(String(localized: "收入"), data.income, color: BalancedPalette.income, change: data.incomeChange, lowerIsBetter: false)
            row(String(localized: "结余"), data.net, color: BalancedPalette.ink, change: data.netChange, lowerIsBetter: false,
                prefix: data.net < 0 ? "−" : "")
            Text("对比 \(LedgerReportCalendar().label(data.previousPeriod))")
                .balancedFont(size: 11.5)
                .foregroundStyle(BalancedPalette.meta)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ title: String, _ value: Int, color: Color, change: Double?, lowerIsBetter: Bool,
                     prefix: String = "") -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
            Spacer()
            BalancedKeyTotalText.value(minorUnits: value, currency: data.currency, prefix: prefix, color: color,
                amountsVisible: session.amountsVisible, size: 17, currencyScale: 0.78)
            ReportChangeText(ratio: change, lowerIsBetter: lowerIsBetter).frame(minWidth: 48, alignment: .trailing)
        }
    }
}

private struct ReportShareBar: View {
    let share: Double
    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(BalancedPalette.rule)
            Rectangle().fill(BalancedPalette.ink)
                .scaleEffect(x: max(min(share, 1), 0), y: 1, anchor: .leading)
        }
        .frame(height: 4)
    }
}

private struct ReportCategories: View {
    @EnvironmentObject private var session: LedgerSession
    let data: LedgerReportData

    var body: some View {
        if data.categories.isEmpty {
            Text("本期没有支出").balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
        } else {
            VStack(spacing: 10) {
                ForEach(data.categories) { slice in
                    VStack(spacing: 4) {
                        HStack {
                            Text(slice.label).balancedFont(size: 13).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                            Spacer()
                            Text(verbatim: "\(Int((slice.share * 100).rounded()))%")
                                .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                            BalancedKeyTotalText.value(minorUnits: slice.amount, currency: data.currency, color: BalancedPalette.ink,
                                amountsVisible: session.amountsVisible, size: 13, currencyScale: 0.78)
                        }
                        ReportShareBar(share: slice.share)
                    }
                }
            }
        }
    }
}

private struct ReportDailyChart: View {
    @EnvironmentObject private var session: LedgerSession
    let data: LedgerReportData
    let calendar: LedgerReportCalendar

    var body: some View {
        // Long custom ranges come back one bucket per week.
        let unit: Calendar.Component = data.buckets.count < calendar.dayCount(data.period) ? .weekOfYear : .day
        Chart(data.buckets) { bucket in
            BarMark(
                x: .value("日期", calendar.day(bucket.start) ?? Date(), unit: unit),
                y: .value("支出", Double(bucket.amount) / 100)
            )
            .foregroundStyle(BalancedPalette.expense)
        }
        .chartYAxis(session.amountsVisible ? .automatic : .hidden)
        .frame(height: 160)
        .accessibilityLabel("每日支出柱状图")
    }
}

private struct ReportLargest: View {
    @EnvironmentObject private var session: LedgerSession
    let data: LedgerReportData
    let calendar: LedgerReportCalendar

    var body: some View {
        if data.largest.isEmpty {
            Text("本期没有\(data.currency)支出").balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
        } else {
            VStack(spacing: 0) {
                ForEach(data.largest) { item in
                    NavigationLink { TransactionDetailView(transaction: item.transaction) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).balancedFont(size: 14).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                                Text(item.date).balancedFont(size: 11.5).foregroundStyle(BalancedPalette.meta)
                            }
                            Spacer()
                            BalancedKeyTotalText.value(minorUnits: item.minorUnits, currency: data.currency,
                                color: BalancedPalette.expense, amountsVisible: session.amountsVisible, size: 14, currencyScale: 0.78)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(BalancedPalette.edge)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .navigationLinkIndicatorVisibility(.hidden)
                }
            }
        }
    }
}

private struct ReportCoverageView: View {
    let coverage: LedgerReportCoverage
    let onRecord: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(coverage.elapsedDays) 天里有 \(coverage.recordedDays) 天有记录，\(coverage.blankDays.count) 天空白")
                .balancedFont(size: 14).foregroundStyle(BalancedPalette.ink)
            if !coverage.blankDays.isEmpty {
                Text(coverage.blankDays.prefix(10).map { String($0.suffix(5)) }.joined(separator: "  ")
                     + (coverage.blankDays.count > 10 ? " …" : ""))
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                HStack(spacing: 10) {
                    Button("去补记", action: onRecord).buttonStyle(.balanced(.outline))
                        .accessibilityIdentifier("report-record")
                    Button("导入账单", action: onImport).buttonStyle(.balanced(.primary))
                        .accessibilityIdentifier("report-import")
                }
            }
        }
    }
}

// MARK: - Custom range

private struct LedgerReportCustomRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let calendar: LedgerReportCalendar
    let onApply: (LedgerReportPeriod) -> Void

    @State private var start: Date
    @State private var end: Date

    init(calendar: LedgerReportCalendar, period: LedgerReportPeriod, onApply: @escaping (LedgerReportPeriod) -> Void) {
        self.calendar = calendar
        self.onApply = onApply
        _start = State(initialValue: calendar.day(period.start) ?? Date())
        _end = State(initialValue: calendar.day(period.end) ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("开始", selection: $start, in: ...Date(), displayedComponents: .date)
                DatePicker("结束", selection: $end, in: start...max(start, Date()), displayedComponents: .date)
            }
            .navigationTitle("自定义报告")
            .terminalNativeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if let period = calendar.custom(calendar.text(start), calendar.text(end)) { onApply(period) }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Settings

struct LedgerReportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// False when pushed from 设置, where the back button closes it.
    var showsDone = true
    @State private var settings = LedgerReportSettings.load()

    private static let weekdays = [2, 3, 4, 5, 6, 7, 1]

    private func weekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: String(localized: "周日")
        case 2: String(localized: "周一")
        case 3: String(localized: "周二")
        case 4: String(localized: "周三")
        case 5: String(localized: "周四")
        case 6: String(localized: "周五")
        default: String(localized: "周六")
        }
    }

    private func timeBinding(_ keyPath: WritableKeyPath<LedgerReportSettings, LedgerReminderTime>) -> Binding<Date> {
        Binding(
            get: {
                let time = settings[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings[keyPath: keyPath] = LedgerReminderTime(hour: components.hour ?? 9, minute: components.minute ?? 0)
            }
        )
    }

    private var monthDayBinding: Binding<Int> {
        Binding(
            get: {
                switch settings.monthly.day {
                case let .day(day): day
                case .last: 0
                }
            },
            set: { settings.monthly.day = $0 == 0 ? .last : .day($0) }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("周报", isOn: $settings.weekly.isEnabled)
                    .accessibilityIdentifier("report-settings-weekly")
                if settings.weekly.isEnabled {
                    Picker("出报告", selection: $settings.weekly.weekday) {
                        ForEach(Self.weekdays, id: \.self) { Text(weekdayName($0)).tag($0) }
                    }
                    DatePicker("时间", selection: timeBinding(\.weekly.time), displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("报告范围是上一个完整的自然周。")
            }
            Section {
                Toggle("月报", isOn: $settings.monthly.isEnabled)
                    .accessibilityIdentifier("report-settings-monthly")
                if settings.monthly.isEnabled {
                    Picker("出报告", selection: monthDayBinding) {
                        ForEach(1...28, id: \.self) { Text("每月 \($0) 号").tag($0) }
                        Text("月末最后一天").tag(0)
                    }
                    DatePicker("时间", selection: timeBinding(\.monthly.time), displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("报告范围是上一个完整的自然月。")
            }
            Section {
                Toggle("报告前提醒导入账单", isOn: $settings.remindsImportBeforeReport)
                Picker("一周开始于", selection: $settings.firstWeekday) {
                    Text("周一").tag(2)
                    Text("周日").tag(1)
                }
            } footer: {
                Text("在每期报告的前一天 20:00 提醒导入微信 / 支付宝账单，和你单独设置的导入提醒合并，不会同时来两条。通知里不显示金额。")
            }
            Section {
                ForEach($settings.sections) { $preference in
                    Toggle(preference.section.title, isOn: $preference.isVisible)
                }
                .onMove { settings.sections.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("报告板块")
            } footer: {
                Text("点右上角「编辑」可以拖动排序。")
            }
        }
        .navigationTitle("报告设置")
        .terminalNativeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { EditButton() }
            if showsDone {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
        }
        .onChange(of: settings) { _, value in
            var next = value
            next.hasOfferedWeekly = true
            next.save()
            LedgerReportReminders.settingsChanged()
        }
    }
}

// MARK: - Receipt

/// The 热敏小票 image. It prints only what `LedgerReportReceipt` kept.
struct LedgerReportReceiptCard: View {
    let receipt: LedgerReportReceipt

    private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    var body: some View {
        VStack(spacing: 10) {
            Image("LaunchMark")
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
            Text(receipt.title).font(mono(16, .bold))
            Text(receipt.periodLabel).font(mono(12))
            ReceiptDashedRule()
            ForEach(Array(receipt.blocks.enumerated()), id: \.offset) { _, block in
                VStack(alignment: .leading, spacing: 6) {
                    Text(block.section.title).font(mono(12, .bold))
                    ForEach(Array(block.lines.enumerated()), id: \.offset) { _, line in
                        VStack(spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(line.label).font(mono(11.5)).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(line.value).font(mono(11.5, .semibold)).lineLimit(1)
                            }
                            if let bar = line.bar {
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Color.black.opacity(0.08))
                                    Rectangle().fill(Color.black.opacity(0.7))
                                        .scaleEffect(x: max(min(bar, 1), 0), y: 1, anchor: .leading)
                                }
                                .frame(height: 3)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ReceiptDashedRule()
            }
            Text(receipt.footer).font(mono(10.5))
            Text("* * * 谢谢惠顾 * * *").font(mono(10.5))
        }
        .foregroundStyle(Color.black)
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .frame(width: 300)
        .background(Color(red: 0.99, green: 0.98, blue: 0.96))
        .environment(\.colorScheme, .light)
    }
}

private struct ReceiptDashedRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 1)
            .overlay {
                GeometryReader { proxy in
                    Path { path in
                        path.move(to: .zero)
                        path.addLine(to: CGPoint(x: proxy.size.width, y: 0))
                    }
                    .stroke(Color.black.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
    }
}

/// Export options with a live preview. While amounts are hidden or the
/// ledger is locked only the 占比 version can be made, as with other sharing.
struct LedgerReportReceiptSheet: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    let data: LedgerReportData
    let periodLabel: String

    @State private var options: LedgerReportReceiptOptions
    @State private var imageURL: URL?
    @State private var imageDirectory = ShareImageDirectory()

    init(data: LedgerReportData, periodLabel: String, sections: [LedgerReportSection]) {
        self.data = data
        self.periodLabel = periodLabel
        var options = LedgerReportReceiptOptions()
        options.sections = Set(sections)
        _options = State(initialValue: options)
    }

    private var amountsAllowed: Bool {
        session.amountsVisible && session.phase == .ready && !session.privacyShielded
            && (session.ledger?.sensitiveUnlocked ?? false)
    }

    private var receipt: LedgerReportReceipt {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return LedgerReportReceipt.build(data, options: options, periodLabel: periodLabel,
            dayLabel: { String($0.suffix(5)) }, generatedAt: formatter.string(from: Date()),
            amountsAllowed: amountsAllowed)
    }

    private var sharesOnlyBinding: Binding<Bool> {
        Binding(get: { options.sharesOnly || !amountsAllowed }, set: { options.sharesOnly = $0 })
    }

    private func sectionBinding(_ section: LedgerReportSection) -> Binding<Bool> {
        Binding(
            get: { options.sections.contains(section) },
            set: { if $0 { options.sections.insert(section) } else { options.sections.remove(section) } }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LedgerReportReceiptCard(receipt: receipt)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } header: { Text("预览") }
                Section {
                    Toggle("隐藏收入", isOn: $options.hidesIncome)
                    Toggle("隐藏结余", isOn: $options.hidesNet)
                    Toggle("金额改为占比", isOn: sharesOnlyBinding)
                        .disabled(!amountsAllowed)
                        .accessibilityIdentifier("report-receipt-shares-only")
                    Toggle("隐藏交易明细", isOn: $options.hidesDetails)
                } header: {
                    Text("隐私")
                } footer: {
                    if !amountsAllowed {
                        Text("金额已隐藏或账本未解锁，只能导出不含金额的占比版本。显示金额后可导出完整版本。")
                    } else {
                        Text("「金额改为占比」只显示分类百分比，图片里不含任何金额。")
                    }
                }
                Section {
                    ForEach(LedgerReportSection.allCases.filter(\.appearsOnReceipt)) { section in
                        Toggle(section.title, isOn: sectionBinding(section))
                    }
                } header: { Text("包含的板块") }
            }
            .navigationTitle("导出小票")
            .terminalNativeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if let imageURL, session.phase == .ready, !session.privacyShielded {
                        ShareLink(item: imageURL, preview: SharePreview(receipt.title, icon: Image(systemName: "doc.text.image"))) {
                            Text("分享")
                        }
                        .accessibilityIdentifier("report-receipt-share")
                    } else {
                        ProgressView()
                    }
                }
            }
            .task(id: RenderKey(options: options, amountsAllowed: amountsAllowed, ready: session.phase == .ready && !session.privacyShielded)) {
                render()
            }
            // Locking removes the on-disk image, as other sharing does.
            .onChange(of: session.phase) { _, phase in
                if phase != .ready { discard() }
            }
            .onChange(of: session.privacyShielded) { _, shielded in
                if shielded { discard() }
            }
            .onDisappear { discard() }
        }
    }

    private struct RenderKey: Hashable {
        let options: LedgerReportReceiptOptions
        let amountsAllowed: Bool
        let ready: Bool
    }

    private func discard() {
        imageDirectory.discard()
        imageURL = nil
    }

    @MainActor
    private func render() {
        guard session.phase == .ready, !session.privacyShielded else { discard(); return }
        let renderer = ImageRenderer(content: LedgerReportReceiptCard(receipt: receipt))
        renderer.scale = 3.0
        guard let data = renderer.uiImage?.pngData() else { return }
        let kind = self.data.period.kind.rawValue
        let start = self.data.period.start.replacingOccurrences(of: "-", with: "")
        do {
            imageURL = try imageDirectory.write(data, fileName: "Ledger-Report-\(kind)-\(start).png")
        } catch {
            imageURL = nil
        }
    }
}
