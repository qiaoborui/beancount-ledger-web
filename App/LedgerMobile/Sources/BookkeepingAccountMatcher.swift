import Foundation

/// Local, explainable account matching for natural-language bookkeeping.
///
/// The text side and the ledger side are matched separately: a concept is
/// triggered by words in the sentence (`滴滴` → taxi), then resolved to the
/// best-named account in the user's own ledger (`Expenses:Transport:Taxi`,
/// or an alias such as `打车`). A concept that has no account of its own falls
/// back to its parent (`taxi` → `transport`). Nothing is guessed when the text
/// carries no evidence for a category.
enum BookkeepingAccountMatcher {
    struct Concept: Sendable {
        let id: String
        /// Words in the user's sentence. Longer words win over shorter ones.
        let triggers: [String]
        /// Words in account names, aliases or labels, with their weight.
        let names: [(String, Double)]
        let fallback: String?
        /// Umbrella concepts (`food`, `shopping`) lose ties to specific ones.
        var generic = false
    }

    // MARK: Lexicons

    static let expenseConcepts: [Concept] = [
        .init(id: "takeout", triggers: ["美团外卖", "饿了么", "外卖", "点外卖", "叫外卖"],
              names: [("takeout", 3), ("delivery", 3), ("外卖", 3)], fallback: "meals"),
        .init(id: "drinks", triggers: ["咖啡", "奶茶", "星巴克", "瑞幸", "喜茶", "蜜雪冰城", "蜜雪", "奈雪", "茶颜", "霸王茶姬", "古茗",
                                       "库迪", "manner", "costa", "饮料", "饮品", "果汁", "可乐", "矿泉水", "瓶水", "豆浆", "拿铁", "美式", "酸奶"],
              names: [("drink", 3), ("beverage", 3), ("coffee", 3), ("tea", 2), ("饮品", 3), ("饮料", 3), ("咖啡", 3), ("奶茶", 3)], fallback: "food"),
        .init(id: "snacks", triggers: ["零食", "便利店", "全家", "罗森", "7-11", "711", "便利蜂", "美宜佳", "小卖部", "雪糕", "冰淇淋", "面包", "蛋糕", "甜品", "水果捞"],
              names: [("snack", 3), ("零食", 3), ("dessert", 2), ("甜品", 2)], fallback: "food"),
        .init(id: "groceries", triggers: ["买菜", "菜市场", "超市", "盒马", "山姆", "沃尔玛", "永辉", "叮咚", "朴朴", "多多买菜", "美团买菜", "生鲜",
                                          "蔬菜", "水果", "牛奶", "排骨", "五花肉", "鸡肉", "海鲜", "粮油", "香蕉", "橘子", "橙子", "西瓜", "葡萄", "草莓", "鸡蛋", "猪肉", "牛肉", "大米", "食材", "costco", "家乐福", "大润发", "物美"],
              names: [("grocer", 3), ("supermarket", 3), ("买菜", 3), ("超市", 3), ("生鲜", 3), ("食材", 3)], fallback: "food"),
        .init(id: "alcohol", triggers: ["啤酒", "红酒", "白酒", "喝酒", "酒吧", "清吧", "精酿"],
              names: [("alcohol", 3), ("bar", 2), ("wine", 3), ("beer", 3), ("酒", 3)], fallback: "drinks"),
        .init(id: "meals", triggers: ["早饭", "早餐", "午饭", "午餐", "中饭", "晚饭", "晚餐", "夜宵", "宵夜", "吃饭", "聚餐", "餐厅", "饭店", "食堂",
                                      "火锅", "烧烤", "麦当劳", "肯德基", "汉堡王", "必胜客", "海底捞", "萨莉亚", "汉堡", "拉面", "米线", "面馆",
                                      "麻辣烫", "披萨", "寿司", "日料", "西餐", "自助餐", "盒饭", "快餐", "便当", "包子", "饺子", "馄饨", "煎饼",
                                      "请客", "吃了", "吃的", "点餐", "堂食", "沙县", "兰州拉面", "黄焖鸡", "串串", "小龙虾", "牛排", "炸鸡", "烤鸭", "沙拉", "轻食", "煎饼"],
              names: [("meal", 3), ("dining", 3), ("restaurant", 3), ("eat", 2), ("正餐", 3), ("三餐", 3), ("用餐", 3), ("餐", 2)], fallback: "food"),
        .init(id: "food", triggers: ["吃", "餐饮", "饭", "餐", "食"],
              names: [("food", 3), ("餐饮", 3), ("饮食", 3), ("meal", 2), ("dining", 2)], fallback: nil, generic: true),
        .init(id: "bike", triggers: ["共享单车", "美团单车", "哈啰", "青桔", "单车", "骑车", "电单车"],
              names: [("bike", 3), ("bicycle", 3), ("单车", 3), ("public", 1), ("transit", 1)], fallback: "transit"),
        .init(id: "taxi", triggers: ["打车", "滴滴", "出租车", "的士", "网约车", "曹操出行", "高德打车", "首汽", "T3", "uber", "专车", "快车", "顺风车", "出租", "打的"],
              names: [("taxi", 3), ("cab", 3), ("ride", 2), ("didi", 3), ("打车", 3), ("出租", 3), ("网约车", 3)], fallback: "transport"),
        .init(id: "transit", triggers: ["地铁", "公交", "乘车码", "轻轨", "巴士", "交通卡", "公交卡", "坐车", "通勤", "轮渡", "地铁卡"],
              names: [("public", 3), ("transit", 3), ("subway", 3), ("metro", 3), ("bus", 3), ("公交", 3), ("地铁", 3), ("公共交通", 3)], fallback: "transport"),
        .init(id: "intercity", triggers: ["高铁", "火车", "动车", "火车票", "机票", "航班", "飞机", "12306", "携程", "去哪儿", "飞猪", "长途汽车", "大巴"],
              names: [("train", 3), ("flight", 3), ("air", 2), ("rail", 3), ("intercity", 3), ("travel", 1), ("火车", 3), ("高铁", 3), ("机票", 3), ("差旅", 2)],
              fallback: "transport"),
        .init(id: "car", triggers: ["加油", "油费", "停车", "停车费", "过路费", "高速费", "洗车", "充电桩", "汽车保养", "保养", "车险", "违章", "ETC", "etc"],
              names: [("fuel", 3), ("gas", 2), ("parking", 3), ("car", 3), ("auto", 3), ("vehicle", 3), ("加油", 3), ("停车", 3), ("汽车", 3), ("车", 1)],
              fallback: "transport"),
        .init(id: "transport", triggers: ["交通", "出行", "车费", "路费", "车票", "交通卡", "公交卡"],
              names: [("transport", 3), ("traffic", 3), ("commute", 2), ("交通", 3), ("出行", 3)], fallback: nil, generic: true),
        .init(id: "subscription", triggers: ["会员", "订阅", "icloud", "netflix", "spotify", "网易云", "爱奇艺", "腾讯视频", "优酷", "芒果tv",
                                             "大会员", "开会员", "chatgpt", "claude", "apple music", "youtube premium", "qq音乐", "百度网盘", "app store", "应用内购买"],
              names: [("subscription", 3), ("membership", 3), ("订阅", 3), ("会员", 3), ("service", 1)], fallback: "digital"),
        .init(id: "phone", triggers: ["话费", "流量", "宽带", "手机费", "电话费", "充话费", "中国移动", "中国联通", "中国电信"],
              names: [("phone", 3), ("mobile", 3), ("telecom", 3), ("communication", 3), ("internet", 3), ("话费", 3), ("通讯", 3), ("通信", 3)],
              fallback: "utilities"),
        .init(id: "digital", triggers: ["手机", "电脑", "笔记本电脑", "耳机", "数码", "充电器", "数据线", "键盘", "鼠标", "显示器", "ipad", "iphone", "macbook",
                                        "相机", "平板", "switch", "ps5", "硬盘", "路由器"],
              names: [("digital", 3), ("electronic", 3), ("gadget", 3), ("数码", 3), ("电子", 3)], fallback: "shopping"),
        .init(id: "clothing", triggers: ["衣服", "裤子", "鞋", "外套", "T恤", "t恤", "裙子", "卫衣", "羽绒服", "衬衫", "袜子", "内衣", "帽子", "优衣库",
                                         "zara", "耐克", "nike", "阿迪", "adidas", "包包"],
              names: [("cloth", 3), ("apparel", 3), ("fashion", 3), ("服饰", 3), ("服装", 3), ("衣", 2)], fallback: "shopping"),
        .init(id: "daily", triggers: ["日用", "日用品", "纸巾", "卫生纸", "洗发水", "沐浴露", "牙膏", "牙刷", "洗衣液", "垃圾袋", "洗洁精", "百货", "生活用品"],
              names: [("daily", 3), ("household", 3), ("necessit", 3), ("日用", 3), ("百货", 3), ("生活用品", 3)], fallback: "shopping"),
        .init(id: "beauty", triggers: ["理发", "剪头", "剪发", "美甲", "化妆品", "护肤", "面膜", "口红", "美容", "按摩", "足疗", "洗头"],
              names: [("beauty", 3), ("personal", 2), ("haircut", 3), ("cosmetic", 3), ("美容", 3), ("理发", 3), ("个护", 3)], fallback: "shopping"),
        .init(id: "pets", triggers: ["猫粮", "狗粮", "宠物", "猫砂", "猫咪", "狗狗", "宠物医院"],
              names: [("pet", 3), ("宠物", 3)], fallback: nil),
        .init(id: "rent", triggers: ["房租", "租金", "交租", "租房"],
              names: [("rent", 3), ("房租", 3), ("租", 2)], fallback: "housing"),
        .init(id: "utilities", triggers: ["水费", "电费", "燃气费", "燃气", "煤气", "水电", "暖气", "物业费", "物业"],
              names: [("utilit", 3), ("水电", 3), ("水电煤", 3), ("物业", 3), ("property", 2), ("bill", 1)], fallback: "housing"),
        .init(id: "housing", triggers: ["住房", "房贷", "家具", "装修", "家居", "维修"],
              names: [("housing", 3), ("home", 3), ("house", 3), ("居住", 3), ("住房", 3), ("家居", 3)], fallback: nil, generic: true),
        .init(id: "medical", triggers: ["医院", "看病", "挂号", "药", "药店", "门诊", "体检", "牙科", "诊所", "看牙", "牙医", "补牙", "洗牙", "拔牙", "医药", "感冒药", "医保"],
              names: [("medical", 3), ("health", 3), ("hospital", 3), ("pharmacy", 3), ("medicine", 3), ("医疗", 3), ("药", 2), ("健康", 3)], fallback: nil),
        .init(id: "fitness", triggers: ["健身", "健身房", "游泳", "瑜伽", "羽毛球", "篮球", "球馆", "跑步", "私教", "普拉提", "攀岩"],
              names: [("fitness", 3), ("gym", 3), ("sport", 3), ("健身", 3), ("运动", 3)], fallback: "entertainment"),
        .init(id: "books", triggers: ["买书", "书店", "《", "图书", "电子书", "kindle", "教材", "书"],
              names: [("book", 3), ("图书", 3), ("书籍", 3), ("书", 2), ("education", 1)], fallback: "education"),
        .init(id: "education", triggers: ["课程", "培训", "学费", "网课", "考试", "报名费", "学习", "辅导", "补习"],
              names: [("education", 3), ("course", 3), ("learning", 3), ("study", 3), ("tuition", 3), ("学习", 3), ("教育", 3)], fallback: nil),
        .init(id: "travel", triggers: ["旅游", "旅行", "酒店", "民宿", "住宿", "景点", "景区", "度假", "airbnb"],
              names: [("travel", 3), ("hotel", 3), ("vacation", 3), ("trip", 3), ("旅行", 3), ("旅游", 3), ("住宿", 3)], fallback: "entertainment"),
        .init(id: "entertainment", triggers: ["电影", "电影票", "游戏", "门票", "ktv", "KTV", "唱歌", "唱k", "k歌", "演唱会", "话剧", "展览", "剧本杀", "桌游", "密室",
                                              "steam", "玩", "娱乐", "演出", "live"],
              names: [("entertain", 3), ("recreation", 3), ("leisure", 3), ("fun", 3), ("movie", 2), ("game", 2), ("娱乐", 3), ("休闲", 3)], fallback: nil),
        .init(id: "gift", triggers: ["发红包", "红包", "礼物", "份子钱", "随礼", "随份子", "送礼", "礼金", "请朋友", "生日礼物", "孝敬", "生活费"],
              names: [("gift", 3), ("social", 3), ("红包", 3), ("礼", 3), ("人情", 3), ("社交", 3)], fallback: nil),
        .init(id: "insurance", triggers: ["保险", "保费", "社保", "公积金"],
              names: [("insurance", 3), ("保险", 3)], fallback: nil),
        .init(id: "fees", triggers: ["手续费", "服务费", "年费", "利息支出", "滞纳金", "罚款"],
              names: [("fee", 3), ("charge", 2), ("bank", 1), ("手续费", 3)], fallback: nil),
        .init(id: "tax", triggers: ["个税", "税费", "交税", "缴税"],
              names: [("tax", 3), ("税", 3)], fallback: nil),
        .init(id: "donation", triggers: ["捐款", "捐赠", "慈善"],
              names: [("donation", 3), ("charity", 3), ("捐", 3)], fallback: "gift"),
        .init(id: "shopping", triggers: ["购物", "淘宝", "京东", "拼多多", "天猫", "网购", "抖音商城", "唯品会", "闲鱼", "买了", "亚马逊", "amazon", "宜家", "ikea", "无印良品"],
              names: [("shopping", 3), ("购物", 3), ("shop", 3), ("other", 1.6), ("misc", 1.6), ("其他", 1.6)], fallback: nil, generic: true),
    ]

