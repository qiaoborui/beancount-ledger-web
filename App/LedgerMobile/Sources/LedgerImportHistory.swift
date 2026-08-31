import Foundation

struct LedgerImportProvider: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let compactLabel: String
    let systemImage: String

    static let all: [LedgerImportProvider] = [
        LedgerImportProvider(id: "alipay", label: "支付宝", compactLabel: "支付宝", systemImage: "creditcard"),
        LedgerImportProvider(id: "alipay-small-purse", label: "支付宝小荷包", compactLabel: "小荷包", systemImage: "person.2"),
        LedgerImportProvider(id: "wechat", label: "微信支付", compactLabel: "微信支付", systemImage: "message"),
        LedgerImportProvider(id: "cmb", label: "招商银行信用卡", compactLabel: "招行信用卡", systemImage: "creditcard.fill"),
        LedgerImportProvider(id: "ccb-credit", label: "建设银行信用卡", compactLabel: "建行信用卡", systemImage: "creditcard.fill"),
        LedgerImportProvider(id: "hsbchk-credit", label: "汇丰香港信用卡", compactLabel: "汇丰香港信用卡", systemImage: "creditcard.fill"),
        LedgerImportProvider(id: "cmb-checking", label: "招商银行储蓄卡", compactLabel: "招行储蓄卡", systemImage: "building.columns"),
    ]

    static func provider(_ id: String?) -> LedgerImportProvider? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}

enum LedgerImportFreshness: Int, Equatable, Sendable {
    case overdue
    case attention
    case current
    case missing

    var title: String {
        switch self {
        case .overdue: "需要更新"
        case .attention: "建议更新"
        case .current: "已更新"
        case .missing: "暂无记录"
        }
    }
}

struct LedgerImportChannelStatus: Identifiable, Equatable, Sendable {
    let provider: LedgerImportProvider
    let document: LedgerImportDocument?
    let freshness: LedgerImportFreshness
    let daysSinceCoverage: Int?

    var id: String { provider.id }
}

enum LedgerImportHistory {
    static func latestDocumentsByProvider(
        _ documents: [LedgerImportDocument]
    ) -> [String: LedgerImportDocument] {
        var latest: [String: LedgerImportDocument] = [:]
        for document in documents {
            guard let provider = document.provider,
                  LedgerImportProvider.provider(provider) != nil else { continue }
            if let current = latest[provider], !isLater(document, than: current) { continue }
            latest[provider] = document
        }
        return latest
    }

    static func channelStatuses(
        documents: [LedgerImportDocument],
        referenceDate: Date = Date()
    ) -> [LedgerImportChannelStatus] {
        let latest = latestDocumentsByProvider(documents)
        return LedgerImportProvider.all.map { provider in
            guard let document = latest[provider.id],
                  let coverage = coverageDate(document),
                  let date = dayDate(coverage) else {
                return LedgerImportChannelStatus(
                    provider: provider,
                    document: latest[provider.id],
                    freshness: .missing,
                    daysSinceCoverage: nil
                )
            }
            let days = max(0, calendar.dateComponents([.day], from: date, to: referenceDate).day ?? 0)
            let freshness: LedgerImportFreshness
            if days > 35 {
                freshness = .overdue
            } else if days > 20 {
                freshness = .attention
            } else {
                freshness = .current
            }
            return LedgerImportChannelStatus(
                provider: provider,
                document: document,
                freshness: freshness,
                daysSinceCoverage: days
            )
        }
        .sorted {
            if $0.freshness.rawValue != $1.freshness.rawValue {
                return $0.freshness.rawValue < $1.freshness.rawValue
            }
            return $0.provider.label.localizedStandardCompare($1.provider.label) == .orderedAscending
        }
    }

    static func sortedDocuments(_ documents: [LedgerImportDocument]) -> [LedgerImportDocument] {
        documents.sorted {
            if $0.modTime != $1.modTime { return $0.modTime > $1.modTime }
            return $0.id > $1.id
        }
    }

    static func coverageDate(_ document: LedgerImportDocument) -> String? {
        document.dateEnd ?? document.dateStart
    }

    static func coverageText(_ document: LedgerImportDocument) -> String {
        if let start = document.dateStart, let end = document.dateEnd, start != end {
            return "覆盖 \(slashDate(start)) 至 \(slashDate(end))"
        }
        if let date = coverageDate(document) {
            return "覆盖至 \(slashDate(date))"
        }
        return "账期范围未知"
    }

    static func archivedText(_ document: LedgerImportDocument, relativeTo referenceDate: Date = Date()) -> String {
        guard let date = instantDate(document.modTime) else { return document.modTime }
        let relative = RelativeDateTimeFormatter()
        relative.locale = Locale(identifier: "zh_CN")
        relative.unitsStyle = .full
        return relative.localizedString(for: date, relativeTo: referenceDate)
    }

    static func fullArchivedText(_ document: LedgerImportDocument) -> String {
        guard let date = instantDate(document.modTime) else { return document.modTime }
        return date.formatted(
            .dateTime
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .locale(Locale(identifier: "zh_CN"))
        )
    }

    static func fileSizeText(_ document: LedgerImportDocument) -> String? {
        guard let size = document.size else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private static func isLater(_ candidate: LedgerImportDocument, than current: LedgerImportDocument) -> Bool {
        let candidateCoverage = coverageDate(candidate) ?? ""
        let currentCoverage = coverageDate(current) ?? ""
        if candidateCoverage != currentCoverage { return candidateCoverage > currentCoverage }
        return candidate.modTime > current.modTime
    }

    private static func slashDate(_ raw: String) -> String {
        raw.replacingOccurrences(of: "-", with: "/")
    }

    private static func dayDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    private static func instantDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }
}
