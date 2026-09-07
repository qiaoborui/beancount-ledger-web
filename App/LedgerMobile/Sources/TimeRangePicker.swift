import SwiftUI

struct LedgerTimeRangeControl: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            stepButton(direction: -1, systemImage: "chevron.left", label: "上一周期")
            Button {
                session.presentRangePicker()
            } label: {
                VStack(spacing: 3) {
                    Label(session.selectedRange.displayTitle, systemImage: "calendar")
                        .font(.subheadline.weight(.semibold))
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text("\(session.selectedRange.start) 至 \(session.selectedRange.end)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(session.isRangeLoading)
            .accessibilityLabel("选择时间范围，当前为\(session.selectedRange.displayTitle)")
            .accessibilityValue("\(session.selectedRange.start) 至 \(session.selectedRange.end)")
            .overlay(alignment: .trailing) {
                if session.isRangeLoading { ProgressView().controlSize(.small) }
            }
            stepButton(direction: 1, systemImage: "chevron.right", label: "下一周期")
        }
        .accessibilityIdentifier("page-time-range")
    }

    private func stepButton(direction: Int, systemImage: String, label: String) -> some View {
        Button {
            Task { await session.moveRange(by: direction) }
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(session.isRangeLoading || session.selectedRange.preset == .custom)
        .accessibilityLabel(label)
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