    static let incomeConcepts: [Concept] = [
        .init(id: "salary", triggers: ["工资", "薪水", "薪资", "发薪", "月薪", "工资卡到账", "发工资"],
              names: [("salary", 3), ("wage", 3), ("payroll", 3), ("工资", 3), ("薪", 3)], fallback: "other"),
        .init(id: "bonus", triggers: ["奖金", "年终奖", "绩效", "提成", "分红"],
              names: [("bonus", 3), ("奖金", 3), ("commission", 2)], fallback: "salary"),
        .init(id: "interest", triggers: ["利息", "理财收益", "余额宝收益", "收益", "基金收益", "零钱通收益", "分息"],
              names: [("interest", 3), ("利息", 3), ("investment", 2), ("yield", 2), ("收益", 3)], fallback: "other"),
        .init(id: "reimbursement", triggers: ["报销", "报账"],
              names: [("reimburse", 3), ("expense", 1), ("报销", 3)], fallback: "other"),
        .init(id: "refundIncome", triggers: ["退税"],
              names: [("tax", 3), ("refund", 2), ("退税", 3)], fallback: "other"),
        .init(id: "gift", triggers: ["收到红包", "收红包", "抢红包", "红包", "礼金", "压岁钱", "生活费"],
              names: [("gift", 3), ("redpacket", 3), ("红包", 3), ("礼", 3)], fallback: "other"),
        .init(id: "side", triggers: ["兼职", "稿费", "外快", "副业", "接私活", "咨询费", "讲课费"],
              names: [("side", 3), ("freelance", 3), ("part", 2), ("兼职", 3), ("副业", 3)], fallback: "other"),
        .init(id: "sale", triggers: ["闲鱼卖", "卖了", "二手", "出售"],
              names: [("sale", 3), ("sell", 3), ("二手", 3)], fallback: "other"),
        .init(id: "other", triggers: ["收入", "收到", "入账", "进账", "赚了"],
              names: [("other", 3), ("misc", 3), ("其他", 3), ("其它", 3)], fallback: nil, generic: true),
    ]

