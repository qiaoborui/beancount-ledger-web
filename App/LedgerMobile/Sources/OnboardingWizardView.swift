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
    @State private var ledgerName: String = "我的账本"
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
        AccountDraft(id: "wechat_lq", name: "微信零钱", account: "Assets:Wallet:WeChat:LingQian", icon: "message.fill", category: .wallet, isSelected: true, initialBalance: "", isLiability: false),
        AccountDraft(id: "alipay_bal", name: "支付宝余额", account: "Assets:Wallet:Alipay:Balance", icon: "creditcard.and.123", category: .wallet, isSelected: true, initialBalance: "", isLiability: false),
        AccountDraft(id: "alipay_yeb", name: "余额宝", account: "Assets:Wallet:Alipay:YuEBao", icon: "chart.line.uptrend.xyaxis", category: .wallet, isSelected: true, initialBalance: "", isLiability: false),
        AccountDraft(id: "wechat_lqt", name: "微信零钱通", account: "Assets:Wallet:WeChat:LingQianTong", icon: "arrow.triangle.swap", category: .wallet, isSelected: false, initialBalance: "", isLiability: false),
        AccountDraft(id: "wallet_unionpay", name: "云闪付", account: "Assets:Wallet:UnionPay", icon: "creditcard", category: .wallet, isSelected: false, initialBalance: "", isLiability: false),

        // 银行储蓄卡
        AccountDraft(id: "bank_cmb", name: "招商银行储蓄卡", account: "Assets:Bank:CMB", icon: "building.columns", category: .bank, isSelected: true, initialBalance: "", isLiability: false),
        AccountDraft(id: "bank_icbc", name: "工商银行储蓄卡", account: "Assets:Bank:ICBC", icon: "building.columns", category: .bank, isSelected: false, initialBalance: "", isLiability: false),
        AccountDraft(id: "bank_ccb", name: "建设银行储蓄卡", account: "Assets:Bank:CCB", icon: "building.columns", category: .bank, isSelected: false, initialBalance: "", isLiability: false),
        AccountDraft(id: "bank_boc", name: "中国银行储蓄卡", account: "Assets:Bank:BOC", icon: "building.columns", category: .bank, isSelected: false, initialBalance: "", isLiability: false),
        AccountDraft(id: "bank_abc", name: "农业银行储蓄卡", account: "Assets:Bank:ABC", icon: "building.columns", category: .bank, isSelected: false, initialBalance: "", isLiability: false),
        AccountDraft(id: "bank_comm", name: "交通银行储蓄卡", account: "Assets:Bank:COMM", icon: "building.columns", category: .bank, isSelected: false, initialBalance: "", isLiability: false),
        AccountDraft(id: "bank_psbc", name: "邮政储蓄储蓄卡", account: "Assets:Bank:PSBC", icon: "building.columns", category: .bank, isSelected: false, initialBalance: "", isLiability: false),

        // 信用卡与信用消费
        AccountDraft(id: "credit_cmb", name: "招行信用卡", account: "Liabilities:CreditCard:CMB", icon: "creditcard.fill", category: .credit, isSelected: false, initialBalance: "", isLiability: true),
        AccountDraft(id: "credit_icbc", name: "工行信用卡", account: "Liabilities:CreditCard:ICBC", icon: "creditcard.fill", category: .credit, isSelected: false, initialBalance: "", isLiability: true),
        AccountDraft(id: "credit_huabei", name: "蚂蚁花呗", account: "Liabilities:CreditCard:Huabei", icon: "hand.tap", category: .credit, isSelected: false, initialBalance: "", isLiability: true),
        AccountDraft(id: "credit_baitiao", name: "京东白条", account: "Liabilities:CreditCard:Baitiao", icon: "cart.fill", category: .credit, isSelected: false, initialBalance: "", isLiability: true),
        AccountDraft(id: "credit_meituan", name: "美团月付", account: "Liabilities:CreditCard:MeituanYuefu", icon: "fork.knife", category: .credit, isSelected: false, initialBalance: "", isLiability: true),

        // 现金
        AccountDraft(id: "cash_cny", name: "人民币现金", account: "Assets:Cash:CNY", icon: "banknote", category: .cash, isSelected: true, initialBalance: "", isLiability: false)
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
        let subnames = section.items.map(\.name).joined(separator: "、")
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
                // 顶部步骤进度条
                progressBar
                    .padding(.horizontal, LedgerSpacing.lg)
                    .padding(.top, LedgerSpacing.sm)

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
            .background(LedgerPalette.canvas.ignoresSafeArea())
            .navigationTitle(navigationTitleForCurrentStep)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isCreating)
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
                        VStack(spacing: LedgerSpacing.md) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("正在生成并校验账本...")
                                .font(.subheadline)
                                .foregroundStyle(LedgerPalette.ink)
                        }
                        .padding(LedgerSpacing.xxl)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }
    }

    // MARK: - 顶部步骤进度条
    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(step.rawValue <= currentStep.rawValue ? LedgerPalette.cobalt : LedgerPalette.line)
                    .frame(height: 4)
            }
        }
    }

    private var navigationTitleForCurrentStep: String {
        switch currentStep {
        case .welcome: "新手向导"
        case .accounts: "选择常用账户 (1/3)"
        case .categories: "选择记账分类 (2/3)"
        case .summary: "完成开账 (3/3)"
        }
    }

    // MARK: - 步骤 1: 欢迎与介绍
    private var welcomeStepView: some View {
        ScrollView {
            VStack(spacing: LedgerSpacing.xl) {
                // 图标 Hero
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.blue.opacity(0.15), Color.indigo.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 96, height: 96)
                    Image(systemName: "book.pages.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(LedgerPalette.cobalt)
                }
                .padding(.top, LedgerSpacing.xl)

                VStack(spacing: LedgerSpacing.xs) {
                    Text("欢迎使用个人账本")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text("基于 Beancount 专业复式记账\n数据 100% 留存在您的设备，隐私绝对安全")
                        .font(.subheadline)
                        .foregroundStyle(LedgerPalette.secondary)
                        .multilineTextAlignment(.center)
                }

                // 核心价值卡片
                VStack(spacing: LedgerSpacing.md) {
                    featureCard(
                        icon: "lock.shield.fill",
                        color: .green,
                        title: "100% 本地离线掌控",
                        desc: "无需注册账号，无中心服务器抓取，账本文件直接存放在本机，由您完全拥有。"
                    )
                    featureCard(
                        icon: "sparkles",
                        color: .orange,
                        title: "告别复杂代码，向导即开即用",
                        desc: "自动预置微信、支付宝、银行储蓄卡与高频生活分类，像普通记账 App 一样自然顺手。"
                    )
                    featureCard(
                        icon: "chart.pie.fill",
                        color: .blue,
                        title: "复式记账，资金流向一清二楚",
                        desc: "每笔交易借贷平衡，资产、负债、净资产与收支报表自动计算，杜绝糊涂账。"
                    )
                }
                .padding(.horizontal, LedgerSpacing.md)

                Spacer(minLength: LedgerSpacing.xl)
            }
            .padding(.bottom, LedgerSpacing.xl)
        }
    }

    private func featureCard(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: LedgerSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(LedgerPalette.ink)
                Text(desc)
                    .font(.footnote)
                    .foregroundStyle(LedgerPalette.secondary)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
        .padding(LedgerSpacing.md)
        .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
    }

    // MARK: - 步骤 2: 常用账户与期初余额（分组清晰）
    private var accountsStepView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LedgerSpacing.lg) {
                VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
                    Text("选择日常资金账户")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text("勾选您平时的支付钱包、储蓄卡及信用卡，右侧可录入当前大概余额（后续随时可修改）：")
                        .font(.footnote)
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .padding(.horizontal, LedgerSpacing.md)
                .padding(.top, LedgerSpacing.sm)

                // 币种选择器
                HStack {
                    Text("账本基础货币")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(LedgerPalette.ink)
                    Spacer()
                    Picker("基础货币", selection: $selectedCurrency) {
                        ForEach(AccountPresets.commonCurrencies, id: \.self) { cur in
                            Text(cur).tag(cur)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(.horizontal, LedgerSpacing.md)
                .padding(.vertical, LedgerSpacing.sm)
                .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: LedgerRadius.sm))
                .padding(.horizontal, LedgerSpacing.md)

                // ── 1. 移动支付与电子钱包 ──
                accountSectionHeader(title: "移动支付 & 电子钱包", icon: "iphone")
                VStack(spacing: LedgerSpacing.sm) {
                    ForEach($accountDrafts) { $draft in
                        if draft.category == .wallet {
                            accountRow(draft: $draft)
                        }
                    }
                }
                .padding(.horizontal, LedgerSpacing.md)

                // ── 2. 银行储蓄卡 ──
                HStack {
                    accountSectionHeader(title: "银行储蓄卡", icon: "building.columns")
                    Spacer()
                    Button {
                        showingInstitutionPicker = true
                    } label: {
                        HStack(spacing: 2) {
                            Text("更多银行...")
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(LedgerPalette.cobalt)
                    }
                    .padding(.trailing, LedgerSpacing.md)
                }

                VStack(spacing: LedgerSpacing.sm) {
                    ForEach($accountDrafts) { $draft in
                        if draft.category == .bank {
                            accountRow(draft: $draft)
                        }
                    }
                }
                .padding(.horizontal, LedgerSpacing.md)

                // ── 3. 信用卡与消费信贷 ──
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        accountSectionHeader(title: "信用卡与信用消费 (负债)", icon: "creditcard.fill")
                        Spacer()
                        Button {
                            showingInstitutionPicker = true
                        } label: {
                            HStack(spacing: 2) {
                                Text("更多信贷...")
                                Image(systemName: "chevron.right")
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(LedgerPalette.cobalt)
                        }
                        .padding(.trailing, LedgerSpacing.md)
                    }

                    // 友好提示卡片：解释欠款 vs 额度
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                            .padding(.top, 1)
                        Text("💡 信用卡填的是当前待还欠款（若已还清请留空）。切勿填写信用总额度（如5万元额度），避免净资产被扣减。")
                            .font(.caption2)
                            .foregroundStyle(LedgerPalette.secondary)
                            .lineSpacing(2)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, LedgerSpacing.md)
                }

                VStack(spacing: LedgerSpacing.sm) {
                    ForEach($accountDrafts) { $draft in
                        if draft.isLiability {
                            accountRow(draft: $draft)
                        }
                    }
                }
                .padding(.horizontal, LedgerSpacing.md)

                // ── 4. 现金账户 ──
                accountSectionHeader(title: "现钞与备用金", icon: "banknote")
                VStack(spacing: LedgerSpacing.sm) {
                    ForEach($accountDrafts) { $draft in
                        if draft.category == .cash {
                            accountRow(draft: $draft)
                        }
                    }
                }
                .padding(.horizontal, LedgerSpacing.md)

                // ── 5. 自定义账户添加按钮 ──
                Button {
                    showingAddCustomAccount = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("添加其他自定义账户...")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LedgerPalette.cobalt)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LedgerSpacing.sm)
                }
                .padding(.horizontal, LedgerSpacing.md)

                Spacer(minLength: LedgerSpacing.xl)
            }
            .padding(.bottom, LedgerSpacing.xl)
        }
    }

    private func accountSectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(LedgerPalette.cobalt)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LedgerPalette.ink)
        }
        .padding(.horizontal, LedgerSpacing.md)
        .padding(.top, LedgerSpacing.xs)
    }

    private func accountRow(draft: Binding<AccountDraft>) -> some View {
        HStack(spacing: LedgerSpacing.md) {
            Button {
                draft.wrappedValue.isSelected.toggle()
            } label: {
                HStack(spacing: LedgerSpacing.md) {
                    Image(systemName: draft.wrappedValue.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(draft.wrappedValue.isSelected ? LedgerPalette.cobalt : LedgerPalette.secondary)

                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(categoryThemeColor(draft.wrappedValue.category).opacity(0.12))
                            .frame(width: 32, height: 32)
                        Image(systemName: draft.wrappedValue.icon)
                            .font(.system(size: 15))
                            .foregroundStyle(categoryThemeColor(draft.wrappedValue.category))
                    }

                    Text(draft.wrappedValue.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(LedgerPalette.ink)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if draft.wrappedValue.isSelected {
                HStack(spacing: 4) {
                    Text(currencySymbol(for: selectedCurrency))
                        .font(.footnote)
                        .foregroundStyle(LedgerPalette.secondary)
                    TextField(draft.wrappedValue.isLiability ? "待还欠款" : "期初余额", text: draft.initialBalance)
                        .keyboardType(.decimalPad)
                        .font(.subheadline.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(width: 88)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(LedgerPalette.canvas, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(LedgerSpacing.md)
        .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
    }

    // MARK: - 步骤 3: 丰富全面的收支分类
    private var categoriesStepView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
                    Text("选择日常收支分类")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text("提供标准丰富的生活收支分类体系，按需勾选开启：")
                        .font(.footnote)
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .padding(.horizontal, LedgerSpacing.md)
                .padding(.top, LedgerSpacing.sm)

                // 支出/收入选项卡切换
                let selectedExpenseCount = categoryDrafts.filter { $0.kind == .expense && $0.isSelected }.count
                let selectedIncomeCount = categoryDrafts.filter { $0.kind == .income && $0.isSelected }.count

                Picker("分类类型", selection: $selectedCategoryTab) {
                    Text("支出分类 (\(selectedExpenseCount) 已选)").tag(CategoryKind.expense)
                    Text("收入分类 (\(selectedIncomeCount) 已选)").tag(CategoryKind.income)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, LedgerSpacing.md)

                // 快捷操作按钮
                HStack {
                    Button("推荐常用") {
                        for i in categoryDrafts.indices {
                            let item = categoryDrafts[i]
                            categoryDrafts[i].isSelected = ["exp_food", "exp_daily", "exp_transport", "exp_home", "exp_fun", "exp_health", "inc_career", "inc_invest"].contains(item.id)
                        }
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(LedgerPalette.cobalt)

                    Text("|").font(.caption).foregroundStyle(.tertiary)

                    Button("当前大类全选") {
                        for i in categoryDrafts.indices where categoryDrafts[i].kind == selectedCategoryTab {
                            categoryDrafts[i].isSelected = true
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(LedgerPalette.cobalt)

                    Text("|").font(.caption).foregroundStyle(.tertiary)

                    Button("当前大类清空") {
                        for i in categoryDrafts.indices where categoryDrafts[i].kind == selectedCategoryTab {
                            categoryDrafts[i].isSelected = false
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(LedgerPalette.secondary)

                    Spacer()
                }
                .padding(.horizontal, LedgerSpacing.md)

                // 分类卡片列表
                VStack(spacing: LedgerSpacing.sm) {
                    ForEach($categoryDrafts) { $draft in
                        if draft.kind == selectedCategoryTab {
                            categoryCardRow(draft: $draft)
                        }
                    }
                }
                .padding(.horizontal, LedgerSpacing.md)

                Spacer(minLength: LedgerSpacing.xl)
            }
            .padding(.bottom, LedgerSpacing.xl)
        }
    }

    private func categoryCardRow(draft: Binding<CategoryDraft>) -> some View {
        Button {
            draft.wrappedValue.isSelected.toggle()
        } label: {
            HStack(alignment: .top, spacing: LedgerSpacing.md) {
                Image(systemName: draft.wrappedValue.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(draft.wrappedValue.isSelected ? (draft.wrappedValue.kind == .income ? LedgerPalette.income : LedgerPalette.cobalt) : LedgerPalette.secondary)
                    .padding(.top, 2)

                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((draft.wrappedValue.kind == .income ? LedgerPalette.income : Color.orange).opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: draft.wrappedValue.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(draft.wrappedValue.kind == .income ? LedgerPalette.income : Color.orange)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(draft.wrappedValue.name)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(LedgerPalette.ink)
                        Spacer()
                        Text(draft.wrappedValue.account)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LedgerPalette.secondary)
                    }

                    if !draft.wrappedValue.detail.isEmpty {
                        Text(draft.wrappedValue.detail)
                            .font(.caption2)
                            .foregroundStyle(LedgerPalette.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(LedgerSpacing.md)
            .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 步骤 4: 命名与确认开账（透明展示资产负债与净资产）
    private var summaryStepView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LedgerSpacing.lg) {
                VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
                    Text("即将开启您的新账本")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text("核对账户资产与负债配置，确认后即可创建专属账本：")
                        .font(.footnote)
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .padding(.horizontal, LedgerSpacing.md)
                .padding(.top, LedgerSpacing.sm)

                // 账本名称
                VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
                    Text("账本名称")
                        .font(.footnote)
                        .foregroundStyle(LedgerPalette.secondary)
                    TextField("账本名称", text: $ledgerName)
                        .font(.body.weight(.medium))
                        .padding(LedgerSpacing.md)
                        .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: LedgerRadius.sm))
                }
                .padding(.horizontal, LedgerSpacing.md)

                // 财务期初平衡卡片（直观展示资产、待还负债与期初净资产）
                VStack(spacing: LedgerSpacing.sm) {
                    HStack {
                        Text("期初财务概况")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LedgerPalette.secondary)
                        Spacer()
                        Text("自动通过 Equity:Opening-Balances 配平")
                            .font(.caption2)
                            .foregroundStyle(LedgerPalette.secondary)
                    }

                    HStack {
                        financialMetric(
                            title: "初始总资产",
                            amount: totalAssetBalance,
                            currency: selectedCurrency,
                            color: LedgerPalette.income
                        )
                        Divider()
                        financialMetric(
                            title: "待还总负债",
                            amount: totalLiabilityBalance,
                            currency: selectedCurrency,
                            color: totalLiabilityBalance > 0 ? Color.orange : LedgerPalette.secondary
                        )
                        Divider()
                        financialMetric(
                            title: "期初净资产",
                            amount: netWorth,
                            currency: selectedCurrency,
                            color: LedgerPalette.cobalt
                        )
                    }
                    .frame(height: 60)
                }
                .padding(LedgerSpacing.md)
                .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: LedgerRadius.md))
                .padding(.horizontal, LedgerSpacing.md)

                // 统计卡片
                let selectedAccountCount = accountDrafts.filter(\.isSelected).count
                let selectedCategoryCount = categoryDrafts.filter(\.isSelected).count

                HStack {
                    summaryStatItem(title: "主要币种", value: selectedCurrency, icon: "dollarsign.circle.fill", color: .blue)
                    Divider()
                    summaryStatItem(title: "初始账户", value: "\(selectedAccountCount) 个", icon: "creditcard.fill", color: .green)
                    Divider()
                    summaryStatItem(title: "记账分类", value: "\(selectedCategoryCount) 个", icon: "tag.fill", color: .orange)
                }
                .frame(height: 65)
                .padding(LedgerSpacing.md)
                .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: LedgerRadius.md))
                .padding(.horizontal, LedgerSpacing.md)

                // 本地存储与模板保障说明
                VStack(spacing: LedgerSpacing.sm) {
                    featureBenefitRow(
                        icon: "doc.text.fill",
                        title: "已预置账单导入模板",
                        desc: "已为您准备好微信与支付宝的 imports/*.yaml 规则模板，后续直接导入账单即可智能匹配。"
                    )
                    featureBenefitRow(
                        icon: "lock.shield.fill",
                        title: "100% 本地安全掌控",
                        desc: "所有文件存放在本机沙盒，无需配置 Git 亦可畅快记账，后续随时可导出备份。"
                    )
                }
                .padding(.horizontal, LedgerSpacing.md)

                Spacer(minLength: LedgerSpacing.xl)
            }
            .padding(.bottom, LedgerSpacing.xl)
        }
    }

    private func financialMetric(title: String, amount: Decimal, currency: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(LedgerPalette.secondary)
            Text("\(currencySymbol(for: currency))\(amount as NSDecimalNumber, formatter: metricFormatter)")
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var metricFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }

    private func featureBenefitRow(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: LedgerSpacing.md) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(LedgerPalette.cobalt)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LedgerPalette.ink)
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(LedgerPalette.secondary)
                    .lineSpacing(2)
            }
            Spacer()
        }
        .padding(LedgerSpacing.md)
        .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: LedgerRadius.sm))
    }

    private func summaryStatItem(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LedgerPalette.ink)
            Text(title)
                .font(.caption2)
                .foregroundStyle(LedgerPalette.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 底部操作栏
    private var bottomBar: some View {
        VStack(spacing: LedgerSpacing.sm) {
            HStack(spacing: LedgerSpacing.md) {
                if currentStep != .welcome {
                    Button {
                        if let prev = Step(rawValue: currentStep.rawValue - 1) {
                            currentStep = prev
                        }
                    } label: {
                        Text("上一步")
                            .font(.body.weight(.medium))
                            .foregroundStyle(LedgerPalette.secondary)
                            .frame(width: 80)
                            .padding(.vertical, 14)
                            .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: LedgerRadius.md))
                    }
                }

                Button {
                    if currentStep == .summary {
                        confirmAndCreateLedger()
                    } else {
                        if let next = Step(rawValue: currentStep.rawValue + 1) {
                            currentStep = next
                        }
                    }
                } label: {
                    Text(currentStep == .summary ? "立即开启记账" : "下一步")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(LedgerPalette.cobalt, in: RoundedRectangle(cornerRadius: LedgerRadius.md))
                }
                .disabled(isCreating || (currentStep == .summary && ledgerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }

            if currentStep == .welcome {
                Button("我有已有账本？导入文件夹或从 Git 添加") {
                    dismiss()
                }
                .font(.footnote)
                .foregroundStyle(LedgerPalette.secondary)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, LedgerSpacing.lg)
        .padding(.vertical, LedgerSpacing.md)
        .background(LedgerPalette.panel)
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
            Form {
                Section("账户名称") {
                    TextField("例如：招行二类卡、现金钱包", text: $customAccountName)
                }
                Section("账户类型") {
                    Picker("类型", selection: $customAccountCategory) {
                        ForEach(AccountTypeCategory.allCases) { cat in
                            Label(cat.title, systemImage: cat.defaultIcon).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .navigationTitle("添加账户")
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

    private func categoryThemeColor(_ category: AccountTypeCategory) -> Color {
        switch category {
        case .bank: .blue
        case .wallet: .green
        case .credit: .orange
        case .cash: .brown
        case .wealth: .purple
        case .loan: .red
        case .receivable: .teal
        }
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
