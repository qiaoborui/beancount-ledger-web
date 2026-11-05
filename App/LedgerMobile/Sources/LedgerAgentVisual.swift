import Foundation

/// An interactive visual the model asks the app to draw, written in its reply
/// as a fenced `visual` block of JSON. It is a declarative spec: the app draws
/// each block natively and never runs anything the model wrote. Taps either
/// open a `ledger://` page or send a follow-up question the model prepared.
///
/// Decoding is lenient where it is safe: a block that does not decode is
/// left out, a link that is not `ledger://` is dropped, and numbers may come
/// as strings. A visual with no usable block is shown as the code instead.
struct LedgerAgentVisual: Equatable, Sendable {
    var title: String?
    var subtitle: String?
    /// The unit of amounts in blocks that do not name their own.
    var unit: String?
    var blocks: [Block]

    static let maximumBlocks = 12
    static let maximumRowBlocks = 3
    /// Containers (tabs, rows, sections) nest at most this deep.
    static let maximumDepth = 3

    indirect enum Block: Equatable, Sendable {
        case stats([Stat])
        case chart(LedgerAgentChart)
        case ranking(Ranking)
        case table(Table)
        case compare(Compare)
        case tabs([Tab])
        case actions([Action])
        case note(String)
        /// Blocks side by side, stacking when the width runs out.
        case row([Block])
        case section(Section)
        case progress(Progress)
        case timeline(Timeline)
        case keyValues(KeyValues)
        case callout(Callout)
        case heatmap(Heatmap)

        /// Drops containers nested past `maximumDepth` and empty ones left behind.
        static func pruned(_ blocks: [Block], depth: Int) -> [Block] {
            blocks.compactMap { block in
                switch block {
                case let .row(children):
                    guard depth < maximumDepth else { return nil }
                    let kept = pruned(children, depth: depth + 1)
                    return kept.isEmpty ? nil : .row(kept)
                case var .section(section):
                    guard depth < maximumDepth else { return nil }
                    section.blocks = pruned(section.blocks, depth: depth + 1)
                    return section.blocks.isEmpty ? nil : .section(section)
                case let .tabs(tabs):
                    guard depth < maximumDepth else { return nil }
                    let kept = tabs.compactMap { tab -> Tab? in
                        let blocks = pruned(tab.blocks, depth: depth + 1)
                        return blocks.isEmpty ? nil : Tab(label: tab.label, blocks: blocks)
                    }
                    return kept.count >= 2 ? .tabs(kept) : nil
                default:
                    return block
                }
            }
        }
    }

    /// A titled group of blocks that can start folded.
    struct Section: Equatable, Sendable {
        var title: String
        var summary: String?
        var collapsed: Bool
        var blocks: [Block]
    }

    /// Meters against a target, such as budgets.
    struct Progress: Equatable, Sendable {
        struct Item: Equatable, Sendable {
            var label: String
            var value: Double
            var target: Double
            var note: String?
            var link: URL?
        }

        var title: String?
        var unit: String?
        /// Lower is better for spending against a budget, the default.
        var better: Better
        var items: [Item]

        static let maximumItems = 20
    }

    /// Dated events in order, such as large payments or a trip.
    struct Timeline: Equatable, Sendable {
        struct Item: Equatable, Sendable {
            var date: String
            var title: String
            var detail: String?
            var value: Double?
            var tone: Tone
            var link: URL?
        }

        var title: String?
        var unit: String?
        var items: [Item]

        static let maximumItems = 50
    }

    /// Label and value pairs, such as an account's facts.
    struct KeyValues: Equatable, Sendable {
        struct Item: Equatable, Sendable {
            var label: String
            var value: String
            var tone: Tone
            var link: URL?
        }

        var title: String?
        var items: [Item]

        static let maximumItems = 30
    }

    /// A highlighted remark: a finding, a warning, a good sign.
    struct Callout: Equatable, Sendable {
        enum Kind: String, Equatable, Sendable { case info, good, warn, bad }
        var kind: Kind
        var title: String?
        var text: String
    }

    /// Daily values on a calendar grid, one column per week.
    struct Heatmap: Equatable, Sendable {
        struct Day: Equatable, Sendable {
            var date: Date
            var value: Double
            var link: URL?
        }

        var title: String?
        var unit: String?
        var days: [Day]

        static let maximumDays = 400