    /// Payment channels and cards. `kind` restricts the root account.
    struct FundingConcept: Sendable {
        enum Kind: Sendable { case asset, liability, either }
        let id: String
        let triggers: [String]
        let names: [(String, Double)]
        let kind: Kind
    }

    static let banks: [(triggers: [String], names: [String])] = [
        (["招商银行", "招行", "招商", "cmb"], ["cmb", "cmbchina", "招行", "招商"]),
        (["工商银行", "工行", "icbc"], ["icbc", "工行", "工商"]),
        (["建设银行", "建行", "ccb"], ["ccb", "建行", "建设"]),
        (["农业银行", "农行", "abc"], ["abc", "农行", "农业"]),
        (["中国银行", "中行", "boc"], ["boc", "中行", "中国银行"]),
        (["交通银行", "交行", "bocom"], ["bocom", "comm", "交行", "交通银行"]),
        (["浦发银行", "浦发", "spdb"], ["spdb", "浦发"]),
        (["中信银行", "中信", "citic"], ["citic", "中信"]),
        (["光大银行", "光大", "ceb"], ["ceb", "光大"]),
        (["民生银行", "民生", "cmbc"], ["cmbc", "民生"]),
        (["兴业银行", "兴业", "cib"], ["cib", "兴业"]),
        (["平安银行", "平安", "pingan"], ["pingan", "pab", "平安"]),
        (["广发银行", "广发", "cgb"], ["cgb", "gdb", "广发"]),
        (["邮储银行", "邮政储蓄", "邮储", "psbc"], ["psbc", "邮储", "邮政"]),
        (["华夏银行", "华夏"], ["hxb", "华夏"]),
        (["北京银行"], ["bob", "北京银行"]),
        (["宁波银行"], ["nbcb", "宁波银行"]),
        (["上海银行"], ["bosc", "上海银行"]),
        (["汇丰", "hsbc"], ["hsbc", "汇丰"]),
        (["花旗", "citi"], ["citi", "花旗"]),
        (["渣打"], ["standardchartered", "scb", "渣打"]),
        (["微众银行", "微众"], ["webank", "微众"]),
        (["网商银行", "网商"], ["mybank", "网商"]),
    ]

