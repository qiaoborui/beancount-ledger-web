import Foundation

struct BQLColumn: Codable, Equatable, Hashable, Sendable {
    let name: String
    let type: String

    var isNumeric: Bool {
        type == "money" || type == "number"
    }

    var isTimeDimension: Bool {
        let normalized = name.lowercased()
        return type == "date"
            || normalized == "date"
            || normalized == "month"
            || normalized.hasSuffix("_date")
            || normalized.hasSuffix("_month")
    }
}

enum BQLCell: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([BQLCell])
    case object([String: BQLCell])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([BQLCell].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: BQLCell].self) {
            self = .object(value)
        } else {
            throw DecodingError.typeMismatch(
                BQLCell.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported BQL cell value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    var numberValue: Double? {
        switch self {
        case let .number(value): value
        case let .string(value): Double(value)
        default: nil
        }
    }

    var plainText: String {
        switch self {
        case .null:
            ""
        case let .bool(value):
            value ? "true" : "false"
        case let .number(value):
            BQLCell.numberFormatter.string(from: NSNumber(value: value)) ?? String(value)
        case let .string(value):
            value
        case let .array(values):
            values.map(\.plainText).joined(separator: ", ")
        case let .object(value):
            value.keys.sorted().map { "\($0): \(value[$0]?.plainText ?? "")" }.joined(separator: ", ")
        }
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        return formatter
    }()
}

struct BQLResult: Decodable, Equatable, Sendable {
    let columns: [BQLColumn]
    let rows: [[BQLCell]]
    let query: String
    let warnings: [String]
    let valuationCurrency: String
    let limit: Int
    let rowCount: Int

    private enum CodingKeys: String, CodingKey {
        case columns
        case rows
        case query
        case warnings
        case valuationCurrency
        case limit
        case rowCount
    }

    init(
        columns: [BQLColumn],
        rows: [[BQLCell]],
        query: String,
        warnings: [String] = [],
        valuationCurrency: String,
        limit: Int,
        rowCount: Int
    ) {
        self.columns = columns
        self.rows = rows
        self.query = query
        self.warnings = warnings
        self.valuationCurrency = valuationCurrency
        self.limit = limit
        self.rowCount = rowCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = try container.decodeIfPresent([BQLColumn].self, forKey: .columns) ?? []
        rows = try container.decodeIfPresent([[BQLCell]].self, forKey: .rows) ?? []
        query = try container.decode(String.self, forKey: .query)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        valuationCurrency = try container.decode(String.self, forKey: .valuationCurrency)
        limit = try container.decode(Int.self, forKey: .limit)
        rowCount = try container.decode(Int.self, forKey: .rowCount)
    }
}

struct BQLHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let query: String
    let title: String
    let titleSource: String
    let createdAt: String
    let lastRunAt: String
    let runCount: Int
}

struct BQLHistoryResponse: Decodable, Equatable, Sendable {
    let records: [BQLHistoryRecord]

    init(records: [BQLHistoryRecord]) {
        self.records = records
    }

    private enum CodingKeys: String, CodingKey {
        case records
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decodeIfPresent([BQLHistoryRecord].self, forKey: .records) ?? []
    }
}

struct BQLRequest: Encodable, Sendable {
    let query: String
    let valuationCurrency: String
}

struct BQLHistorySaveRequest: Encodable, Sendable {
    let query: String
}

struct BQLHistoryRenameRequest: Encodable, Sendable {
    let title: String
}

enum BQLHistoryMerge {
    static func reconcile(
        loaded: [BQLHistoryRecord],
        snapshot: [BQLHistoryRecord],
        current: [BQLHistoryRecord]
    ) -> [BQLHistoryRecord] {
        let snapshotByID = recordsByID(snapshot)
        let currentByID = recordsByID(current)
        let locallyChangedIDs = Set(snapshotByID.keys).union(currentByID.keys).filter {
            snapshotByID[$0] != currentByID[$0]
        }

        var mergedByID = recordsByID(loaded)
        for id in locallyChangedIDs {
            if let record = currentByID[id] {
                mergedByID[id] = record
            } else {
                mergedByID.removeValue(forKey: id)
            }
        }
        return Array(mergedByID.values)
    }

    private static func recordsByID(_ records: [BQLHistoryRecord]) -> [String: BQLHistoryRecord] {
        records.reduce(into: [:]) { result, record in
            result[record.id] = record
        }
    }
}

enum BQLStatements {
    static func split(_ raw: String) -> [String] {
        var statements: [String] = []
        var start = raw.startIndex
        var index = raw.startIndex
        var quote: Character?
        var escaped = false

        while index < raw.endIndex {
            let character = raw[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == ";" {
                append(raw[start..<index], to: &statements)
                start = raw.index(after: index)
            }
            index = raw.index(after: index)
        }
        append(raw[start..<raw.endIndex], to: &statements)
        return statements
    }

    private static func append(_ slice: Substring, to statements: inout [String]) {
        let statement = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        if !statement.isEmpty {
            statements.append(statement)
        }
    }
}