        /// The page a day opens: the model's link, else that day's transactions.
        func link(for day: Day) -> URL? {
            day.link ?? URL(string: "ledger://transactions?date=" + LedgerAgentVisual.dayString(day.date))
        }
    }

    /// A headline number, with how it moved against a reference.
    struct Stat: Equatable, Sendable {
        var label: String
        var value: Double?
        /// Shown instead of `value` when the figure is not a number.
        var text: String?
        var unit: String?
        /// Relative change as a fraction: -0.12 is 12% lower.
        var delta: Double?
        /// What the change compares against, such as 较上月.
        var deltaLabel: String?
        var better: Better?
        var link: URL?
        /// A small trend line under the number.
        var spark: [Double]? = nil

        static let maximum = 6
    }

    /// Which direction of change is good, so it can be coloured.
    enum Better: String, Equatable, Sendable { case higher, lower }

    /// Items ranked by value, each as a bar of its share.
    struct Ranking: Equatable, Sendable {
        struct Item: Equatable, Sendable {
            var label: String
            var value: Double
            var note: String?
            var link: URL?
        }

        var title: String?
        var unit: String?
        var items: [Item]
        /// The whole that shares are taken of; the items' sum when absent.
        var total: Double?

        static let maximumItems = 30
        var whole: Double { total ?? items.reduce(0) { $0 + max($1.value, 0) } }
    }

    /// A table whose rows can open a page and expand into child rows.
    struct Table: Equatable, Sendable {
        struct Column: Equatable, Sendable {
            var title: String
            var numeric: Bool
        }

        struct Row: Equatable, Sendable {
            var cells: [String]
            var link: URL?
            var children: [Row]
        }

        var title: String?
        var columns: [Column]
        var rows: [Row]
        var sortable: Bool
        /// A column whose distinct values become filter chips.
        var filter: Int? = nil
        /// Whether to sum numeric columns over the rows shown.
        var totals: Bool = false

        static let maximumColumns = 6
        static let maximumRows = 200
        static let maximumChildren = 50
        /// Rows shown before 显示全部.
        static let collapsedRows = 8
    }

    /// Two periods or groups side by side, item by item.
    struct Compare: Equatable, Sendable {
        struct Item: Equatable, Sendable {
            var label: String
            var left: Double
            var right: Double
            var link: URL?
        }

        var title: String?
        var unit: String?
        var left: String
        var right: String
        var better: Better?
        var items: [Item]

        static let maximumItems = 30
    }

    /// One page of a tab switcher, such as a time range.
    struct Tab: Equatable, Sendable {
        var label: String
        var blocks: [Block]

        static let maximum = 6
    }

    /// A button under the visual: a follow-up question or a page to open.
    struct Action: Equatable, Sendable {
        enum Target: Equatable, Sendable {
            case ask(String)
            case link(URL)
        }

        var label: String
        var target: Target

        static let maximum = 6
        static let maximumQuestion = 500
    }

    init(title: String? = nil, subtitle: String? = nil, unit: String? = nil, blocks: [Block]) {
        self.title = title
        self.subtitle = subtitle
        self.unit = unit
        self.blocks = blocks
    }

    init?(json: String) {
        guard let visual = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)), !visual.blocks.isEmpty else { return nil }
        self = visual
    }

    /// A link the visual may open: only pages inside the ledger.
    static func ledgerLink(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.lowercased().hasPrefix("ledger://") else { return nil }
        if let url = URL(string: raw) { return url }
        // The model may leave CJK or spaces in the query unencoded.
        return URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(.urlPathAllowed).union(["?", "&", "="])) ?? "")
    }

    /// A number the model may also write as a string with grouping commas,
    /// a currency sign or a trailing unit.
    static func number(_ raw: String) -> Double? {
        let trimmed = raw.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "¥$€£元 %").union(.whitespaces))
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }
}

// MARK: - Decoding

extension LedgerAgentVisual: Decodable {
    private enum CodingKeys: String, CodingKey { case title, subtitle, unit, blocks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
        unit = try? container.decodeIfPresent(String.self, forKey: .unit)
        let blocks = try container.decode([Lossy<Block>].self, forKey: .blocks).compactMap(\.value)
        self.blocks = Block.pruned(Array(blocks.prefix(Self.maximumBlocks)), depth: 0)
    }
}

/// Decodes an element without failing the array it is in.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// A number or a numeric string.
private struct Flexible: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self), number.isFinite {
            value = number
        } else if let string = try? container.decode(String.self), let number = LedgerAgentVisual.number(string) {
            value = number
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a number")
        }
    }
}

