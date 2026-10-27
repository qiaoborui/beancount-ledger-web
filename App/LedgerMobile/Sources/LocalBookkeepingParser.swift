import Foundation

/// Rule-based parser for everyday Chinese bookkeeping sentences. It needs no
/// network or model: it runs when no semantic service is configured, when the
/// service fails, and its readings ground the service's own answer.
///
/// Every amount it writes is read from the text, so the draft carries the same
/// guarantee as the model path: nothing is invented, gaps become questions.
struct LocalBookkeepingParser: BookkeepingSemanticParser {
    var history: [LedgerTransaction] = []

    func parse(_ input: BookkeepingParseInput) async throws -> BookkeepingDraft {
        draft(for: input)
    }

    enum Kind: String, Sendable {
        case expense, income, refund, transfer, lend, collect, borrow, repayDebt
    }

    /// One transaction found in the text, before accounts are chosen.
    struct Reading: Sendable {
        var ranges: [NSRange]
        var amount: BookkeepingText.Amount
        var splits: [(amount: BookkeepingText.Amount, range: NSRange)] = []
        var date: String
        var kind: Kind = .expense
    }

    func draft(for input: BookkeepingParseInput) -> BookkeepingDraft {
        let readings = Self.readings(input.text, reference: input.referenceDate)
        let source = input.text as NSString
        var questions: [String] = []
        var records: [LedgerTransactionEntry] = []
        var roles: [[String]] = []
        var evidence: [String] = []
        for (index, reading) in readings.enumerated() {
            let text = reading.ranges.map { source.substring(with: $0) }.joined(separator: "，")
            let built = build(reading, text: text, input: input)
            records.append(built.entry)
            roles.append(built.roles)
            evidence.append(text)
            for (postingIndex, posting) in built.entry.postings.enumerated() where posting.account.isEmpty {
                questions.append(String(localized: "第 \(index + 1) 笔第 \(postingIndex + 1) 条分录需要选择账户。"))
            }
            questions += built.questions.map { String(localized: "第 \(index + 1) 笔：\($0)") }
        }
        if records.isEmpty {
            questions.append(String(localized: "没有识别到金额，请补充金额后重新解析。"))
        }
        var draft = BookkeepingDraft(records: records, evidence: [.make(.naturalLanguage, original: input.text,
            locator: input.referenceDate + " " + input.timeZone)], questions: questions, accountRoles: roles)
        draft.recordEvidence = evidence
        return draft
    }

    // MARK: Reading the text

    private static let separators: Set<Unicode.Scalar> = ["，", ",", "；", ";", "。", "！", "!", "？", "?", "\n", "、"]
    private static let splitWords = ["其中", "里面", "包括", "包含", "这里面", "含"]
    private static let totalWords = ["一共", "总共", "合计", "共计", "总计", "总额", "共"]

    static func clauses(_ folded: NSString, amounts: [BookkeepingText.Amount]) -> [NSRange] {
        var result: [NSRange] = []
        var start = 0
        for location in 0...folded.length {
            let isEnd = location == folded.length
            if !isEnd {
                guard let scalar = BookkeepingText.scalar(folded, location), separators.contains(scalar) else { continue }
                // Thousands separators and dates live inside an amount.
                if amounts.contains(where: { NSLocationInRange(location, $0.range) }) { continue }
            }
            let range = trimmed(folded, NSRange(location: start, length: location - start))
            if range.length > 0 { result.append(range) }
            start = location + 1
        }
        return result
    }

