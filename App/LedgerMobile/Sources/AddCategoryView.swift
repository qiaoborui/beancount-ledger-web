import SwiftUI

struct AddCategoryView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss

    var initialKind: CategoryKind = .expense

    @State private var selectedKind: CategoryKind = .expense
    @State private var selectedSection: CategorySectionPreset = CategoryPresets.sections(for: .expense)[0]
    @State private var selectedItem: CategoryItemPreset? = nil
    @State private var isCustom = false
    @State private var customName: String = ""

    // 高级选项
    @State private var showAdvanced: Bool = false
    @State private var isCustomPathEdited: Bool = false
    @State private var manualCategoryPath: String = ""

    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String? = nil

    private var availableSections: [CategorySectionPreset] {
        CategoryPresets.sections(for: selectedKind)
    }

    private var effectiveName: String {
        if isCustom {
            return customName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let item = selectedItem {
            return item.name
        }
        return customName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var calculatedPath: String {
        if isCustomPathEdited && !manualCategoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return manualCategoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return BeancountNaming.buildCategoryPath(
            kind: selectedKind,
            sectionCode: selectedSection.code,
            itemCode: isCustom ? nil : selectedItem?.code,
            customName: customName
        )
    }

    private var isPathValid: Bool {
        BeancountNaming.isValidAccountPath(calculatedPath)
    }

    private var canSubmit: Bool {
        !effectiveName.isEmpty && isPathValid && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        StatusBanner(message: errorMessage) {
                            self.errorMessage = nil
                        }
                    }
                }

                // ── 1. 支出 / 收入 ──
                Section {
                    Picker("分类类型", selection: $selectedKind) {
                        ForEach(CategoryKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedKind) { _, newKind in
                        if let firstSection = CategoryPresets.sections(for: newKind).first {
                            selectedSection = firstSection
                            selectedItem = firstSection.items.first
                            isCustom = false
                            isCustomPathEdited = false
                        }
                    }
                }

                // ── 2. 一级大类 ──
                Section("一级大类") {
                    Picker("一级大类", selection: $selectedSection) {
                        ForEach(availableSections) { sec in
                            Label(sec.name, systemImage: sec.icon).tag(sec)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedSection) { _, newSec in
                        selectedItem = newSec.items.first
                        isCustom = false
                        isCustomPathEdited = false
                    }
                }

                // ── 3. 二级子分类选择 / 自定义 ──
                Section("子分类") {
                    if !selectedSection.items.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: LedgerSpacing.sm) {
                                ForEach(selectedSection.items) { item in
                                    let isSelected = !isCustom && selectedItem?.id == item.id
                                    Button {
                                        LedgerFeedback.selection()
                                        selectedItem = item
                                        isCustom = false
                                        isCustomPathEdited = false
                                    } label: {
                                        VStack(spacing: 6) {
                                            ZStack {
                                                Circle()
                                                    .fill(isSelected ? LedgerPalette.cobalt : LedgerPalette.panel)
                                                    .frame(width: 44, height: 44)
                                                Image(systemName: item.icon)
                                                    .font(.system(size: 17, weight: .medium))
                                                    .foregroundStyle(isSelected ? Color.white : LedgerPalette.ink)
                                            }
                                            Text(item.name)
                                                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                                                .foregroundStyle(isSelected ? LedgerPalette.cobalt : LedgerPalette.ink)
                                                .lineLimit(1)
                                        }
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 6)
                                        .background(isSelected ? LedgerPalette.cobalt.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)
                                }

                                // 自定义
                                Button {
                                    LedgerFeedback.selection()
                                    isCustom = true
                                    selectedItem = nil
                                    isCustomPathEdited = false
                                } label: {
                                    VStack(spacing: 6) {
                                        ZStack {
                                            Circle()
                                                .fill(isCustom ? LedgerPalette.cobalt : LedgerPalette.panel)
                                                .frame(width: 44, height: 44)
                                            Image(systemName: "plus")
                                                .font(.system(size: 17, weight: .semibold))
                                                .foregroundStyle(isCustom ? Color.white : LedgerPalette.ink)
                                        }
                                        Text("自定义")
                                            .font(.system(size: 11.5, weight: isCustom ? .semibold : .regular))
                                            .foregroundStyle(isCustom ? LedgerPalette.cobalt : LedgerPalette.ink)
                                            .lineLimit(1)
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 6)
                                    .background(isCustom ? LedgerPalette.cobalt.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if isCustom {
                        TextField("输入自定义分类名称（例如：私教课）", text: $customName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: customName) { _, _ in
                                isCustomPathEdited = false
                            }
                    }
                }

                // ── 4. 高级设置 ──
                Section {
                    DisclosureGroup("高级：Beancount 路径规范", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
                            HStack {
                                Text("底层路径:")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(LedgerPalette.secondary)
                                Spacer()
                                if isPathValid {
                                    Label("合规", systemImage: "checkmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(LedgerPalette.success)
                                } else {
                                    Label("无效", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(LedgerPalette.risk)
                                }
                            }

                            TextField("Beancount 路径", text: Binding(
                                get: { calculatedPath },
                                set: { newValue in
                                    manualCategoryPath = newValue
                                    isCustomPathEdited = true
                                }
                            ))
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(8)
                            .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: 8))

                            HStack {
                                Text("分类中文名 (alias):")
                                    .font(.caption)
                                    .foregroundStyle(LedgerPalette.secondary)
                                Text(effectiveName.isEmpty ? "（空）" : effectiveName)
                                    .font(.caption.weight(.semibold))
                            }

                            if isCustomPathEdited {
                                Button("恢复自动生成路径") {
                                    isCustomPathEdited = false
                                    manualCategoryPath = ""
                                }
                                .font(.caption)
                                .foregroundStyle(LedgerPalette.cobalt)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("新建分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "正在保存..." : "保存") {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                selectedKind = initialKind
                if let firstSec = CategoryPresets.sections(for: initialKind).first {
                    selectedSection = firstSec
                    selectedItem = firstSec.items.first
                }
            }
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())

        do {
            try await session.addAccount(
                account: calculatedPath,
                alias: effectiveName,
                currency: "",
                date: today
            )
            LedgerFeedback.selection()
            dismiss()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}
