import Foundation
import XCTest
@testable import LedgerMobile

final class ImportHistoryTests: XCTestCase {
    func testLatestDocumentsPreferCoverageBeforeArchiveTime() throws {
        let documents = [
            document(provider: "alipay", start: "2026-08-01", end: "2026-08-20", modTime: "2026-08-30T08:00:00Z"),
            document(provider: "alipay", start: "2026-08-01", end: "2026-08-28", modTime: "2026-08-29T08:00:00Z"),
            document(provider: "wechat", start: "2026-08-01", end: "2026-08-25", modTime: "2026-08-26T08:00:00Z"),
        ]

        let latest = LedgerImportHistory.latestDocumentsByProvider(documents)

        XCTAssertEqual(latest["alipay"]?.dateEnd, "2026-08-28")
        XCTAssertEqual(latest["wechat"]?.dateEnd, "2026-08-25")
    }

    func testChannelStatusesClassifyFreshAttentionOverdueAndMissing() throws {
        let referenceDate = try XCTUnwrap(day("2026-08-31"))
        let documents = [
            document(provider: "alipay", start: "2026-08-01", end: "2026-08-28", modTime: "2026-08-29T08:00:00Z"),
            document(provider: "wechat", start: "2026-08-01", end: "2026-08-08", modTime: "2026-08-09T08:00:00Z"),
            document(provider: "cmb", start: "2026-06-01", end: "2026-06-30", modTime: "2026-07-03T08:00:00Z"),
        ]

        let statuses = Dictionary(
            uniqueKeysWithValues: LedgerImportHistory.channelStatuses(
                documents: documents,
                referenceDate: referenceDate
            ).map { ($0.provider.id, $0) }
        )

        XCTAssertEqual(statuses["alipay"]?.freshness, .current)
        XCTAssertEqual(statuses["alipay"]?.daysSinceCoverage, 3)
        XCTAssertEqual(statuses["wechat"]?.freshness, .attention)
        XCTAssertEqual(statuses["cmb"]?.freshness, .overdue)
        XCTAssertEqual(statuses["ccb-credit"]?.freshness, .missing)
    }

    func testHistorySortsNewestArchiveFirstAndFormatsCoverage() {
        let older = document(provider: "alipay", start: "2026-07-01", end: "2026-07-31", modTime: "2026-08-01T08:00:00Z")
        let newer = document(provider: "wechat", start: "2026-08-01", end: "2026-08-25", modTime: "2026-08-26T08:00:00Z")

        XCTAssertEqual(LedgerImportHistory.sortedDocuments([older, newer]).first?.provider, "wechat")
        XCTAssertEqual(LedgerImportHistory.coverageText(newer), "覆盖 2026/08/01 至 2026/08/25")
    }

    private func document(
        provider: String,
        start: String,
        end: String,
        modTime: String
    ) -> LedgerImportDocument {
        LedgerImportDocument(
            provider: provider,
            dateStart: start,
            dateEnd: end,
            modTime: modTime
        )
    }

    private func day(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }
}
