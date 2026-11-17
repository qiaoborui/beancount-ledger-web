import Foundation

/// When a scheduled task runs, in the task's own timezone. Mirrors
/// `automation.Schedule` in server/internal/automation/task.go:
///
///     hourly            every hour on the hour
///     hourly :15        every hour at minute 15
///     daily 21:00
///     weekly mon,thu 09:00
///     monthly 1 09:00   (a day past the month's end runs on its last day)
struct LedgerAutomationSchedule: Equatable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case hourly, daily, weekly, monthly
        var id: String { rawValue }

        var title: String {
            switch self {
            case .hourly: String(localized: "每小时")
            case .daily: String(localized: "每天")
            case .weekly: String(localized: "每周")
            case .monthly: String(localized: "每月")
            }
        }
    }

    var kind: Kind
    var hour = 21
    var minute = 0
    /// Weekdays for weekly, as `Calendar` numbers them: 1 is Sunday.
    var weekdays: Set<Int> = [2]
    var dayOfMonth = 1

    static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    static let weekdayTitles = ["日", "一", "二", "三", "四", "五", "六"]

    init(kind: Kind, hour: Int = 21, minute: Int = 0, weekdays: Set<Int> = [2], dayOfMonth: Int = 1) {
        self.kind = kind
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.dayOfMonth = dayOfMonth
    }

    init?(text: String) {
        let fields = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = fields.first, let kind = Kind(rawValue: first) else { return nil }
        self.kind = kind
        switch (kind, fields.count) {
        case (.hourly, 1):
            minute = 0
        case (.hourly, 2):
            guard fields[1].hasPrefix(":"), let value = Int(fields[1].dropFirst()), (0...59).contains(value) else { return nil }
            minute = value
        case (.daily, 2):
            guard let clock = Self.clock(fields[1]) else { return nil }
            (hour, minute) = clock
        case (.weekly, 3):
            var days = Set<Int>()
            for name in fields[1].split(separator: ",") {
                let key = String(name.trimmingCharacters(in: .whitespaces).prefix(3))
                guard let index = Self.weekdayNames.firstIndex(of: key) else { return nil }
                days.insert(index + 1)
            }
            guard !days.isEmpty, let clock = Self.clock(fields[2]) else { return nil }
            weekdays = days
            (hour, minute) = clock
        case (.monthly, 3):
            guard let day = Int(fields[1]), (1...31).contains(day), let clock = Self.clock(fields[2]) else { return nil }
            dayOfMonth = day
            (hour, minute) = clock
        default:
            return nil
        }
    }

    private static func clock(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    private var clockText: String { String(format: "%02d:%02d", hour, minute) }

    /// The line the task file holds.
    var text: String {
        switch kind {
        case .hourly: minute == 0 ? "hourly" : String(format: "hourly :%02d", minute)
        case .daily: "daily \(clockText)"
        case .weekly: "weekly \(weekdays.sorted().map { Self.weekdayNames[$0 - 1] }.joined(separator: ",")) \(clockText)"
        case .monthly: "monthly \(dayOfMonth) \(clockText)"
        }
    }

    /// How the phone says it.
    var title: String {
        switch kind {
        case .hourly: minute == 0 ? String(localized: "每小时整点") : String(localized: "每小时第 \(minute) 分")
        case .daily: String(localized: "每天 \(clockText)")
        case .weekly:
            String(localized: "每周\(weekdays.sorted().map { Self.weekdayTitles[$0 - 1] }.joined(separator: "、")) \(clockText)")
        case .monthly: String(localized: "每月 \(dayOfMonth) 日 \(clockText)")
        }
    }

    /// The first planned run after `date`.
    func nextSlot(after date: Date, in zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func at(_ day: Date, hour: Int, minute: Int) -> Date? {
            var parts = calendar.dateComponents([.year, .month, .day], from: day)
            parts.hour = hour
            parts.minute = minute
            parts.second = 0
            return calendar.date(from: parts)
        }
        switch kind {
        case .hourly:
            var parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            parts.minute = minute
            parts.second = 0
            guard let slot = calendar.date(from: parts) else { return nil }
            return slot > date ? slot : calendar.date(byAdding: .hour, value: 1, to: slot)
        case .daily, .weekly:
            for ahead in 0...8 {
                guard let day = calendar.date(byAdding: .day, value: ahead, to: date),
                      let slot = at(day, hour: hour, minute: minute), slot > date else { continue }
                if kind == .daily || weekdays.contains(calendar.component(.weekday, from: slot)) { return slot }
            }
            return nil
        case .monthly:
            let start = calendar.dateComponents([.year, .month], from: date)
            for ahead in 0...2 {
                guard let first = calendar.date(from: start).flatMap({ calendar.date(byAdding: .month, value: ahead, to: $0) }),
                      let days = calendar.range(of: .day, in: .month, for: first)?.count else { continue }
                var parts = calendar.dateComponents([.year, .month], from: first)
                parts.day = min(dayOfMonth, days)
                parts.hour = hour
                parts.minute = minute
                parts.second = 0
                if let slot = calendar.date(from: parts), slot > date { return slot }
            }
            return nil
        }
    }
}

