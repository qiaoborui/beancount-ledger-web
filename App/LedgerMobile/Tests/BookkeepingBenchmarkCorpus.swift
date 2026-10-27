import Foundation
@testable import LedgerMobile

/// Everyday Chinese bookkeeping sentences with their expected reading, used to
/// measure natural-language parsing and account matching. Reference date is
/// Tuesday 2026-10-27; every account below is synthetic.
enum BookkeepingBenchmark {
    static let today = "2026-10-27"

    struct Record {
        var kind = "expense"
        var date = BookkeepingBenchmark.today
        let amount: String
        var currency = "CNY"
        /// The non-payment side: expense or income account, transfer target,
        /// receivable or payable.
        let category: String?
        /// Where the money left or arrived; nil when the sentence names none.
        var funding: String?
        /// The words this record was read from, when the sentence has several.
        var evidence: String?
    }

    struct Case {
        let text: String
        let records: [Record]
    }

    static let wechat = "Assets:CN:Wechat:Balance", alipay = "Assets:CN:Alipay:Balance", yuebao = "Assets:CN:Alipay:YuEBao"
    static let cmb = "Assets:CN:Bank:CMB", icbc = "Assets:CN:Bank:ICBC", cash = "Assets:Cash"
    static let cmbCredit = "Liabilities:CreditCard:CMB", huabei = "Liabilities:Alipay:Huabei", baitiao = "Liabilities:JD:Baitiao"
    static let colleagues = "Assets:Receivable:Colleagues", friends = "Assets:Receivable:Friends", owed = "Liabilities:Payable:Friends"

    static let accounts: [LedgerAccount] = {
        let rows: [(String, String?, String)] = [
            (cmb, "招行储蓄卡", "CNY"), (icbc, "工行工资卡", "CNY"), (wechat, "微信零钱", "CNY"), (alipay, "支付宝余额", "CNY"),
            (yuebao, "余额宝", "CNY"), (cash, "现金", "CNY"), (colleagues, "同事垫付", "CNY"), (friends, "朋友 AA / 待收款", "CNY"),
            ("Assets:HK:HSBC:USD", "汇丰美元", "USD"), (cmbCredit, "招行信用卡 8888", "CNY"), (huabei, "花呗", "CNY"),
            (baitiao, "京东白条", "CNY"), (owed, "欠朋友的钱", "CNY"),
            ("Income:Salary", nil, ""), ("Income:Bonus", nil, ""), ("Income:Interest", nil, ""), ("Income:Reimbursement", nil, ""),
            ("Income:RedPacket", "红包", ""), ("Income:SideJob", "兼职", ""), ("Income:Other", nil, ""),
            ("Expenses:Food:Meals", nil, ""), ("Expenses:Food:Takeout", nil, ""), ("Expenses:Food:Drinks", nil, ""),
            ("Expenses:Food:Groceries", nil, ""), ("Expenses:Food:Snacks", nil, ""), ("Expenses:Transport:Public", nil, ""),
            ("Expenses:Transport:Taxi", nil, ""), ("Expenses:Transport:Train", nil, ""), ("Expenses:Transport:Car", nil, ""),
            ("Expenses:Shopping:Daily", nil, ""), ("Expenses:Shopping:Clothing", nil, ""), ("Expenses:Shopping:Digital", nil, ""),
            ("Expenses:Shopping:Other", nil, ""), ("Expenses:Digital:Subscription", nil, ""), ("Expenses:Housing:Rent", nil, ""),
            ("Expenses:Housing:Utilities", nil, ""), ("Expenses:Communication:Phone", nil, ""), ("Expenses:Health:Medical", nil, ""),
            ("Expenses:Health:Fitness", nil, ""), ("Expenses:Education:Books", nil, ""), ("Expenses:Education:Courses", nil, ""),
            ("Expenses:Entertainment:Recreation", nil, ""), ("Expenses:Travel:Hotel", nil, ""), ("Expenses:Social:Gift", nil, ""),
            ("Expenses:Pets", nil, ""), ("Expenses:Personal:Care", nil, ""), ("Expenses:Unknown", nil, ""),
        ]
        return rows.map { .init(account: $0.0, openDate: "2020-01-01", closeDate: nil, currency: $0.2, alias: $0.1,
                                label: "", group: "test", active: true) }
    }()

