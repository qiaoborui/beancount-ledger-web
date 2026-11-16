import CoreGraphics
import Foundation
#if canImport(os)
import os
#endif

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
        /// Money moving between nodes, such as income into accounts and on
        /// into spending.
        case sankey(Sankey)
        /// Shares of a whole as nested rectangles, one level deep.
        case treemap(Treemap)
        /// Rings filled to a ratio, such as a savings rate.
        case gauge(Gauge)
        /// A grid of values by row and column, shaded by size.
        case matrix(Matrix)
        /// Ledger entries drawn as the app's transaction rows.
        case transactions(Transactions)

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

    /// Money moving from node to node. Flows that would close a loop are
    /// left out, so every node has a column: sources on the left, each
    /// other node one column right of its furthest source.
    struct Sankey: Equatable, Sendable {
        struct Flow: Equatable, Sendable {
            var from: String
            var to: String
            var value: Double
            var link: URL?
        }

        struct Node: Equatable, Sendable {
            var name: String
            var column: Int
            var inflow: Double
            var outflow: Double
            /// The height the node takes: the larger of what comes in and goes out.
            var value: Double { max(inflow, outflow) }
        }

        var title: String?
        var unit: String?
        var flows: [Flow]
        var nodes: [Node]

        static let maximumFlows = 60
        static let maximumNodes = 30

        init(title: String? = nil, unit: String? = nil, flows: [Flow]) {
            self.title = title
            self.unit = unit
            var kept: [Flow] = []
            var names: [String] = []
            var edges: [String: Set<String>] = [:]
            func reaches(_ start: String, _ goal: String) -> Bool {
                var stack = [start], seen: Set<String> = []
                while let node = stack.popLast() {
                    if node == goal { return true }
                    guard seen.insert(node).inserted else { continue }
                    stack.append(contentsOf: edges[node] ?? [])
                }
                return false
            }
            for flow in flows where kept.count < Self.maximumFlows {
                let added = [flow.from, flow.to].filter { !names.contains($0) }
                guard names.count + added.count <= Self.maximumNodes, !reaches(flow.to, flow.from) else { continue }
                names.append(contentsOf: added)
                edges[flow.from, default: []].insert(flow.to)
                kept.append(flow)
            }
            self.flows = kept
            // Longest path from a source; the graph is acyclic, so this settles
            // within one pass per node.
            var column = Dictionary(uniqueKeysWithValues: names.map { ($0, 0) })
            for _ in names {
                var moved = false
                for flow in kept where column[flow.to]! < column[flow.from]! + 1 {
                    column[flow.to] = column[flow.from]! + 1
                    moved = true
                }
                if !moved { break }
            }
            nodes = names.map { name in
                Node(name: name, column: column[name]!,
                     inflow: kept.filter { $0.to == name }.reduce(0) { $0 + $1.value },
                     outflow: kept.filter { $0.from == name }.reduce(0) { $0 + $1.value })
            }
        }

        var columnCount: Int { (nodes.map(\.column).max() ?? 0) + 1 }

        /// Where each node and flow sits in a box of the given size, with
        /// `nodeWidth`-wide bars and at least `gap` between nodes of a column.
        struct Layout: Equatable, Sendable {
            struct Band: Equatable, Sendable {
                var flow: Int
                /// The flow's top edge where it leaves and where it arrives.
                var fromY: Double
                var toY: Double
                var thickness: Double
                var fromX: Double
                var toX: Double
            }

            var frames: [CGRect]
            var bands: [Band]
        }

        func layout(width: Double, height: Double, nodeWidth: Double = 10, gap: Double = 10) -> Layout {
            let columns = columnCount
            let byColumn = (0..<columns).map { index in nodes.indices.filter { nodes[$0].column == index } }
            // One scale for every column, set by the one that needs the most room.
            let scale = byColumn.compactMap { members -> Double? in
                let total = members.reduce(0) { $0 + nodes[$1].value }
                guard total > 0 else { return nil }
                return max(height - gap * Double(members.count - 1), 1) / total
            }.min() ?? 0
            let step = columns > 1 ? (width - nodeWidth) / Double(columns - 1) : 0
            var frames = Array(repeating: CGRect.zero, count: nodes.count)
            for (index, members) in byColumn.enumerated() {
                let used = members.reduce(0) { $0 + nodes[$1].value * scale } + gap * Double(max(members.count - 1, 0))
                var y = max((height - used) / 2, 0)
                let x = columns > 1 ? Double(index) * step : (width - nodeWidth) / 2
                for member in members {
                    let h = max(nodes[member].value * scale, 1)
                    frames[member] = CGRect(x: x, y: y, width: nodeWidth, height: h)
                    y += h + gap
                }
            }
            let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.name, $0) })
            // A node's flows stack in the order of the nodes at their other end,
            // top to bottom, so bands cross as little as they can.
            var outOffset = Array(repeating: 0.0, count: nodes.count)
            var inOffset = Array(repeating: 0.0, count: nodes.count)
            var bands = Array(repeating: Layout.Band(flow: 0, fromY: 0, toY: 0, thickness: 0, fromX: 0, toX: 0), count: flows.count)
            let byTarget = flows.indices.sorted { frames[index[flows[$0].to]!].minY < frames[index[flows[$1].to]!].minY }
            for flow in byTarget {
                let source = index[flows[flow].from]!
                let thickness = flows[flow].value * scale
                bands[flow].flow = flow
                bands[flow].thickness = thickness
                bands[flow].fromY = frames[source].minY + outOffset[source]
                bands[flow].fromX = frames[source].maxX
                outOffset[source] += thickness
            }
            let bySource = flows.indices.sorted { frames[index[flows[$0].from]!].minY < frames[index[flows[$1].from]!].minY }
            for flow in bySource {
                let target = index[flows[flow].to]!
                bands[flow].toY = frames[target].minY + inOffset[target]
                bands[flow].toX = frames[target].minX
                inOffset[target] += bands[flow].thickness
            }
            return Layout(frames: frames, bands: bands)
        }
    }

    /// Shares of a whole as rectangles sized by value. An item with
    /// children opens into them when tapped.
    struct Treemap: Equatable, Sendable {
        struct Item: Equatable, Sendable {
            var label: String
            var value: Double
            var note: String?
            var link: URL?
            var children: [Item]
        }

        var title: String?
        var unit: String?
        var items: [Item]

        static let maximumItems = 40

        /// Squarified layout (Bruls, Huizing and van Wijk): rectangles as close
        /// to square as the values allow, largest first, in the order given.
        /// Values should be sorted from largest to smallest.
        static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
            let total = values.reduce(0) { $0 + max($1, 0) }
            guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
            let areas = values.map { max($0, 0) / total * Double(rect.width * rect.height) }
            var frames: [CGRect] = []
            var remaining = rect
            var start = 0
            func worst(_ row: ArraySlice<Double>, side: Double) -> Double {
                let sum = row.reduce(0, +)
                guard sum > 0, let largest = row.max(), let smallest = row.min(), smallest > 0 else { return .infinity }
                return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
            }
            while start < areas.count {
                let side = Double(min(remaining.width, remaining.height))
                var end = start + 1
                while end < areas.count, worst(areas[start...end], side: side) <= worst(areas[start..<end], side: side) {
                    end += 1
                }
                let row = areas[start..<end]
                let sum = row.reduce(0, +)
                if remaining.width >= remaining.height {
                    // A column along the left edge.
                    let w = side > 0 ? sum / Double(remaining.height) : 0
                    var y = Double(remaining.minY)
                    for area in row {
                        let h = w > 0 ? area / w : 0
                        frames.append(CGRect(x: Double(remaining.minX), y: y, width: w, height: h))
                        y += h
                    }
                    remaining = CGRect(x: Double(remaining.minX) + w, y: Double(remaining.minY),
                                       width: max(Double(remaining.width) - w, 0), height: Double(remaining.height))
                } else {
                    // A row along the top edge.
                    let h = side > 0 ? sum / Double(remaining.width) : 0
                    var x = Double(remaining.minX)
                    for area in row {
                        let w = h > 0 ? area / h : 0
                        frames.append(CGRect(x: x, y: Double(remaining.minY), width: w, height: h))
                        x += w
                    }
                    remaining = CGRect(x: Double(remaining.minX), y: Double(remaining.minY) + h,
                                       width: Double(remaining.width), height: max(Double(remaining.height) - h, 0))
                }
                start = end
            }
            return frames
        }
    }

    /// Rings filled to a ratio: `value` of `maximum`, or `value` as a
    /// fraction of 1 when there is no maximum.
    struct Gauge: Equatable, Sendable {
        struct Item: Equatable, Sendable {
            var label: String
            var value: Double
            var maximum: Double?
            /// A mark on the ring, on the same scale as `value`.
            var target: Double?
            var note: String?
            var link: URL?

            var ratio: Double { value / (maximum ?? 1) }
            var targetRatio: Double? { target.map { $0 / (maximum ?? 1) } }
        }

        var title: String?
        var unit: String?
        /// Which way is good, for colouring against the target.
        var better: Better?
        var items: [Item]

        static let maximumItems = 6
    }

    /// Values by row and column, such as categories by month. Blank cells
    /// stay blank.
    struct Matrix: Equatable, Sendable {
        struct Row: Equatable, Sendable {
            var label: String
            var values: [Double?]
            var link: URL?
            var total: Double { values.reduce(0) { $0 + ($1 ?? 0) } }
        }

        var title: String?
        var unit: String?
        var columns: [String]
        var rows: [Row]
        /// Whether to add a total column and a total row.
        var totals: Bool
        /// Colours the totals row's changes when set; shading is by size either way.
        var better: Better?

        static let maximumColumns = 24
        static let maximumRows = 40

        var columnTotals: [Double] {
            columns.indices.map { index in rows.reduce(0) { $0 + ($1.values[index] ?? 0) } }
        }

        /// The largest magnitude among the cells, which full shading stands for.
        var peak: Double { rows.flatMap(\.values).compactMap { $0.map(abs) }.max() ?? 0 }
    }

    /// Ledger entries, newest first as given, grouped by day.
    struct Transactions: Equatable, Sendable {
        struct Item: Equatable, Sendable {
            var date: Date
            var payee: String?
            var narration: String?
            var account: String?
            /// Signed: negative is money going out.
            var amount: Double
            var currency: String?
            var tags: [String]
            var link: URL?

            /// The page a row opens: the model's link, else that day's transactions.
            var destination: URL? {
                link ?? URL(string: "ledger://transactions?date=" + LedgerAgentVisual.dayString(date))
            }
        }

        var title: String?
        var unit: String?
        var items: [Item]

        static let maximumItems = 100
        /// Rows shown before 显示全部.
        static let collapsedItems = 10

        /// Items grouped by day in the order they first appear.
        func days(_ items: [Item]) -> [(date: Date, items: [Item])] {
            var order: [Date] = []
            var groups: [Date: [Item]] = [:]
            for item in items {
                if groups[item.date] == nil { order.append(item.date) }
                groups[item.date, default: []].append(item)
            }
            return order.map { ($0, groups[$0]!) }
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

    /// With `logging`, the parts that did not decode go to the log once per
    /// visual, so the prompt can be fixed where the model often goes wrong.
    init?(json: String, logging: Bool = false) {
        let (visual, drops) = Self.decode(json)
        if logging, !drops.isEmpty { Self.log(drops, of: json) }
        guard let visual, !visual.blocks.isEmpty else { return nil }
        self = visual
    }

    /// The parts of a visual that lenient decoding left out, by coding path
    /// and block type, such as `blocks.3 (chart)`; `JSON` when none decodes.
    static func drops(json: String) -> [String] { decode(json).drops }

    private static func decode(_ json: String) -> (visual: Self?, drops: [String]) {
        let decoder = JSONDecoder()
        let drops = LedgerAgentVisualDrops()
        decoder.userInfo[.ledgerAgentVisualDrops] = drops
        do {
            return (try decoder.decode(Self.self, from: Data(json.utf8)), drops.paths)
        } catch {
            return (nil, drops.paths + ["JSON"])
        }
    }

    #if canImport(os)
    private static let logger = Logger(subsystem: "app.beancount.ledger", category: "agent-visual")
    /// Visuals already logged; a reply's segments are read on every redraw.
    private static let logged = OSAllocatedUnfairLock(initialState: Set<Int>())
    #endif

    private static func log(_ drops: [String], of json: String) {
        #if canImport(os)
        let isNew = logged.withLock { seen in
            if seen.count > 200 { seen.removeAll() }
            return seen.insert(json.hashValue).inserted
        }
        guard isNew else { return }
        let parts = drops.joined(separator: ", ")
        logger.notice("visual left out \(drops.count, privacy: .public) part(s): \(parts, privacy: .public)")
        #endif
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

/// Decodes an element without failing the array it is in, noting what it
/// left out when the decoder collects that.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        do {
            value = try Value(from: decoder)
        } catch {
            value = nil
            guard let drops = decoder.userInfo[.ledgerAgentVisualDrops] as? LedgerAgentVisualDrops else { return }
            let type = (try? decoder.container(keyedBy: AnyKey.self))?.string("type")
            drops.record(path: decoder.codingPath, type: type)
        }
    }
}