/// A table cell: text, or a number shown as the model wrote it.
private struct Cell: Decodable {
    let text: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
        } else if let number = try? container.decode(Double.self) {
            text = LedgerAgentVisual.plain(number)
        } else if container.decodeNil() {
            text = ""
        } else {
            text = (try? container.decode(Bool.self)).map { $0 ? "✓" : "" } ?? ""
        }
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer where Key == AnyKey {
    func string(_ key: String) -> String? {
        guard let value = try? decodeIfPresent(String.self, forKey: AnyKey(key)) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func number(_ key: String) -> Double? { (try? decodeIfPresent(Flexible.self, forKey: AnyKey(key)))?.value }
    func numbers(_ key: String) -> [Double]? { (try? decodeIfPresent([Flexible].self, forKey: AnyKey(key)))?.map(\.value) }
    func link(_ key: String = "link") -> URL? { LedgerAgentVisual.ledgerLink(string(key)) }
    func tone() -> LedgerAgentVisual.Tone {
        switch string("tone")?.lowercased() {
        case "good", "positive", "income": .good
        case "bad", "negative", "expense", "warn": .bad
        default: .neutral
        }
    }

    func better() -> LedgerAgentVisual.Better? { string("better").flatMap { LedgerAgentVisual.Better(rawValue: $0.lowercased()) } }

    func lossy<Value: Decodable>(_ key: String, as _: Value.Type = Value.self) -> [Value] {
        (try? decodeIfPresent([Lossy<Value>].self, forKey: AnyKey(key)))?.compactMap(\.value) ?? []
    }
}

private struct DecodingFailure: Error {}

extension LedgerAgentVisual.Block: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        switch c.string("type")?.lowercased() {
        case "stats", "stat", "kpi":
            let stats = Array(c.lossy("items", as: LedgerAgentVisual.Stat.self).prefix(LedgerAgentVisual.Stat.maximum))
            guard !stats.isEmpty else { throw DecodingFailure() }
            self = .stats(stats)
        case "chart":
            self = .chart(try LedgerAgentChart(block: c))
        case "ranking", "rank", "bars":
            let items = Array(c.lossy("items", as: LedgerAgentVisual.Ranking.Item.self).prefix(LedgerAgentVisual.Ranking.maximumItems))
            guard !items.isEmpty else { throw DecodingFailure() }
            self = .ranking(.init(title: c.string("title"), unit: c.string("unit"), items: items, total: c.number("total").flatMap { $0 > 0 ? $0 : nil }))
        case "table":
            self = .table(try LedgerAgentVisual.Table(c))
        case "compare", "comparison":
            let items = Array(c.lossy("items", as: LedgerAgentVisual.Compare.Item.self).prefix(LedgerAgentVisual.Compare.maximumItems))
            guard !items.isEmpty, let left = c.string("left"), let right = c.string("right") else { throw DecodingFailure() }
            self = .compare(.init(title: c.string("title"), unit: c.string("unit"), left: left, right: right, better: c.better(), items: items))
        case "tabs":
            let tabs = Array(c.lossy("tabs", as: LedgerAgentVisual.Tab.self).prefix(LedgerAgentVisual.Tab.maximum))
            guard tabs.count >= 2, Set(tabs.map(\.label)).count == tabs.count else { throw DecodingFailure() }
            self = .tabs(tabs)
        case "actions", "buttons":
            let actions = Array(c.lossy("items", as: LedgerAgentVisual.Action.self).prefix(LedgerAgentVisual.Action.maximum))
            guard !actions.isEmpty else { throw DecodingFailure() }
            self = .actions(actions)
        case "note", "text", "markdown":
            guard let text = c.string("text") else { throw DecodingFailure() }
            self = .note(text)
        case "row", "columns", "grid":
            let blocks = c.lossy("blocks", as: LedgerAgentVisual.Block.self)
            guard !blocks.isEmpty else { throw DecodingFailure() }
            self = .row(Array(blocks.prefix(LedgerAgentVisual.maximumRowBlocks)))
        case "section", "group", "collapse":
            let blocks = c.lossy("blocks", as: LedgerAgentVisual.Block.self)
            guard let title = c.string("title"), !blocks.isEmpty else { throw DecodingFailure() }
            self = .section(.init(title: title, summary: c.string("summary"),
                                  collapsed: (try? c.decodeIfPresent(Bool.self, forKey: AnyKey("collapsed"))) ?? false,
                                  blocks: Array(blocks.prefix(LedgerAgentVisual.maximumBlocks))))
        case "progress", "budget", "meters":
            let items = Array(c.lossy("items", as: LedgerAgentVisual.Progress.Item.self).prefix(LedgerAgentVisual.Progress.maximumItems))
            guard !items.isEmpty else { throw DecodingFailure() }
            self = .progress(.init(title: c.string("title"), unit: c.string("unit"), better: c.better() ?? .lower, items: items))
        case "timeline", "events":
            let items = Array(c.lossy("items", as: LedgerAgentVisual.Timeline.Item.self).prefix(LedgerAgentVisual.Timeline.maximumItems))
            guard !items.isEmpty else { throw DecodingFailure() }
            self = .timeline(.init(title: c.string("title"), unit: c.string("unit"), items: items))
        case "kv", "keyvalue", "details", "facts":
            let items = Array(c.lossy("items", as: LedgerAgentVisual.KeyValues.Item.self).prefix(LedgerAgentVisual.KeyValues.maximumItems))
            guard !items.isEmpty else { throw DecodingFailure() }
            self = .keyValues(.init(title: c.string("title"), items: items))
        case "callout", "alert", "tip":
            guard let text = c.string("text") else { throw DecodingFailure() }
            let kind = c.string("tone").flatMap { LedgerAgentVisual.Callout.Kind(rawValue: $0.lowercased()) } ?? .info
            self = .callout(.init(kind: kind, title: c.string("title"), text: text))
        case "heatmap", "calendar":
            let days = Array(c.lossy("days", as: LedgerAgentVisual.Heatmap.Day.self).suffix(LedgerAgentVisual.Heatmap.maximumDays))
                .sorted { $0.date < $1.date }
            guard !days.isEmpty else { throw DecodingFailure() }
            self = .heatmap(.init(title: c.string("title"), unit: c.string("unit"), days: days))
        default:
            throw DecodingFailure()
        }
    }
}

