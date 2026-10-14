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
            List {
                if let errorMessage {
                    Section {
                        StatusBanner(message: errorMessage) {
                            self.errorMessage = nil
                        }
                    }
                }

                // ── 1. 支出 / 收入 ──
                Section {
                    CategoryKindSeg(selected: $selectedKind)
                        .onChange(of: selectedKind) { _, newKind in
                            if let firstSection = CategoryPresets.sections(for: newKind).first {
                                selectedSection = firstSection
                                selectedItem = firstSection.items.first
                                isCustom = false
                                isCustomPathEdited = false
                            }
                        }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // ── 2. 一级大类 ──
                Section {
                    Menu {
                        ForEach(availableSections) { sec in
                            Button(sec.name) {
                                selectedSection = sec
                                selectedItem = sec.items.first
                                isCustom = false
                                isCustomPathEdited = false
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedSection.name).balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink)
                                Text(selectedSection.rootAccount).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(BalancedPalette.edge)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                } header: { TerminalSectionLabel(text: "上级科目").listRowBackground(BalancedPalette.page) }

                // ── 3. 二级子分类选择 / 自定义 ──
                Section {
                    ForEach(selectedSection.items) { item in
                        let isSelected = !isCustom && selectedItem?.id == item.id
                        Button {
                            LedgerFeedback.selection()
                            selectedItem = item
                            isCustom = false
                            isCustomPathEdited = false
                        } label: {
                            HStack {
                                Text(item.name).balancedFont(size: 15, weight: isSelected ? .medium : .regular)
                                    .foregroundStyle(isSelected ? BalancedPalette.ink : BalancedPalette.secondary)
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(BalancedPalette.ink)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    Button {
                        LedgerFeedback.selection()
                        isCustom = true
                        selectedItem = nil
                        isCustomPathEdited = false
                    } label: {
                        HStack {
                            Text("自定义").balancedFont(size: 15, weight: isCustom ? .medium : .regular)
                                .foregroundStyle(isCustom ? BalancedPalette.ink : BalancedPalette.secondary)
                            Spacer()
                            if isCustom {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(BalancedPalette.ink)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    if isCustom {
                        TextField("输入自定义分类名称（例如：私教课）", text: $customName)
                            .balancedFont(size: 15)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: customName) { _, _ in
                                isCustomPathEdited = false
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: { TerminalSectionLabel(text: "子分类").listRowBackground(BalancedPalette.page) }

                // ── 4. 将创建 ──
                Section {
                    Text("2000-01-01 open \(calculatedPath) CNY")
                        .balancedMono(size: 11.5)
                        .foregroundStyle(BalancedPalette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .balancedBand()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    HStack(spacing: 6) {
                        Image(systemName: isPathValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(isPathValid ? BalancedPalette.income : BalancedPalette.expense)
                        Text(isPathValid ? "路径合规" : "路径无效")
                            .balancedFont(size: 12.5)
                            .foregroundStyle(BalancedPalette.meta)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: { TerminalSectionLabel(text: "将创建").listRowBackground(BalancedPalette.page) }

                // ── 5. 高级设置 ──
                Section {
                    DisclosureGroup("高级：Beancount 路径规范", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Beancount 路径", text: Binding(
                                get: { calculatedPath },
                                set: { newValue in
                                    manualCategoryPath = newValue
                                    isCustomPathEdited = true
                                }
                            ))
                            .balancedMono(size: 12.5)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            HStack {
                                Text("分类中文名 (alias):")
                                    .balancedFont(size: 12)
                                    .foregroundStyle(BalancedPalette.meta)
                                Text(effectiveName.isEmpty ? "（空）" : effectiveName)
                                    .balancedFont(size: 12, weight: .medium)
                                    .foregroundStyle(BalancedPalette.ink)
                            }

                            if isCustomPathEdited {
                                Button("恢复自动生成路径") {
                                    isCustomPathEdited = false
                                    manualCategoryPath = ""
                                }
                                .balancedFont(size: 12.5)
                                .foregroundStyle(BalancedPalette.ink)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .balancedFont(size: 14)
                    .foregroundStyle(BalancedPalette.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .navigationTitle("新建分类")
            .terminalNativeChrome()
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
