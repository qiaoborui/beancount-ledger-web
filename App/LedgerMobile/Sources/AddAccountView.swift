import SwiftUI

struct AddAccountView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss

    @State private var selectedCategory: AccountTypeCategory = .bank
    @State private var selectedPreset: AccountPresetItem? = AccountPresets.presets.first(where: { $0.id == "bank_cmb" })
    @State private var isCustom = false
    @State private var showingInstitutionPicker = false

    @State private var customName: String = ""
    @State private var accountDetail: String = ""
    @State private var currency: String = "CNY"
    @State private var openingBalance: String = ""
    @State private var useLedgerInceptionDate: Bool = true
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
        if useLedgerInceptionDate {
            return "1970-01-01"
        }
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
                Section("机构与银行") {
                    if let preset = selectedPreset, !isCustom {
                        HStack(spacing: LedgerSpacing.md) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(LedgerPalette.cobalt.opacity(0.12))
                                    .frame(width: 44, height: 44)
                                Image(systemName: preset.icon)
                                    .font(.system(size: 20))
                                    .foregroundStyle(LedgerPalette.cobalt)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(LedgerPalette.ink)
                                Text(preset.defaultAccount)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                            Spacer()
                            Button("更换") {
                                showingInstitutionPicker = true
                            }
                            .font(.subheadline)
                            .foregroundStyle(LedgerPalette.cobalt)
                        }
                        .padding(.vertical, 2)
                    } else {
                        HStack(spacing: LedgerSpacing.md) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(LedgerPalette.panel)
                                    .frame(width: 44, height: 44)
                                Image(systemName: "pencil.and.outline")
                                    .font(.system(size: 20))
                                    .foregroundStyle(LedgerPalette.ink)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("自定义机构名称")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(LedgerPalette.ink)
                                Text("手动输入任意机构或卡种")
                                    .font(.caption2)
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                            Spacer()
                            Button("从列表选择") {
                                showingInstitutionPicker = true
                            }
                            .font(.subheadline)
                            .foregroundStyle(LedgerPalette.cobalt)
                        }
                        .padding(.vertical, 2)
                    }

                    // 机构选择列表按钮入口
                    Button {
                        showingInstitutionPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "list.bullet.rectangle")
                            Text("浏览全部银行与机构列表 (\(AccountPresets.presets.count) 家)...")
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LedgerPalette.cobalt)
                    }

                    if isCustom {
                        TextField("输入机构或账户名称（如：自如押金、招商二类卡）", text: $customName)
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
                        Text(selectedCategory.isLiability ? "当前待还欠款" : "当前账户余额")
                        Spacer()
                        TextField("0.00", text: $openingBalance)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .rounded).monospacedDigit())
                    }

                    // 开户日期模式
                    Toggle("账本起始日生效 (推荐)", isOn: $useLedgerInceptionDate)

                    if !useLedgerInceptionDate {
                        DatePicker("生效日期", selection: $openDate, displayedComponents: .date)
                    }
                } header: {
                    Text("余额与币种")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if selectedCategory.isLiability {
                            Text("⚠️ 仅需录入当前未还账单欠款，如已还清或无欠款请留空。切勿填写信用总额度。")
                                .font(.caption2)
                                .foregroundStyle(LedgerPalette.secondary)
                        } else {
                            Text("填写当前卡内金额将自动通过期初余额（Equity:Opening-Balances）配平。如不确定可留空。")
                                .font(.caption2)
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                        Text("推荐使用账本起始生效 (1970-01-01)，避免后续补录历史账单时因交易先于开户日期而触发 Beancount 校验冲突。")
                            .font(.caption2)
                            .foregroundStyle(LedgerPalette.secondary)
                    }
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
            .sheet(isPresented: $showingInstitutionPicker) {
                InstitutionPickerSheet(
                    onSelect: { preset in
                        selectedPreset = preset
                        selectedCategory = preset.category
                        isCustom = false
                        isCustomPathEdited = false
                        if let suggested = preset.suggestedCurrency {
                            currency = suggested
                        }
                    },
                    onSelectCustom: {
                        isCustom = true
                        selectedPreset = nil
                        isCustomPathEdited = false
                    }
                )
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
