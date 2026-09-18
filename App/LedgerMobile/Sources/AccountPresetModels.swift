import Foundation

/// 账户大类
public enum AccountTypeCategory: String, CaseIterable, Identifiable, Sendable {
    case bank = "bank"
    case wallet = "wallet"
    case credit = "credit"
    case cash = "cash"
    case wealth = "wealth"
    case loan = "loan"
    case receivable = "receivable"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bank: "银行储蓄卡"
        case .wallet: "电子钱包"
        case .credit: "信用卡/信用额度"
        case .cash: "现金账户"
        case .wealth: "投资理财"
        case .loan: "贷款/借款"
        case .receivable: "应收款项"
        }
    }

    public var rootPrefix: String {
        switch self {
        case .bank: "Assets:Bank"
        case .wallet: "Assets:Wallet"
        case .credit: "Liabilities:CreditCard"
        case .cash: "Assets:Cash"
        case .wealth: "Assets:Investment"
        case .loan: "Liabilities:Loan"
        case .receivable: "Assets:Receivable"
        }
    }

    public var defaultIcon: String {
        switch self {
        case .bank: "building.columns"
        case .wallet: "iphone"
        case .credit: "creditcard"
        case .cash: "banknote"
        case .wealth: "chart.line.uptrend.xyaxis"
        case .loan: "percent"
        case .receivable: "arrow.uturn.backward"
        }
    }

    public var isLiability: Bool {
        self == .credit || self == .loan
    }
}

/// 预设机构/账户项
public struct AccountPresetItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let category: AccountTypeCategory
    public let code: String
    public let icon: String
    public let suggestedCurrency: String?

    public init(
        id: String,
        name: String,
        category: AccountTypeCategory,
        code: String,
        icon: String,
        suggestedCurrency: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.code = code
        self.icon = icon
        self.suggestedCurrency = suggestedCurrency
    }

    public var defaultAccount: String {
        "\(category.rootPrefix):\(code)"
    }
}

/// 常用中国本土账户预设列表
public enum AccountPresets {
    public static let commonCurrencies = ["CNY", "USD", "HKD", "JPY", "EUR", "GBP", "AUD", "CAD", "SGD"]

