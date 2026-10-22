import Foundation

/// Bucket labels for the cashflow bar chart. Pure formatting, so the chart view
/// and the portable tests share one implementation.
enum BalancedBucketAxis {
    enum Granularity { case day, week, month, quarter }
    static let maxLabels = 6

    static func granularity(_ labels: [String]) -> Granularity {
        guard let sample = labels.first else { return .month }
        if sample.contains("~") { return .week }
        if sample.contains("Q") { return .quarter }
        return sample.split(separator: "-").count == 2 && sample.count == 7 ? .month : .day
    }

    /// Section head for the bar chart, so a month range is not called 月度.
    static func title(_ labels: [String]) -> String {
        switch granularity(labels) {
        case .day: String(localized: "每日收支")
        case .week: String(localized: "每周收支")
        case .month: String(localized: "月度收支")
        case .quarter: String(localized: "季度收支")
        }
    }

    static func footnote(_ labels: [String]) -> String {
        switch granularity(labels) {
        case .day: String(localized: "按日汇总 · 转账不计收支")
        case .week: String(localized: "按周汇总 · 转账不计收支")
        case .month: String(localized: "按月汇总 · 转账不计收支")
        case .quarter: String(localized: "按季汇总 · 转账不计收支")
        }
    }

    static func labelled(_ labels: [String]) -> [String] {
        guard labels.count > maxLabels else { return labels }
        let stride = Int((Double(labels.count) / Double(maxLabels)).rounded(.up))
        // Days and weeks read from the start of the range; months and quarters
        // anchor on the latest bucket so the current period is labelled.
        let fromStart = [.day, .week].contains(granularity(labels))
        return labels.enumerated().filter { item in
            (fromStart ? item.offset : labels.count - 1 - item.offset) % stride == 0
        }.map(\.element)
    }

    static func label(_ raw: String, showsYear: Bool) -> String {
        let start = raw.split(separator: "~").first.map(String.init) ?? raw
        let parts = start.split(separator: "-").map(String.init)
        switch granularity([raw]) {
        case .quarter:
            guard parts.count == 2 else { return raw }
            return "\(parts[0].suffix(2)) \(parts[1])"
        case .month:
            guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]),
                  let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: 1))
            else { return raw }
            let style = Date.FormatStyle(date: .omitted, time: .omitted).locale(LedgerLocale.current)
            return showsYear || month == 1
                ? date.formatted(style.year(.twoDigits).month(.abbreviated))
                : date.formatted(style.month(.abbreviated))
        case .day, .week:
            let tail = parts.suffix(2)
            guard tail.count == 2, let month = Int(tail.first!), let day = Int(tail.last!) else { return raw }
            return "\(month)/\(day)"
        }
    }
}
