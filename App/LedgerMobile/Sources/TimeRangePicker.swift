import SwiftUI

struct LedgerTimeRangeButton: View {
    @EnvironmentObject private var session: LedgerSession

    var body: some View {
        Button {
            session.presentRangePicker()
        } label: {
            HStack(spacing: 4) {
                if session.isRangeLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "calendar")
                }
                Text(session.selectedRange.toolbarTitle())
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.medium))
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("周期", selection: Binding(
                        get: { session.draftRange.preset },
                        set: { preset in
                            if preset == .custom { session.updateDraftStart(session.draftRange.startDate) }
                            else { session.selectDraftPreset(preset) }
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
                            session.moveDraftRange(by: -1)
                        } label: {
                            Label("上一周期", systemImage: "chevron.left")
                        }
                        Spacer()
                        Button {
                            session.moveDraftRange(by: 1)
                        } label: {
                            Label("下一周期", systemImage: "chevron.right")
                        }
                    }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .disabled(session.draftRange.preset == .custom)
                }
                Section("日期") {
                    DatePicker("开始日期", selection: startBinding, displayedComponents: .date)
                    DatePicker("结束日期", selection: endBinding, displayedComponents: .date)
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
}