    static func readings(_ text: String, reference: String) -> [Reading] {
        let folded = BookkeepingText.fold(text) as NSString
        let dates = BookkeepingText.dates(in: text, reference: reference)
        let amounts = BookkeepingText.amounts(in: text).filter { amount in
            !dates.contains { NSIntersectionRange($0.range, amount.range).length > 0 }
        }
        let clauses = clauses(folded, amounts: amounts)
        var readings: [Reading] = []
        var pending: [NSRange] = []
        var carriedDate: String?
        var sinceTotal = Decimal(0)
        var readingsSinceTotal = 0
        for (index, clause) in clauses.enumerated() {
            let clauseDate = dates.first { NSLocationInRange($0.range.location, clause) }?.date
            if let clauseDate { carriedDate = clauseDate }
            var own = amounts.filter { NSLocationInRange($0.range.location, clause) }
            if own.contains(where: { !$0.weak }) { own.removeAll(where: \.weak) }
            let clauseText = folded.substring(with: clause)
            guard !own.isEmpty else {
                // Context without an amount joins the previous transaction, or
                // the next one when it describes what that next amount bought.
                let next = clauses.indices.contains(index + 1) ? clauses[index + 1] : nil
                let nextHasAmount = next.map { range in amounts.contains { NSLocationInRange($0.range.location, range) } } ?? false
                let describesNext = nextHasAmount && hasCategory(clauseText) && !hasCategory(next.map { stripped(folded, $0, amounts: amounts) } ?? "")
                if readings.isEmpty || describesNext {
                    pending.append(clause)
                } else {
                    readings[readings.count - 1].ranges.append(clause)
                    if let clauseDate, !hasDate(readings[readings.count - 1], dates) { readings[readings.count - 1].date = clauseDate }
                }
                continue
            }
            // `其中 48 元替同事垫付` divides the previous transaction.
            if !readings.isEmpty, splitWords.contains(where: clauseText.hasPrefix) || splitWords.contains(where: { clauseText.contains($0) }) && own.count == 1
                && !totalWords.contains(where: clauseText.contains) {
                for amount in own { readings[readings.count - 1].splits.append((amount, clause)) }
                readings[readings.count - 1].ranges.append(clause)
                continue
            }
            // `一共 55` that only restates the sum of what came before.
            if own.count == 1, readingsSinceTotal >= 2 || readingsSinceTotal == 1 && !hasCategory(stripped(folded, clause, amounts: amounts)),
               totalWords.contains(where: clauseText.contains), own[0].value == sinceTotal {
                readings[readings.count - 1].ranges.append(clause)
                sinceTotal = 0
                readingsSinceTotal = 0
                continue
            }
            for segment in segments(folded, clause: clause, amounts: own) {
                let date = dates.first { NSLocationInRange($0.range.location, segment.range) }?.date ?? clauseDate ?? carriedDate ?? reference
                readings.append(Reading(ranges: pending + [segment.range], amount: segment.amount, date: date))
                pending = []
                sinceTotal += segment.amount.value
                readingsSinceTotal += 1
            }
        }
        if !pending.isEmpty, !readings.isEmpty { readings[readings.count - 1].ranges += pending }
        return readings
    }

    /// Several amounts in one clause: `午饭35打车20` describes each amount by
    /// the words before it; `花35吃午饭花20打车` by the words after it.
    private static func segments(_ folded: NSString, clause: NSRange, amounts: [BookkeepingText.Amount]) -> [(range: NSRange, amount: BookkeepingText.Amount)] {
        guard amounts.count > 1 else { return [(clause, amounts[0])] }
        let head = folded.substring(with: NSRange(location: clause.location, length: amounts[0].range.location - clause.location))
        let lastEnd = NSMaxRange(amounts[amounts.count - 1].range)
        let tail = folded.substring(with: NSRange(location: lastEnd, length: NSMaxRange(clause) - lastEnd))
        let trailing = !hasCategory(head) && hasCategory(tail)
        var result: [(NSRange, BookkeepingText.Amount)] = []
        for (index, amount) in amounts.enumerated() {
            let start: Int, end: Int
            if trailing {
                start = amount.range.location
                end = index + 1 < amounts.count ? amounts[index + 1].range.location : NSMaxRange(clause)
                // Words before the first amount (a date, a channel) belong to it.
                let lead = index == 0 ? clause.location : start
                result.append((NSRange(location: lead, length: end - lead), amount))
            } else {
                start = index == 0 ? clause.location : NSMaxRange(amounts[index - 1].range)
                end = index + 1 < amounts.count ? NSMaxRange(amount.range) : NSMaxRange(clause)
                result.append((NSRange(location: start, length: end - start), amount))
            }
        }
        return result
    }

