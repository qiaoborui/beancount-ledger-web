import SwiftUI

/// 引导式新手开账向导：降低非技术用户使用 Beancount 的门槛，
/// 1 分钟内完成常用账户勾选、初始余额校准及分类定制，一键生成可用账本。
struct OnboardingWizardView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case welcome = 0
        case accounts = 1
        case categories = 2
        case summary = 3
    }

    @State private var currentStep: Step = .welcome
    @State private var ledgerName: String = String(localized: "我的账本")
    @State private var selectedCurrency: String = "CNY"

    // ── 账户选择状态 ──
    struct AccountDraft: Identifiable, Equatable {
        let id: String
        var name: String
        var account: String
        let icon: String
        let category: AccountTypeCategory
        var isSelected: Bool
        var initialBalance: String
        var isLiability: Bool
    }

    @State private var accountDrafts: [AccountDraft] = [
        // 移动支付
        AccountDraft(id: "wechat_lq", name: String(localized: "微信零钱"), account: "Assets:Wallet:WeChat:LingQian", icon: "message.fill", category: .wallet, isSelected: true, initialBalance: "", isLiability: false),
        AccountDraft(id: "alipay_bal", name: String(localized: "支付宝余额"), account: "Assets:Wallet:Alipay:Balance", icon: "creditcard.and.123", category: .wallet, isSelected: true, initialBalance: "", isLiability: false),
        AccountDraft(id: "alipay_yeb", name: String(localized: "余额宝"), account: "Assets:Wallet:Alipay:YuEBao", icon: "chart.line.uptrend.xyaxis", category: .wallet, isSelected: true, initialBalance: "", isLiability: false),
        AccountDraft(id: "wechat_lqt", name: String(localized: "微信零钱通"), account: "Assets:Wallet:WeChat:LingQianTong", icon: "arrow.triangle.swap", category: .wallet, isSelected: false, initialBalance: "", isLiability: false),
        AccountDraft(id: "wallet_unionpay", name: String(localized: "云闪付"), account: "Assets:Wallet:UnionPay", icon: "creditcard", category: .wallet, isSelected: false, initialBalance: "", isLiability: false),

        // 银行储蓄卡
        AccountDraft(id: "bank_cmb", name: String(localized: "招商银行储蓄卡"), account: "Assets:Bank:CMB", icon: "building.columns", category: .bank, isSelected: true, initialBalance: "", isLiability: false),
        AccountDraft(id: "bank_icbc", name: String(localized: "工商银行储蓄卡"), account: "Assets:Bank:ICBC", icon: "building.columns", category: .bank, isSelected: false, initialBalance: "", isLiability: false),
        AccountDraft(id: "bank_ccb", name: String(localized: "建设银行储蓄卡"), account: "Assets:Bank:CCB", icon: "building.columns", category: .bank, isSelected: false, initialBalance: "", isLiability: false),
        AccountDraft(id: "bank_boc", name: String(localized: "中国银行储蓄卡"), account: "Assets:Bank:BOC", icon: "building.columns", category: .bank, isSelected: false, initialBalance: "", isLiability: false),
        AccountDraft(id: "bank_abc", name: String(localized: "农业银行储蓄卡"), account: "Assets:Bank:ABC", icon: "building.columns", category: .bank, isSelected: false, initialBalance: "", isLiability: false),
        AccountDraft(id: "bank_comm", name: String(localized: "交通银行储蓄卡"), account: "Assets:Bank:COMM", icon: "building.columns", category: .bank, isSelected: false, initialBalance: "", isLiability: false),
        AccountDraft(id: "bank_psbc", name: String(localized: "邮政储蓄储蓄卡"), account: "Assets:Bank:PSBC", icon: "building.columns", category: .bank, isSelected: false, initialBalance: "", isLiability: false),

        // 信用卡与信用消费
        AccountDraft(id: "credit_cmb", name: String(localized: "招行信用卡"), account: "Liabilities:CreditCard:CMB", icon: "creditcard.fill", category: .credit, isSelected: false, initialBalance: "", isLiability: true),
        AccountDraft(id: "credit_icbc", name: String(localized: "工行信用卡"), account: "Liabilities:CreditCard:ICBC", icon: "creditcard.fill", category: .credit, isSelected: false, initialBalance: "", isLiability: true),
        AccountDraft(id: "credit_huabei", name: String(localized: "蚂蚁花呗"), account: "Liabilities:CreditCard:Huabei", icon: "hand.tap", category: .credit, isSelected: false, initialBalance: "", isLiability: true),
        AccountDraft(id: "credit_baitiao", name: String(localized: "京东白条"), account: "Liabilities:CreditCard:Baitiao", icon: "cart.fill", category: .credit, isSelected: false, initialBalance: "", isLiability: true),
        AccountDraft(id: "credit_meituan", name: String(localized: "美团月付"), account: "Liabilities:CreditCard:MeituanYuefu", icon: "fork.knife", category: .credit, isSelected: false, initialBalance: "", isLiability: true),

        // 现金
        AccountDraft(id: "cash_cny", name: String(localized: "人民币现金"), account: "Assets:Cash:CNY", icon: "banknote", category: .cash, isSelected: true, initialBalance: "", isLiability: false)
    ]

    // ── 分类选择状态（基于全面预设字典动态初始化）──
    struct CategoryDraft: Identifiable, Equatable {
        let id: String
        let name: String
        let account: String
        let icon: String
        let kind: CategoryKind
        let detail: String
        var isSelected: Bool
    }

    @State private var categoryDrafts: [CategoryDraft] = CategoryPresets.sections.map { section in
        let subnames = section.items.map(\.name).joined(separator: String(localized: "、"))
        let isRecommended = ["exp_food", "exp_daily", "exp_transport", "exp_home", "exp_fun", "exp_health", "inc_career", "inc_invest"].contains(section.id)
        return CategoryDraft(
            id: section.id,
            name: section.name,
            account: section.rootAccount,
            icon: section.icon,
            kind: section.kind,
            detail: subnames,
            isSelected: isRecommended
        )
    }

    @State private var selectedCategoryTab: CategoryKind = .expense
    @State private var isCreating = false
    @State private var customAccountName = ""
    @State private var customAccountCategory: AccountTypeCategory = .bank
    @State private var showingAddCustomAccount = false
    @State private var showingInstitutionPicker = false

    // 财务期初统计计算
    private var totalAssetBalance: Decimal {
        accountDrafts.filter { $0.isSelected && !$0.isLiability }.reduce(Decimal.zero) { sum, draft in
            let raw = draft.initialBalance.trimmingCharacters(in: .whitespacesAndNewlines)
            let val = Decimal(string: raw) ?? 0
            return sum + max(val, 0)
        }
    }

    private var totalLiabilityBalance: Decimal {
        accountDrafts.filter { $0.isSelected && $0.isLiability }.reduce(Decimal.zero) { sum, draft in
            let raw = draft.initialBalance.trimmingCharacters(in: .whitespacesAndNewlines)
            let val = Decimal(string: raw) ?? 0
            return sum + max(val, 0)
        }
    }

    private var netWorth: Decimal {
        totalAssetBalance - totalLiabilityBalance
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部步骤进度条 — `.rail`：四等分，已完成为 ink，其余为 rule-strong
                OnboardingRail(current: currentStep.rawValue, total: Step.allCases.count)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)

                // 步骤内容容器
                TabView(selection: $currentStep) {
                    welcomeStepView.tag(Step.welcome)
                    accountsStepView.tag(Step.accounts)
                    categoriesStepView.tag(Step.categories)
                    summaryStepView.tag(Step.summary)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.25), value: currentStep)

                // 底部导航栏
                bottomBar
            }
            .background(BalancedPalette.page.ignoresSafeArea())
            .navigationTitle(navigationTitleForCurrentStep)
            .terminalNativeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if currentStep == .welcome {
                        Button("取消") { dismiss() }
                            .disabled(isCreating)
                    } else {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(isCreating)
                        .accessibilityLabel("取消")
                    }
                }
                if currentStep != .welcome {
                    ToolbarItem(placement: .confirmationAction) {
                        Text("\(currentStep.rawValue + 1) / \(Step.allCases.count)")
                            .balancedFont(size: 12.5)
                            .foregroundStyle(BalancedPalette.meta)
                    }
                }
            }
            .sheet(isPresented: $showingAddCustomAccount) {
                addCustomAccountSheet
            }
            .sheet(isPresented: $showingInstitutionPicker) {
                InstitutionPickerSheet(
                    onSelect: { preset in
                        if let idx = accountDrafts.firstIndex(where: { $0.account == preset.defaultAccount }) {
                            accountDrafts[idx].isSelected = true
                        } else {
                            let newDraft = AccountDraft(
                                id: preset.id,
                                name: preset.name,
                                account: preset.defaultAccount,
                                icon: preset.icon,
                                category: preset.category,
                                isSelected: true,
                                initialBalance: "",
                                isLiability: preset.category.isLiability
                            )
                            accountDrafts.append(newDraft)
                        }
                    },
                    onSelectCustom: {
                        showingAddCustomAccount = true
                    }
                )
            }
            .overlay {
                if isCreating {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(BalancedPalette.ink)
                            Text("正在生成并校验账本...")
                                .balancedFont(size: 13.5)
                                .foregroundStyle(BalancedPalette.ink)
                        }
                        .padding(28)
                        .background(BalancedPalette.page)
                    }
                }
            }
        }
    }

    private var navigationTitleForCurrentStep: String {
        switch currentStep {
        case .welcome: String(localized: "开账")
        case .accounts: String(localized: "选择账户")
        case .categories: String(localized: "选择分类")
        case .summary: String(localized: "核对期初")
        }
    }

    // MARK: - 步骤 1: 起名字与货币（d02）
    private var welcomeStepView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("先给它起个名字")
                    .balancedFont(size: 23, weight: .semibold)
                    .foregroundStyle(BalancedPalette.ink)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                Text("账本是磁盘上的一个文件夹。名字只影响这里的显示，文件名之后随时可以改。")
                    .balancedFont(size: 13.5)
                    .foregroundStyle(BalancedPalette.meta)
                    .padding(.bottom, 24)

                Text("账本名称").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                TextField("账本名称", text: $ledgerName)
                    .balancedFont(size: 15)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
                    .padding(.bottom, 16)

                BalancedSectionLabel(text: String(localized: "记账货币"))
                VStack(spacing: 0) {
                    ForEach(AccountPresets.commonCurrencies, id: \.self) { cur in
                        Button {
                            selectedCurrency = cur
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(currencyName(for: cur)).balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink)
                                    Text("\(cur) · \(currencySymbol(for: cur))").balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                                }
                                Spacer()
                                if selectedCurrency == cur {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(BalancedPalette.ink)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                    }
                }
                Text("这是估值货币。其它币种按录入当日的汇率折算到它。")
                    .balancedFont(size: 12.5)
                    .foregroundStyle(BalancedPalette.meta)
                    .padding(.top, 10)

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private func currencyName(for currency: String) -> String {
        switch currency {
        case "CNY": String(localized: "人民币")
        case "USD": String(localized: "美元")
        case "JPY": String(localized: "日元")
        case "HKD": String(localized: "港币")
        case "EUR": String(localized: "欧元")
        case "GBP": String(localized: "英镑")
        default: currency
        }
    }

    // MARK: - 步骤 2: 常用账户与期初余额（d03）
    private var accountsStepView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("已勾选 \(accountDrafts.filter(\.isSelected).count) 个。填了余额的账户会在 accounts.bean 里生成一条 open 加上期初 balance 断言。")
                    .balancedFont(size: 12.5)
                    .foregroundStyle(BalancedPalette.meta)
                    .padding(.top, 2)
                    .padding(.bottom, 10)

                accountSection(title: String(localized: "移动支付"), category: .wallet)
                accountSection(title: String(localized: "银行储蓄卡"), category: .bank, showsMore: true)
                accountSection(title: String(localized: "信用卡与信用消费 (负债)"), liabilityOnly: true, showsMore: true)
                Text("信用卡填的是当前待还欠款（已还清请留空）。切勿填写信用总额度，避免净资产被扣减。")
                    .balancedFont(size: 12)
                    .foregroundStyle(BalancedPalette.meta)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                accountSection(title: String(localized: "现钞与备用金"), category: .cash)

                Button {
                    showingAddCustomAccount = true
                } label: {
                    Text("添加其他自定义账户…")
                        .balancedFont(size: 14)
                        .foregroundStyle(BalancedPalette.ink)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)

                Text("没填余额的账户只生成 open，之后第一次对账再补。")
                    .balancedFont(size: 12.5)
                    .foregroundStyle(BalancedPalette.meta)
                    .padding(.top, 6)

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private func accountSection(title: String, category: AccountTypeCategory? = nil, liabilityOnly: Bool = false, showsMore: Bool = false) -> some View {
        let rows = accountDrafts.indices.filter { idx in
            liabilityOnly ? accountDrafts[idx].isLiability : accountDrafts[idx].category == category
        }
        let selectedCount = rows.filter { accountDrafts[$0].isSelected }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .balancedFont(size: 12.5, weight: .medium)
                    .tracking(0.375)
                    .foregroundStyle(BalancedPalette.meta)
                Spacer()
                Text("\(selectedCount) / \(rows.count)")
                    .balancedFont(size: 12.5)
                    .foregroundStyle(BalancedPalette.meta)
                if showsMore {
                    Button {
                        showingInstitutionPicker = true
                    } label: {
                        Text("更多…").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary)
                    }
                }
            }
            .frame(minHeight: 28, alignment: .bottom)
            ForEach(rows, id: \.self) { idx in
                OnboardingAccountRow(draft: $accountDrafts[idx], currency: selectedCurrency, currencySymbol: currencySymbol(for: selectedCurrency))
            }
        }
    }

    // MARK: - 步骤 3: 收支分类
    private var categoriesStepView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let selectedExpenseCount = categoryDrafts.filter { $0.kind == .expense && $0.isSelected }.count
                let selectedIncomeCount = categoryDrafts.filter { $0.kind == .income && $0.isSelected }.count

                HStack(spacing: 0) {
                    Button { selectedCategoryTab = .expense } label: {
                        BalancedMark(title: String(localized: "支出分类 (\(selectedExpenseCount))"), selected: selectedCategoryTab == .expense, size: 14)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.plain)
                    Button { selectedCategoryTab = .income } label: {
                        BalancedMark(title: String(localized: "收入分类 (\(selectedIncomeCount))"), selected: selectedCategoryTab == .income, size: 14)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.plain)
                }
                .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                .padding(.bottom, 10)

                HStack(spacing: 14) {
                    Button("推荐常用") {
                        for i in categoryDrafts.indices {
                            let item = categoryDrafts[i]
                            categoryDrafts[i].isSelected = ["exp_food", "exp_daily", "exp_transport", "exp_home", "exp_fun", "exp_health", "inc_career", "inc_invest"].contains(item.id)
                        }
                    }
                    Button("全选") {
                        for i in categoryDrafts.indices where categoryDrafts[i].kind == selectedCategoryTab {
                            categoryDrafts[i].isSelected = true
                        }
                    }
                    Button("清空") {
                        for i in categoryDrafts.indices where categoryDrafts[i].kind == selectedCategoryTab {
                            categoryDrafts[i].isSelected = false
                        }
                    }
                    Spacer()
                }
                .balancedFont(size: 12.5)
                .foregroundStyle(BalancedPalette.secondary)
                .padding(.bottom, 4)

                VStack(spacing: 0) {
                    ForEach($categoryDrafts) { $draft in
                        if draft.kind == selectedCategoryTab {
                            OnboardingCategoryRow(draft: $draft)
                        }
                    }
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    // MARK: - 步骤 4: 命名与确认开账（透明展示资产负债与净资产）
    private var summaryStepView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("你填了 \(accountDrafts.filter { $0.isSelected && !$0.initialBalance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count) 个账户的余额。加起来应当等于你的净值——这是这张表唯一要说的话。")
                    .balancedFont(size: 12.5)
                    .foregroundStyle(BalancedPalette.meta)
                    .padding(.top, 2)
                    .padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 0) {
                    BalancedKeyRow(label: String(localized: "资产"), minorUnits: minorUnits(totalAssetBalance), currency: selectedCurrency)
                    BalancedKeyRow(label: String(localized: "负债"), minorUnits: minorUnits(totalLiabilityBalance), currency: selectedCurrency, color: totalLiabilityBalance > 0 ? BalancedPalette.expense : BalancedPalette.ink)
                    BalancedPalette.rule.frame(height: 1).padding(.top, 6)
                    BalancedKeyRow(label: String(localized: "净值"), minorUnits: minorUnits(netWorth), currency: selectedCurrency, isTotal: true, settle: true)
                }
                .balancedBand(lead: true)

                BalancedSectionLabel(text: String(localized: "将写入 accounts.bean"))
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(accountsBeanPreview)
                        .balancedMono(size: 11.5)
                        .foregroundStyle(BalancedPalette.secondary)
                        .lineSpacing(5)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .balancedBand()

                Text("余额会写成 balance 断言放在同一天。之后每次改动都要通过 bean-check 才会落盘。")
                    .balancedFont(size: 12.5)
                    .foregroundStyle(BalancedPalette.meta)
                    .padding(.top, 10)

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private func minorUnits(_ amount: Decimal) -> Int {
        NSDecimalNumber(decimal: amount * 100).intValue
    }

    /// A preview of the `open` directives the wizard will write — mirrors
    /// the `将写入 accounts.bean` band in d04, truncated to the selected
    /// accounts so the preview stays proportionate to what will be created.
    private var accountsBeanPreview: String {
        let lines = accountDrafts.filter(\.isSelected).prefix(6).map { draft in
            "2000-01-01 open \(draft.account) \(selectedCurrency)"
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 底部操作栏
    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if currentStep != .welcome {
                    Button("上一步") {
                        if let prev = Step(rawValue: currentStep.rawValue - 1) {
                            currentStep = prev
                        }
                    }
                    .buttonStyle(.balanced(.quiet))
                    .frame(width: 96)
                }

                Button(currentStep == .summary ? "创建账本" : "下一步") {
                    if currentStep == .summary {
                        confirmAndCreateLedger()
                    } else {
                        if let next = Step(rawValue: currentStep.rawValue + 1) {
                            currentStep = next
                        }
                    }
                }
                .buttonStyle(.balanced(.primary))
                .disabled(isCreating || (currentStep == .summary && ledgerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }

            if currentStep == .welcome {
                Button("我有已有账本？导入文件夹或从 Git 添加") {
                    dismiss()
                }
                .balancedFont(size: 12.5)
                .foregroundStyle(BalancedPalette.meta)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
        .background(BalancedPalette.page)
    }

    // MARK: - 创建账本执行逻辑
    private func confirmAndCreateLedger() {
        guard !isCreating else { return }
        isCreating = true

        let selectedAccounts = accountDrafts.filter(\.isSelected).map { draft in
            OnboardingAccountSelection(
                name: draft.name,
                account: draft.account,
                currency: selectedCurrency,
                initialBalance: draft.initialBalance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft.initialBalance,
                isLiability: draft.isLiability
            )
        }

        let selectedCategories = categoryDrafts.filter(\.isSelected).map { draft in
            OnboardingCategorySelection(
                name: draft.name,
                account: draft.account,
                currency: selectedCurrency
            )
        }

        Task {
            await session.createCustomLocalLedger(
                name: ledgerName.trimmingCharacters(in: .whitespacesAndNewlines),
                currency: selectedCurrency,
                accounts: selectedAccounts,
                categories: selectedCategories
            )
            isCreating = false
            if session.phase == .ready {
                dismiss()
            }
        }
    }

    // MARK: - 添加自定义账户弹窗
    private var addCustomAccountSheet: some View {
        NavigationStack {
            List {
                Section {
                    TextField("例如：招行二类卡、现金钱包", text: $customAccountName).balancedFont(size: 15)
                } header: { TerminalSectionLabel(text: String(localized: "账户名称")) }
                Section {
                    Picker("类型", selection: $customAccountCategory) {
                        ForEach(AccountTypeCategory.allCases) { cat in
                            Text(cat.title).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                } header: { TerminalSectionLabel(text: String(localized: "账户类型")) }
            }
            .scrollContentBackground(.hidden)
            .background(BalancedPalette.page)
            .navigationTitle("添加账户")
            .terminalNativeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingAddCustomAccount = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        let trimmed = customAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let path = BeancountNaming.buildAccountPath(
                            category: customAccountCategory,
                            preset: nil,
                            customName: trimmed,
                            detail: ""
                        )
                        let newDraft = AccountDraft(
                            id: UUID().uuidString,
                            name: trimmed,
                            account: path,
                            icon: customAccountCategory.defaultIcon,
                            category: customAccountCategory,
                            isSelected: true,
                            initialBalance: "",
                            isLiability: customAccountCategory.isLiability
                        )
                        accountDrafts.append(newDraft)
                        customAccountName = ""
                        showingAddCustomAccount = false
                    }
                    .disabled(customAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func currencySymbol(for currency: String) -> String {
        switch currency {
        case "CNY", "JPY": "¥"
        case "USD": "$"
        case "HKD": "HK$"
        case "EUR": "€"
        case "GBP": "£"
        default: currency
        }
    }
}

/// `.rail` — four equal 2px segments, `--ink` for a completed step and
/// `--rule-strong` for the rest. Replaces a numbered step indicator because it
/// says both where you are and how much is left.
private struct OnboardingRail: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { index in
                Rectangle()
                    .fill(index <= current ? BalancedPalette.ink : BalancedPalette.ruleStrong)
                    .frame(height: 2)
            }
        }
    }
}

/// `.imp .box` — a checkbox drawn as a rule-cornered square, paired with an
/// `.acct` path and the current/entered balance. Used by the account and
/// category checklists (d03).
private struct OnboardingCheckbox: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isOn ? BalancedPalette.ink : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .stroke(isOn ? BalancedPalette.ink : BalancedPalette.edge, lineWidth: 1)
                }
                .frame(width: 20, height: 20)
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(BalancedPalette.page)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

/// An `.imp row` — checkbox, title over `.acct` path, and the balance field
/// (or a dash when nothing is selected).
private struct OnboardingAccountRow: View {
    @Binding var draft: OnboardingWizardView.AccountDraft
    let currency: String
    let currencySymbol: String

    var body: some View {
        HStack(spacing: 12) {
            OnboardingCheckbox(isOn: draft.isSelected) { draft.isSelected.toggle() }
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.name)
                    .balancedFont(size: 15, weight: .text)
                    .foregroundStyle(draft.isSelected ? BalancedPalette.ink : BalancedPalette.meta)
                Text(draft.account).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
            }
            Spacer(minLength: 8)
            if draft.isSelected {
                HStack(spacing: 2) {
                    Text(currencySymbol).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    TextField(draft.isLiability ? "待还欠款" : "期初余额", text: $draft.initialBalance)
                        .keyboardType(.decimalPad)
                        .balancedFont(size: 13)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 76)
                }
            } else {
                Text("—").balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
    }
}

/// An `.imp row` for a category: checkbox, name, and sub-items as a one-line
/// `--ink-3` caption.
private struct OnboardingCategoryRow: View {
    @Binding var draft: OnboardingWizardView.CategoryDraft

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OnboardingCheckbox(isOn: draft.isSelected) { draft.isSelected.toggle() }
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(draft.name).balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink)
                    Spacer()
                    Text(draft.account).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                }
                if !draft.detail.isEmpty {
                    Text(draft.detail).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
    }
}