extension LedgerAgentVisual.Progress.Item: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let label = c.string("label"), let value = c.number("value"),
              let target = c.number("target") ?? c.number("budget"), target > 0 else { throw DecodingFailure() }
        self.init(label: label, value: value, target: target, note: c.string("note"), link: c.link())
    }
}

extension LedgerAgentVisual.Timeline.Item: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let date = c.string("date"), let title = c.string("title") ?? c.string("label") else { throw DecodingFailure() }
        self.init(date: date, title: title, detail: c.string("detail") ?? c.string("note"), value: c.number("value"),
                  tone: c.tone(), link: c.link())
    }
}

extension LedgerAgentVisual.KeyValues.Item: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let label = c.string("label"),
              let value = c.string("value") ?? c.number("value").map(LedgerAgentVisual.plain) else { throw DecodingFailure() }
        self.init(label: label, value: value, tone: c.tone(), link: c.link())
    }
}

extension LedgerAgentVisual.Heatmap.Day: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let raw = c.string("date"), let date = LedgerAgentVisual.day(raw), let value = c.number("value") else {
            throw DecodingFailure()
        }
        self.init(date: date, value: value, link: c.link())
    }
}

extension LedgerAgentVisual.Tab: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let label = c.string("label") ?? c.string("title") else { throw DecodingFailure() }
        let blocks = c.lossy("blocks", as: LedgerAgentVisual.Block.self)
        guard !blocks.isEmpty else { throw DecodingFailure() }
        self.init(label: label, blocks: Array(blocks.prefix(LedgerAgentVisual.maximumBlocks)))
    }
}

extension LedgerAgentVisual.Stat: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let label = c.string("label") else { throw DecodingFailure() }
        let value = c.number("value")
        let text = value == nil ? c.string("value") ?? c.string("text") : c.string("text")
        guard value != nil || text != nil else { throw DecodingFailure() }
        self.init(label: label, value: value, text: text, unit: c.string("unit"), delta: c.number("delta"),
                  deltaLabel: c.string("deltaLabel"), better: c.better(), link: c.link(),
                  spark: c.numbers("spark").flatMap { (2...60).contains($0.count) ? $0 : nil })
    }
}

extension LedgerAgentVisual.Ranking.Item: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let label = c.string("label"), let value = c.number("value") else { throw DecodingFailure() }
        self.init(label: label, value: value, note: c.string("note"), link: c.link())
    }
}

