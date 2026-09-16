import SwiftUI

struct LedgerTimeRangeButton: View {
    @EnvironmentObject private var session: LedgerSession

    var body: some View {
        Button {
            LedgerFeedback.selection()
            session.presentRangePicker()
        } label: {
            HStack(spacing: 5) {
                if session.isRangeLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "calendar")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(session.selectedRange.toolbarTitle())
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(session.isRangeLoading || session.isValuationCurrencyLoading)
        .accessibilityLabel("选择时间范围，当前为\(session.selectedRange.displayTitle)")
        .accessibilityValue("\(session.selectedRange.start) 至 \(session.selectedRange.end)")
        .accessibilityIdentifier("navigation-time-range")
    }
}

private struct LedgerTimeRangeSheetPresenter: ViewModifier {
    @EnvironmentObject private var session: LedgerSession

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { session.rangePickerPresented },
            set: { presented in
                if presented { session.presentRangePicker() }
                else { session.dismissRangePicker() }
            }
        )
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: sheetBinding) {
            LedgerTimeRangeSheet()
                .ledgerPrivacyProtectedSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

extension View {
    func ledgerTimeRangeSheet() -> some View {
        modifier(LedgerTimeRangeSheetPresenter())
    }
}

private struct LedgerTimeRangeSheet: View {
    @EnvironmentObject private var session: LedgerSession

    private var startBinding: Binding<Date> {
        Binding(get: { session.draftRange.startDate }, set: session.updateDraftStart)
    }

    private var endBinding: Binding<Date> {
        Binding(get: { session.draftRange.endDate }, set: session.updateDraftEnd)
    }

    private var startComponents: DateComponents {
        LedgerDateRange.calendar.dateComponents([.year, .month], from: session.draftRange.startDate)
    }

    private var selectedYear: Int {
        startComponents.year ?? LedgerDateRange.calendar.component(.year, from: Date())
    }

    private var selectedMonth: Int {
        startComponents.month ?? 1
    }

    private var selectedQuarter: Int {
        ((selectedMonth - 1) / 3) + 1
    }

    private var customDaysCount: Int {
        let days = LedgerDateRange.calendar.dateComponents(
            [.day],
            from: session.draftRange.startDate,
            to: session.draftRange.endDate
        ).day ?? 0
        return max(1, days + 1)
    }

    var body: some View {
        NavigationStack {
            Form {
                // 1. Preset Selector & Status
                Section {
                    Picker("周期", selection: Binding(
                        get: { session.draftRange.preset },
                        set: { preset in
                            LedgerFeedback.selection()
                            if preset == .custom {
                                session.updateDraftStart(session.draftRange.startDate)
                            } else {
                                session.selectDraftPreset(preset)
                            }
                        }
                    )) {
                        Text("本月").tag(LedgerDateRangePreset.month)
                        Text("本季度").tag(LedgerDateRangePreset.quarter)
                        Text("今年").tag(LedgerDateRangePreset.year)
                        Text("自定义").tag(LedgerDateRangePreset.custom)
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("当前选择", value: session.draftRange.displayTitle)

                    HStack {
                        Button {
                            LedgerFeedback.light()
                            session.moveDraftRange(by: -1)
                        } label: {
                            Label("上一周期", systemImage: "chevron.left")
                        }
                        Spacer()
                        Button {
                            LedgerFeedback.light()
                            session.moveDraftRange(by: 1)
                        } label: {
                            Label("下一周期", systemImage: "chevron.right")
                        }
                    }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .disabled(session.draftRange.preset == .custom)
                }

                // 2. Interactive Picker Panel (Month Grid / Quarter Cards / Year Pills / Custom Presets)
                switch session.draftRange.preset {
                case .month:
                    monthGridSection
                case .quarter:
                    quarterCardsSection
                case .year:
                    yearPillsSection
                case .custom:
                    customPresetsSection
                }

                // 3. Fine-tuning Custom Dates
                if session.draftRange.preset == .custom {
                    Section("具体起止日期") {
                        DatePicker("开始日期", selection: startBinding, displayedComponents: .date)
                        DatePicker("结束日期", selection: endBinding, displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("时间范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { session.dismissRangePicker() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { Task { await session.applyDraftRange() } }
                        .accessibilityIdentifier("apply-time-range")
                }
            }
        }
    }

    // MARK: - Month Grid View
    private var monthGridSection: some View {
        Section {
            VStack(spacing: 12) {
                // Year Navigator
                HStack {
                    Button {
                        LedgerFeedback.light()
                        shiftMonthYear(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(Color(uiColor: .tertiarySystemFill))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text(verbatim: "\(selectedYear)年")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(LedgerPalette.ink)

                    Spacer()

                    Button {
                        LedgerFeedback.light()
                        shiftMonthYear(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(Color(uiColor: .tertiarySystemFill))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)

                // 12-Month Squircle Grid
                let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(1...12, id: \.self) { month in
                        let isSelected = selectedMonth == month
                        Button {
                            LedgerFeedback.selection()
                            session.setDraftRange(LedgerDateRange.month(year: selectedYear, month: month))
                        } label: {
                            Text("\(month)月")
                                .font(.system(size: 13.5, weight: isSelected ? .bold : .medium, design: .rounded))
                                .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : Color.primary)
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .background(isSelected ? Color.primary : Color(uiColor: .tertiarySystemFill))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.94, enablesHaptic: false))
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("月份快捷直选")
        }
    }

    // MARK: - Quarter Cards View
    private var quarterCardsSection: some View {
        Section {
            VStack(spacing: 12) {
                // Year Navigator
                HStack {
                    Button {
                        LedgerFeedback.light()
                        shiftQuarterYear(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(Color(uiColor: .tertiarySystemFill))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text(verbatim: "\(selectedYear)年")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(LedgerPalette.ink)

                    Spacer()

                    Button {
                        LedgerFeedback.light()
                        shiftQuarterYear(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(Color(uiColor: .tertiarySystemFill))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)

                // 4-Quarter Grid
                let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(1...4, id: \.self) { q in
                        let isSelected = selectedQuarter == q
                        Button {
                            LedgerFeedback.selection()
                            session.setDraftRange(LedgerDateRange.quarter(year: selectedYear, quarter: q))
                        } label: {
                            VStack(spacing: 3) {
                                Text("第\(q)季度")
                                    .font(.system(size: 14.5, weight: isSelected ? .bold : .medium, design: .rounded))
                                Text(quarterMonthsLabel(q))
                                    .font(.system(size: 11, weight: .regular))
                                    .opacity(0.8)
                            }
                            .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(isSelected ? Color.primary : Color(uiColor: .tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.94, enablesHaptic: false))
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("季度快捷直选")
        }
    }

    // MARK: - Year Pills View
    private var yearPillsSection: some View {
        Section {
            let currentCalYear = LedgerDateRange.calendar.component(.year, from: Date())
            let years = ((currentCalYear - 4)...(currentCalYear + 1)).map { $0 }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(years, id: \.self) { y in
                    let isSelected = selectedYear == y
                    Button {
                        LedgerFeedback.selection()
                        session.setDraftRange(LedgerDateRange.year(year: y))
                    } label: {
                        Text(verbatim: "\(y)年")
                            .font(.system(size: 14, weight: isSelected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(isSelected ? Color.primary : Color(uiColor: .tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(PressScaleButtonStyle(pressedScale: 0.94, enablesHaptic: false))
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("年份快捷直选")
        }
    }

    // MARK: - Custom Presets View
    private var customPresetsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    customPresetChip(title: "近 7 天", days: 7)
                    customPresetChip(title: "近 30 天", days: 30)
                    customPresetChip(title: "近 90 天", days: 90)
                    Button {
                        applyYearToDate()
                    } label: {
                        Text("今年至今")
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color(uiColor: .tertiarySystemFill))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerPalette.secondary)
                    Text("当前跨度：共 \(customDaysCount) 天")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
        } header: {
            Text("快捷范围预设")
        }
    }

    private func customPresetChip(title: String, days: Int) -> some View {
        Button {
            applyCustomPreset(days: days)
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(uiColor: .tertiarySystemFill))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func quarterMonthsLabel(_ quarter: Int) -> String {
        switch quarter {
        case 1: "1月 – 3月"
        case 2: "4月 – 6月"
        case 3: "7月 – 9月"
        case 4: "10月 – 12月"
        default: ""
        }
    }

    private func shiftMonthYear(by delta: Int) {
        let newYear = selectedYear + delta
        session.setDraftRange(LedgerDateRange.month(year: newYear, month: selectedMonth))
    }

    private func shiftQuarterYear(by delta: Int) {
        let newYear = selectedYear + delta
        session.setDraftRange(LedgerDateRange.quarter(year: newYear, quarter: selectedQuarter))
    }

    private func applyCustomPreset(days: Int) {
        let now = Date()
        let cal = LedgerDateRange.calendar
        let start = cal.date(byAdding: .day, value: -(days - 1), to: now) ?? now
        session.setDraftRange(LedgerDateRange.custom(start: start, end: now))
        LedgerFeedback.selection()
    }

    private func applyYearToDate() {
        let now = Date()
        let cal = LedgerDateRange.calendar
        let year = cal.component(.year, from: now)
        let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
        session.setDraftRange(LedgerDateRange.custom(start: start, end: now))
        LedgerFeedback.selection()
    }
}