    private static func r(_ amount: String, _ category: String?, _ funding: String? = nil, kind: String = "expense",
                          date: String = today, currency: String = "CNY", evidence: String? = nil) -> Record {
        .init(kind: kind, date: date, amount: amount, currency: currency, category: category, funding: funding, evidence: evidence)
    }

    static let cases: [Case] = [
        // Single purchases with a named payment account.
        .init(text: "中午在美团外卖点餐 35 元，微信零钱支付。", records: [r("35", "Expenses:Food:Takeout", wechat)]),
        .init(text: "今早乘坐地铁 7 元，支付宝花呗扣款。", records: [r("7", "Expenses:Transport:Public", huabei)]),
        .init(text: "下午买了一杯星巴克 32 元，招行信用卡付款。", records: [r("32", "Expenses:Food:Drinks", cmbCredit)]),
        .init(text: "昨天晚上和朋友吃火锅花了 268，用的支付宝", records: [r("268", "Expenses:Food:Meals", alipay, date: "2026-10-26")]),
        .init(text: "瑞幸咖啡 9.9", records: [r("9.9", "Expenses:Food:Drinks")]),
        .init(text: "打车回家 46.5 元 微信", records: [r("46.5", "Expenses:Transport:Taxi", wechat)]),
        .init(text: "超市买菜 86.3，现金", records: [r("86.3", "Expenses:Food:Groceries", cash)]),
        .init(text: "交房租 4500，招行卡转账", records: [r("4500", "Expenses:Housing:Rent", cmb)]),
        .init(text: "交电费 200 支付宝", records: [r("200", "Expenses:Housing:Utilities", alipay)]),
        .init(text: "充话费 100", records: [r("100", "Expenses:Communication:Phone")]),
        .init(text: "健身房年卡 2999 花呗", records: [r("2999", "Expenses:Health:Fitness", huabei)]),
        .init(text: "京东买了个耳机 399", records: [r("399", "Expenses:Shopping:Digital")]),
        .init(text: "淘宝买衣服 159", records: [r("159", "Expenses:Shopping:Clothing")]),
        .init(text: "优衣库买了条裤子 199 招行信用卡", records: [r("199", "Expenses:Shopping:Clothing", cmbCredit)]),
        .init(text: "拼多多买纸巾 29.9", records: [r("29.9", "Expenses:Shopping:Daily")]),
        .init(text: "看电影 2 张票 90", records: [r("90", "Expenses:Entertainment:Recreation")]),
        .init(text: "买了 2 杯奶茶共 30 元", records: [r("30", "Expenses:Food:Drinks")]),
        .init(text: "昨天加油 300 信用卡", records: [r("300", "Expenses:Transport:Car", cmbCredit, date: "2026-10-26")]),
        .init(text: "停车费 15", records: [r("15", "Expenses:Transport:Car")]),
        .init(text: "高铁票 553.5 去上海 12306", records: [r("553.5", "Expenses:Transport:Train")]),
        .init(text: "机票 1280 携程 招行信用卡", records: [r("1280", "Expenses:Transport:Train", cmbCredit)]),
        .init(text: "滴滴 23.6", records: [r("23.6", "Expenses:Transport:Taxi")]),
        .init(text: "共享单车 1.5", records: [r("1.5", "Expenses:Transport:Public")]),
        .init(text: "猫粮 168", records: [r("168", "Expenses:Pets")]),
        .init(text: "理发 68", records: [r("68", "Expenses:Personal:Care")]),
        .init(text: "买了一本《三体》 45", records: [r("45", "Expenses:Education:Books")]),
        .init(text: "报了个网课 1999", records: [r("1999", "Expenses:Education:Courses")]),
        .init(text: "酒店住宿 680 两晚", records: [r("680", "Expenses:Travel:Hotel")]),
        .init(text: "朋友结婚随礼 1000", records: [r("1000", "Expenses:Social:Gift")]),
        .init(text: "iCloud 续费 21", records: [r("21", "Expenses:Digital:Subscription")]),
        .init(text: "Netflix 会员 68 元", records: [r("68", "Expenses:Digital:Subscription")]),
        .init(text: "猫砂 59.9 淘宝", records: [r("59.9", "Expenses:Pets")]),
        .init(text: "买药 36.5", records: [r("36.5", "Expenses:Health:Medical")]),
        .init(text: "宽带续费 1200 一年", records: [r("1200", "Expenses:Communication:Phone")]),
        .init(text: "交学费 5000 工行卡", records: [r("5000", "Expenses:Education:Courses", icbc)]),
        .init(text: "今天中午麦当劳 39.9 支付宝", records: [r("39.9", "Expenses:Food:Meals", alipay)]),
        .init(text: "晚上喝酒 380", records: [r("380", "Expenses:Food:Drinks")]),
        .init(text: "洗车 40", records: [r("40", "Expenses:Transport:Car")]),
        .init(text: "ETC 高速费 85", records: [r("85", "Expenses:Transport:Car")]),
        .init(text: "开会员 爱奇艺 25", records: [r("25", "Expenses:Digital:Subscription")]),
        .init(text: "饿了么点了麻辣烫 28.5 花呗", records: [r("28.5", "Expenses:Food:Takeout", huabei)]),
        .init(text: "Apple Music 订阅 11 元", records: [r("11", "Expenses:Digital:Subscription")]),
        .init(text: "早上买早餐包子豆浆 12", records: [r("12", "Expenses:Food:Meals")]),
        .init(text: "给猫买猫砂 45 淘宝", records: [r("45", "Expenses:Pets")]),
        .init(text: "交通银行信用卡 买咖啡 25", records: [r("25", "Expenses:Food:Drinks")]),
        .init(text: "地铁2号线 4 元", records: [r("4", "Expenses:Transport:Public")]),
        .init(text: "买水果 3 斤 25", records: [r("25", "Expenses:Food:Groceries")]),
        .init(text: "花 35 吃了碗面", records: [r("35", "Expenses:Food:Meals")]),
        .init(text: "买了一块蛋糕 28", records: [r("28", "Expenses:Food:Snacks")]),
        .init(text: "和同事一块吃饭 120", records: [r("120", "Expenses:Food:Meals")]),
        .init(text: "包子 3 块 5", records: [r("3.5", "Expenses:Food:Meals")]),
        .init(text: "买了个 200 块的耳机", records: [r("200", "Expenses:Shopping:Digital")]),
        .init(text: "转账给房东 4500 房租", records: [r("4500", "Expenses:Housing:Rent")]),
        .init(text: "微信发红包 66", records: [r("66", "Expenses:Social:Gift", wechat)]),
        .init(text: "在海底捞吃饭 480，招行信用卡尾号 8888", records: [r("480", "Expenses:Food:Meals", cmbCredit)]),
        .init(text: "买了个 iPhone 15 花了 5999", records: [r("5999", "Expenses:Shopping:Digital")]),
        .init(text: "用微信付的打车费 38，绑的招行信用卡", records: [r("38", "Expenses:Transport:Taxi", cmbCredit)]),

        // Amount spellings.
        .init(text: "午饭三十五块", records: [r("35", "Expenses:Food:Meals")]),
        .init(text: "咖啡十八块五", records: [r("18.5", "Expenses:Food:Drinks")]),
        .init(text: "买菜花了五十三块二", records: [r("53.2", "Expenses:Food:Groceries")]),
        .init(text: "打车花了一百二", records: [r("120", "Expenses:Transport:Taxi")]),
        .init(text: "两千三的房租", records: [r("2300", "Expenses:Housing:Rent")]),
        .init(text: "¥1,280 买了个显示器，京东白条", records: [r("1280", "Expenses:Shopping:Digital", baitiao)]),
        .init(text: "１２８元 午餐", records: [r("128", "Expenses:Food:Meals")]),
        .init(text: "昨天在山姆买了 1,288.50 的东西 招行信用卡", records: [r("1288.5", "Expenses:Food:Groceries", cmbCredit, date: "2026-10-26")]),
        .init(text: "美国出差打车 25 美元", records: [r("25", "Expenses:Transport:Taxi", currency: "USD")]),
        .init(text: "停车 5 块", records: [r("5", "Expenses:Transport:Car")]),

        // Dates.
        .init(text: "上周五聚餐 AA 每人 150", records: [r("150", "Expenses:Food:Meals", date: "2026-10-23")]),
        .init(text: "周日看演唱会 880", records: [r("880", "Expenses:Entertainment:Recreation", date: "2026-10-25")]),
        .init(text: "10月1日 国庆出去玩 门票 120", records: [r("120", "Expenses:Entertainment:Recreation", date: "2026-10-01")]),
        .init(text: "3号交了物业费 380", records: [r("380", "Expenses:Housing:Utilities", date: "2026-10-03")]),
        .init(text: "上个月15号买的鞋 699 花呗", records: [r("699", "Expenses:Shopping:Clothing", huabei, date: "2026-09-15")]),
        .init(text: "2026-10-20 体检 450", records: [r("450", "Expenses:Health:Medical", date: "2026-10-20")]),
        .init(text: "3天前 买了个充电器 89", records: [r("89", "Expenses:Shopping:Digital", date: "2026-10-24")]),
        .init(text: "前天晚上吃烧烤 156，微信", records: [r("156", "Expenses:Food:Meals", wechat, date: "2026-10-25")]),
        .init(text: "大前天打车 32", records: [r("32", "Expenses:Transport:Taxi", date: "2026-10-24")]),
        .init(text: "28号买的电影票 70", records: [r("70", "Expenses:Entertainment:Recreation", date: "2026-09-28")]),
        .init(text: "12月24日 平安夜聚餐 520 招行信用卡", records: [r("520", "Expenses:Food:Meals", cmbCredit, date: "2025-12-24")]),

        // Several transactions in one message.
        .init(text: "午饭35，打车20", records: [
            r("35", "Expenses:Food:Meals", evidence: "午饭35"), r("20", "Expenses:Transport:Taxi", evidence: "打车20")]),
        .init(text: "早餐 8 块，地铁 4 元，午饭 25", records: [
            r("8", "Expenses:Food:Meals", evidence: "早餐 8 块"), r("4", "Expenses:Transport:Public", evidence: "地铁 4 元"),
            r("25", "Expenses:Food:Meals", evidence: "午饭 25")]),
        .init(text: "去医院看病挂号 50，药费 120", records: [
            r("50", "Expenses:Health:Medical", evidence: "去医院看病挂号 50"), r("120", "Expenses:Health:Medical", evidence: "药费 120")]),
        .init(text: "午餐 32 晚餐 45", records: [
            r("32", "Expenses:Food:Meals", evidence: "午餐 32"), r("45", "Expenses:Food:Meals", evidence: "晚餐 45")]),
        .init(text: "在全家买了瓶水 3.5 和面包 6.8", records: [
            r("3.5", "Expenses:Food:Drinks", evidence: "在全家买了瓶水 3.5"), r("6.8", "Expenses:Food:Snacks", evidence: "和面包 6.8")]),
        .init(text: "电费 156.78 水费 45.2", records: [
            r("156.78", "Expenses:Housing:Utilities", evidence: "电费 156.78"), r("45.2", "Expenses:Housing:Utilities", evidence: "水费 45.2")]),
        .init(text: "国庆旅游住酒店 1200，吃饭 300，门票 200", records: [
            r("1200", "Expenses:Travel:Hotel", evidence: "国庆旅游住酒店 1200"), r("300", "Expenses:Food:Meals", evidence: "吃饭 300"),
            r("200", "Expenses:Entertainment:Recreation", evidence: "门票 200")]),
        .init(text: "下午茶 奶茶 18 蛋糕 22", records: [
            r("18", "Expenses:Food:Drinks", evidence: "奶茶 18"), r("22", "Expenses:Food:Snacks", evidence: "蛋糕 22")]),
        .init(text: "每月房租 3800 + 水电 200", records: [
            r("3800", "Expenses:Housing:Rent", evidence: "每月房租 3800"), r("200", "Expenses:Housing:Utilities", evidence: "水电 200")]),
        .init(text: "午饭 35 微信，晚上打车 42 支付宝", records: [
            r("35", "Expenses:Food:Meals", wechat, evidence: "午饭 35 微信"), r("42", "Expenses:Transport:Taxi", alipay, evidence: "晚上打车 42 支付宝")]),
        .init(text: "买了苹果、香蕉共 30", records: [r("30", "Expenses:Food:Groceries")]),
        .init(text: "早餐 6，午餐 28，一共 34", records: [
            r("6", "Expenses:Food:Meals", evidence: "早餐 6"), r("28", "Expenses:Food:Meals", evidence: "午餐 28")]),

        // Splits, transfers, income and debts.
        .init(text: "昨天用招行信用卡买书 128 元，其中 48 元替同事垫付。", records: [
            r("128", "Expenses:Education:Books", cmbCredit, date: "2026-10-26")]),
        .init(text: "从工行储蓄卡转账 3000 元还招商银行信用卡。", records: [r("3000", cmbCredit, icbc, kind: "transfer")]),
        .init(text: "微信提现 1000 到招行", records: [r("1000", cmb, wechat, kind: "transfer")]),
        .init(text: "支付宝转 2000 到余额宝", records: [r("2000", yuebao, alipay, kind: "transfer")]),
        .init(text: "还花呗 1200 用招行储蓄卡", records: [r("1200", huabei, cmb, kind: "transfer")]),
        .init(text: "信用卡还款 5000", records: [r("5000", cmbCredit, kind: "transfer")]),
        .init(text: "发工资 15000 到工行卡", records: [r("15000", "Income:Salary", icbc, kind: "income")]),
        .init(text: "收到年终奖 3 万，打到招行", records: [r("30000", "Income:Bonus", cmb, kind: "income")]),
        .init(text: "工资 1.5万 到账", records: [r("15000", "Income:Salary", kind: "income")]),
        .init(text: "余额宝收益 1.23", records: [r("1.23", "Income:Interest", yuebao, kind: "income")]),
        .init(text: "公司报销差旅费 860 到账招行", records: [r("860", "Income:Reimbursement", cmb, kind: "income")]),
        .init(text: "收到红包 200 微信", records: [r("200", "Income:RedPacket", wechat, kind: "income")]),
        .init(text: "抢红包 8.88", records: [r("8.88", "Income:RedPacket", kind: "income")]),
        .init(text: "兼职收入 800 支付宝", records: [r("800", "Income:SideJob", alipay, kind: "income")]),
        .init(text: "淘宝退款 59 到支付宝", records: [r("59", "Expenses:Shopping:Other", alipay, kind: "refund")]),
        .init(text: "朋友还我 200 微信", records: [r("200", friends, wechat, kind: "collect")]),
        .init(text: "借给朋友 1000 招行卡转账", records: [r("1000", friends, cmb, kind: "lend")]),
        .init(text: "向朋友借了 500 到微信", records: [r("500", owed, wechat, kind: "borrow")]),
        .init(text: "帮同事垫付了午饭 45", records: [r("45", colleagues, kind: "lend")]),
        .init(text: "同事还了我 45 块", records: [r("45", colleagues, kind: "collect")]),
        .init(text: "还朋友 500", records: [r("500", owed, kind: "repayDebt")]),
        .init(text: "给妈妈发了 520 红包", records: [r("520", "Expenses:Social:Gift")]),
    ]