    static let fundingConcepts: [FundingConcept] = [
        .init(id: "lingqiantong", triggers: ["零钱通"], names: [("lingqiantong", 3), ("零钱通", 3)], kind: .asset),
        .init(id: "wechat", triggers: ["微信零钱", "微信支付", "微信", "零钱", "wechat", "weixin", "wx"],
              names: [("wechat", 3), ("weixin", 3), ("微信", 3), ("零钱", 3), ("lingqian", 3)], kind: .asset),
        .init(id: "yuebao", triggers: ["余额宝"], names: [("yuebao", 3), ("yuebao", 3), ("余额宝", 3)], kind: .asset),
        .init(id: "huabei", triggers: ["花呗"], names: [("huabei", 3), ("花呗", 3)], kind: .liability),
        .init(id: "jiebei", triggers: ["借呗"], names: [("jiebei", 3), ("借呗", 3)], kind: .liability),
        .init(id: "baitiao", triggers: ["京东白条", "白条"], names: [("baitiao", 3), ("白条", 3)], kind: .liability),
        .init(id: "alipay", triggers: ["支付宝余额", "支付宝", "alipay", "zfb"], names: [("alipay", 3), ("支付宝", 3)], kind: .asset),
        .init(id: "cash", triggers: ["现金", "cash", "纸币"], names: [("cash", 3), ("现金", 3), ("wallet", 1)], kind: .asset),
        .init(id: "transitCard", triggers: ["公交卡", "交通卡", "一卡通", "羊城通", "八达通", "octopus"],
              names: [("transitcard", 3), ("octopus", 3), ("公交卡", 3), ("交通卡", 3), ("一卡通", 3), ("八达通", 3)], kind: .asset),
        .init(id: "paypal", triggers: ["paypal"], names: [("paypal", 3)], kind: .asset),
        .init(id: "credit", triggers: ["信用卡", "credit card", "visa", "master"], names: [("credit", 3), ("信用卡", 3), ("card", 1)], kind: .liability),
        .init(id: "debit", triggers: ["储蓄卡", "借记卡", "银行卡", "工资卡", "储蓄账户", "银行账户"],
              names: [("checking", 3), ("debit", 3), ("saving", 3), ("bank", 2), ("储蓄", 3), ("借记", 3), ("工资卡", 3), ("银行卡", 3)], kind: .asset),
    ]