    public static let presets: [AccountPresetItem] = [
        // ── 银行卡 ──
        AccountPresetItem(id: "bank_cmb", name: "招商银行", category: .bank, code: "CMB", icon: "building.columns"),
        AccountPresetItem(id: "bank_icbc", name: "工商银行", category: .bank, code: "ICBC", icon: "building.columns"),
        AccountPresetItem(id: "bank_ccb", name: "建设银行", category: .bank, code: "CCB", icon: "building.columns"),
        AccountPresetItem(id: "bank_boc", name: "中国银行", category: .bank, code: "BOC", icon: "building.columns"),
        AccountPresetItem(id: "bank_abc", name: "农业银行", category: .bank, code: "ABC", icon: "building.columns"),
        AccountPresetItem(id: "bank_comm", name: "交通银行", category: .bank, code: "COMM", icon: "building.columns"),
        AccountPresetItem(id: "bank_spdb", name: "浦发银行", category: .bank, code: "SPDB", icon: "building.columns"),
        AccountPresetItem(id: "bank_citic", name: "中信银行", category: .bank, code: "CITIC", icon: "building.columns"),
        AccountPresetItem(id: "bank_cmbc", name: "民生银行", category: .bank, code: "CMBC", icon: "building.columns"),
        AccountPresetItem(id: "bank_cib", name: "兴业银行", category: .bank, code: "CIB", icon: "building.columns"),
        AccountPresetItem(id: "bank_pab", name: "平安银行", category: .bank, code: "PAB", icon: "building.columns"),
        AccountPresetItem(id: "bank_psbc", name: "邮政储蓄", category: .bank, code: "PSBC", icon: "building.columns"),
        AccountPresetItem(id: "bank_cgb", name: "广发银行", category: .bank, code: "CGB", icon: "building.columns"),
        AccountPresetItem(id: "bank_ceb", name: "光大银行", category: .bank, code: "CEB", icon: "building.columns"),
        AccountPresetItem(id: "bank_hxb", name: "华夏银行", category: .bank, code: "HXB", icon: "building.columns"),
        AccountPresetItem(id: "bank_bob", name: "北京银行", category: .bank, code: "BOB", icon: "building.columns"),
        AccountPresetItem(id: "bank_bos", name: "上海银行", category: .bank, code: "BOS", icon: "building.columns"),
        AccountPresetItem(id: "bank_nbcb", name: "宁波银行", category: .bank, code: "NBCB", icon: "building.columns"),
        AccountPresetItem(id: "bank_cmbhk", name: "招商永隆(香港)", category: .bank, code: "CMBHK", icon: "building.columns", suggestedCurrency: "HKD"),
        AccountPresetItem(id: "bank_hsbc", name: "汇丰银行", category: .bank, code: "HSBC", icon: "building.columns", suggestedCurrency: "HKD"),
        AccountPresetItem(id: "bank_scb", name: "渣打银行", category: .bank, code: "SCB", icon: "building.columns", suggestedCurrency: "HKD"),

        // ── 电子钱包 ──
        AccountPresetItem(id: "wallet_wechat", name: "微信零钱", category: .wallet, code: "WeChat:LingQian", icon: "message.fill"),
        AccountPresetItem(id: "wallet_wechat_lqt", name: "微信零钱通", category: .wallet, code: "WeChat:LingQianTong", icon: "arrow.triangle.swap"),
        AccountPresetItem(id: "wallet_alipay", name: "支付宝余额", category: .wallet, code: "Alipay:Balance", icon: "creditcard.and.123"),
        AccountPresetItem(id: "wallet_alipay_yeb", name: "支付宝余额宝", category: .wallet, code: "Alipay:YuEBao", icon: "chart.line.uptrend.xyaxis"),
        AccountPresetItem(id: "wallet_apple_cash", name: "Apple Cash", category: .wallet, code: "AppleCash", icon: "applelogo", suggestedCurrency: "USD"),
        AccountPresetItem(id: "wallet_paypal", name: "PayPal", category: .wallet, code: "PayPal", icon: "globe", suggestedCurrency: "USD"),
        AccountPresetItem(id: "wallet_octopus", name: "八达通", category: .wallet, code: "Octopus", icon: "wave.3.forward", suggestedCurrency: "HKD"),
        AccountPresetItem(id: "wallet_unionpay", name: "云闪付", category: .wallet, code: "UnionPay", icon: "creditcard"),

        // ── 信用卡 ──
        AccountPresetItem(id: "credit_cmb", name: "招行信用卡", category: .credit, code: "CMB", icon: "creditcard.fill"),
        AccountPresetItem(id: "credit_icbc", name: "工行信用卡", category: .credit, code: "ICBC", icon: "creditcard.fill"),
        AccountPresetItem(id: "credit_ccb", name: "建行信用卡", category: .credit, code: "CCB", icon: "creditcard.fill"),
        AccountPresetItem(id: "credit_boc", name: "中行信用卡", category: .credit, code: "BOC", icon: "creditcard.fill"),
        AccountPresetItem(id: "credit_comm", name: "交行信用卡", category: .credit, code: "COMM", icon: "creditcard.fill"),
        AccountPresetItem(id: "credit_cgb", name: "广发信用卡", category: .credit, code: "CGB", icon: "creditcard.fill"),
        AccountPresetItem(id: "credit_spdb", name: "浦发信用卡", category: .credit, code: "SPDB", icon: "creditcard.fill"),
        AccountPresetItem(id: "credit_citic", name: "中信信用卡", category: .credit, code: "CITIC", icon: "creditcard.fill"),
        AccountPresetItem(id: "credit_pab", name: "平安信用卡", category: .credit, code: "PAB", icon: "creditcard.fill"),
        AccountPresetItem(id: "credit_huabei", name: "蚂蚁花呗", category: .credit, code: "Huabei", icon: "hand.tap"),
        AccountPresetItem(id: "credit_baitiao", name: "京东白条", category: .credit, code: "Baitiao", icon: "cart.fill"),
        AccountPresetItem(id: "credit_meituan", name: "美团月付", category: .credit, code: "MeituanYuefu", icon: "fork.knife"),

        // ── 现金 ──
        AccountPresetItem(id: "cash_cny", name: "人民币现金", category: .cash, code: "CNY", icon: "banknote"),
        AccountPresetItem(id: "cash_petty", name: "备用小金库", category: .cash, code: "PettyCash", icon: "tray.full"),

        // ── 投资理财 ──
        AccountPresetItem(id: "wealth_broker", name: "A股证券账户", category: .wealth, code: "Brokerage", icon: "chart.xyaxis.line"),
        AccountPresetItem(id: "wealth_fund", name: "公募基金账户", category: .wealth, code: "MutualFund", icon: "chart.pie.fill"),
        AccountPresetItem(id: "wealth_pension", name: "个人养老金", category: .wealth, code: "Pension", icon: "umbrella.fill"),
        AccountPresetItem(id: "wealth_crypto", name: "加密资产钱包", category: .wealth, code: "Crypto", icon: "bitcoinsign.circle", suggestedCurrency: "USD"),

        // ── 贷款 ──
        AccountPresetItem(id: "loan_mortgage", name: "住房按揭贷款", category: .loan, code: "Mortgage", icon: "house.fill"),
        AccountPresetItem(id: "loan_personal", name: "个人消费分期", category: .loan, code: "ConsumerLoan", icon: "percent"),

        // ── 应收 ──
        AccountPresetItem(id: "rec_lent", name: "借出款项", category: .receivable, code: "Lent", icon: "person.line.dotted.person"),
        AccountPresetItem(id: "rec_deposit", name: "押金/保证金", category: .receivable, code: "Deposit", icon: "lock.shield"),
        AccountPresetItem(id: "rec_reimbursement", name: "公司代垫报销", category: .receivable, code: "Reimbursement", icon: "doc.text")
    ]