extension LedgerAgentVisual.Compare.Item: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let label = c.string("label"), let left = c.number("left"), let right = c.number("right") else { throw DecodingFailure() }
        self.init(label: label, left: left, right: right, link: c.link())
    }
}

extension LedgerAgentVisual.Action: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let label = c.string("label") else { throw DecodingFailure() }
        if let link = c.link() {
            self.init(label: label, target: .link(link))
        } else if let question = c.string("ask"), question.count <= Self.maximumQuestion {
            self.init(label: label, target: .ask(question))
        } else {
            throw DecodingFailure()
        }
    }
}

extension LedgerAgentVisual.Table {
    fileprivate init(_ c: KeyedDecodingContainer<AnyKey>) throws {
        var columns: [Column] = []
        if let titles = try? c.decode([String].self, forKey: AnyKey("columns")) {
            columns = titles.map { Column(title: $0, numeric: false) }
        } else {
            columns = c.lossy("columns", as: ColumnSpec.self).map(\.column)
        }
        columns = Array(columns.prefix(Self.maximumColumns))
        guard !columns.isEmpty else { throw DecodingFailure() }
        let width = columns.count
        func fit(_ row: RowSpec, depth: Int) -> Row {
            let cells = Array((row.cells + Array(repeating: "", count: max(0, width - row.cells.count))).prefix(width))
            let children = depth == 0 ? Array(row.children.prefix(Self.maximumChildren)).map { fit($0, depth: 1) } : []
            return Row(cells: cells, link: row.link, children: children)
        }
        let rows = Array(c.lossy("rows", as: RowSpec.self).prefix(Self.maximumRows)).map { fit($0, depth: 0) }
        guard !rows.isEmpty else { throw DecodingFailure() }
        // A column the model did not mark is numeric when every cell is a number.
        for index in columns.indices where !columns[index].numeric {
            let values = rows.map { $0.cells[index] }.filter { !$0.isEmpty }
            columns[index].numeric = !values.isEmpty && values.allSatisfy { LedgerAgentVisual.number($0) != nil }
        }
        var filter: Int?
        if let index = try? c.decodeIfPresent(Int.self, forKey: AnyKey("filter")), columns.indices.contains(index) {
            filter = index
        } else if let title = c.string("filter") {
            filter = columns.firstIndex { $0.title == title }
        }
        if let index = filter, Set(rows.map { $0.cells[index] }).count < 2 { filter = nil }
        self.init(title: c.string("title"), columns: columns, rows: rows,
                  sortable: (try? c.decodeIfPresent(Bool.self, forKey: AnyKey("sortable"))) ?? true,
                  filter: filter, totals: (try? c.decodeIfPresent(Bool.self, forKey: AnyKey("totals"))) ?? false)
    }

    private struct ColumnSpec: Decodable {
        let column: Column
        init(from decoder: Decoder) throws {
            if let title = try? decoder.singleValueContainer().decode(String.self) {
                column = Column(title: title, numeric: false)
                return
            }
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let title = c.string("title") ?? c.string("label") else { throw DecodingFailure() }
            let numeric = (try? c.decodeIfPresent(Bool.self, forKey: AnyKey("numeric"))) == true
                || ["trailing", "right"].contains(c.string("align")?.lowercased() ?? "")
            column = Column(title: title, numeric: numeric)
        }
    }

    private struct RowSpec: Decodable {
        let cells: [String]
        let link: URL?
        let children: [RowSpec]
        init(from decoder: Decoder) throws {
            if let cells = try? decoder.singleValueContainer().decode([Cell].self) {
                self.cells = cells.map(\.text)
                link = nil
                children = []
                return
            }
            let c = try decoder.container(keyedBy: AnyKey.self)
            cells = try c.decode([Cell].self, forKey: AnyKey("cells")).map(\.text)
            link = c.link()
            children = c.lossy("children", as: RowSpec.self)
        }
    }
}