    // MARK: Public API

    /// One mention of a payment account in the text, in order of appearance.
    struct FundingMention: Equatable, Sendable {
        let range: NSRange
        let account: String
        /// `微信`/`支付宝` name a payment channel that may draw on a card.
        var isChannel = false
    }

    private static let channelWords: Set<String> = ["微信", "微信支付", "wechat", "weixin", "wx", "支付宝", "alipay", "zfb"]

    /// `role` is the semantic role of a posting: expense, income, funding,
    /// receivable, payable, counterpart or unknown.
    static func match(role: String, text: String, accounts: [LedgerAccount], history: [LedgerTransaction] = [],
                      payee: String = "", excluding: Set<String> = []) -> String? {
        let usable = accounts.filter { $0.active && !excluding.contains($0.account) }
        switch role {
        case "expense":
            return fromHistory(payee: payee, prefixes: ["Expenses:"], history: history, accounts: usable)
                ?? category(text: text, accounts: usable, concepts: expenseConcepts, prefix: "Expenses:")
        case "income":
            return fromHistory(payee: payee, prefixes: ["Income:"], history: history, accounts: usable)
                ?? category(text: text, accounts: usable, concepts: incomeConcepts, prefix: "Income:")
        case "receivable":
            return receivable(text: text, accounts: usable)
        case "payable":
            return payable(text: text, accounts: usable)
        case "funding":
            return paying(text: text, accounts: usable)
                ?? fromHistory(payee: payee, prefixes: ["Assets:", "Liabilities:"], history: history, accounts: usable)
                ?? defaultFunding(usable)
        case "counterpart":
            let mentions = fundingMentions(in: text, accounts: usable)
            if let target = direction(text, mentions: mentions).to { return target }
            // `信用卡还款 5000`: the debt being repaid is the target.
            if text.contains("还"), let debt = mentions.first(where: { $0.account.hasPrefix("Liabilities:") }) { return debt.account }
            return category(text: text, accounts: usable, concepts: expenseConcepts, prefix: "Expenses:")
                ?? category(text: text, accounts: usable, concepts: incomeConcepts, prefix: "Income:")
        default:
            return paying(text: text, accounts: usable)
                ?? category(text: text, accounts: usable, concepts: expenseConcepts, prefix: "Expenses:")
                ?? category(text: text, accounts: usable, concepts: incomeConcepts, prefix: "Income:")
        }
    }

    /// The account money leaves: the source of a two-account transfer, else
    /// the card behind a channel (`微信付的，招行信用卡`), else the first one named.
    static func paying(text: String, accounts: [LedgerAccount]) -> String? {
        let mentions = fundingMentions(in: text, accounts: accounts)
        let cards = Set(mentions.filter { !$0.isChannel }.map(\.account))
        if Set(mentions.map(\.account)).count >= 2, cards.count >= 2 || movesMoney(text),
           let source = direction(text, mentions: mentions).from { return source }
        return (mentions.first { !$0.isChannel } ?? mentions.first)?.account
    }

    /// Words that move money between the user's own accounts.
    static func movesMoney(_ text: String) -> Bool {
        ["转", "提现", "充值", "存", "到", "还"].contains(where: text.contains)
    }

