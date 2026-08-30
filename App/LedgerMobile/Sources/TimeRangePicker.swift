import SwiftUI

struct LedgerTimeRangeControl: View {
    @EnvironmentObject private var session: LedgerSession

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { session.rangePickerPresented },
            set: { presented in
                if presented {
                    session.presentRangePicker()
                } else {
                    session.dismissRangePicker()
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            stepButton(direction: -1, systemImage: "chevron.left", label: "上一周期")
            verticalDivider

            Button {
                session.presentRangePicker()
            } label: {
                HStack(spacing: LedgerSpacing.md) {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LedgerPalette.cobalt)
                        .frame(width: 34, height: 34)
                        .background(LedgerPalette.tag)
                        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.selectedRange.displayTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LedgerPalette.ink)
                            .lineLimit(1)
                        Text("\(session.selectedRange.start) 至 \(session.selectedRange.end)")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(LedgerPalette.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if session.isRangeLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(LedgerPalette.cobalt)
                    } else {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LedgerPalette.cobalt)
                    }
                }
                .padding(.horizontal, LedgerSpacing.md)
                .frame(maxWidth: .infinity, minHeight: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(session.isRangeLoading)
            .accessibilityLabel("选择时间范围，当前为\(session.selectedRange.displayTitle)")

            verticalDivider
            stepButton(direction: 1, systemImage: "chevron.right", label: "下一周期")
        }
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
        .sheet(isPresented: sheetBinding) {
            LedgerTimeRangeSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(LedgerPalette.line)
            .frame(width: 1, height: 60)
    }

    private func stepButton(direction: Int, systemImage: String, label: String) -> some View {
        Button {
            Task { await session.moveRange(by: direction) }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(width: 44, height: 60)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(session.isRangeLoading || session.selectedRange.preset == .custom)
        .opacity(session.selectedRange.preset == .custom ? 0.35 : 1)
        .accessibilityLabel(label)
    }
}

private struct LedgerTimeRangeSheet: View {
    @EnvironmentObject private var session: LedgerSession

    private let presetColumns = [
        GridItem(.flexible(), spacing: LedgerSpacing.sm),
        GridItem(.flexible(), spacing: LedgerSpacing.sm),
        GridItem(.flexible(), spacing: LedgerSpacing.sm),
    ]

    private var startBinding: Binding<Date> {
        Binding(
            get: { session.draftRange.startDate },
            set: session.updateDraftStart
        )
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { session.draftRange.endDate },
            set: session.updateDraftEnd
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LedgerSpacing.xl) {
                    selectionSummary

                    VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                        Text("自然周期")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LedgerPalette.secondary)

                        LazyVGrid(columns: presetColumns, spacing: LedgerSpacing.sm) {
                            presetButton(.month)
                            presetButton(.quarter)
                            presetButton(.year)
                        }
                    }

                    VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                        VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
                            Text("自定义日期")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(LedgerPalette.ink)
                            Text("修改任一日期后，范围会切换为自定义。")
                                .font(.system(size: 11))
                                .foregroundStyle(LedgerPalette.secondary)
                        }

                        dateRow(title: "开始日期", selection: startBinding)
                        dateRow(title: "结束日期", selection: endBinding)
                    }
                    .padding(LedgerSpacing.lg)
                    .background(LedgerPalette.panel)
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous)
                            .stroke(LedgerPalette.line, lineWidth: 1)
                    }
                }
                .padding(LedgerSpacing.lg)
            }
            .background(LedgerPalette.canvas)
            .navigationTitle("时间范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { session.dismissRangePicker() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await session.applyDraftRange() }
                } label: {
                    PrimaryButtonLabel(
                        title: "应用 \(session.draftRange.displayTitle)",
                        loading: false
                    )
                }
                .buttonStyle(PressScaleButtonStyle())
                .padding(.horizontal, LedgerSpacing.lg)
                .padding(.vertical, LedgerSpacing.md)
                .background(LedgerPalette.panel)
                .overlay(alignment: .top) {
                    Rectangle().fill(LedgerPalette.line).frame(height: 1)
                }
            }
        }
    }

    private var selectionSummary: some View {
        HStack(spacing: LedgerSpacing.md) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(width: 40, height: 40)
                .background(LedgerPalette.panel)
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(session.draftRange.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LedgerPalette.cobalt)
                Text("\(session.draftRange.start) 至 \(session.draftRange.end)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(LedgerPalette.olive)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(LedgerSpacing.md)
        .background(LedgerPalette.tag)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
    }

    private func presetButton(_ preset: LedgerDateRangePreset) -> some View {
        let selected = session.draftRange.preset == preset

        return Button {
            session.selectDraftPreset(preset)
        } label: {
            Text(preset.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? LedgerPalette.onBrand : LedgerPalette.olive)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(selected ? LedgerPalette.cobalt : LedgerPalette.panel)
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                        .stroke(selected ? Color.clear : LedgerPalette.line, lineWidth: 1)
                }
        }
        .buttonStyle(PressScaleButtonStyle())
    }

    private func dateRow(title: String, selection: Binding<Date>) -> some View {
        HStack(spacing: LedgerSpacing.md) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
            Spacer(minLength: LedgerSpacing.sm)
            DatePicker("", selection: selection, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .environment(\.locale, Locale(identifier: "zh_CN"))
        }
        .frame(minHeight: 44)
    }
}