    public static func presets(for category: AccountTypeCategory) -> [AccountPresetItem] {
        presets.filter { $0.category == category }
    }
}

/// 收支分类大类与子类预设
public enum CategoryKind: String, CaseIterable, Identifiable, Sendable {
    case expense = "Expenses"
    case income = "Income"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .expense: "支出分类"
        case .income: "收入分类"
        }
    }
}

public struct CategorySectionPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let code: String
    public let kind: CategoryKind
    public let icon: String
    public let items: [CategoryItemPreset]

    public var rootAccount: String {
        "\(kind.rawValue):\(code)"
    }
}

public struct CategoryItemPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let code: String
    public let icon: String

    public init(id: String, name: String, code: String, icon: String) {
        self.id = id
        self.name = name
        self.code = code
        self.icon = icon
    }
}

public enum CategoryPresets {
    public static let sections: [CategorySectionPreset] = [
        // ── 支出分类 ──
        CategorySectionPreset(id: "exp_food", name: "餐饮美食", code: "Food", kind: .expense, icon: "fork.knife", items: [
            CategoryItemPreset(id: "food_dining", name: "堂食餐饮", code: "Dining", icon: "fork.knife"),
            CategoryItemPreset(id: "food_takeaway", name: "外卖订餐", code: "Takeaway", icon: "takeoutbag.and.cup.and.straw"),
            CategoryItemPreset(id: "food_groceries", name: "买菜食材", code: "Groceries", icon: "carrot.fill"),
            CategoryItemPreset(id: "food_coffee", name: "咖啡奶茶", code: "Coffee", icon: "cup.and.saucer.fill"),
            CategoryItemPreset(id: "food_snacks", name: "零食水果", code: "Snacks", icon: "birthday.cake.fill")
        ]),
        CategorySectionPreset(id: "exp_home", name: "居家生活", code: "Home", kind: .expense, icon: "house.fill", items: [
            CategoryItemPreset(id: "home_rent", name: "房屋租金", code: "Rent", icon: "house"),
            CategoryItemPreset(id: "home_utilities", name: "水电燃气", code: "Utilities", icon: "bolt.fill"),
            CategoryItemPreset(id: "home_daily", name: "日用百货", code: "DailyGoods", icon: "basket.fill"),
            CategoryItemPreset(id: "home_property", name: "物业维修", code: "Maintenance", icon: "wrench.and.screwdriver.fill")
        ]),
        CategorySectionPreset(id: "exp_transport", name: "交通出行", code: "Transport", kind: .expense, icon: "car.fill", items: [
            CategoryItemPreset(id: "trans_public", name: "公交地铁", code: "Public", icon: "tram.fill"),
            CategoryItemPreset(id: "trans_taxi", name: "出租打车", code: "Taxi", icon: "car.side.fill"),
            CategoryItemPreset(id: "trans_fuel", name: "加油充电", code: "Fuel", icon: "fuelpump.fill"),
            CategoryItemPreset(id: "trans_parking", name: "停车路桥", code: "Parking", icon: "parkingsign"),
            CategoryItemPreset(id: "trans_flight", name: "机票火车", code: "Travel", icon: "airplane")
        ]),
        CategorySectionPreset(id: "exp_shopping", name: "购物百货", code: "Shopping", kind: .expense, icon: "bag.fill", items: [
            CategoryItemPreset(id: "shop_clothing", name: "服饰鞋包", code: "Clothing", icon: "tshirt.fill"),
            CategoryItemPreset(id: "shop_digital", name: "数码科技", code: "Electronics", icon: "laptopcomputer"),
            CategoryItemPreset(id: "shop_beauty", name: "美妆个护", code: "Beauty", icon: "sparkles")
        ]),
        CategorySectionPreset(id: "exp_fun", name: "休闲娱乐", code: "Entertainment", kind: .expense, icon: "gamecontroller.fill", items: [
            CategoryItemPreset(id: "fun_leisure", name: "休闲玩乐", code: "Leisure", icon: "film.fill"),
            CategoryItemPreset(id: "fun_games", name: "游戏消费", code: "Games", icon: "gamecontroller"),
            CategoryItemPreset(id: "fun_subs", name: "影音会员订阅", code: "Subscriptions", icon: "play.rectangle.fill"),
            CategoryItemPreset(id: "fun_sports", name: "运动健身", code: "Fitness", icon: "figure.run")
        ]),
        CategorySectionPreset(id: "exp_health", name: "医疗健康", code: "Health", kind: .expense, icon: "cross.case.fill", items: [
            CategoryItemPreset(id: "health_med", name: "药品门诊", code: "Medical", icon: "pills.fill"),
            CategoryItemPreset(id: "health_checkup", name: "体检疫苗", code: "Checkup", icon: "heart.text.square.fill")
        ]),
        CategorySectionPreset(id: "exp_social", name: "人情社交", code: "Social", kind: .expense, icon: "person.2.fill", items: [
            CategoryItemPreset(id: "soc_gift", name: "礼金红包", code: "Gifts", icon: "gift.fill"),
            CategoryItemPreset(id: "soc_treat", name: "聚会请客", code: "Treats", icon: "wineglass.fill")
        ]),
        CategorySectionPreset(id: "exp_other", name: "其他支出", code: "Other", kind: .expense, icon: "ellipsis.circle.fill", items: [
            CategoryItemPreset(id: "other_fees", name: "手续费税费", code: "Fees", icon: "doc.plaintext"),
            CategoryItemPreset(id: "other_misc", name: "杂项开销", code: "Misc", icon: "questionmark.circle")
        ]),

        // ── 收入分类 ──
        CategorySectionPreset(id: "inc_career", name: "职业薪酬", code: "Career", kind: .income, icon: "briefcase.fill", items: [
            CategoryItemPreset(id: "career_salary", name: "工资薪金", code: "Salary", icon: "banknote.fill"),
            CategoryItemPreset(id: "career_bonus", name: "年终奖金", code: "Bonus", icon: "dollarsign.circle.fill"),
            CategoryItemPreset(id: "career_freelance", name: "副业兼职", code: "Freelance", icon: "laptopcomputer.and.ipad")
        ]),
        CategorySectionPreset(id: "inc_invest", name: "资本理财", code: "Investment", kind: .income, icon: "chart.line.uptrend.xyaxis", items: [
            CategoryItemPreset(id: "invest_interest", name: "存款利息", code: "Interest", icon: "percent"),
            CategoryItemPreset(id: "invest_dividend", name: "股息分红", code: "Dividends", icon: "chart.pie.fill"),
            CategoryItemPreset(id: "invest_rental", name: "房租收入", code: "Rental", icon: "house.fill")
        ]),
        CategorySectionPreset(id: "inc_other", name: "其他收入", code: "Other", kind: .income, icon: "gift.fill", items: [
            CategoryItemPreset(id: "other_redpacket", name: "人情红包", code: "Gifts", icon: "envelope.fill"),
            CategoryItemPreset(id: "other_refund", name: "退税返现", code: "Refund", icon: "arrow.counterclockwise")
        ])
    ]

