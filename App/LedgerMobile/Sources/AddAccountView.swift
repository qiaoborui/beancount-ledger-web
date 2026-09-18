import SwiftUI

struct AddAccountView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss

    @State private var selectedCategory: AccountTypeCategory = .bank
    @State private var selectedPreset: AccountPresetItem? = AccountPresets.presets.first(where: { $0.id == "bank_cmb" })
    @State private var isCustom = false

    @State private var customName: String = ""
    @State private var accountDetail: String = ""
    @State private var currency: String = "CNY"
    @State private var openingBalance: String = ""
    @State private var openDate: Date = Date()

    // 高级选项
    @State private var showAdvanced: Bool = false
    @State private var isCustomPathEdited: Bool = false
    @State private var manualAccountPath: String = ""

    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String? = nil

    private var availableCurrencies: [String] {
        var list = AccountPresets.commonCurrencies
        if let ledgerCurrencies = session.ledger?.commodities {
            for c in ledgerCurrencies where !list.contains(c) {
                list.append(c)
            }
        }
        return list
    }

    private var effectiveName: String {
        if isCustom {
            return customName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let preset = selectedPreset {
            let detail = accountDetail.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? preset.name : "\(preset.name) (\(detail))"
        }
        return customName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var calculatedAccountPath: String {
        if isCustomPathEdited && !manualAccountPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return manualAccountPath.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return BeancountNaming.buildAccountPath(
            category: selectedCategory,
            preset: isCustom ? nil : selectedPreset,
            customName: customName,
            detail: accountDetail
        )
    }

    private var isPathValid: Bool {
        BeancountNaming.isValidAccountPath(calculatedAccountPath)
    }

    private var canSubmit: Bool {
        !effectiveName.isEmpty && isPathValid && !isSubmitting
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: openDate)
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

                // ── 1. 账户类型 ──
                Section("账户类型") {
                    Picker("大类", selection: $selectedCategory) {
                        ForEach(AccountTypeCategory.allCases) { cat in
                            Label(cat.title, systemImage: cat.defaultIcon).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedCategory) { _, newCat in
                        let catPresets = AccountPresets.presets(for: newCat)
                        if let first = catPresets.first {
                            selectedPreset = first
                            isCustom = false
                        } else {
                            selectedPreset = nil
                            isCustom = true
                        }
                        isCustomPathEdited = false
                    }
                }

                // ── 2. 选择机构或自定义 ──
                Section("选择机构") {
                    let catPresets = AccountPresets.presets(for: selectedCategory)
                    if !catPresets.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: LedgerSpacing.sm) {
                                ForEach(catPresets) { preset in
                                    let isSelected = !isCustom && selectedPreset?.id == preset.id
                                    Button {
                                        LedgerFeedback.selection()
                                        selectedPreset = preset
                                        isCustom = false
                                        isCustomPathEdited = false
                                        if let suggested = preset.suggestedCurrency {
                                            currency = suggested
                                        }
                                    } label: {
                                        VStack(spacing: 6) {
                                            ZStack {
                                                Circle()
                                                    .fill(isSelected ? LedgerPalette.cobalt : LedgerPalette.panel)
                                                    .frame(width: 44, height: 44)
                                                Image(systemName: preset.icon)
                                                    .font(.system(size: 18, weight: .medium))
                                                    .foregroundStyle(isSelected ? Color.white : LedgerPalette.ink)
                                            }
                                            Text(preset.name)
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

                                // 自定义卡片
                                Button {
                                    LedgerFeedback.selection()
                                    isCustom = true
                                    selectedPreset = nil
                                    isCustomPathEdited = false
                                } label: {
                                    VStack(spacing: 6) {
                                        ZStack {
                                            Circle()
                                                .fill(isCustom ? LedgerPalette.cobalt : LedgerPalette.panel)
                                                .frame(width: 44, height: 44)
                                            Image(systemName: "pencil.and.outline")
                                                .font(.system(size: 18, weight: .medium))
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
                        TextField("输入账户或机构名称（如：自如押金）", text: $customName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: customName) { _, _ in
                                isCustomPathEdited = false
                            }
                    } else {
                        TextField("尾号或备注（选填，如：8888、工资卡）", text: $accountDetail)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: accountDetail) { _, _ in
                                isCustomPathEdited = false
                            }
                    }
                }

                // ── 3. 币种与期初余额 ──
                Section {
                    // 币种选择
                    HStack {
                        Text("主要币种")
                        Spacer()
                        Picker("币种", selection: $currency) {
                            ForEach(availableCurrencies, id: \.self) { c in
                                Text(c).tag(c)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // 期初余额
                    HStack {
                        Text(selectedCategory.isLiability ? "当前欠款/负债" : "当前账户余额")
                        Spacer()
                        TextField("0.00", text: $openingBalance)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .rounded).monospacedDigit())
                    }

                    // 开户日期
                    DatePicker("生效日期", selection: $openDate, displayedComponents: .date)
                } header: {
                    Text("余额与币种")
                } footer: {
                    Text("填写当前卡内金额将自动通过期初余额（Equity:Opening-Balances）配平。如不确定可留空后续通过对账录入。")
                        .font(.caption2)
                }

                // ── 4. 高级设置：Beancount 路径 ──
                Section {
                    DisclosureGroup("高级：Beancount 规范设置", isExpanded: $showAdvanced) {
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
                                    Label("路径无效", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(LedgerPalette.risk)
                                }
                            }

                            TextField("Beancount 路径", text: Binding(
                                get: { calculatedAccountPath },
                                set: { newValue in
                                    manualAccountPath = newValue
                                    isCustomPathEdited = true
                                }
                            ))
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(8)
                            .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: 8))

                            HStack {
                                Text("中文别名 (alias):")
                                    .font(.caption)
                                    .foregroundStyle(LedgerPalette.secondary)
                                Text(effectiveName.isEmpty ? "（空）" : effectiveName)
                                    .font(.caption.weight(.semibold))
                            }

                            if isCustomPathEdited {
                                Button("恢复自动生成路径") {
                                    isCustomPathEdited = false
                                    manualAccountPath = ""
                                }
                                .font(.caption)
                                .foregroundStyle(LedgerPalette.cobalt)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("新建账户")
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
                if let ledgerCurrency = session.ledger?.valuationCurrency {
                    currency = ledgerCurrency
                }
            }
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await session.addAccount(
                account: calculatedAccountPath,
                alias: effectiveName,
                currency: currency,
                date: dateString,
                openingBalance: openingBalance.isEmpty ? nil : openingBalance
            )
            LedgerFeedback.selection()
            dismiss()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}