/// The parts one decode left out. A decode runs on one thread.
private final class LedgerAgentVisualDrops: @unchecked Sendable {
    private(set) var paths: [String] = []

    func record(path: [any CodingKey], type: String?) {
        let joined = path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        paths.append(type.map { "\(joined) (\($0))" } ?? joined)
    }
}

private extension CodingUserInfoKey {
    static var ledgerAgentVisualDrops: CodingUserInfoKey { CodingUserInfoKey(rawValue: "ledgerAgentVisualDrops")! }
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
        case "sankey", "flow", "flows":
            self = .sankey(try LedgerAgentVisual.Sankey(c))
        case "treemap", "tree":
            let items = Array(c.lossy("items", as: LedgerAgentVisual.Treemap.Item.self).filter { $0.value > 0 }
                .prefix(LedgerAgentVisual.Treemap.maximumItems))
            guard !items.isEmpty else { throw DecodingFailure() }
            self = .treemap(.init(title: c.string("title"), unit: c.string("unit"), items: items))
        case "gauge", "ring", "rings":
            let items = Array(c.lossy("items", as: LedgerAgentVisual.Gauge.Item.self).prefix(LedgerAgentVisual.Gauge.maximumItems))
            guard !items.isEmpty else { throw DecodingFailure() }
            self = .gauge(.init(title: c.string("title"), unit: c.string("unit"), better: c.better(), items: items))
        case "matrix", "pivot", "heattable":
            self = .matrix(try LedgerAgentVisual.Matrix(c))
        case "transactions", "entries", "ledger":
            let items = Array(c.lossy("items", as: LedgerAgentVisual.Transactions.Item.self)
                .prefix(LedgerAgentVisual.Transactions.maximumItems))
            guard !items.isEmpty else { throw DecodingFailure() }
            self = .transactions(.init(title: c.string("title"), unit: c.string("unit"), items: items))
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

extension LedgerAgentVisual.Sankey {
    fileprivate init(_ c: KeyedDecodingContainer<AnyKey>) throws {
        var flows = c.lossy("flows", as: Flow.self)
        if flows.isEmpty { flows = c.lossy("links", as: Flow.self) }
        self.init(title: c.string("title"), unit: c.string("unit"), flows: flows)
        guard !self.flows.isEmpty else { throw DecodingFailure() }
    }
}

extension LedgerAgentVisual.Sankey.Flow: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let from = c.string("from") ?? c.string("source"), let to = c.string("to") ?? c.string("target"),
              let value = c.number("value"), value > 0, from != to else { throw DecodingFailure() }
        self.init(from: from, to: to, value: value, link: c.link())
    }
}