    /// Transfer direction from the words around each account: `从工行转到招行`.
    static func direction(_ text: String, mentions: [FundingMention]) -> (from: String?, to: String?) {
        let folded = BookkeepingText.fold(text) as NSString
        var from: String?, to: String?
        var unplaced: [String] = []
        for mention in mentions {
            let window = folded.substring(with: NSRange(location: max(0, mention.range.location - 3), length: min(3, mention.range.location)))
            if ["到", "至", "进", "入", "还", "给", "存", "充", "还了", "充值", "转入", "打到", "到账"].contains(where: window.hasSuffix) {
                if to == nil { to = mention.account }
            } else if ["从", "用", "由", "自", "拿", "通过", "转出"].contains(where: window.hasSuffix) {
                if from == nil { from = mention.account }
            } else if !unplaced.contains(mention.account) {
                unplaced.append(mention.account)
            }
        }
        for account in unplaced where account != from && account != to {
            if from == nil { from = account } else if to == nil { to = account }
        }
        return (from, to)
    }

    /// Best expense or income account for the text, masking payment-channel
    /// words first so `交通银行` never reads as transport.
    static func category(text: String, accounts: [LedgerAccount], concepts: [Concept], prefix: String) -> String? {
        let masked = maskFunding(text.lowercased())
        let pool = accounts.filter { $0.account.hasPrefix(prefix) }
        guard !pool.isEmpty else { return nil }
        let byID = Dictionary(concepts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ranked: [(Concept, Double, Int)] = []
        for (order, concept) in concepts.enumerated() {
            let hits = concept.triggers.filter { masked.contains($0.lowercased()) }
            guard let longest = hits.map(\.count).max() else { continue }
            let value = Double(longest) + Double(hits.count - 1) * 0.25
            ranked.append((concept, concept.generic ? value - 1.5 : value, order))
        }
        ranked.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
        for (concept, _, _) in ranked {
            var current: Concept? = concept
            var visited: Set<String> = []
            while let step = current, visited.insert(step.id).inserted {
                if let account = bestAccount(pool, names: step.names) { return account }
                current = step.fallback.flatMap { byID[$0] }
            }
        }
        // A generic `Other`/`Misc` bucket only when the text named an income.
        return nil
    }

    /// Every payment account the text names, in order. A bank followed by
    /// `信用卡` resolves to the liability, by `储蓄卡` to the asset.
    static func fundingMentions(in text: String, accounts: [LedgerAccount]) -> [FundingMention] {
        let folded = BookkeepingText.fold(text).lowercased() as NSString
        let pool = accounts.filter { ($0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:")) && $0.active }
        var found: [(NSRange, String, Bool)] = []
        func claim(_ range: NSRange) -> Bool { !found.contains { NSIntersectionRange($0.0, range).length > 0 } }
        func occurrences(_ word: String) -> [NSRange] {
            var result: [NSRange] = []
            var search = NSRange(location: 0, length: folded.length)
            while true {
                let range = folded.range(of: word.lowercased(), options: [], range: search)
                guard range.location != NSNotFound else { break }
                // ASCII words must stand alone: `cmb` is not inside `cmbc`.
                let ascii = word.unicodeScalars.allSatisfy(\.isASCII)
                let before = BookkeepingText.scalar(folded, range.location - 1)
                let after = BookkeepingText.scalar(folded, NSMaxRange(range))
                if !ascii || !(before.map { $0.isASCII && $0.properties.isAlphabetic } ?? false)
                    && !(after.map { $0.isASCII && $0.properties.isAlphabetic } ?? false) {
                    result.append(range)
                }
                search = NSRange(location: NSMaxRange(range), length: folded.length - NSMaxRange(range))
            }
            return result
        }
        // Card tail numbers identify one account outright.
        let tail = try! NSRegularExpression(pattern: "(?:尾号|末四位|末尾|卡号)\\s*([0-9]{4})")
        for match in tail.matches(in: folded as String, range: NSRange(location: 0, length: folded.length)) {
            let digits = folded.substring(with: match.range(at: 1))
            let hits = pool.filter { ($0.account + " " + ($0.alias ?? "") + " " + $0.label).contains(digits) }
            if hits.count == 1, claim(match.range) { found.append((match.range, hits[0].account, false)) }
        }
        for bank in banks {
            for trigger in bank.triggers {
                for range in occurrences(trigger) where claim(range) {
                    let window = NSRange(location: NSMaxRange(range), length: min(8, folded.length - NSMaxRange(range)))
                    let following = folded.substring(with: window)
                    let wantsCredit = following.hasPrefix("信用卡") || following.hasPrefix("银行信用卡") || following.hasPrefix("的信用卡")
                        || following.hasPrefix("visa") || following.hasPrefix("master")
                    let wantsDebit = ["储蓄卡", "借记卡", "银行储蓄卡", "银行借记卡", "工资卡", "银行卡", "卡"].contains { following.hasPrefix($0) } && !wantsCredit
                    let names = bank.names.map { ($0, 3.0) }
                    let liabilities = pool.filter { $0.account.hasPrefix("Liabilities:") }
                    let assets = pool.filter { $0.account.hasPrefix("Assets:") }
                    var account: String?
                    if wantsCredit {
                        account = bestAccount(liabilities, names: names)
                    } else if wantsDebit {
                        account = bestAccount(assets, names: names)
                    } else {
                        account = bestAccount(assets, names: names) ?? bestAccount(liabilities, names: names)
                    }
                    if let account {
                        var extended = range
                        if wantsCredit || wantsDebit {
                            let suffix = ["银行信用卡", "银行储蓄卡", "银行借记卡", "的信用卡", "信用卡", "储蓄卡", "借记卡", "工资卡", "银行卡", "卡"]
                                .first { following.hasPrefix($0) } ?? ""
                            extended.length += (suffix as NSString).length
                        }
                        found.append((extended, account, false))
                    }
                }
            }
        }
        for concept in fundingConcepts {
            let roots: [String]
            switch concept.kind {
            case .asset: roots = ["Assets:"]
            case .liability: roots = ["Liabilities:"]
            case .either: roots = ["Assets:", "Liabilities:"]
            }
            for trigger in concept.triggers {
                for range in occurrences(trigger) where claim(range) {
                    let candidates = pool.filter { account in roots.contains(where: account.account.hasPrefix) }
                    if let account = bestAccount(candidates, names: concept.names) {
                        found.append((range, account, channelWords.contains(trigger)))
                    }
                }
            }
        }
        return found.sorted { $0.0.location < $1.0.location }.map { FundingMention(range: $0.0, account: $0.1, isChannel: $0.2) }
    }

    static func receivable(text: String, accounts: [LedgerAccount]) -> String? {
        let pool = accounts.filter { $0.account.hasPrefix("Assets:") && $0.active }
        let candidates = pool.filter { score($0, names: [("receivable", 3), ("应收", 3), ("待收", 3), ("借出", 3), ("loan", 2), ("lent", 2), ("垫付", 3), ("advance", 2)]) > 0 }
        return person(in: text, among: candidates) ?? bestAccount(candidates, names: [("receivable", 3), ("应收", 3), ("待收", 3), ("借出", 3), ("loan", 2), ("垫付", 3)])
    }

    static func payable(text: String, accounts: [LedgerAccount]) -> String? {
        let pool = accounts.filter { $0.account.hasPrefix("Liabilities:") && $0.active }
        let names: [(String, Double)] = [("payable", 3), ("应付", 3), ("欠", 3), ("borrow", 3), ("loan", 2), ("借入", 3), ("debt", 2)]
        let candidates = pool.filter { score($0, names: names) > 0 }
        return person(in: text, among: candidates) ?? bestAccount(candidates, names: names)
    }

    /// The fallback payment account when the sentence names none: the
    /// everyday wallets first, then any active asset.
    static func defaultFunding(_ accounts: [LedgerAccount]) -> String? {
        let assets = accounts.filter { $0.account.hasPrefix("Assets:") && $0.active }
        for concept in fundingConcepts where ["wechat", "alipay", "cash"].contains(concept.id) {
            if let account = bestAccount(assets, names: concept.names) { return account }
        }
        let banks = assets.filter { score($0, names: [("bank", 3), ("checking", 3), ("储蓄", 3)]) > 0 }
        return banks.first?.account ?? assets.first {
            score($0, names: [("receivable", 3), ("应收", 3), ("待收", 3), ("invest", 3), ("stock", 3), ("fund", 2)]) == 0
        }?.account
    }

    // MARK: Scoring

    private static func person(in text: String, among candidates: [LedgerAccount]) -> String? {
        let words: [(String, [(String, Double)])] = [
            ("同事", [("colleague", 3), ("coworker", 3), ("同事", 3), ("work", 1)]),
            ("朋友", [("friend", 3), ("朋友", 3)]),
            ("家人", [("family", 3), ("家", 3)]), ("爸", [("family", 3), ("parent", 3), ("家", 3)]),
            ("妈", [("family", 3), ("parent", 3), ("家", 3)]), ("公司", [("company", 3), ("employer", 3), ("work", 2), ("公司", 3)]),
        ]
        for (word, names) in words where text.contains(word) {
            if let account = bestAccount(candidates, names: names) { return account }
        }
        return nil
    }

    private static func fromHistory(payee: String, prefixes: [String], history: [LedgerTransaction], accounts: [LedgerAccount]) -> String? {
        let key = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !history.isEmpty else { return nil }
        let allowed = Set(accounts.map(\.account))
        var counts: [String: (count: Int, latest: String)] = [:]
        for transaction in history where transaction.payee == key {
            for posting in transaction.postings where allowed.contains(posting.account) && prefixes.contains(where: posting.account.hasPrefix) {
                let entry = counts[posting.account] ?? (0, "")
                counts[posting.account] = (entry.count + 1, max(entry.latest, transaction.date))
            }
        }
        return counts.max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.value.latest < $1.value.latest }?.key
    }

    static func bestAccount(_ accounts: [LedgerAccount], names: [(String, Double)]) -> String? {
        var best: (String, Double, Int)?
        for account in accounts {
            let value = score(account, names: names)
            guard value > 0 else { continue }
            let depth = account.account.split(separator: ":").count
            if best == nil || value > best!.1 || value == best!.1 && depth < best!.2 {
                best = (account.account, value, depth)
            }
        }
        return best?.0
    }

    /// Highest weight among the names the account carries. A name in the last
    /// path segment or in the alias counts fully; a parent segment counts half.
    static func score(_ account: LedgerAccount, names: [(String, Double)]) -> Double {
        let segments = account.account.split(separator: ":").dropFirst().map(String.init)
        let leaf = segments.last.map(tokens) ?? []
        let parents = segments.dropLast().flatMap(tokens)
        let labels = [account.alias ?? "", account.label].map { $0.lowercased() }
        let labelTokens = labels.flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
        var own = 0.0, parent = 0.0
        for (name, weight) in names {
            let lowered = name.lowercased()
            let ascii = lowered.unicodeScalars.allSatisfy(\.isASCII)
            func hit(_ list: [String]) -> Bool {
                list.contains { ascii ? $0.hasPrefix(lowered) : $0.contains(lowered) }
            }
            if hit(leaf) || (ascii ? hit(labelTokens) : labels.contains { $0.contains(lowered) }) {
                own = max(own, weight)
            } else if hit(parents) {
                parent = max(parent, weight / 2)
            }
        }
        // `Shopping:Other` beats a bare `Other` for a shopping concept.
        return own + parent
    }

    /// `PublicTransport` → public, transport, publictransport.
    private static func tokens(_ segment: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in segment {
            if character == "-" || character == "_" {
                if !current.isEmpty { parts.append(current) }
                current = ""
            } else if character.isUppercase, let last = current.last, last.isLowercase {
                parts.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return ([segment] + parts).map { $0.lowercased() }
    }

    private static func maskFunding(_ text: String) -> String {
        var masked = text
        // Transit cards stay visible: `交通卡充值` is a transport expense.
        let words = banks.flatMap(\.triggers) + fundingConcepts.filter { $0.id != "transitCard" }.flatMap(\.triggers) + ["银行"]
        for word in words.sorted(by: { $0.count > $1.count }) where word.count >= 2 && !word.unicodeScalars.allSatisfy(\.isASCII) {
            masked = masked.replacingOccurrences(of: word, with: String(repeating: "\u{3000}", count: word.count))
        }
        return masked
    }

    // MARK: Candidate lists for the editor

    static func categoryCandidates(selected: String, accounts: [LedgerAccount]) -> [LedgerAccount] {
        let active = accounts.filter { ($0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:")) && $0.active }
        var result: [LedgerAccount] = []
        if let current = active.first(where: { $0.account == selected }) {
            result.append(current)
            let prefixParts = selected.components(separatedBy: ":").prefix(2).joined(separator: ":")
            let siblings = active.filter { $0.account.hasPrefix(prefixParts) && $0.account != selected }
            result.append(contentsOf: siblings.prefix(3))
        }
        for acc in active where !result.contains(where: { $0.account == acc.account }) {
            result.append(acc)
            if result.count >= 5 { break }
        }
        return result
    }

    static func fundingCandidates(selected: String, accounts: [LedgerAccount]) -> [LedgerAccount] {
        let active = accounts.filter { ($0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:")) && $0.active }
        var result: [LedgerAccount] = []
        if let current = active.first(where: { $0.account == selected }) {
            result.append(current)
        }
        let priorityKeywords = ["wechat", "weixin", "alipay", "cmb", "icbc", "creditcard", "cash"]
        for kw in priorityKeywords {
            if let match = active.first(where: { acc in
                !result.contains(where: { $0.account == acc.account }) &&
                (acc.account.lowercased().contains(kw) || acc.displayLabel.lowercased().contains(kw))
            }) {
                result.append(match)
            }
            if result.count >= 5 { break }
        }
        for acc in active where !result.contains(where: { $0.account == acc.account }) {
            result.append(acc)
            if result.count >= 5 { break }
        }
        return result
    }
}