extension LedgerAgentChart {
    /// A chart inside a visual: the `chart` block's fields, with the chart
    /// type under `kind` because `type` names the block.
    fileprivate init(block c: KeyedDecodingContainer<AnyKey>) throws {
        guard let kind = (c.string("kind") ?? c.string("chart")).flatMap({ Kind(rawValue: $0.lowercased() == "donut" ? "pie" : $0.lowercased()) }),
              let labels = try? c.decode([String].self, forKey: AnyKey("labels")) else { throw DecodingFailure() }
        let series = c.lossy("series", as: SeriesSpec.self).map(\.series)
        let links = try? c.decodeIfPresent([String].self, forKey: AnyKey("links"))
        let rules = c.lossy("rules", as: RuleSpec.self).map(\.rule)
        let chart = LedgerAgentChart(type: kind, title: c.string("title"), unit: c.string("unit"),
                                     stacked: try? c.decodeIfPresent(Bool.self, forKey: AnyKey("stacked")),
                                     labels: labels, series: series, links: links,
                                     rules: rules.isEmpty ? nil : Array(rules.prefix(LedgerAgentChart.maximumRules)))
        guard chart.isValid else { throw DecodingFailure() }
        self = chart
    }

    private struct SeriesSpec: Decodable {
        let series: Series
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            let values = try c.decode([Flexible].self, forKey: AnyKey("values")).map(\.value)
            series = Series(name: c.string("name") ?? "", values: values,
                            kind: c.string("kind").flatMap { Kind(rawValue: $0.lowercased()) })
        }
    }

    private struct RuleSpec: Decodable {
        let rule: Rule
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let value = c.number("value") else { throw DecodingFailure() }
            rule = Rule(value: value, label: c.string("label"))
        }
    }
}

// MARK: - Formatting

extension LedgerAgentVisual {
    /// A number with grouping and at most two decimals, as 1,820.5.
    static func plain(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")).grouping(.automatic))
    }

    /// An amount with its unit: 1,820.5 元, or ¥1,820.5 for a sign unit.
    static func amount(_ value: Double, unit: String?) -> String {
        let number = plain(value)
        guard let unit, !unit.isEmpty else { return number }
        if ["¥", "$", "€", "£"].contains(unit) { return value < 0 ? "-" + unit + plain(-value) : unit + number }
        return number + " " + unit
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// A `yyyy-MM-dd` day at UTC midnight.
    static func day(_ raw: String) -> Date? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        let date = utcCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        // Reject days the calendar rolled over, such as 02-30.
        return date.flatMap { utcCalendar.component(.day, from: $0) == parts[2] ? $0 : nil }
    }

    static func dayString(_ date: Date) -> String {
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Weekday of a day, 0 for Monday.
    static func weekdayIndex(_ date: Date) -> Int { (utcCalendar.component(.weekday, from: date) + 5) % 7 }
    static func addingDays(_ days: Int, to date: Date) -> Date { utcCalendar.date(byAdding: .day, value: days, to: date) ?? date }

    /// A relative change as +12% or -3.5%.
    static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        let text = abs(value).formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US_POSIX")))
        return (value > 0 ? "+" : value < 0 ? "-" : "") + text + "%"
    }

    /// Whether a change is good, bad, or neither, given which way is better.
    static func tone(of change: Double, better: Better?) -> Tone {
        guard let better, change != 0 else { return .neutral }
        return (change > 0) == (better == .higher) ? .good : .bad
    }

    enum Tone: Equatable, Sendable { case good, bad, neutral }
}

extension LedgerAgentVisual.Table {
    /// The distinct values of the filter column, in first-seen order.
    var filterValues: [String] {
        guard let filter else { return [] }
        var seen = Set<String>()
        return rows.map { $0.cells[filter] }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Sums of the numeric columns over some rows; nil for text columns.
    func totals(of rows: [Row]) -> [Double?] {
        columns.indices.map { index in
            guard columns[index].numeric else { return nil }
            return rows.reduce(0) { $0 + (LedgerAgentVisual.number($1.cells[index]) ?? 0) }
        }
    }

    /// The rows ordered by one column. Numeric columns sort by value, with
    /// blanks last; text columns by localized comparison.
    func sorted(by column: Int, ascending: Bool) -> [Row] { sorted(rows, by: column, ascending: ascending) }

    func sorted(_ rows: [Row], by column: Int, ascending: Bool) -> [Row] {
        guard columns.indices.contains(column) else { return rows }
        let numeric = columns[column].numeric
        return rows.enumerated().sorted { lhs, rhs in
            let a = lhs.element.cells[column], b = rhs.element.cells[column]
            if numeric {
                switch (LedgerAgentVisual.number(a), LedgerAgentVisual.number(b)) {
                case let (x?, y?) where x != y: return ascending ? x < y : x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.offset < rhs.offset
                }
            }
            let order = a.localizedStandardCompare(b)
            if order == .orderedSame { return lhs.offset < rhs.offset }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }.map(\.element)
    }
}