extension LedgerAgentVisual.Treemap.Item: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let label = c.string("label"), let value = c.number("value") else { throw DecodingFailure() }
        let children = Array(c.lossy("children", as: Leaf.self).map(\.item).filter { $0.value > 0 }
            .prefix(LedgerAgentVisual.Treemap.maximumItems))
        self.init(label: label, value: value, note: c.string("note"), link: c.link(), children: children)
    }

    /// A child: an item whose own children are left out.
    private struct Leaf: Decodable {
        let item: LedgerAgentVisual.Treemap.Item
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let label = c.string("label"), let value = c.number("value") else { throw DecodingFailure() }
            item = .init(label: label, value: value, note: c.string("note"), link: c.link(), children: [])
        }
    }
}

extension LedgerAgentVisual.Gauge.Item: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let label = c.string("label"), let value = c.number("value") else { throw DecodingFailure() }
        let maximum = c.number("max") ?? c.number("total")
        if let maximum, maximum <= 0 { throw DecodingFailure() }
        self.init(label: label, value: value, maximum: maximum, target: c.number("target"), note: c.string("note"),
                  link: c.link())
    }
}

extension LedgerAgentVisual.Matrix {
    fileprivate init(_ c: KeyedDecodingContainer<AnyKey>) throws {
        guard let columns = try? c.decode([String].self, forKey: AnyKey("columns")), !columns.isEmpty else { throw DecodingFailure() }
        let width = min(columns.count, Self.maximumColumns)
        let rows = Array(c.lossy("rows", as: RowSpec.self).prefix(Self.maximumRows)).map { spec in
            Row(label: spec.label, values: Array((spec.values + Array(repeating: nil, count: max(0, width - spec.values.count))).prefix(width)),
                link: spec.link)
        }
        guard !rows.isEmpty else { throw DecodingFailure() }
        self.init(title: c.string("title"), unit: c.string("unit"), columns: Array(columns.prefix(width)), rows: rows,
                  totals: (try? c.decodeIfPresent(Bool.self, forKey: AnyKey("totals"))) ?? false, better: c.better())
    }