    public static func sections(for kind: CategoryKind) -> [CategorySectionPreset] {
        sections.filter { $0.kind == kind }
    }
}

/// Beancount 账户命名与拼音生成引擎
public enum BeancountNaming {
    private static let knownAliasList: [(key: String, code: String)] = [
        ("招商银行", "CMB"), ("工商银行", "ICBC"), ("建设银行", "CCB"), ("中国银行", "BOC"),
        ("农业银行", "ABC"), ("交通银行", "COMM"), ("浦发银行", "SPDB"), ("中信银行", "CITIC"),
        ("民生银行", "CMBC"), ("兴业银行", "CIB"), ("平安银行", "PAB"), ("邮政储蓄", "PSBC"),
        ("广发银行", "CGB"), ("光大银行", "CEB"), ("华夏银行", "HXB"), ("北京银行", "BOB"),
        ("上海银行", "BOS"), ("宁波银行", "NBCB"), ("招商永隆", "CMBHK"), ("汇丰银行", "HSBC"),
        ("微信零钱通", "WeChat:LingQianTong"), ("微信零钱", "WeChat:LingQian"),
        ("支付宝余额宝", "Alipay:YuEBao"), ("支付宝余额", "Alipay:Balance"),
        ("京东白条", "Baitiao"), ("美团月付", "MeituanYuefu"),
        ("招商", "CMB"), ("招行", "CMB"), ("工商", "ICBC"), ("工行", "ICBC"),
        ("建设", "CCB"), ("建行", "CCB"), ("中行", "BOC"), ("农行", "ABC"), ("交行", "COMM"),
        ("微信", "WeChat"), ("支付宝", "Alipay"), ("余额宝", "YuEBao"), ("花呗", "Huabei"),
        ("白条", "Baitiao"), ("现金", "Cash"), ("餐饮", "Food"), ("外卖", "Takeaway"),
        ("咖啡", "Coffee"), ("买菜", "Groceries"), ("房租", "Rent"), ("水电", "Utilities"),
        ("交通", "Transport"), ("打车", "Taxi"), ("地铁", "Subway"), ("公交", "Bus"),
        ("工资", "Salary"), ("奖金", "Bonus")
    ]

