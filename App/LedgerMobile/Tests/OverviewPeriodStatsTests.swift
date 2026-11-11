import XCTest
@testable import LedgerMobile

final class OverviewPeriodStatsTests: XCTestCase {
    private let summary = LedgerSummary(currency: "CNY", income: 900_000, expense: 310_000, net: 590_000)

    private func comparison(current: Int?, baseline: Int?) -> LedgerPeriodComparison {
        let delta = current.flatMap { current in baseline.map { current - $0 } }
        let percentage = delta.flatMap { delta in baseline.flatMap { $0 == 0 ? nil : Double(delta) / Double($0) } }
        return LedgerPeriodComparison(currentRange: .init(start: "2026-11-01", end: "2026-11-10"),
            baselineRange: .init(start: "2026-10-01", end: "2026-10-10"),
            current: current, baseline: baseline, delta: delta, percentage: percentage)
    }

    private func stats(today: String, comparisons: LedgerPeriodComparisons? = nil,
                       netWorth: LedgerNetWorthWindows? = nil) -> OverviewPeriodStats {
        OverviewPeriodStats(start: "2026-11-01", end: "2026-11-30", today: today, summary: summary,
            comparisons: comparisons, netWorthWindows: netWorth, transactionCount: 42)
    }

    func testInProgressPeriodDividesByDaysSoFarIncludingToday() {
        let stats = stats(today: "2026-11-10")
        XCTAssertEqual(stats.elapsedDays, 10)
        XCTAssertTrue(stats.isInProgress)
        XCTAssertEqual(stats.dailyExpense, 31_000)
        XCTAssertEqual(stats.transactionCount, 42)
    }

    func testLastDayIsStillInProgress() {
        let stats = stats(today: "2026-11-30")
        XCTAssertEqual(stats.elapsedDays, 30)
        XCTAssertTrue(stats.isInProgress)
    }

    func testEndedPeriodDividesByWholePeriod() {
        let stats = stats(today: "2027-01-05")
        XCTAssertEqual(stats.elapsedDays, 30)
        XCTAssertFalse(stats.isInProgress)
        XCTAssertEqual(stats.dailyExpense, 10_333)
    }

    func testFuturePeriodHasNoDailyFigures() {
        let stats = stats(today: "2026-10-20")
        XCTAssertNil(stats.elapsedDays)
        XCTAssertFalse(stats.isInProgress)
        XCTAssertNil(stats.dailyExpense)
    }

    func testComparisonsWithoutBaselineAreDropped() {
        let comparisons = LedgerPeriodComparisons(
            income: .init(monthOverMonth: comparison(current: 900_000, baseline: nil),
                          yearOverYear: comparison(current: 900_000, baseline: nil)),
            expense: .init(monthOverMonth: comparison(current: 310_000, baseline: 250_000),
                           yearOverYear: comparison(current: 310_000, baseline: 0)),
            totalAssets: nil)
        let stats = stats(today: "2026-11-10", comparisons: comparisons)
        XCTAssertEqual(stats.expenseMonthOverMonth?.delta, 60_000)
        XCTAssertNil(stats.incomeMonthOverMonth)
        XCTAssertEqual(stats.expenseYearOverYear?.delta, 310_000)
        XCTAssertNil(stats.expenseYearOverYear?.percentage)
    }

    func testMissingComparisonsAndNetWorthStayNil() {
        let stats = stats(today: "2026-11-10")
        XCTAssertNil(stats.expenseMonthOverMonth)
        XCTAssertNil(stats.netWorth)
        XCTAssertNil(stats.netWorthMonthChange)
    }

    func testNetWorthComesFromLatestPointAndMonthChange() {
        let latest = LedgerNetWorthPoint(date: "2026-11-10", assets: 5_000_000, liabilities: -800_000, netWorth: 4_200_000)
        let windows = LedgerNetWorthWindows(latest: latest, previousMonthEnd: nil, monthChange: -150_000,
            sixMonth: .init(baseline: nil, change: nil, changeRatio: nil),
            twelveMonth: .init(baseline: nil, change: nil, changeRatio: nil))
        let stats = stats(today: "2026-11-10", netWorth: windows)
        XCTAssertEqual(stats.netWorth, 4_200_000)
        XCTAssertEqual(stats.netWorthMonthChange, -150_000)
    }
}