    // MARK: Held-out set

    /// The account layout the app's onboarding presets create: coarse
    /// categories, wallets under `Assets:Wallet`, no aliases.
    static let presetAccounts: [LedgerAccount] = [
        "Assets:Wallet:Alipay:Balance", "Assets:Wallet:Alipay:YuEBao", "Assets:Wallet:WeChat:LingQian", "Assets:Bank:CMB",
        "Assets:Bank:ICBC", "Assets:Cash", "Liabilities:CreditCard:CMB", "Income:Salary", "Income:Reimbursement", "Income:Other",
        "Expenses:Food", "Expenses:Shopping", "Expenses:Transport", "Expenses:Entertainment", "Expenses:Health", "Expenses:Home",
        "Expenses:Other",
    ].map { .init(account: $0, openDate: "2020-01-01", closeDate: nil, currency: "CNY", alias: nil, label: "", group: "test", active: true) }

    /// Written after the parser was tuned on `cases` and never tuned against:
    /// other phrasings, a coarser ledger. Its score is the honest estimate.
    static let heldOut: [Case] = [
        .init(text: "晚上点了个必胜客外卖 89 微信", records: [r("89", "Expenses:Food", "Assets:Wallet:WeChat:LingQian")]),
        .init(text: "早上星巴克拿铁 36", records: [r("36", "Expenses:Food")]),
        .init(text: "坐公交 2 块", records: [r("2", "Expenses:Transport")]),
        .init(text: "打的去机场 120 支付宝", records: [r("120", "Expenses:Transport", "Assets:Wallet:Alipay:Balance")]),
        .init(text: "买了双运动鞋 459 招行信用卡", records: [r("459", "Expenses:Shopping", "Liabilities:CreditCard:CMB")]),
        .init(text: "电影票两张 98", records: [r("98", "Expenses:Entertainment")]),
        .init(text: "牙医补牙 600", records: [r("600", "Expenses:Health")]),
        .init(text: "物业费 1200 招行卡", records: [r("1200", "Expenses:Home", "Assets:Bank:CMB")]),
        .init(text: "下班顺路买菜 47.5", records: [r("47.5", "Expenses:Food")]),
        .init(text: "周六和朋友唱K 300", records: [r("300", "Expenses:Entertainment", date: "2026-10-24")]),
        .init(text: "工资到账 12000 工行", records: [r("12000", "Income:Salary", "Assets:Bank:ICBC", kind: "income")]),
        .init(text: "报销打车费 56", records: [r("56", "Income:Reimbursement", kind: "income")]),
        .init(text: "地铁卡充值 100", records: [r("100", "Expenses:Transport")]),
        .init(text: "前天买了箱牛奶 69.9 京东", records: [r("69.9", "Expenses:Food", date: "2026-10-25")]),
        .init(text: "午餐沙拉 42", records: [r("42", "Expenses:Food")]),
        .init(text: "交水电燃气 320", records: [r("320", "Expenses:Home")]),
        .init(text: "买了两斤排骨 58", records: [r("58", "Expenses:Food")]),
        .init(text: "医院拿药 85.6", records: [r("85.6", "Expenses:Health")]),
        .init(text: "周末去爬山 门票 60", records: [r("60", "Expenses:Entertainment")]),
        .init(text: "手机话费充值 50", records: [r("50", "Expenses:Home")]),
        .init(text: "余额宝转出 500 到招行", records: [r("500", "Assets:Bank:CMB", "Assets:Wallet:Alipay:YuEBao", kind: "transfer")]),
        .init(text: "年终奖到账 2万", records: [r("20000", "Income:Salary", kind: "income")]),
        .init(text: "卖二手书收入 35", records: [r("35", "Income:Other", kind: "income")]),
        .init(text: "早饭 5 块 午饭 15 晚饭 20", records: [
            r("5", "Expenses:Food", evidence: "早饭 5 块"), r("15", "Expenses:Food", evidence: "午饭 15"), r("20", "Expenses:Food", evidence: "晚饭 20")]),
        .init(text: "打车 18 地铁 3", records: [
            r("18", "Expenses:Transport", evidence: "打车 18"), r("3", "Expenses:Transport", evidence: "地铁 3")]),
        .init(text: "超市 128.8 微信支付", records: [r("128.8", "Expenses:Food", "Assets:Wallet:WeChat:LingQian")]),
        .init(text: "Steam 买游戏 98", records: [r("98", "Expenses:Entertainment")]),
        .init(text: "交通卡充值 50", records: [r("50", "Expenses:Transport")]),
        .init(text: "退了一件衣服 退款 129 到支付宝", records: [r("129", "Expenses:Shopping", "Assets:Wallet:Alipay:Balance", kind: "refund")]),
        .init(text: "收到利息 3.5", records: [r("3.5", "Income:Other", kind: "income")]),
        .init(text: "昨晚夜宵烧烤 88 现金", records: [r("88", "Expenses:Food", "Assets:Cash", date: "2026-10-26")]),
        .init(text: "加油 350 招商信用卡", records: [r("350", "Expenses:Transport", "Liabilities:CreditCard:CMB")]),
        .init(text: "公司聚餐自己出了 100", records: [r("100", "Expenses:Food")]),
        .init(text: "体检套餐 699", records: [r("699", "Expenses:Health")]),
        .init(text: "滴滴快车 27.3 支付宝", records: [r("27.3", "Expenses:Transport", "Assets:Wallet:Alipay:Balance")]),
        .init(text: "6块钱的煎饼果子", records: [r("6", "Expenses:Food")]),
        .init(text: "两百五买了个台灯", records: [r("250", "Expenses:Shopping")]),
        .init(text: "上周三看话剧 380 招行信用卡", records: [r("380", "Expenses:Entertainment", "Liabilities:CreditCard:CMB", date: "2026-10-21")]),
        .init(text: "买了件羽绒服八百九", records: [r("890", "Expenses:Shopping")]),
        .init(text: "奶茶 15，炸鸡 39，可乐 3", records: [
            r("15", "Expenses:Food", evidence: "奶茶 15"), r("39", "Expenses:Food", evidence: "炸鸡 39"), r("3", "Expenses:Food", evidence: "可乐 3")]),
    ]