/// One scheduled task: automations/<id>.md in the ledger, a frontmatter
/// block and the prompt. Mirrors `automation.ParseTask`; the host is what
/// finally reads it, so the phone writes only the keys the host knows.
struct LedgerAutomationTask: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var schedule: LedgerAutomationSchedule
    /// nil runs in the host's default timezone.
    var timezone: String?
    var enabled = true
    /// Empty uses the host's default model and thinking effort.
    var model = ""
    var thinking = ""
    /// Runs the deterministic checks first and hands their findings over.
    var audit = true
    var prompt: String

    static let directory = "automations"
    static let thinkingLevels = ["", "off", "minimal", "low", "medium", "high"]

    var path: String { "\(Self.directory)/\(id).md" }

    var zone: TimeZone { timezone.flatMap(TimeZone.init(identifier:)) ?? .current }

    static func isValidID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, id.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(first)
            && id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A file name for a new task: its name in ASCII when it has one, else
    /// `task`, numbered past the ids already taken.
    static func newID(for name: String, taken: Set<String>) -> String {
        let ascii = name.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(scalar) ? Character(scalar) : "-"
        }
        var base = String(ascii).split(separator: "-").joined(separator: "-")
        base = String(base.prefix(48))
        if !isValidID(base) { base = "task" }
        var id = base, number = 2
        while taken.contains(id) {
            id = "\(base)-\(number)"
            number += 1
        }
        return id
    }

    enum ParseError: LocalizedError, Equatable {
        case invalidID, noFrontmatter, unclosedFrontmatter, unknownKey(String), badValue(String), badSchedule(String), noPrompt

        var errorDescription: String? {
            switch self {
            case .invalidID: String(localized: "文件名只能用小写字母、数字和横线")
            case .noFrontmatter: String(localized: "文件开头要有 --- 包起来的设置")
            case .unclosedFrontmatter: String(localized: "设置部分缺少结尾的 ---")
            case let .unknownKey(key): String(localized: "不认识的设置项：\(key)")
            case let .badValue(key): String(localized: "设置项 \(key) 的值不对")
            case let .badSchedule(text): String(localized: "频率写法不对：\(text)")
            case .noPrompt: String(localized: "任务没有写要助手做什么")
            }
        }
    }

    static func parse(id: String, text raw: String) throws -> LedgerAutomationTask {
        guard isValidID(id) else { throw ParseError.invalidID }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.hasPrefix("---\n") else { throw ParseError.noFrontmatter }
        let rest = text.dropFirst(4)
        guard let end = rest.range(of: "\n---") else { throw ParseError.unclosedFrontmatter }
        var values: [String: String] = [:]
        for line in rest[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { throw ParseError.badValue(trimmed) }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            guard ["name", "schedule", "timezone", "enabled", "model", "thinking", "audit"].contains(key) else {
                throw ParseError.unknownKey(key)
            }
            values[key] = try scalar(String(trimmed[trimmed.index(after: colon)...]), key: key)
        }
        var body = String(rest[end.upperBound...])
        while body.hasPrefix("-") { body.removeFirst() }
        let prompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ParseError.noPrompt }
        let scheduleText = values["schedule"] ?? ""
        guard let schedule = LedgerAutomationSchedule(text: scheduleText) else { throw ParseError.badSchedule(scheduleText) }
        let name = (values["name"] ?? "").trimmingCharacters(in: .whitespaces)
        let enabled = try bool(values["enabled"], key: "enabled") ?? true
        let audit = try bool(values["audit"], key: "audit") ?? true
        return LedgerAutomationTask(id: id, name: name.isEmpty ? id : name, schedule: schedule,
                                    timezone: values["timezone"].flatMap { $0.isEmpty ? nil : $0 },
                                    enabled: enabled, model: values["model"] ?? "", thinking: values["thinking"] ?? "",
                                    audit: audit, prompt: prompt)
    }

    /// A YAML scalar as the frontmatter writes one: plain, single- or
    /// double-quoted, with a trailing comment on a plain one.
    private static func scalar(_ raw: String, key: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            guard let data = value.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(String.self, from: data) else { throw ParseError.badValue(key) }
            return decoded
        }
        if value.hasPrefix("'") {
            guard value.count >= 2, value.hasSuffix("'") else { throw ParseError.badValue(key) }
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if let comment = value.range(of: " #") { return value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces) }
        return value
    }

    private static func bool(_ value: String?, key: String) throws -> Bool? {
        guard let value, !value.isEmpty else { return nil }
        switch value.lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: throw ParseError.badValue(key)
        }
    }

    private static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    /// The file, with only the settings that differ from the defaults.
    var fileText: String {
        var lines = ["---", "name: \(Self.quoted(name))", "schedule: \(schedule.text)"]
        if let timezone, !timezone.isEmpty { lines.append("timezone: \(timezone)") }
        lines.append("enabled: \(enabled)")
        if !model.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("model: \(Self.quoted(model.trimmingCharacters(in: .whitespaces)))") }
        if !thinking.isEmpty { lines.append("thinking: \(thinking)") }
        if !audit { lines.append("audit: false") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Tasks to start from.
    static func templates(timezone: String) -> [LedgerAutomationTask] {
        [
            LedgerAutomationTask(id: "daily-audit", name: String(localized: "每日巡检"),
                                 schedule: .init(kind: .daily, hour: 21, minute: 0), timezone: timezone, thinking: "low",
                                 prompt: String(localized: """
                                 看一下今天的巡检结果：

                                 1. 逐条核实疑似重复和待处理的交易，真重复的起草删除，能确定分类的起草改分类。
                                 2. 很久没对账的账户，列出来提醒我，不用改。
                                 3. 有没被 include 的文件，起草把它加回 main.bean。

                                 最后用三五句话告诉我结论，拿不准的列出来等我决定。
                                 """)),
            LedgerAutomationTask(id: "weekly-review", name: String(localized: "每周消费小结"),
                                 schedule: .init(kind: .weekly, hour: 20, minute: 0, weekdays: [1]), timezone: timezone,
                                 audit: false, prompt: String(localized: """
                                 总结过去 7 天的支出：总额、和前几周比的变化、最大的几类和几笔。
                                 有异常的地方（突然变多的类别、重复扣款、陌生商户）单独列出来。用几句话说结论，不要改账本。
                                 """)),
            LedgerAutomationTask(id: "monthly-close", name: String(localized: "月初对账提醒"),
                                 schedule: .init(kind: .monthly, hour: 9, minute: 0, dayOfMonth: 2), timezone: timezone,
                                 prompt: String(localized: """
                                 上个月已经结束。检查上个月的账：
                                 1. 列出需要对账的账户和它们上次 balance 断言的日期。
                                 2. 找出还没分类或待处理的交易，能确定的起草修正。
                                 最后告诉我这个月该去核对哪些账户的余额。
                                 """)),
        ]
    }
}

