import SwiftUI
import UIKit

/// 设置 › 提醒: 记账提醒 and 导入账单提醒, for a local ledger.
struct LedgerRemindersSettingsView: View {
    @ObservedObject private var reminders = LedgerLocalReminders.shared
    @Environment(\.openURL) private var openURL

    private var settings: LedgerReminderSettings { reminders.settings }

    var body: some View {
        List {
            if reminders.permission == .denied {
                Section {
                    Button {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("通知已关闭").balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.expense)
                                Text("去系统设置打开，提醒才会出现。").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.forward.app")
                                .foregroundStyle(BalancedPalette.edge)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reminders-open-system-settings")
                    .listRowBackground(BalancedPalette.page)
                }
            }
            bookkeepingSection
            importSection
        }
        .terminalNativeChrome()
        .navigationTitle("提醒")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reminders.refreshPermission() }
    }

    // MARK: 记账提醒

    private var bookkeepingSection: some View {
        Section {
            Toggle(isOn: binding(\.bookkeeping.isEnabled)) {
                Text("记账提醒").balancedFont(size: 15, weight: .text)
            }
            .accessibilityIdentifier("reminders-bookkeeping-toggle")
            .listRowBackground(BalancedPalette.page)
            if settings.bookkeeping.isEnabled {
                DatePicker(selection: timeBinding(\.bookkeeping.time), displayedComponents: .hourAndMinute) {
                    Text("时间").balancedFont(size: 15, weight: .text)
                }
                .accessibilityIdentifier("reminders-bookkeeping-time")
                .listRowBackground(BalancedPalette.page)
                Picker(selection: repeatChoice) {
                    Text("每天").tag(RepeatChoice.daily)
                    Text("工作日").tag(RepeatChoice.weekdays)
                    Text("自定义").tag(RepeatChoice.custom)
                } label: {
                    Text("重复").balancedFont(size: 15, weight: .text)
                }
                .accessibilityIdentifier("reminders-bookkeeping-repeat")
                .listRowBackground(BalancedPalette.page)
                if case let .custom(days) = settings.bookkeeping.repeats {
                    weekdayChips(selected: days)
                        .listRowBackground(BalancedPalette.page)
                }
                Toggle(isOn: binding(\.bookkeeping.skipsRecordedDays)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("智能跳过").balancedFont(size: 15, weight: .text)
                        Text("今天已经有记录（记的或导入的）就不再提醒").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    }
                }
                .accessibilityIdentifier("reminders-bookkeeping-skip")
                .listRowBackground(BalancedPalette.page)
            }
        } header: {
            TerminalSectionLabel(text: String(localized: "记账"))
                .listRowBackground(BalancedPalette.page)
        } footer: {
            Text(settings.bookkeeping.isEnabled && settings.bookkeeping.repeats.days.isEmpty
                 ? "至少选一天，提醒才会出现。"
                 : "到点提醒「今天的账记了吗？」，可以直接点「记一笔」或「一句话记账」。")
                .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                .listRowBackground(BalancedPalette.page)
        }
    }

    private enum RepeatChoice: Hashable { case daily, weekdays, custom }

    private var repeatChoice: Binding<RepeatChoice> {
        Binding {
            switch settings.bookkeeping.repeats {
            case .daily: .daily
            case .weekdays: .weekdays
            case .custom: .custom
            }
        } set: { choice in
            reminders.update { settings in
                switch choice {
                case .daily: settings.bookkeeping.repeats = .daily
                case .weekdays: settings.bookkeeping.repeats = .weekdays
                case .custom:
                    guard case .custom = settings.bookkeeping.repeats else {
                        settings.bookkeeping.repeats = .custom(settings.bookkeeping.repeats.days)
                        return
                    }
                }
            }
        }
    }

    /// Monday first, as the week reads in Chinese.
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    private static func weekdayName(_ weekday: Int) -> String {
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

    private func weekdayChips(selected: Set<Int>) -> some View {
        HStack(spacing: 6) {
            ForEach(Self.weekdayOrder, id: \.self) { weekday in
                let isOn = selected.contains(weekday)
                Button {
                    reminders.update { settings in
                        var days = settings.bookkeeping.repeats.days
                        if isOn { days.remove(weekday) } else { days.insert(weekday) }
                        settings.bookkeeping.repeats = .custom(days)
                    }
                } label: {
                    Text(Self.weekdayName(weekday))
                        .balancedFont(size: 13, weight: isOn ? .medium : .text)
                        .foregroundStyle(isOn ? BalancedPalette.page : BalancedPalette.ink)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(isOn ? BalancedPalette.ink : Color.clear, in: Capsule())
                        .overlay(Capsule().stroke(BalancedPalette.rule, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("reminders-bookkeeping-weekdays")
    }

    // MARK: 导入账单提醒

    private var importSection: some View {
        Section {
            Toggle(isOn: binding(\.imports.isEnabled)) {
                Text("导入账单提醒").balancedFont(size: 15, weight: .text)
            }
            .accessibilityIdentifier("reminders-import-toggle")
            .listRowBackground(BalancedPalette.page)
            if settings.imports.isEnabled {
                Picker(selection: importCadenceKind) {
                    Text("每周").tag(false)
                    Text("每月").tag(true)
                } label: {
                    Text("频率").balancedFont(size: 15, weight: .text)
                }
                .accessibilityIdentifier("reminders-import-cadence")
                .listRowBackground(BalancedPalette.page)
                switch settings.imports.cadence {
                case let .weekly(weekday):
                    Picker(selection: Binding(get: { weekday }, set: { value in
                        reminders.update { $0.imports.cadence = .weekly(weekday: value) }
                    })) {
                        ForEach(Self.weekdayOrder, id: \.self) { Text(Self.weekdayName($0)).tag($0) }
                    } label: {
                        Text("星期").balancedFont(size: 15, weight: .text)
                    }
                    .accessibilityIdentifier("reminders-import-weekday")
                    .listRowBackground(BalancedPalette.page)
                case let .monthly(day):
                    Picker(selection: Binding(get: { Self.dayTag(day) }, set: { value in
                        reminders.update { $0.imports.cadence = .monthly(value == 0 ? .last : .day(value)) }
                    })) {
                        ForEach(1...28, id: \.self) { Text("\($0) 号").tag($0) }
                        Text("月末").tag(0)
                    } label: {
                        Text("日期").balancedFont(size: 15, weight: .text)
                    }
                    .accessibilityIdentifier("reminders-import-day")
                    .listRowBackground(BalancedPalette.page)
                }
                DatePicker(selection: timeBinding(\.imports.time), displayedComponents: .hourAndMinute) {
                    Text("时间").balancedFont(size: 15, weight: .text)
                }
                .accessibilityIdentifier("reminders-import-time")
                .listRowBackground(BalancedPalette.page)
            }
        } header: {
            TerminalSectionLabel(text: String(localized: "导入账单"))
                .listRowBackground(BalancedPalette.page)
        } footer: {
            Text("到点提醒把微信 / 支付宝账单导进来，点「导入账单」直接打开导入页。")
                .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                .listRowBackground(BalancedPalette.page)
        }
    }

    private static func dayTag(_ day: LedgerReminderMonthDay) -> Int {
        switch day {
        case let .day(value): value
        case .last: 0
        }
    }

    /// false for weekly, true for monthly.
    private var importCadenceKind: Binding<Bool> {
        Binding {
            if case .monthly = settings.imports.cadence { return true }
            return false
        } set: { monthly in
            reminders.update { settings in
                switch (settings.imports.cadence, monthly) {
                case (.weekly, true): settings.imports.cadence = .monthly(.day(1))
                case (.monthly, false): settings.imports.cadence = .weekly(weekday: 1)
                default: break
                }
            }
        }
    }

    // MARK: Bindings

    private func binding(_ keyPath: WritableKeyPath<LedgerReminderSettings, Bool>) -> Binding<Bool> {
        Binding {
            reminders.settings[keyPath: keyPath]
        } set: { value in
            reminders.update { $0[keyPath: keyPath] = value }
        }
    }

    private func timeBinding(_ keyPath: WritableKeyPath<LedgerReminderSettings, LedgerReminderTime>) -> Binding<Date> {
        Binding {
            let time = reminders.settings[keyPath: keyPath]
            return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            reminders.update { $0[keyPath: keyPath] = LedgerReminderTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0) }
        }
    }
}

extension LedgerReminderSettings {
    /// The 设置 row's value: the time when on, else 未开启.
    var bookkeepingSummary: String {
        bookkeeping.isEnabled ? bookkeeping.time.text : String(localized: "未开启")
    }

    var importSummary: String {
        guard imports.isEnabled else { return String(localized: "未开启") }
        switch imports.cadence {
        case .weekly: return String(localized: "每周 \(imports.time.text)")
        case .monthly: return String(localized: "每月 \(imports.time.text)")
        }
    }
}