    /// 将中文转换为大驼峰拼音，同时保留常见金融机构与消费词的英文/代码映射
    public static func toPinyinCamelCase(_ text: String) -> String {
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else { return "" }

        // 1. 从长到短将已知关键词替换为标记（例如 [CMB]）
        var tokenMap: [String: String] = [:]
        var counter = 0
        for (keyword, code) in knownAliasList {
            if working.contains(keyword) {
                let token = "TOKEN\(counter)X"
                counter += 1
                tokenMap[token] = code
                working = working.replacingOccurrences(of: keyword, with: " \(token) ")
            }
        }

        // 2. 将字符串拆分为由空格分隔的段落
        let segments = working.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var resultSegments: [String] = []

        for seg in segments {
            if let mappedCode = tokenMap[seg] {
                resultSegments.append(mappedCode)
            } else {
                // 将中文段落转为拼音大驼峰
                let mutable = NSMutableString(string: seg) as CFMutableString
                CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
                CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)

                let words = (mutable as String)
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined()

                if !words.isEmpty {
                    resultSegments.append(words)
                }
            }
        }

        let combined = resultSegments.joined(separator: ":")
        return combined.isEmpty ? "Custom" : combined
    }

    /// 构造建议的完整账户路径
    public static func buildAccountPath(
        category: AccountTypeCategory,
        preset: AccountPresetItem?,
        customName: String,
        detail: String? = nil
    ) -> String {
        let baseAccount: String
        if let preset {
            baseAccount = preset.defaultAccount
        } else {
            let segment = toPinyinCamelCase(customName)
            baseAccount = "\(category.rootPrefix):\(segment.isEmpty ? "Custom" : segment)"
        }

        let detailTrimmed = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !detailTrimmed.isEmpty {
            let detailSegment = toPinyinCamelCase(detailTrimmed)
            if !detailSegment.isEmpty {
                return "\(baseAccount):\(detailSegment)"
            }
        }
        return baseAccount
    }

    /// 构造建议的分类账户路径
    public static func buildCategoryPath(
        kind: CategoryKind,
        sectionCode: String,
        itemCode: String?,
        customName: String
    ) -> String {
        let root = kind.rawValue
        if let itemCode, !itemCode.isEmpty {
            return "\(root):\(sectionCode):\(itemCode)"
        }
        let pinyin = toPinyinCamelCase(customName)
        let sub = pinyin.isEmpty ? "Custom" : pinyin
        return "\(root):\(sectionCode):\(sub)"
    }

    /// 校验是否是合法的 Beancount 账户名
    public static func isValidAccountPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }

        let roots = ["Assets", "Liabilities", "Equity", "Income", "Expenses"]
        guard roots.contains(String(parts[0])) else { return false }

        let segmentRegex = try? NSRegularExpression(pattern: "^[A-Z0-9][A-Za-z0-9-]*$")
        for part in parts.dropFirst() {
            let str = String(part)
            let range = NSRange(location: 0, length: str.utf16.count)
            guard segmentRegex?.firstMatch(in: str, options: [], range: range) != nil else {
                return false
            }
        }
        return true
    }
}

/// 创建账户请求模型
public struct LedgerAccountInput: Codable, Equatable, Sendable {
    public let date: String
    public let account: String
    public let alias: String
    public let currency: String

    public init(date: String, account: String, alias: String, currency: String) {
        self.date = date
        self.account = account
        self.alias = alias
        self.currency = currency
    }
}