    private struct RowSpec: Decodable {
        let label: String
        let values: [Double?]
        let link: URL?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let label = c.string("label") else { throw DecodingFailure() }
            self.label = label
            values = try c.decode([OptionalNumber].self, forKey: AnyKey("values")).map(\.value)
            link = c.link()
        }
    }

    /// A number, or a blank for null, an empty string or anything else.
    private struct OptionalNumber: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws { value = (try? Flexible(from: decoder))?.value }
    }
}

extension LedgerAgentVisual.Transactions.Item: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let raw = c.string("date"), let date = LedgerAgentVisual.day(raw), let amount = c.number("amount") ?? c.number("value")
        else { throw DecodingFailure() }
        let payee = c.string("payee"), narration = c.string("narration") ?? c.string("title") ?? c.string("label")
        guard payee != nil || narration != nil else { throw DecodingFailure() }
        let tags = ((try? c.decodeIfPresent([String].self, forKey: AnyKey("tags"))) ?? [])
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }.filter { !$0.isEmpty }
        self.init(date: date, payee: payee, narration: narration, account: c.string("account"), amount: amount,
                  currency: c.string("currency"), tags: Array(tags.prefix(4)), link: c.link())
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
        value.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US")).grouping(.automatic))
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

// MARK: - Streaming