    private static func hasDate(_ reading: Reading, _ dates: [BookkeepingText.DateMention]) -> Bool {
        dates.contains { date in reading.ranges.contains { NSLocationInRange(date.range.location, $0) } }
    }

    private static func hasCategory(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return (BookkeepingAccountMatcher.expenseConcepts + BookkeepingAccountMatcher.incomeConcepts)
            .contains { $0.triggers.contains { $0.count >= 2 && lowered.contains($0.lowercased()) } }
    }

    private static func stripped(_ folded: NSString, _ range: NSRange, amounts: [BookkeepingText.Amount]) -> String {
        let text = NSMutableString(string: folded.substring(with: range))
        for amount in amounts.reversed() where NSLocationInRange(amount.range.location, range) {
            text.replaceCharacters(in: NSRange(location: amount.range.location - range.location, length: amount.range.length), with: " ")
        }
        return text as String
    }

    private static func trimmed(_ text: NSString, _ range: NSRange) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        while start < end, let scalar = BookkeepingText.scalar(text, start), scalar.properties.isWhitespace { start += 1 }
        while end > start, let scalar = BookkeepingText.scalar(text, end - 1), scalar.properties.isWhitespace { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Building a transaction

    private struct Built {
        var entry: LedgerTransactionEntry
        var roles: [String]
        var questions: [String]
    }

    static func kind(of text: String, fundingCount: Int, hasLiability: Bool) -> Kind {
        let t = BookkeepingText.fold(text).lowercased()
        func any(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        func matches(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }
        if any(["退款", "退了", "退回", "退货", "返现", "退钱", "退费", "退还", "退给我", "返还"]) && !t.contains("退税") { return .refund }
        if fundingCount >= 2 || any(["还信用卡", "信用卡还款", "还花呗", "还白条", "还借呗", "提现"]) || hasLiability && any(["还款", "还了", "还"]) && !any(["还我", "还给我"]) {
            return .transfer
        }
        if matches("(借给|借出|垫付|代付|垫了|垫钱|先垫)") && !matches("(帮我|替我)") || matches("(帮|替)(?!我).{0,6}(付|垫|买|交)") { return .lend }
        if matches("还(了)?(给)?我") || any(["收回", "把钱还"]) { return .collect }
        if matches("(还给|还钱给|还朋友|还同事|还爸|还妈)") { return .repayDebt }
        if matches("(向|找|跟|问).{0,6}借") || any(["借了", "借来", "借到"]) { return .borrow }
        let incomeWords = ["工资", "薪水", "薪资", "发薪", "奖金", "年终奖", "提成", "分红", "利息", "收益", "报销", "退税", "收到", "收入",
                           "入账", "进账", "赚了", "兼职", "稿费", "外快", "收红包", "抢红包", "压岁钱", "卖了", "出售", "到账", "领了"]
        if any(incomeWords) && !matches("(发|给|包).{0,6}红包") { return .income }
        return .expense
    }

    private func build(_ reading: Reading, text: String, input: BookkeepingParseInput) -> Built {
        let accounts = input.accounts.filter { $0.active && $0.openDate <= reading.date && ($0.closeDate.map { $0 > reading.date } ?? true) }
        let mentions = BookkeepingAccountMatcher.fundingMentions(in: text, accounts: accounts)
        let distinct = mentions.map(\.account).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        // `微信付的，招行信用卡` names one card through a channel, not a transfer.
        let cards = Set(mentions.filter { !$0.isChannel }.map(\.account))
        let accountCount = cards.count >= 2 || BookkeepingAccountMatcher.movesMoney(text) ? distinct.count : cards.count
        // A split clause (`其中 48 元替同事垫付`) does not change what the
        // transaction itself is.
        let source = input.text as NSString
        let mainText = reading.ranges.filter { range in !reading.splits.contains { $0.range == range } }
            .map { source.substring(with: $0) }.joined(separator: "，")
        let kind = Self.kind(of: mainText, fundingCount: accountCount, hasLiability: distinct.contains { $0.hasPrefix("Liabilities:") })
        let currency = reading.amount.currency ?? Self.currencyWord(in: text) ?? input.currency
        let payee = Self.payee(in: text)
        let total = reading.amount.value
        var questions: [String] = []
        var postings: [(String, Decimal, String)] = []
        let categoryText = text
        func funding(excluding: Set<String> = []) -> String {
            BookkeepingAccountMatcher.match(role: "funding", text: text, accounts: accounts, history: history,
                                            payee: payee, excluding: excluding) ?? ""
        }
        func expenseAccount() -> String {
            BookkeepingAccountMatcher.match(role: "expense", text: categoryText, accounts: accounts, history: history, payee: payee) ?? ""
        }
        switch kind {
        case .expense:
            var own = total
            var splitPostings: [(String, Decimal, String)] = []
            for split in reading.splits {
                let splitText = (input.text as NSString).substring(with: split.range)
                let splitKind = Self.kind(of: splitText, fundingCount: 0, hasLiability: false)
                if splitKind == .lend || splitKind == .collect {
                    splitPostings.append((BookkeepingAccountMatcher.receivable(text: splitText, accounts: accounts) ?? "", split.amount.value, "receivable"))
                } else {
                    let account = BookkeepingAccountMatcher.match(role: "expense", text: splitText, accounts: accounts) ?? ""
                    splitPostings.append((account, split.amount.value, "expense"))
                }
                own -= split.amount.value
            }
            if own < 0 || own == 0 && !reading.splits.isEmpty && splitPostings.allSatisfy({ $0.2 != "receivable" }) {
                // Parts that do not fit inside the total stay with the user.
                questions.append(String(localized: "拆分金额超过总额，请核对。"))
                own = total
                splitPostings = []
            }
            if own > 0 { postings.append((expenseAccount(), own, "expense")) }
            postings += splitPostings
            postings.append((funding(), -total, "funding"))
        case .income:
            let income = BookkeepingAccountMatcher.match(role: "income", text: categoryText, accounts: accounts, history: history, payee: payee)
                ?? BookkeepingAccountMatcher.bestAccount(accounts.filter { $0.account.hasPrefix("Income:") }, names: [("other", 3), ("misc", 3), ("其他", 3)])
            postings = [(funding(), total, "funding"), (income ?? "", -total, "income")]
        case .refund:
            postings = [(funding(), total, "funding"), (expenseAccount(), -total, "expense")]
        case .transfer:
            let (from, to) = BookkeepingAccountMatcher.direction(text, mentions: mentions)
            var source = from
            var target = to
            if target == nil, source?.hasPrefix("Liabilities:") == true { target = source; source = nil }
            if text.contains("提现"), target == nil {
                target = BookkeepingAccountMatcher.fundingMentions(in: "储蓄卡", accounts: accounts).first?.account
            }
            if source == nil { source = funding(excluding: Set([target].compactMap { $0 })) }
            if source == target { questions.append(String(localized: "转出和转入账户相同，请核对。")) }
            postings = [(target ?? "", total, "counterpart"), (source ?? "", -total, "funding")]
        case .lend:
            postings = [(BookkeepingAccountMatcher.receivable(text: text, accounts: accounts) ?? "", total, "receivable"), (funding(), -total, "funding")]
        case .collect:
            postings = [(funding(), total, "funding"), (BookkeepingAccountMatcher.receivable(text: text, accounts: accounts) ?? "", -total, "receivable")]
        case .borrow:
            postings = [(funding(), total, "funding"), (BookkeepingAccountMatcher.payable(text: text, accounts: accounts) ?? "", -total, "payable")]
        case .repayDebt:
            postings = [(BookkeepingAccountMatcher.payable(text: text, accounts: accounts) ?? "", total, "payable"), (funding(), -total, "funding")]
        }
        if ["AA", "aa", "人均", "每人", "平摊", "均摊"].contains(where: text.contains) {
            questions.append(String(localized: "包含分摊，请核对自己承担的金额。"))
        }
        let entry = LedgerTransactionEntry(date: reading.date, flag: "*", payee: payee,
            narration: Self.narration(text, payee: payee, reading: reading, kind: kind),
            postings: postings.map { .init(account: $0.0, amount: ExactBookkeepingAmount.text($0.1), currency: currency) })
        return Built(entry: entry, roles: postings.map(\.2), questions: questions)
    }

    private static let currencyWords: [(String, String)] = [
        ("美元", "USD"), ("美金", "USD"), ("刀", "USD"), ("港币", "HKD"), ("港元", "HKD"), ("日元", "JPY"), ("日币", "JPY"),
        ("欧元", "EUR"), ("英镑", "GBP"), ("人民币", "CNY"), ("韩元", "KRW"), ("澳元", "AUD"), ("加元", "CAD"), ("新币", "SGD"), ("泰铢", "THB"),
    ]

    private static func currencyWord(in text: String) -> String? {
        currencyWords.first { text.contains($0.0) }?.1
    }

    static let merchants: [String] = [
        "美团外卖", "美团", "饿了么", "星巴克", "瑞幸", "喜茶", "蜜雪冰城", "奈雪", "霸王茶姬", "库迪", "麦当劳", "肯德基", "汉堡王", "必胜客",
        "海底捞", "萨莉亚", "全家", "罗森", "7-11", "便利蜂", "美宜佳", "盒马", "山姆", "沃尔玛", "永辉", "叮咚买菜", "朴朴", "家乐福", "大润发",
        "Costco", "淘宝", "天猫", "京东", "拼多多", "闲鱼", "唯品会", "宜家", "优衣库", "无印良品", "滴滴", "高德", "曹操出行", "哈啰", "青桔",
        "12306", "携程", "飞猪", "去哪儿", "中国移动", "中国联通", "中国电信", "爱奇艺", "腾讯视频", "优酷", "网易云音乐", "网易云", "B站", "哔哩哔哩",
        "Apple", "苹果", "Steam", "Netflix", "Spotify", "iCloud", "ChatGPT", "Claude", "Kindle", "Amazon", "亚马逊",
    ]

    /// `在全家买`, `去海底捞吃`, or a known brand name.
    static func payee(in text: String) -> String {
        let folded = BookkeepingText.fold(text)
        let place = try! NSRegularExpression(pattern: "(?:在|去|到)([^\\s，,。；;0-9在去到了的]{2,10}?)(?:买|吃|喝|点|消费|付|花|充|办|看|打|加|用|订|刷|唱|玩|做|剪|理|拿|取)")
        let ns = folded as NSString
        if let match = place.firstMatch(in: folded, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            let generic = ["公司", "家里", "家", "楼下", "附近", "路上", "超市", "外面", "网上", "店里", "食堂", "医院", "学校", "单位"]
            if !generic.contains(name), BookkeepingAccountMatcher.fundingMentions(in: name, accounts: []).isEmpty,
               !["今天", "昨天", "中午", "晚上", "早上", "下午"].contains(where: name.hasPrefix) {
                return merchants.first { name.lowercased().hasPrefix($0.lowercased()) } ?? name
            }
        }
        let lowered = folded.lowercased()
        return merchants.filter { lowered.contains($0.lowercased()) }.max { $0.count < $1.count } ?? ""
    }

    private static let fillers = [
        "花了", "花费", "用了", "付了", "支付了", "支付", "付款", "扣款", "扣了", "消费", "一共", "总共", "合计", "共计", "块钱", "元钱",
        "大概", "左右", "差不多", "今天", "昨天", "前天", "今早", "今晚", "昨晚", "中午", "早上", "晚上", "下午", "上午", "刚刚", "刚才",
        "我", "了", "的", "用", "在", "去", "花", "付", "刷", "共", "元", "块", "钱", "从",
    ]

    /// The sentence with amounts, dates, payment accounts and filler removed.
    static func narration(_ text: String, payee: String, reading: Reading, kind: Kind) -> String {
        var result = BookkeepingText.fold(text)
        var removals = BookkeepingText.amounts(in: result).map(\.range)
        removals += BookkeepingText.dates(in: result, reference: reading.date).map(\.range)
        removals += BookkeepingAccountMatcher.fundingMentions(in: result, accounts: banksAndChannelsFixture).map(\.range)
        let mutable = NSMutableString(string: result)
        for range in removals.sorted(by: { $0.location > $1.location }) where NSMaxRange(range) <= mutable.length {
            mutable.replaceCharacters(in: range, with: " ")
        }
        result = mutable as String
        for word in ["支付宝", "微信", "零钱", "现金", "花呗", "信用卡", "储蓄卡", "银行卡", "白条", "余额宝", "零钱通"] {
            result = result.replacingOccurrences(of: word, with: " ")
        }
        for word in fillers.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: word, with: " ")
        }
        result = result.components(separatedBy: CharacterSet(charactersIn: " ，,。；;！!？?、\n\t¥$")).filter { !$0.isEmpty }.joined(separator: " ")
        if result.isEmpty {
            switch kind {
            case .income: return String(localized: "收入")
            case .refund: return String(localized: "退款")
            case .transfer: return String(localized: "转账")
            case .lend: return String(localized: "垫付")
            case .collect: return String(localized: "收回垫付")
            case .borrow: return String(localized: "借入")
            case .repayDebt: return String(localized: "还款")
            case .expense: return payee.isEmpty ? String(localized: "支出") : payee
            }
        }
        return String(result.prefix(60))
    }

