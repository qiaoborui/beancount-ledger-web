import XCTest
@testable import LedgerMobile

final class LedgerColorThemeTests: XCTestCase {
    /// The original scheme must keep the exact Balanced tones the app shipped with.
    func testPaperKeepsTheShippedBalancedTones() {
        let light = LedgerColorTheme.paper.tokens(dark: false)
        XCTAssertEqual(light.page, 0xFBFAF8)
        XCTAssertEqual(light.sunken, 0xF1EFE9)
        XCTAssertEqual(light.ink, 0x14100C)
        XCTAssertEqual(light.edge, 0x88837A)
        let dark = LedgerColorTheme.paper.tokens(dark: true)
        XCTAssertEqual(dark.page, 0x121110)
        XCTAssertEqual(dark.sunken, 0x1B1918)
        XCTAssertEqual(dark.ink, 0xF6F3EE)
    }

    func testNeutralIsPureWhiteAndTrueBlack() {
        XCTAssertEqual(LedgerColorTheme.neutral.tokens(dark: false).page, 0xFFFFFF)
        XCTAssertEqual(LedgerColorTheme.neutral.tokens(dark: true).page, 0x000000)
    }

    /// Text and control boundaries stay legible on both grounds in every scheme.
    func testEverySchemeMeetsContrast() {
        for theme in LedgerColorTheme.allCases {
            for dark in [false, true] {
                let t = theme.tokens(dark: dark)
                for ground in [t.page, t.sunken] {
                    let label = "\(theme.rawValue) dark=\(dark)"
                    XCTAssertGreaterThanOrEqual(LedgerContrast.ratio(t.ink, ground), 7, label)
                    XCTAssertGreaterThanOrEqual(LedgerContrast.ratio(t.secondary, ground), 7, label)
                    XCTAssertGreaterThanOrEqual(LedgerContrast.ratio(t.meta, ground), 4.5, label)
                    XCTAssertGreaterThanOrEqual(LedgerContrast.ratio(t.income, ground), 4.5, label)
                    XCTAssertGreaterThanOrEqual(LedgerContrast.ratio(t.expense, ground), 4.5, label)
                    XCTAssertGreaterThanOrEqual(LedgerContrast.ratio(t.edge, ground), 3, label)
                }
            }
        }
    }

    /// Chart marks are graphics: 3:1 against both grounds, six distinct series.
    func testChartColoursAreVisibleAndDistinct() {
        for theme in LedgerColorTheme.allCases {
            for dark in [false, true] {
                let t = theme.tokens(dark: dark)
                let label = "\(theme.rawValue) dark=\(dark)"
                for mark in [t.chart.accent, t.chart.income, t.chart.expense] {
                    for ground in [t.page, t.sunken] {
                        XCTAssertGreaterThanOrEqual(LedgerContrast.ratio(mark, ground), 3, label)
                    }
                }
                XCTAssertEqual(t.chart.series.count, 6, label)
                XCTAssertEqual(Set(t.chart.series).count, 6, label)
                XCTAssertEqual(t.value(.chartSeries(6)), t.chart.series[0], label)
                XCTAssertEqual(t.value(.chartSeries(-1)), t.chart.series[5], label)
            }
        }
        // Paper keeps the ink / income / expense marks it shipped with.
        let paper = LedgerColorTheme.paper.tokens(dark: false)
        XCTAssertEqual(paper.chart.accent, paper.ink)
        XCTAssertEqual(paper.chart.income, paper.income)
        XCTAssertEqual(paper.chart.expense, paper.expense)
    }

    func testChoicePersistsAndDefaultsToPaper() throws {
        let suite = "LedgerColorThemeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(LedgerColorTheme.stored(in: defaults), .paper)
        LedgerColorTheme.slate.store(in: defaults)
        XCTAssertEqual(LedgerColorTheme.stored(in: defaults), .slate)
        LedgerColorTheme.paper.store(in: defaults)
        XCTAssertNil(defaults.string(forKey: LedgerColorTheme.defaultsKey))
        defaults.set("bogus", forKey: LedgerColorTheme.defaultsKey)
        XCTAssertEqual(LedgerColorTheme.stored(in: defaults), .paper)
    }

    func testArtifactThemeFollowsTheActiveScheme() {
        let previous = LedgerColorTheme.active
        defer { LedgerColorTheme.active = previous }

        LedgerColorTheme.active = .paper
        XCTAssertTrue(LedgerAgentArtifactHTML.theme.contains("--page:#FBFAF8;"))
        XCTAssertTrue(LedgerAgentArtifactHTML.theme.contains("--page:#121110;"))
        LedgerColorTheme.active = .neutral
        XCTAssertTrue(LedgerAgentArtifactHTML.theme.contains("--page:#FFFFFF;"))
        XCTAssertTrue(LedgerAgentArtifactHTML.theme.contains("--page:#000000;"))
        XCTAssertTrue(LedgerAgentArtifactHTML.theme.contains("html,body{margin:0;background:var(--page)"))
    }
}