    // MARK: Scoring

    struct Score: CustomStringConvertible {
        var counts: [String: (hit: Int, total: Int)] = [:]
        var misses: [String] = []
        mutating func add(_ field: String, _ hit: Bool, _ note: @autoclosure () -> String = "") {
            let current = counts[field] ?? (0, 0)
            counts[field] = (current.hit + (hit ? 1 : 0), current.total + 1)
            if !hit, !note().isEmpty { misses.append("[\(field)] " + note()) }
        }
        func rate(_ field: String) -> Double {
            guard let value = counts[field], value.total > 0 else { return 0 }
            return Double(value.hit) / Double(value.total)
        }
        var description: String {
            counts.keys.sorted().map { key in
                let value = counts[key]!
                return String(format: "%@ %d/%d (%.1f%%)", key, value.hit, value.total, rate(key) * 100)
            }.joined(separator: "\n")
        }
    }

    /// End-to-end local reading: record count, amount, date, currency and both accounts.
    static func evaluateLocalParser(_ cases: [Case] = cases, accounts: [LedgerAccount] = accounts) -> Score {
        var score = Score()
        for item in cases {
            let input = BookkeepingParseInput(text: item.text, referenceDate: today, timeZone: "Asia/Shanghai",
                                              accounts: accounts, currency: "CNY")
            let draft = LocalBookkeepingParser().draft(for: input)
            score.add("records", draft.records.count == item.records.count, "\(item.text): \(draft.records.count) records")
            for (index, expected) in item.records.enumerated() {
                guard draft.records.indices.contains(index) else {
                    for field in ["amount", "date", "currency", "category", "funding", "complete"] where field != "funding" || expected.funding != nil {
                        score.add(field, false, "\(item.text): missing record \(index + 1)")
                    }
                    continue
                }
                let record = draft.records[index]
                let roles = draft.accountRoles.indices.contains(index) ? draft.accountRoles[index] : []
                let fundingIndex = roles.firstIndex(of: "funding")
                let categoryIndex = roles.firstIndex { $0 != "funding" }
                let total = fundingIndex.map { record.postings[$0].amount.replacingOccurrences(of: "-", with: "") }
                    ?? record.postings.map { $0.amount.replacingOccurrences(of: "-", with: "") }.first ?? ""
                let category = categoryIndex.map { record.postings[$0].account } ?? ""
                let funding = fundingIndex.map { record.postings[$0].account } ?? ""
                let amountOK = total == expected.amount, dateOK = record.date == expected.date
                let currencyOK = record.postings.first?.currency == expected.currency
                let categoryOK = category == expected.category, fundingOK = expected.funding == nil || funding == expected.funding
                score.add("amount", amountOK, "\(item.text): \(total)")
                score.add("date", dateOK, "\(item.text): \(record.date)")
                score.add("currency", currencyOK, "\(item.text): \(record.postings.first?.currency ?? "")")
                score.add("category", categoryOK, "\(item.text): \(category)")
                if expected.funding != nil { score.add("funding", fundingOK, "\(item.text): \(funding)") }
                score.add("complete", amountOK && dateOK && currencyOK && categoryOK && fundingOK, "\(item.text)")
            }
        }
        return score
    }

    static func role(for kind: String) -> String {
        switch kind {
        case "income": "income"
        case "transfer": "counterpart"
        case "lend", "collect": "receivable"
        case "borrow", "repayDebt": "payable"
        default: "expense"
        }
    }

    /// Account matching alone, given the transaction structure a semantic
    /// parser returns. `perRecord` passes each record's own words, as the
    /// editor now does; the old editor passed the whole message.
    static func evaluateMatcher(_ cases: [Case] = cases, accounts: [LedgerAccount] = accounts, perRecord: Bool, _ match: (String, String, [LedgerAccount]) -> String?) -> Score {
        var score = Score()
        for item in cases {
            for expected in item.records {
                let text = perRecord ? expected.evidence ?? item.text : item.text
                let category = match(role(for: expected.kind), text, accounts)
                score.add("category", category == expected.category, "\(item.text): \(category ?? "nil")")
                if let funding = expected.funding {
                    let found = match("funding", text, accounts)
                    score.add("funding", found == funding, "\(item.text): \(found ?? "nil")")
                }
            }
        }
        return score
    }
}