/// The tasks of a ledger as the phone reads them, and the files it could
/// not read, which the host would skip too.
struct LedgerAutomationTaskList: Equatable, Sendable {
    var tasks: [LedgerAutomationTask] = []
    var problems: [String: String] = [:]

    static func read(workspace root: URL, fileManager: FileManager = .default) -> LedgerAutomationTaskList {
        let directory = root.appendingPathComponent(LedgerAutomationTask.directory, isDirectory: true)
        var list = LedgerAutomationTaskList()
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".md") && !name.hasPrefix(".") && name.lowercased() != "readme.md" {
            let id = String(name.dropLast(3))
            do {
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                list.tasks.append(try LedgerAutomationTask.parse(id: id, text: String(decoding: data, as: UTF8.self)))
            } catch {
                list.problems[id] = error.localizedDescription
            }
        }
        return list
    }
}

/// state.json on the run records branch: what the host last did per task.
struct LedgerAutomationState: Decodable, Sendable {
    struct Task: Decodable, Equatable, Sendable {
        var lastRunId: String?
        var lastStatus: String?
        var lastRunAt: Date?
        var retry: Retry?
    }

    struct Retry: Decodable, Equatable, Sendable {
        var nextAt: Date?
    }

    var tasks: [String: Task] = [:]

    static func read(in root: URL) -> LedgerAutomationState {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
              let state = try? LedgerAutomationRecords.decoder.decode(LedgerAutomationState.self, from: data) else {
            return LedgerAutomationState()
        }
        return state
    }
}