    /// Synthetic accounts that make every channel and bank resolvable, used
    /// only to locate their names in text for removal from the narration.
    private static let banksAndChannelsFixture: [LedgerAccount] = {
        var accounts: [LedgerAccount] = []
        for concept in BookkeepingAccountMatcher.fundingConcepts {
            let root = concept.kind == .liability ? "Liabilities" : "Assets"
            accounts.append(.init(account: "\(root):\(concept.id)", openDate: "1970-01-01", closeDate: nil, currency: "",
                                  alias: concept.names.map(\.0).joined(separator: " "), label: "", group: "", active: true))
        }
        for (index, bank) in BookkeepingAccountMatcher.banks.enumerated() {
            for root in ["Assets", "Liabilities"] {
                accounts.append(.init(account: "\(root):Bank\(index)", openDate: "1970-01-01", closeDate: nil, currency: "",
                                      alias: bank.names.joined(separator: " "), label: "", group: "", active: true))
            }
        }
        return accounts
    }()

    /// Deterministic readings handed to the semantic service as grounding.
    static func hints(for input: BookkeepingParseInput) -> [String: Any] {
        let dates = BookkeepingText.dates(in: input.text, reference: input.referenceDate)
        let amounts = BookkeepingText.amounts(in: input.text).filter { amount in
            !dates.contains { NSIntersectionRange($0.range, amount.range).length > 0 }
        }
        let source = input.text as NSString
        return [
            "amounts": amounts.map { ["text": source.substring(with: $0.range), "value": $0.text, "currency": $0.currency ?? ""] },
            "dates": dates.map { ["text": source.substring(with: $0.range), "date": $0.date] },
        ]
    }
}

/// Uses the configured semantic service when there is one and falls back to
/// the local rules when there is none or its answer cannot be verified.
struct HybridBookkeepingParser: BookkeepingSemanticParser {
    let remote: (any BookkeepingSemanticParser)?
    var local = LocalBookkeepingParser()

    func parse(_ input: BookkeepingParseInput) async throws -> BookkeepingDraft {
        guard let remote else { return try await local.parse(input) }
        do {
            return try await remote.parse(input)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            var draft = try await local.parse(input)
            guard !draft.records.isEmpty else { throw error }
            draft.questions.insert(String(localized: "语义解析不可用（\(error.localizedDescription)），已改用本地规则解析，请核对。"), at: 0)
            return draft
        }
    }
}
