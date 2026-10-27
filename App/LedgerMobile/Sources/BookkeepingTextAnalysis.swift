import Foundation

/// Deterministic reading of everyday Chinese bookkeeping sentences: amounts
/// (Arabic, full-width, thousands separators, Chinese numerals, 块/毛/分),
/// currencies and relative dates. Every reading keeps the UTF-16 range of the
/// source text it came from, so callers can prove a value exists in the input.
enum BookkeepingText {
    struct Amount: Equatable, Sendable {
        let range: NSRange
        let value: Decimal
        /// ISO code when the text names one; nil means the ledger default.
        let currency: String?
        /// `一块蛋糕`-style readings that are dropped when the same clause has
        /// an explicit amount.
        let weak: Bool
        var text: String { ExactBookkeepingAmount.text(value) }
    }

    struct DateMention: Equatable, Sendable {
        let range: NSRange
        let date: String
    }

    /// Full-width digits, letters and money symbols folded to ASCII. Each UTF-16
    /// unit maps to exactly one unit, so ranges on the folded text address the
    /// original text. The full-width comma stays: it separates clauses.
    static func fold(_ text: String) -> String {
        var units = Array(text.utf16)
        for index in units.indices {
            let unit = units[index]
            switch unit {
            case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A, 0xFF04, 0xFF05, 0xFF0B, 0xFF0D, 0xFF0E, 0xFF0F, 0xFF1A:
                units[index] = unit - 0xFEE0
            case 0xFFE5: units[index] = 0x00A5 // ￥ → ¥
            case 0xFFE1: units[index] = 0x00A3 // ￡ → £
            case 0x3000: units[index] = 0x0020
            default: break
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: Amounts

    private static let currencyPrefixes: [(String, String)] = [
        ("US$", "USD"), ("HK$", "HKD"), ("S$", "SGD"), ("A$", "AUD"), ("C$", "CAD"), ("NT$", "TWD"),
        ("RMB", "CNY"), ("CNY", "CNY"), ("USD", "USD"), ("HKD", "HKD"), ("JPY", "JPY"), ("EUR", "EUR"),
        ("GBP", "GBP"), ("$", "USD"), ("¥", "CNY"), ("€", "EUR"), ("£", "GBP"),
    ]

    /// Longest spelling first. `""` keeps the ledger default currency.
    private static let currencyUnits: [(String, String)] = [
        ("新加坡元", "SGD"), ("新台币", "TWD"), ("人民币", "CNY"), ("dollars", "USD"), ("dollar", "USD"),
        ("块钱", ""), ("元钱", ""), ("美元", "USD"), ("美金", "USD"), ("港币", "HKD"), ("港元", "HKD"),
        ("港纸", "HKD"), ("日元", "JPY"), ("日币", "JPY"), ("欧元", "EUR"), ("英镑", "GBP"), ("韩元", "KRW"),
        ("澳元", "AUD"), ("加元", "CAD"), ("新币", "SGD"), ("台币", "TWD"), ("泰铢", "THB"), ("卢布", "RUB"),
        ("rmb", "CNY"), ("cny", "CNY"), ("usd", "USD"), ("hkd", "HKD"), ("jpy", "JPY"), ("yen", "JPY"),
        ("eur", "EUR"), ("gbp", "GBP"), ("krw", "KRW"), ("aud", "AUD"), ("cad", "CAD"), ("sgd", "SGD"),
        ("twd", "TWD"), ("thb", "THB"), ("刀", "USD"), ("円", "JPY"), ("块", ""), ("元", ""), ("圆", ""),
    ]

    /// A number directly followed by one of these is a quantity, time or date.
    private static let quantitySuffixes = [
        "分钟", "号线", "小时", "公里", "公斤", "个月", "千米", "月", "日", "号", "点", "时", "年", "天", "周", "岁",
        "楼", "层", "人", "位", "斤", "杯", "个", "件", "份", "次", "张", "瓶", "本", "盒", "袋", "箱", "只", "支",
        "条", "晚", "间", "折", "%", "度", "期", "秒", "分", "寸", "米", "克", "升", "包", "双", "套", "节", "站",
        "遍", "局", "场", "顿", "碗", "串", "粒", "片", "根", "颗", "台", "部", "辆", "趟", "块地", "成", "倍", "集",
        "km", "kg", "ml", "gb", "g", "l", ":", "：", "x", "×", "*",
    ]
    /// After a space only unambiguous units count: `32 晚餐` and `200 支付宝`
    /// start a new word, `3 斤` does not.
    private static let spacedQuantitySuffixes = [
        "分钟", "小时", "公里", "公斤", "个月", "斤", "杯", "个", "件", "张", "份", "瓶", "本", "盒", "袋", "箱", "只", "条", "碗", "顿",
        "双", "套", "km", "kg", "x", "×", "*",
    ]
    private static let modelWords: Set<String> = [
        "iphone", "ipad", "mate", "pixel", "galaxy", "note", "pro", "max", "plus", "ultra", "series", "gen", "ps", "xbox", "watch",
        "airpods", "model", "macbook", "mini", "nova", "redmi", "xiaomi", "honor", "oppo", "vivo", "version",
    ]
    private static let quantityPrefixes = ["尾号", "卡号", "末四位", "末尾", "编号", "号码", "第", "×", "*", "@"]
    private static let excludedNumbers: Set<String> = ["12306"]

    static func amounts(in text: String) -> [Amount] {
        let folded = fold(text) as NSString
        var result: [Amount] = []
        var consumed: [NSRange] = []
        let arabic = try! NSRegularExpression(pattern: #"([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.([0-9]+))?"#)
        for match in arabic.matches(in: folded as String, range: NSRange(location: 0, length: folded.length)) {
            // `3 块 5` already read the 5 as its minor unit.
            if consumed.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
            var start = match.range.location
            var end = NSMaxRange(match.range)
            // `2026-10-01`, `10/1`, `7-11` and `18:30` are not amounts.
            for separator: Unicode.Scalar in ["-", "/", ":"] {
                if scalar(folded, end) == separator, isDigit(folded, end + 1) { start = -1 }
                if scalar(folded, start - 1) == separator, isDigit(folded, start - 2) { start = -1 }
            }
            guard start >= 0, scalar(folded, start - 1) != "." else { continue }
            let raw = folded.substring(with: match.range).replacingOccurrences(of: ",", with: "")
            if excludedNumbers.contains(raw) { continue }
            guard var value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else { continue }
            var currency: String?
            var explicit = false
            // Prefix currency, allowing one space: `¥35`, `RMB 35`, `US$ 12`.
            for (symbol, code) in currencyPrefixes {
                var probe = start
                if probe > 0, scalar(folded, probe - 1) == " " { probe -= 1 }
                let length = (symbol as NSString).length
                guard probe >= length else { continue }
                if folded.substring(with: NSRange(location: probe - length, length: length)).uppercased() == symbol.uppercased() {
                    currency = code
                    explicit = true
                    start = probe - length
                    break
                }
            }
            // `iPhone15`, `ps5` and `iPhone 15` are model names; `唱K 300` is not.
            if !explicit, let previous = scalar(folded, start - 1), previous.isASCII, previous.properties.isAlphabetic { continue }
            if !explicit, scalar(folded, start - 1) == " ", modelWords.contains(wordBefore(folded, start - 1).lowercased()) { continue }
            if !explicit && hasAnyPrefixBefore(folded, start, quantityPrefixes) { continue }
            var cursor = skipSpaces(folded, end)
            if let (multiplier, length) = multiplier(folded, cursor) {
                value *= multiplier
                cursor += length
                end = cursor
                explicit = true
                cursor = skipSpaces(folded, cursor)
            }
            var weak = false
            if let unit = unitAt(folded, cursor) {
                cursor += unit.length
                end = cursor
                explicit = true
                if !unit.code.isEmpty { currency = unit.code }
                if unit.isMinor {
                    value /= 10
                    (value, end) = minorTail(folded, end, value: value, minorScale: 100)
                } else if unit.isYuan {
                    let before = end
                    (value, end) = minorTail(folded, end, value: value, minorScale: 10)
                    if end == before, unit.spelling == "块", isLooseNoun(folded, end), value <= 10 { weak = true }
                }
            } else if !explicit {
                if hasAnyPrefixAt(folded, cursor, cursor == end ? quantitySuffixes : spacedQuantitySuffixes) { continue }
            }
            result.append(.init(range: NSRange(location: start, length: end - start), value: value, currency: currency, weak: weak))
            consumed.append(NSRange(location: start, length: end - start))
        }
        result += chineseAmounts(folded, avoiding: consumed)
        return result.sorted { $0.range.location < $1.range.location }
    }

    private static let chineseDigits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "壹": 1, "二": 2, "贰": 2, "两": 2, "三": 3, "叁": 3, "四": 4, "肆": 4,
        "五": 5, "伍": 5, "六": 6, "陆": 6, "七": 7, "柒": 7, "八": 8, "捌": 8, "九": 9, "玖": 9,
    ]
    private static let chineseUnits: [Character: Int] = ["十": 10, "拾": 10, "百": 100, "佰": 100, "千": 1000, "仟": 1000]
    private static let chineseSections: [Character: Int] = ["万": 10_000, "亿": 100_000_000]

    /// `三十五` 35, `两千三` 2300, `一万五` 15000, `一百零五` 105, `十` 10.
    static func chineseNumber(_ text: String) -> Decimal? {
        guard !text.isEmpty else { return nil }
        var total = Decimal(0), section = Decimal(0), number = Decimal(0)
        var lastUnit = Decimal(1)
        var previousWasUnit = false
        var sawDigitAfterUnit = false
        for character in text {
            if let digit = chineseDigits[character] {
                if digit == 0 { lastUnit = 10; previousWasUnit = false; sawDigitAfterUnit = false; continue }
                number = Decimal(digit)
                sawDigitAfterUnit = previousWasUnit
                previousWasUnit = false
            } else if let unit = chineseUnits[character] {
                if number == 0 { number = 1 }
                section += number * Decimal(unit)
                number = 0
                lastUnit = Decimal(unit)
                previousWasUnit = true
                sawDigitAfterUnit = false
            } else if let unit = chineseSections[character] {
                section += number
                if section == 0 { section = 1 }
                total += section * Decimal(unit)
                section = 0
                number = 0
                lastUnit = Decimal(unit)
                previousWasUnit = true
                sawDigitAfterUnit = false
            } else {
                return nil
            }
        }
        // Colloquial tail: `两千三` is 2300, `一万五` is 15000.
        if sawDigitAfterUnit, lastUnit >= 10 { number *= lastUnit / 10 }
        return total + section + number
    }

    private static func chineseAmounts(_ folded: NSString, avoiding consumed: [NSRange]) -> [Amount] {
        let pattern = try! NSRegularExpression(pattern: "[零〇一壹二贰两三叁四肆五伍六陆七柒八捌九玖十拾百佰千仟万亿]+(?:点[零〇一二三四五六七八九]+)?")
        var result: [Amount] = []
        for match in pattern.matches(in: folded as String, range: NSRange(location: 0, length: folded.length)) {
            guard !consumed.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let token = folded.substring(with: match.range)
            let parts = token.components(separatedBy: "点")
            guard var value = chineseNumber(parts[0]) else { continue }
            if parts.count == 2 {
                let fraction = parts[1].compactMap { chineseDigits[$0] }.map(String.init).joined()
                guard let decimal = Decimal(string: "0." + fraction, locale: Locale(identifier: "en_US_POSIX")) else { continue }
                value += decimal
            }
            var end = NSMaxRange(match.range)
            let cursor = skipSpaces(folded, end)
            guard let unit = unitAt(folded, cursor) else {
                // `打车花了一百二`: a numeral with a place value is an amount
                // unless a quantity, date or holiday follows (`十一假期`).
                let hasPlace = token.contains { chineseUnits[$0] != nil || chineseSections[$0] != nil }
                if hasPlace, token.count >= 2, !hasAnyPrefixAt(folded, cursor, quantitySuffixes + ["假", "长假", "黄金周", "期间"]) {
                    result.append(.init(range: match.range, value: value, currency: nil, weak: false))
                }
                continue
            }
            // `一块去`, `一起`: together, not one yuan.
            if unit.spelling == "块", value == 1, hasAnyPrefixAt(folded, cursor + 1, ["去", "吃", "玩", "走", "儿", "来", "做", "回", "坐", "住", "买", "出"]) { continue }
            end = cursor + unit.length
            var weak = false
            if unit.isMinor {
                value /= 10
                (value, end) = minorTail(folded, end, value: value, minorScale: 100)
            } else if unit.isYuan {
                let before = end
                (value, end) = minorTail(folded, end, value: value, minorScale: 10)
                if end == before, unit.spelling == "块", isLooseNoun(folded, end), value <= 10 { weak = true }
            }
            result.append(.init(range: NSRange(location: match.range.location, length: end - match.range.location),
                                value: value, currency: unit.code.isEmpty ? nil : unit.code, weak: weak))
        }
        return result
    }

    private struct Unit { let spelling: String; let code: String; let length: Int; let isYuan: Bool; let isMinor: Bool }

    private static func unitAt(_ text: NSString, _ location: Int) -> Unit? {
        for (spelling, code) in currencyUnits where hasPrefixAt(text, location, spelling, caseInsensitive: true) {
            // `rmb` and friends must not run into a longer word.
            let length = (spelling as NSString).length
            if spelling.first?.isASCII == true, let next = scalar(text, location + length), next.properties.isAlphabetic, next.isASCII { continue }
            return .init(spelling: spelling, code: code, length: length,
                         isYuan: ["块", "元", "圆", "块钱", "元钱"].contains(spelling), isMinor: false)
        }
        for spelling in ["毛钱", "毛", "角"] where hasPrefixAt(text, location, spelling) {
            return .init(spelling: spelling, code: "", length: (spelling as NSString).length, isYuan: false, isMinor: true)
        }
        return nil
    }

    private static func multiplier(_ text: NSString, _ location: Int) -> (Decimal, Int)? {
        if hasPrefixAt(text, location, "万") { return (10_000, 1) }
        if hasPrefixAt(text, location, "千") { return (1_000, 1) }
        for (letter, value) in [("k", Decimal(1_000)), ("w", Decimal(10_000))] where hasPrefixAt(text, location, letter, caseInsensitive: true) {
            if let next = scalar(text, location + 1), next.properties.isAlphabetic, next.isASCII { return nil }
            return (value, 1)
        }
        return nil
    }

    /// `35块5`, `三块五毛`, `十块半`, `八毛五`, `5元3角2分`.
    private static func minorTail(_ text: NSString, _ location: Int, value: Decimal, minorScale: Int) -> (Decimal, Int) {
        var value = value, cursor = skipSpaces(text, location)
        if minorScale == 10, hasPrefixAt(text, cursor, "半") { return (value + Decimal(string: "0.5")!, cursor + 1) }
        guard let digit = digitAt(text, cursor), !isDigitOrChineseDigit(text, cursor + 1) else { return (value, location) }
        // A digit that starts a new quantity (`35元2杯`) is not a minor unit.
        if hasAnyPrefixAt(text, cursor + 1, quantitySuffixes.filter { $0 != "分" }) { return (value, location) }
        // `35元 5元打车` starts a second amount.
        if let next = unitAt(text, skipSpaces(text, cursor + 1)), next.isYuan || !next.code.isEmpty { return (value, location) }
        value += Decimal(digit) / Decimal(minorScale)
        cursor += 1
        if minorScale == 10 {
            cursor = skipSpaces(text, cursor)
            if hasPrefixAt(text, cursor, "毛") || hasPrefixAt(text, cursor, "角") {
                cursor += 1
                if let fen = digitAt(text, cursor), hasPrefixAt(text, cursor + 1, "分") || !isDigitOrChineseDigit(text, cursor + 1) && !isLooseNoun(text, cursor + 1) {
                    value += Decimal(fen) / 100
                    cursor += hasPrefixAt(text, cursor + 1, "分") ? 2 : 1
                }
            }
        } else if hasPrefixAt(text, cursor, "分") {
            cursor += 1
        }
        return (value, cursor)
    }

    private static func digitAt(_ text: NSString, _ location: Int) -> Int? {
        guard let scalar = scalar(text, location) else { return nil }
        if let value = scalar.properties.numericType != nil && scalar.isASCII ? Int(String(scalar)) : nil { return value }
        if let value = chineseDigits[Character(scalar)], value > 0 { return value }
        return nil
    }

    private static func isDigitOrChineseDigit(_ text: NSString, _ location: Int) -> Bool {
        guard let scalar = scalar(text, location) else { return false }
        return scalar.isASCII && scalar.properties.numericType != nil || chineseDigits[Character(scalar)] != nil
            || chineseUnits[Character(scalar)] != nil
    }

    /// A CJK character that is neither money vocabulary nor a verb we read as a
    /// price (`5块买了瓶水`).
    private static func isLooseNoun(_ text: NSString, _ location: Int) -> Bool {
        guard let scalar = scalar(text, location), (0x4E00...0x9FFF).contains(Int(scalar.value)) else { return false }
        return !"钱买花付用给的吧啊呢了左右多和".unicodeScalars.contains(scalar)
    }

    // MARK: Dates

    static func dates(in text: String, reference: String) -> [DateMention] {
        guard let today = day(reference) else { return [] }
        let folded = fold(text) as NSString
        let whole = NSRange(location: 0, length: folded.length)
        var result: [DateMention] = []
        func add(_ range: NSRange, _ date: Date?) {
            guard let date, !result.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
            result.append(.init(range: range, date: string(date)))
        }
        let calendar = gregorian
        let number = "([0-9]{1,2}|[一二三四五六七八九十两]{1,3})"
        // 2026-10-01, 2026/10/1, 2026.10.1, 2026年10月1日
        let full = try! NSRegularExpression(pattern: #"(20[0-9]{2})\s*[-/.年]\s*([0-9]{1,2})\s*[-/.月]\s*([0-9]{1,2})\s*[日号]?"#)
        for match in full.matches(in: folded as String, range: whole) {
            add(match.range, make(year: int(folded, match.range(at: 1)), month: int(folded, match.range(at: 2)), day: int(folded, match.range(at: 3))))
        }
        // 10月1日, 十月一号, 上个月5号, 上月5号
        let monthDay = try! NSRegularExpression(pattern: "(上个?月|这个?月|本月)?" + number + "月" + number + "[日号]?")
        for match in monthDay.matches(in: folded as String, range: whole) {
            guard let month = smallNumber(folded, match.range(at: 2)), let dayNumber = smallNumber(folded, match.range(at: 3)) else { continue }
            let components = calendar.dateComponents([.year], from: today)
            var date = make(year: components.year, month: month, day: dayNumber)
            if let candidate = date, candidate > today { date = calendar.date(byAdding: .year, value: -1, to: candidate) }
            add(match.range, date)
        }
        // 上个月5号, 5号, 5日 (not 5号线)
        let dayOnly = try! NSRegularExpression(pattern: "(上上个?月|上个?月|这个?月|本月)?" + number + "[号日](?!线)")
        for match in dayOnly.matches(in: folded as String, range: whole) {
            if match.range.location > 0, let previous = scalar(folded, match.range.location - 1),
               previous == "月" || previous == "尾" || previous == "第" || previous.isASCII && previous.properties.numericType != nil { continue }
            guard let dayNumber = smallNumber(folded, match.range(at: 2)) else { continue }
            let prefix = match.range(at: 1).location == NSNotFound ? "" : folded.substring(with: match.range(at: 1))
            var monthOffset = prefix.hasPrefix("上上") ? -2 : prefix.hasPrefix("上") ? -1 : 0
            var components = calendar.dateComponents([.year, .month], from: today)
            if prefix.isEmpty, let dayToday = calendar.dateComponents([.day], from: today).day, dayNumber > dayToday { monthOffset = -1 }
            components.day = 1
            guard let first = calendar.date(from: components), let month = calendar.date(byAdding: .month, value: monthOffset, to: first) else { continue }
            let parts = calendar.dateComponents([.year, .month], from: month)
            add(match.range, make(year: parts.year, month: parts.month, day: dayNumber))
        }
        // 上周五, 周三, 星期天, 礼拜六, 这周一
        let weekday = try! NSRegularExpression(pattern: "(上上|上个?|这个?|本|下个?)?(?:周|星期|礼拜)([一二三四五六日天1-7])")
        for match in weekday.matches(in: folded as String, range: whole) {
            let prefix = match.range(at: 1).location == NSNotFound ? "" : folded.substring(with: match.range(at: 1))
            let token = folded.substring(with: match.range(at: 2))
            let target = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7][token] ?? 1
            // Monday-first week index of today.
            let todayIndex = (calendar.component(.weekday, from: today) + 5) % 7 + 1
            var delta: Int
            if prefix.hasPrefix("上上") { delta = target - todayIndex - 14 }
            else if prefix.hasPrefix("上") { delta = target - todayIndex - 7 }
            else if prefix.hasPrefix("下") { delta = target - todayIndex + 7 }
            else if prefix.isEmpty { delta = target - todayIndex; if delta > 0 { delta -= 7 } }
            else { delta = target - todayIndex }
            add(match.range, calendar.date(byAdding: .day, value: delta, to: today))
        }
        // N天前
        let daysAgo = try! NSRegularExpression(pattern: number + "天前")
        for match in daysAgo.matches(in: folded as String, range: whole) {
            guard let count = smallNumber(folded, match.range(at: 1)) else { continue }
            add(match.range, calendar.date(byAdding: .day, value: -count, to: today))
        }
        // Relative words, longest first.
        let words: [(String, Int)] = [("大前天", -3), ("大后天", 3), ("前天", -2), ("前晚", -2), ("昨天", -1), ("昨日", -1), ("昨晚", -1),
                                      ("昨早", -1), ("昨儿", -1), ("昨夜", -1), ("今天", 0), ("今日", 0), ("今早", 0), ("今晚", 0),
                                      ("今儿", 0), ("今晨", 0), ("明天", 1), ("后天", 2)]
        for (word, offset) in words {
            var search = whole
            while true {
                let found = folded.range(of: word, options: [], range: search)
                guard found.location != NSNotFound else { break }
                add(found, calendar.date(byAdding: .day, value: offset, to: today))
                search = NSRange(location: NSMaxRange(found), length: folded.length - NSMaxRange(found))
            }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    static let gregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return make(year: parts[0], month: parts[1], day: parts[2])
    }

    static func string(_ date: Date) -> String {
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func make(year: Int?, month: Int?, day: Int?) -> Date? {
        guard let year, let month, let day, (1...12).contains(month), (1...31).contains(day) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        // `2月30日` rolls over in `Calendar`; reject it instead.
        guard let date = gregorian.date(from: components), gregorian.component(.month, from: date) == month,
              gregorian.component(.day, from: date) == day else { return nil }
        return date
    }

    private static func int(_ text: NSString, _ range: NSRange) -> Int? {
        range.location == NSNotFound ? nil : Int(text.substring(with: range))
    }

    private static func smallNumber(_ text: NSString, _ range: NSRange) -> Int? {
        guard range.location != NSNotFound else { return nil }
        let token = text.substring(with: range)
        if let value = Int(token) { return value }
        return chineseNumber(token).map { NSDecimalNumber(decimal: $0).intValue }
    }

    // MARK: Low-level scanning

    static func scalar(_ text: NSString, _ location: Int) -> Unicode.Scalar? {
        guard location >= 0, location < text.length else { return nil }
        return Unicode.Scalar(text.character(at: location))
    }

    private static func isDigit(_ text: NSString, _ location: Int) -> Bool {
        guard let scalar = scalar(text, location) else { return false }
        return scalar.isASCII && scalar.properties.numericType != nil
    }

    private static func wordBefore(_ text: NSString, _ location: Int) -> String {
        var start = location
        while let scalar = scalar(text, start - 1), scalar.isASCII, scalar.properties.isAlphabetic { start -= 1 }
        return text.substring(with: NSRange(location: start, length: location - start))
    }

    private static func skipSpaces(_ text: NSString, _ location: Int) -> Int {
        var cursor = location
        while scalar(text, cursor) == " " { cursor += 1 }
        return cursor
    }

    static func hasPrefixAt(_ text: NSString, _ location: Int, _ prefix: String, caseInsensitive: Bool = false) -> Bool {
        let length = (prefix as NSString).length
        guard location >= 0, location + length <= text.length else { return false }
        let slice = text.substring(with: NSRange(location: location, length: length))
        return caseInsensitive ? slice.lowercased() == prefix.lowercased() : slice == prefix
    }

    private static func hasAnyPrefixAt(_ text: NSString, _ location: Int, _ prefixes: [String]) -> Bool {
        prefixes.contains { hasPrefixAt(text, location, $0, caseInsensitive: true) }
    }

    private static func hasAnyPrefixBefore(_ text: NSString, _ location: Int, _ words: [String]) -> Bool {
        var cursor = location
        while cursor > 0, scalar(text, cursor - 1) == " " { cursor -= 1 }
        return words.contains { hasSuffixBefore(text, cursor, $0) }
    }

    private static func hasSuffixBefore(_ text: NSString, _ location: Int, _ word: String) -> Bool {
        let length = (word as NSString).length
        guard location - length >= 0 else { return false }
        return text.substring(with: NSRange(location: location - length, length: length)).lowercased() == word.lowercased()
    }
}
