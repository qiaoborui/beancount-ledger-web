import XCTest
@testable import LedgerMobile

@MainActor
final class BalancedBucketAxisTests: XCTestCase {
    func testDailyMonthThinsToSixLabelsFromTheFirstDay() {
        let days = (1...31).map { String(format: "08-%02d", $0) }
        XCTAssertEqual(BalancedBucketAxis.title(days), "每日收支")
        XCTAssertEqual(BalancedBucketAxis.labelled(days), ["08-01", "08-07", "08-13", "08-19", "08-25", "08-31"])
        XCTAssertEqual(BalancedBucketAxis.label("08-07", showsYear: false), "8/7")
    }

    func testWeeksUseTheirStartDay() {
        let weeks = ["06-01~06-07", "06-08~06-14"]
        XCTAssertEqual(BalancedBucketAxis.title(weeks), "每周收支")
        XCTAssertEqual(BalancedBucketAxis.label(weeks[1], showsYear: false), "6/8")
    }

    func testMonthsAnchorOnLatestAndMarkYears() {
        let months = (1...12).map { String(format: "2025-%02d", $0) } + ["2026-01", "2026-02"]
        XCTAssertEqual(BalancedBucketAxis.title(months), "月度收支")
        XCTAssertEqual(BalancedBucketAxis.labelled(months).last, "2026-02")
        XCTAssertLessThanOrEqual(BalancedBucketAxis.labelled(months).count, BalancedBucketAxis.maxLabels)
        XCTAssertEqual(BalancedBucketAxis.label("2026-01", showsYear: false), "26年1月")
        XCTAssertEqual(BalancedBucketAxis.label("2025-08", showsYear: false), "8月")
        XCTAssertEqual(BalancedBucketAxis.label("2025-08", showsYear: true), "25年8月")
    }

    func testQuarters() {
        XCTAssertEqual(BalancedBucketAxis.title(["2024-Q1"]), "季度收支")
        XCTAssertEqual(BalancedBucketAxis.label("2024-Q3", showsYear: false), "24 Q3")
    }

    func testShortSeriesKeepsEveryLabel() {
        let months = ["2026-03", "2026-04", "2026-05"]
        XCTAssertEqual(BalancedBucketAxis.labelled(months), months)
    }
}