extension LedgerAgentVisual {
    /// What a `visual` or `chart` fence still being written can already show.
    struct Partial: Equatable, Sendable {
        /// The top-level blocks written in full so far; nil until one is.
        var visual: LedgerAgentVisual?
        /// The root object's title, once it is written, for the placeholder.
        var title: String?
        /// Whether the root object has closed, though the fence has not.
        var complete = false
    }

    /// Reads JSON cut off mid-stream. It keeps the top-level blocks already
    /// written in full and leaves out the one being written, so a number never
    /// shows half typed and a table does not grow row by row.
    static func partial(json: String) -> Partial {
        let bytes = Array(json.utf8)
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        let open: Set<UInt8> = [UInt8(ascii: "{"), UInt8(ascii: "[")]
        let close: Set<UInt8> = [UInt8(ascii: "}"), UInt8(ascii: "]")]
        let blocksLevel = [UInt8(ascii: "{"), UInt8(ascii: "[")]
        var stack: [UInt8] = []
        var inString = false, escaped = false
        // A root-level string after a colon is a value, not a key.
        var afterColon = false, stringIsValue = false
        var blocksEnd: Int?, valueEnd: Int?
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                    if stringIsValue { valueEnd = index + 1 }
                }
                continue
            }
            if byte == quote {
                inString = true
                stringIsValue = stack.count == 1 && afterColon
            } else if stack.count == 1, byte == UInt8(ascii: ":") {
                afterColon = true
            } else if stack.count == 1, byte == UInt8(ascii: ",") {
                afterColon = false
            } else if open.contains(byte) {
                stack.append(byte)
            } else if close.contains(byte) {
                guard stack.popLast() != nil else { return Partial() }
                if stack.isEmpty {
                    let visual = LedgerAgentVisual(json: String(decoding: bytes[...index], as: UTF8.self))
                    return Partial(visual: visual, title: visual?.title ?? title(bytes, upTo: valueEnd), complete: true)
                }
                if stack == blocksLevel { blocksEnd = index + 1 }
            }
        }
        let visual = blocksEnd.flatMap { end in
            LedgerAgentVisual(json: String(decoding: bytes[..<end], as: UTF8.self) + "]}")
        }
        return Partial(visual: visual, title: visual?.title ?? title(bytes, upTo: valueEnd))
    }

    /// The root `title`, read from the text up to a root-level string value.
    private static func title(_ bytes: [UInt8], upTo end: Int?) -> String? {
        guard let end,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes[..<end] + Array("}".utf8))) as? [String: Any],
              let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }
}
