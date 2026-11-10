import XCTest
@testable import LedgerMobile

final class LedgerModelsTests: XCTestCase {
    func testRangeToolbarTitlePreservesCrossYearAndCustomContext() {
        let now = ISO8601DateFormatter().date(from: "2026-08-31T12:00:00Z")!
        XCTAssertEqual(LedgerDateRange.month(year: 2026, month: 8).toolbarTitle(relativeTo: now), "8月")
        XCTAssertEqual(LedgerDateRange.month(year: 2025, month: 12).toolbarTitle(relativeTo: now), "2025/12月")
        XCTAssertEqual(LedgerDateRange.current(.quarter, now: now).toolbarTitle(relativeTo: now), "Q3")
        XCTAssertEqual(LedgerDateRange.current(.year, now: now).toolbarTitle(relativeTo: now), "2026年")
        XCTAssertEqual(LedgerDateRange.custom(start: now, end: now).toolbarTitle(relativeTo: now), "8/31")
    }

    func testSearchAndMoreNeverBecomeOverflowRoutes() {
        for tabs: [LedgerDestination] in [[.overview, .transactions, .accounts], [.assets]] {
            XCTAssertFalse(LedgerDestination.search.isCompactOverflow(in: tabs))
            XCTAssertFalse(LedgerDestination.settings.isCompactOverflow(in: tabs))
            XCTAssertEqual(LedgerDestination.search.compactSelection(in: tabs), .search)
            XCTAssertTrue(LedgerDestination.imports.isCompactOverflow(in: tabs))
            XCTAssertEqual(LedgerDestination.imports.compactSelection(in: tabs), .settings)
        }
    }

    func testCompactTabsPreserveOrderDeduplicateLimitAndFallback() {
        XCTAssertEqual(
            LedgerDestination.normalizedCompactTabs([
                .transactions,
                .imports,
                .transactions,
                .assets,
                .query,
                .accounts,
            ]),
            [.transactions, .imports, .assets]
        )
        XCTAssertEqual(
            LedgerDestination.normalizedCompactTabs([.settings, .search]),
            LedgerDestination.defaultCompactTabs
        )
        XCTAssertEqual(
            LedgerDestination.overview.compactSelection(in: [.transactions, .accounts]),
            .settings
        )
        XCTAssertEqual(
            LedgerDestination.accounts.compactSelection(in: [.transactions, .accounts]),
            .accounts
        )
    }

    func testAgentCanBeChosenAsACompactTab() {
        XCTAssertTrue(LedgerDestination.compactTabCandidates.contains(.agent))
        XCTAssertEqual(LedgerDestination.normalizedCompactTabs([.overview, .transactions, .agent]), [.overview, .transactions, .agent])
        XCTAssertEqual(LedgerDestination.agent.compactSelection(in: [.overview, .transactions, .agent]), .agent)
        XCTAssertEqual(LedgerDestination.agent.compactSelection(in: LedgerDestination.defaultCompactTabs), .settings)
        XCTAssertEqual(LedgerDestination.stored("agent"), .agent)
    }

    func testPasskeyAssertionUsesUnpaddedBase64URLWebAuthnJSON() throws {
        let assertion = PasskeyAssertion(
            credentialID: Data([0xFB, 0xFF]),
            clientDataJSON: Data([0x01, 0x02]),
            authenticatorData: Data([0x03]),
            signature: Data([0x04]),
            userHandle: Data()
        )

        let data = try JSONEncoder().encode(assertion)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, "-_8")
        XCTAssertEqual(json["rawId"] as? String, "-_8")
        XCTAssertEqual(json["type"] as? String, "public-key")
        let response = try XCTUnwrap(json["response"] as? [String: Any])
        XCTAssertEqual(response["clientDataJSON"] as? String, "AQI")
        XCTAssertEqual(response["authenticatorData"] as? String, "Aw")
        XCTAssertEqual(response["signature"] as? String, "BA")
        XCTAssertNil(response["userHandle"])
        XCTAssertEqual(Data(base64URLEncoded: "-_8"), Data([0xFB, 0xFF]))
    }

    func testNativePasskeyPreparationPinsRelyingPartyAndDecodesCredentialIDs() throws {
        let options = PasskeyRequestOptions(
            challenge: "AQID",
            relyingPartyID: "beancount.borry.org",
            allowCredentials: [
                PasskeyCredentialDescriptor(type: "public-key", id: "BAUG", transports: ["internal"]),
            ]
        )

        let prepared = try options.preparedForNativeAuthentication(relyingPartyID: "beancount.borry.org")
        XCTAssertEqual(prepared.challenge, Data([1, 2, 3]))
        XCTAssertEqual(prepared.allowedCredentialIDs, [Data([4, 5, 6])])
        XCTAssertThrowsError(try options.preparedForNativeAuthentication(relyingPartyID: "mesh.example")) { error in
            XCTAssertEqual(
                error as? PasskeyAuthenticationError,
                .relyingPartyMismatch(expected: "mesh.example", received: "beancount.borry.org")
            )
        }
    }

    func testServerOriginNormalizationAddsHTTPS() throws {
        let url = try ServerConfiguration.normalize("ledger.mesh.arpa/")
        XCTAssertEqual(url.absoluteString, "https://ledger.mesh.arpa")
    }

    func testServerOriginRejectsHTTPAndPaths() {
        XCTAssertThrowsError(try ServerConfiguration.normalize("http://ledger.example.com")) { error in
            XCTAssertEqual(error as? ServerConfigurationError, .requiresHTTPS)
        }
        XCTAssertThrowsError(try ServerConfiguration.normalize("https://ledger.example.com/private")) { error in
            XCTAssertEqual(error as? ServerConfigurationError, .originOnly)
        }
    }

    func testBootstrapDecodingBuildsBalanceSheetAndSections() throws {
        let payload = try JSONDecoder().decode(LedgerBootstrap.self, from: Data(Self.bootstrapJSON.utf8))

        XCTAssertEqual(payload.summary.net, 315_000)
        XCTAssertEqual(payload.comparisons?.income.monthOverMonth.delta, 20_000)
        XCTAssertEqual(payload.comparisons?.income.yearOverYear.percentage, 0.5)
        XCTAssertEqual(payload.comparisons?.expense.monthOverMonth.delta, -1_000)
        XCTAssertNil(payload.comparisons?.expense.yearOverYear.percentage)
        XCTAssertNil(payload.comparisons?.totalAssets)
        XCTAssertEqual(
            payload.balanceSheetTotals,
            BalanceSheetTotals(assets: 1_235_000, liabilities: 235_000, netWorth: 1_000_000)
        )
        XCTAssertEqual(payload.accountSections.map(\.title), ["现金与支付", "信用账户"])
        XCTAssertEqual(payload.accountSections.first?.rows.first?.label, "日常账户")
        XCTAssertEqual(payload.transactions.first?.source.gitSHA, "abc123")
        XCTAssertEqual(payload.transactions.first?.metadata?["verified"], .bool(true))
        XCTAssertEqual(payload.transactions.first?.metadata?["reviewedAt"], .null)
        XCTAssertEqual(payload.transactions.first?.editableEntry?.flag, "!")
        XCTAssertEqual(payload.transactions.first?.editableEntry?.links, ["receipt-2026"])
        XCTAssertEqual(payload.transactions.first?.editableEntry?.postings.first?.amount, "1.23456789")
        XCTAssertEqual(payload.transactions.first?.editableEntry?.postings.first?.costKind, "total")
        XCTAssertEqual(payload.transactions.first?.editableEntry?.postings.first?.costSpec, #"{{ 123.456789 USD, 2026-05-01, "lot-a" }}"#)
        XCTAssertEqual(payload.transactions.first?.editableEntry?.postings.first?.priceKind, "unit")
        XCTAssertEqual(payload.netWorthHistory.last?.netWorth, 1_000_000)
        XCTAssertEqual(payload.netWorthTrend.first?.date, "2026-02-28")
        XCTAssertEqual(payload.netWorthTrend.last?.netWorth, 1_000_000)
        XCTAssertEqual(payload.monthEndNetWorth.count, 1)
        XCTAssertEqual(payload.netWorthWindows?.monthChange, 15_000)
        XCTAssertEqual(payload.commodities, ["CNY", "USD"])
        XCTAssertEqual(payload.prices.first, LedgerPrice(date: "2026-08-20", currency: "USD", amount: 713, quoteCurrency: "CNY"))

        let rows = payload.accountSections.flatMap(\.rows)
        XCTAssertEqual(rows.filter(AccountBalanceCategory.assets.includes).map(\.account), ["Assets:Bank:Daily"])
        XCTAssertEqual(rows.filter(AccountBalanceCategory.liabilities.includes).map(\.account), ["Liabilities:CreditCard:Visa"])
        XCTAssertEqual(rows.first(where: { $0.account == "Assets:Bank:Daily" })?.openingValuation, 1_243_500)
        XCTAssertEqual(rows.first(where: { $0.account == "Assets:Bank:Daily" })?.closingValuation, 1_235_000)
        XCTAssertEqual(rows.first(where: { $0.account == "Assets:Bank:Daily" })?.periodValuationChange, -8_500)
        XCTAssertTrue(rows.allSatisfy(\.periodBalancesAvailable))

        let legacyRows = payload.accountSections(periodBalancesAvailable: false).flatMap(\.rows)
        let daily = try XCTUnwrap(legacyRows.first(where: { $0.account == "Assets:Bank:Daily" }))
        XCTAssertFalse(daily.periodBalancesAvailable)
        XCTAssertEqual(daily.closingValuation, daily.valuation)
        XCTAssertEqual(daily.periodValuationChange, 0)
    }

    /// An overpaid card (a positive Liabilities balance) is owed to the user:
    /// it lowers debt instead of adding to it, so net worth is not understated
    /// by twice the overpayment.
    func testBalanceSheetTotalsTreatAnOverpaidCardAsReducingDebt() throws {
        let json = Self.bootstrapJSON.replacingOccurrences(of: #""valuation": -235000,"#, with: #""valuation": 50000,"#)
        let payload = try JSONDecoder().decode(LedgerBootstrap.self, from: Data(json.utf8))
        XCTAssertEqual(
            payload.balanceSheetTotals,
            BalanceSheetTotals(assets: 1_235_000, liabilities: -50_000, netWorth: 1_285_000)
        )
    }

    /// The 账户 period totals classify by account prefix like the non-period
    /// path: a payable in the 应收 group is debt, an Assets account in the 其他
    /// group is still an asset, and closing valuations are used.
    func testClosingRowTotalsClassifyByAccountPrefixNotGroup() {
        func row(_ account: String, group: String, valuation: Int, closing: Int) -> AccountBalanceRow {
            AccountBalanceRow(
                account: account, label: account, group: group,
                nativeCurrency: "CNY", nativeAmount: valuation,
                valuationCurrency: "CNY", valuation: valuation, valuationMissing: false,
                periodBalancesAvailable: true,
                openingNativeAmount: valuation, closingNativeAmount: closing, periodNativeChange: closing - valuation,
                openingValuation: valuation, closingValuation: closing, periodValuationChange: closing - valuation,
                periodValuationMissing: false
            )
        }
        let totals = BalanceSheetTotals(closingRows: [
            row("Assets:Bank", group: "cash", valuation: 0, closing: 1_000_000),
            row("Assets:Misc", group: "other", valuation: 0, closing: 20_000),
            row("Liabilities:Payable:Alice", group: "receivable", valuation: 0, closing: -200_000),
            row("Liabilities:CreditCard", group: "credit", valuation: 0, closing: 30_000),
            row("Expenses:Food", group: "expense", valuation: 0, closing: 9_999),
        ])
        XCTAssertEqual(totals, BalanceSheetTotals(assets: 1_020_000, liabilities: 170_000, netWorth: 850_000))
    }

    func testAssetsCompositionGroupsByAccountTypeFirst() {
        XCTAssertEqual(TerminalAssetsIndex.compositionGroup(account: "Liabilities:Payable:Alice", metadataGroup: "receivable"), "liability")
        XCTAssertEqual(TerminalAssetsIndex.compositionGroup(account: "Liabilities:CreditCard", metadataGroup: "credit"), "liability")
        XCTAssertEqual(TerminalAssetsIndex.compositionGroup(account: "Assets:Misc", metadataGroup: "other"), "asset")
        XCTAssertEqual(TerminalAssetsIndex.compositionGroup(account: "Assets:Misc", metadataGroup: nil), "asset")
        XCTAssertEqual(TerminalAssetsIndex.compositionGroup(account: "Assets:Broker", metadataGroup: "wealth"), "wealth")
        XCTAssertEqual(TerminalAssetsIndex.compositionGroup(account: "Assets:Receivable:Bob", metadataGroup: "receivable"), "receivable")
    }

    func testNetWorthTrendCutsAtThePagePeriodAndFallsBackToRangeHistory() throws {
        let trend = """
        [
          { "date": "2025-01-31", "assets": 10, "liabilities": 0, "netWorth": 10 },
          { "date": "2026-06-30", "assets": 15, "liabilities": 0, "netWorth": 15 },
          { "date": "2026-08-31", "assets": 20, "liabilities": 0, "netWorth": 20 }
        ]
        """
        let full = try JSONDecoder().decode(
            LedgerBootstrap.self,
            from: Data(Self.trendBootstrapJSON(netWorthTrend: trend).utf8)
        )
        XCTAssertEqual(full.netWorthTrend.map(\.date), ["2025-01-31", "2026-06-30", "2026-08-31"])

        // The curve ends on the closing figure the page shows for its period.
        XCTAssertEqual(full.netWorthTrendHistory(before: "2026-09-01").map(\.date), full.netWorthTrend.map(\.date))
        XCTAssertEqual(full.netWorthTrendHistory(before: "2026-07-01").map(\.date), ["2025-01-31", "2026-06-30"])
        // A period before the series cannot leave a drawable window, so the
        // whole series stays rather than blanking the chart.
        XCTAssertEqual(full.netWorthTrendHistory(before: "2025-02-01").map(\.date), full.netWorthTrend.map(\.date))

        let legacy = try JSONDecoder().decode(
            LedgerBootstrap.self,
            from: Data(Self.trendBootstrapJSON(netWorthTrend: nil).utf8)
        )
        XCTAssertTrue(legacy.netWorthTrend.isEmpty)
        XCTAssertEqual(legacy.netWorthTrendHistory(before: "2026-09-01").map(\.date), ["2026-08-01"])
    }

    func testBootstrapDecodesMonthlyExpenseTrendAndToleratesOlderServers() throws {
        let full = try JSONDecoder().decode(LedgerBootstrap.self, from: Data(Self.trendBootstrapJSON(
            netWorthTrend: nil,
            monthlyExpenseTrend: #"[{ "month": "2026-07", "expense": 120 }, { "month": "2026-08", "expense": 0 }]"#
        ).utf8))
        XCTAssertEqual(full.monthlyExpenseTrend, [
            LedgerMonthlyExpensePoint(month: "2026-07", expense: 120),
            LedgerMonthlyExpensePoint(month: "2026-08", expense: 0),
        ])
        let legacy = try JSONDecoder().decode(LedgerBootstrap.self, from: Data(Self.trendBootstrapJSON(netWorthTrend: nil).utf8))
        XCTAssertTrue(legacy.monthlyExpenseTrend.isEmpty)
    }

    private static func expensePoints(_ values: [(String, Int)]) -> [LedgerMonthlyExpensePoint] {
        values.map { LedgerMonthlyExpensePoint(month: $0.0, expense: $0.1) }
    }

    private static let sixMonths = expensePoints([
        ("2026-06", 8_000), ("2026-07", 9_000), ("2026-08", 10_000),
        ("2026-09", 11_000), ("2026-10", 12_000), ("2026-11", 3_000),
    ])

    func testExpenseTrendProjectsTheMonthInProgressAndAveragesOnlyEndedMonths() throws {
        let today = try XCTUnwrap(LedgerDateRange.parse("2026-11-10"))
        let trend = try XCTUnwrap(OverviewExpenseTrend(points: Self.sixMonths, months: 6, today: today))
        XCTAssertEqual(trend.bars.map(\.id), [202606, 202607, 202608, 202609, 202610, 202611])
        XCTAssertEqual(trend.progress, OverviewExpenseTrend.Progress(day: 10, days: 30))
        // November's 3,000 over ten days runs to 9,000 for the month.
        XCTAssertEqual(trend.bars.last?.projected, 9_000)
        XCTAssertEqual(trend.bars.dropLast().compactMap(\.projected), [])
        // The half-spent month would drag the mean down; only June–October count.
        XCTAssertEqual(trend.average, 10_000)
        XCTAssertEqual(trend.scaleMaximum, 12_000)
        XCTAssertEqual(try XCTUnwrap(trend.change(of: trend.bars[4])), 0.2, accuracy: 1e-9)
        // The month in progress compares its estimate, not its partial total.
        XCTAssertEqual(try XCTUnwrap(trend.change(of: trend.bars[5])), -0.1, accuracy: 1e-9)
    }

    func testExpenseTrendSkipsTheEstimateUntilTheMonthHasRunAFewDays() throws {
        let early = try XCTUnwrap(LedgerDateRange.parse("2026-11-04"))
        let trend = try XCTUnwrap(OverviewExpenseTrend(points: Self.sixMonths, months: 6, today: early))
        XCTAssertEqual(trend.progress?.day, 4)
        XCTAssertNil(trend.bars.last?.projected)
        XCTAssertNil(trend.change(of: trend.bars[5]))
        XCTAssertEqual(trend.average, 10_000)

        // On the last day the spend so far is the month; nothing is extrapolated.
        let lastDay = try XCTUnwrap(LedgerDateRange.parse("2026-11-30"))
        XCTAssertNil(OverviewExpenseTrend(points: Self.sixMonths, months: 6, today: lastDay)?.bars.last?.projected)
    }

    func testExpenseTrendForAnEndedPeriodAveragesEveryBar() throws {
        let later = try XCTUnwrap(LedgerDateRange.parse("2027-01-15"))
        let trend = try XCTUnwrap(OverviewExpenseTrend(points: Self.sixMonths, months: 6, today: later))
        XCTAssertNil(trend.progress)
        XCTAssertNil(trend.bars.last?.projected)
        XCTAssertEqual(trend.average, 8_833)
        XCTAssertEqual(try XCTUnwrap(trend.change(of: trend.bars[5])), Double(3_000 - 8_833) / 8_833, accuracy: 1e-9)
    }

    func testExpenseTrendWindowTakesTheLatestMonthsAndNeedsTwo() throws {
        let today = try XCTUnwrap(LedgerDateRange.parse("2026-11-10"))
        let year = Self.expensePoints((1...12).map { (String(format: "2025-%02d", $0), $0 * 100) })
        XCTAssertEqual(OverviewExpenseTrend(points: year, months: 6, today: today)?.bars.map(\.month), [7, 8, 9, 10, 11, 12])
        XCTAssertEqual(OverviewExpenseTrend(points: year, months: 12, today: today)?.bars.count, 12)

        XCTAssertNil(OverviewExpenseTrend(points: [], months: 6, today: today))
        XCTAssertNil(OverviewExpenseTrend(points: Self.expensePoints([("2026-11", 500)]), months: 6, today: today))
        // One ended month is enough for an average; a zero average compares nothing.
        let two = try XCTUnwrap(OverviewExpenseTrend(points: Self.expensePoints([("2026-10", 900), ("2026-11", 500)]), months: 6, today: today))
        XCTAssertEqual(two.average, 900)
        let fresh = try XCTUnwrap(OverviewExpenseTrend(points: Self.expensePoints([("2026-10", 0), ("2026-11", 500)]), months: 6, today: today))
        XCTAssertNil(fresh.change(of: fresh.bars[1]))
    }

    func testNetWorthTrendWindowsAnchorOnTheLastPoint() throws {
        // Monthly points from 2025-01 through the series' own last point in
        // 2026-08, so every window is measured from that point, not from today.
        var points = (0..<20).map { offset -> LedgerNetWorthPoint in
            let year = 2025 + offset / 12
            let month = offset % 12 + 1
            return LedgerNetWorthPoint(
                date: String(format: "%04d-%02d-01", year, month),
                assets: offset, liabilities: 0, netWorth: offset
            )
        }
        let last = try XCTUnwrap(points.popLast())

        XCTAssertEqual(NetWorthTrendRange.all.filter(points + [last]), points + [last])
        XCTAssertEqual(NetWorthTrendRange.oneMonth.filter(points + [last]).map(\.date), ["2026-07-01", last.date])
        XCTAssertEqual(NetWorthTrendRange.threeMonths.filter(points + [last]).count, 4)
        XCTAssertEqual(NetWorthTrendRange.sixMonths.filter(points + [last]).count, 7)
        XCTAssertEqual(NetWorthTrendRange.oneYear.filter(points + [last]).count, 13)
        XCTAssertEqual(NetWorthTrendRange.yearToDate.filter(points + [last]).count, 8)
        for window in NetWorthTrendRange.allCases where window != .all {
            XCTAssertEqual(window.filter(points + [last]).last, last, "\(window.title) must end on the closing point")
        }

        // Two points is the floor: a one-point window cannot draw a line.
        let tail = Array((points + [last]).suffix(2))
        XCTAssertEqual(NetWorthTrendRange.oneMonth.filter(tail), tail)
        XCTAssertEqual(NetWorthTrendRange.all.filter([last]), [last])
        XCTAssertEqual(NetWorthTrendRange.oneMonth.filter([]), [])
    }

    func testNetWorthTrendThinsWideWindowsToRealPoints() throws {
        // Two years of daily closings: enough that every window must thin, and
        // enough that no window has to repeat a point.
        let calendar = LedgerDateRange.calendar
        let start = try XCTUnwrap(LedgerDateRange.parse("2024-09-01"))
        let series = (0..<731).compactMap { offset -> LedgerNetWorthPoint? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return LedgerNetWorthPoint(date: LedgerDateRange.format(day),
                assets: offset, liabilities: 0, netWorth: offset)
        }
        let known = Set(series.map(\.date))

        for window in NetWorthTrendRange.allCases {
            let drawn = window.series(series)
            XCTAssertGreaterThan(drawn.count, 2, "\(window.title) must draw a line")
            XCTAssertLessThanOrEqual(drawn.count, window.pointBudget, "\(window.title) exceeded its budget")
            XCTAssertEqual(drawn.last, series.last, "\(window.title) must end on the same closing point")
            XCTAssertEqual(drawn.map(\.date), drawn.map(\.date).sorted(), "\(window.title) must stay in date order")
            XCTAssertEqual(Set(drawn.map(\.date)).count, drawn.count, "\(window.title) repeated a date")
            XCTAssertTrue(drawn.allSatisfy { known.contains($0.date) }, "\(window.title) invented a point")
        }

        // The one-month window still shows every day it is given.
        let month = NetWorthTrendRange.oneMonth.series(series)
        XCTAssertEqual(month.count, series.suffix(32).count)
        XCTAssertEqual(month.map(\.netWorth), Array(series.suffix(32).map(\.netWorth)))
    }

    func testSampledNetWorthKeepsBothEndsAndNeverAverages() throws {
        let series = (0..<100).map { index in
            LedgerNetWorthPoint(date: String(format: "2026-01-%02d", index % 28 + 1),
                assets: index, liabilities: 0, netWorth: index)
        }
        let sampled = LedgerNetWorthPoint.sampled(series, maxPoints: 10)
        XCTAssertEqual(sampled.count, 10)
        XCTAssertEqual(sampled.first, series.first)
        XCTAssertEqual(sampled.last, series.last)
        XCTAssertTrue(sampled.allSatisfy { series.contains($0) })
        XCTAssertEqual(LedgerNetWorthPoint.sampled(series, maxPoints: 200), series)
        XCTAssertEqual(LedgerNetWorthPoint.sampled(series, maxPoints: 2), [series[0], series[99]])
    }

    func testAccountBalanceTrendSortsDatesAndKeepsDailyClosingBalance() throws {
        let decoded = try JSONDecoder().decode(
            LedgerAccountDetail.self,
            from: Data(Self.accountDetailJSON.utf8)
        )
        let transaction = try XCTUnwrap(decoded.rows.first?.transaction)
        let detail = LedgerAccountDetail(
            account: decoded.account,
            label: decoded.label,
            alias: decoded.alias,
            group: decoded.group,
            active: decoded.active,
            currency: decoded.currency,
            currentBalance: 140_000,
            rows: [
                LedgerAccountDetailRow(
                    date: "2026-08-20",
                    payee: "第一次变动",
                    narration: "",
                    change: 20_000,
                    balance: 120_000,
                    transaction: transaction
                ),
                LedgerAccountDetailRow(
                    date: "2026-08-01",
                    payee: "期初变动",
                    narration: "",
                    change: 10_000,
                    balance: 100_000,
                    transaction: transaction
                ),
                LedgerAccountDetailRow(
                    date: "2026-08-20",
                    payee: "当日收盘",
                    narration: "",
                    change: 20_000,
                    balance: 140_000,
                    transaction: transaction
                ),
            ]
        )

        XCTAssertEqual(
            detail.balanceTrend,
            [
                LedgerAccountBalanceTrendPoint(date: "2026-08-01", balance: 100_000),
                LedgerAccountBalanceTrendPoint(date: "2026-08-20", balance: 140_000),
            ]
        )
    }

    func testAccountBalanceTrendDownsamplesLongHistoryAndKeepsExtrema() throws {
        let decoded = try JSONDecoder().decode(
            LedgerAccountDetail.self,
            from: Data(Self.accountDetailJSON.utf8)
        )
        let transaction = try XCTUnwrap(decoded.rows.first?.transaction)
        let balances = [100, 120, 40, 130, 90, 110, 180, 105, 140, 160]
        let detail = LedgerAccountDetail(
            account: decoded.account,
            label: decoded.label,
            alias: decoded.alias,
            group: decoded.group,
            active: decoded.active,
            currency: decoded.currency,
            currentBalance: 160,
            rows: balances.enumerated().map { index, balance in
                LedgerAccountDetailRow(
                    date: String(format: "2026-01-%02d", index + 1),
                    payee: "趋势测试",
                    narration: "",
                    change: 0,
                    balance: balance,
                    transaction: transaction
                )
            }
        )

        let sampled = detail.balanceTrend(maxPoints: 6)
        XCTAssertLessThanOrEqual(sampled.count, 6)
        XCTAssertEqual(sampled.first?.balance, 100)
        XCTAssertEqual(sampled.last?.balance, 160)
        XCTAssertTrue(sampled.contains { $0.balance == 40 })
        XCTAssertTrue(sampled.contains { $0.balance == 180 })
    }

    func testAccountBalanceTrendIncludesSelectedRangeBoundaries() throws {
        let decoded = try JSONDecoder().decode(
            LedgerAccountDetail.self,
            from: Data(Self.accountDetailJSON.utf8)
        )
        let range = LedgerDateRange(start: "2026-08-01", end: "2026-08-31", preset: .month)

        XCTAssertEqual(
            decoded.balanceTrend(in: range, maxPoints: 180),
            [
                LedgerAccountBalanceTrendPoint(date: "2026-08-01", balance: 1_243_500),
                LedgerAccountBalanceTrendPoint(date: "2026-08-20", balance: 1_235_000),
                LedgerAccountBalanceTrendPoint(date: "2026-08-31", balance: 1_235_000),
            ]
        )
    }

    func testCurrencyAnalysisMatchesWebDirectInverseBridgeAndMissingRates() {
        let prices = [
            LedgerPrice(date: "2026-07-31", currency: "USD", amount: 720, quoteCurrency: "CNY"),
            LedgerPrice(date: "2026-08-29", currency: "USD", amount: 713, quoteCurrency: "CNY"),
            LedgerPrice(date: "2026-07-31", currency: "EUR", amount: 780, quoteCurrency: "CNY"),
            LedgerPrice(date: "2026-08-29", currency: "EUR", amount: 776, quoteCurrency: "CNY"),
            LedgerPrice(date: "2026-08-29", currency: "QQQ", amount: 41_825, quoteCurrency: "USD"),
        ]

        let direct = CurrencyAnalysis.latestRate(currency: "USD", targetCurrency: "CNY", prices: prices)
        XCTAssertEqual(direct?.source, .direct)
        XCTAssertEqual(direct?.rate ?? 0, 7.13, accuracy: 0.000_001)

        let inverse = CurrencyAnalysis.latestRate(currency: "CNY", targetCurrency: "USD", prices: prices)
        XCTAssertEqual(inverse?.source, .inverse)
        XCTAssertEqual(inverse?.rate ?? 0, 1 / 7.13, accuracy: 0.000_001)

        let bridge = CurrencyAnalysis.latestRate(currency: "EUR", targetCurrency: "USD", prices: prices)
        XCTAssertEqual(bridge?.source, .bridge)
        XCTAssertEqual(bridge?.rate ?? 0, 7.76 / 7.13, accuracy: 0.000_001)
        XCTAssertNil(CurrencyAnalysis.latestRate(currency: "GBP", targetCurrency: "USD", prices: prices))

        let history = CurrencyAnalysis.rateHistory(currency: "EUR", targetCurrency: "USD", prices: prices)
        XCTAssertEqual(history.map(\.date), ["2026-07-31", "2026-08-29"])
        XCTAssertEqual(history.last?.rate ?? 0, 7.76 / 7.13, accuracy: 0.000_001)

        let universe = CurrencyAnalysis.currencyUniverse(
            commodities: ["CNY", "USD", "EUR", "GBP", "QQQ"],
            prices: prices,
            balances: [],
            accounts: [],
            valuationCurrency: "USD"
        )
        XCTAssertEqual(universe.first, "USD")
        XCTAssertTrue(universe.contains("GBP"))
        XCTAssertFalse(universe.contains("QQQ"))
    }

    func testCurrencyRatesUseExactPriceDecimalAndSkipZeroDirectPrices() throws {
        let json = Data("""
        [{"date":"2026-08-29","currency":"JPY","amount":5,"amountValue":"0.0478","quoteCurrency":"CNY"},
         {"date":"2026-08-29","currency":"IDR","amount":0,"amountValue":"0.00045","quoteCurrency":"CNY"},
         {"date":"2026-08-29","currency":"KRW","amount":0,"quoteCurrency":"CNY"},
         {"date":"2026-08-29","currency":"CNY","amount":19,"quoteCurrency":"KRW"},
         {"date":"2026-08-29","currency":"USD","amount":713,"quoteCurrency":"CNY"}]
        """.utf8)
        let prices = try JSONDecoder().decode([LedgerPrice].self, from: json)
        XCTAssertEqual(prices[0].amountValue, "0.0478")
        XCTAssertNil(prices[4].amountValue) // older servers send cents only
        XCTAssertEqual(prices[4], LedgerPrice(date: "2026-08-29", currency: "USD", amount: 713, quoteCurrency: "CNY"))

        let jpy = CurrencyAnalysis.latestRate(currency: "JPY", targetCurrency: "CNY", prices: prices)
        XCTAssertEqual(jpy?.source, .direct)
        XCTAssertEqual(jpy?.rate ?? 0, 0.0478, accuracy: 1e-12)
        XCTAssertEqual(CurrencyAnalysis.latestRate(currency: "IDR", targetCurrency: "CNY", prices: prices)?.rate ?? 0,
                       0.000_45, accuracy: 1e-12)
        XCTAssertEqual(CurrencyAnalysis.latestRate(currency: "USD", targetCurrency: "CNY", prices: prices)?.rate ?? 0,
                       7.13, accuracy: 1e-12)
        // A zero direct price is missing, not "1 KRW = 0 CNY": the inverse pair answers.
        let krw = CurrencyAnalysis.latestRate(currency: "KRW", targetCurrency: "CNY", prices: prices)
        XCTAssertEqual(krw?.source, .inverse)
        XCTAssertEqual(krw?.rate ?? 0, 1 / 0.19, accuracy: 1e-9)
        let history = CurrencyAnalysis.rateHistory(currency: "JPY", targetCurrency: "CNY", prices: prices)
        XCTAssertEqual(history.last?.rate ?? 0, 0.0478, accuracy: 1e-12)
    }

    /// Mirrors TestLocalOverviewCategoriesValueForeignPostings and the server's
    /// PriceIndex.Valuation, which values the overview 支出 row.
    func testPriceValuationMatchesServerIntegerValuation() {
        let valuation = LedgerPriceValuation(prices: [
            LedgerPrice(date: "2026-07-01", currency: "JPY", amount: 4, quoteCurrency: "CNY"),
            LedgerPrice(date: "2026-08-01", currency: "JPY", amount: 5, quoteCurrency: "CNY", amountValue: "0.0478"),
            LedgerPrice(date: "2026-08-01", currency: "USD", amount: 700, quoteCurrency: "CNY"),
        ])
        XCTAssertEqual(valuation.value(10_000, currency: "JPY", in: "CNY"), 500) // latest cents, not the decimal
        XCTAssertEqual(valuation.value(1_000, currency: "CNY", in: "USD"), 142) // inverse, truncated
        XCTAssertEqual(valuation.value(10_000, currency: "JPY", in: "USD"), 71) // bridged through CNY
        XCTAssertEqual(valuation.value(-1_000, currency: "usd ", in: "CNY"), -7_000)
        XCTAssertEqual(valuation.value(1_000, currency: nil, in: "CNY"), 1_000) // missing currency is CNY
        XCTAssertNil(valuation.value(1_000, currency: "GBP", in: "CNY"))
    }

    func testOverviewCategoriesCarryTheirValuationCurrency() throws {
        let base = #""revision":"r","start":"2026-09-01","end":"2026-10-01","sensitiveUnlocked":true,"positiveTotalMinorUnits":0,"transactionCount":0,"highestExpense":null,"categories":[]"#
        let valued = try JSONDecoder().decode(LedgerOverviewCategories.self, from: Data("{\(base),\"currency\":\"USD\"}".utf8))
        XCTAssertEqual(valued.currency, "USD")
        let restored = try JSONDecoder().decode(LedgerOverviewCategories.self, from: JSONEncoder().encode(valued))
        XCTAssertEqual(restored.currency, "USD")
        XCTAssertNil(try JSONDecoder().decode(LedgerOverviewCategories.self, from: Data("{\(base)}".utf8)).currency)
        XCTAssertEqual(LocalLedgerRepository.overviewQuery(start: "2026-09-01", end: "2026-10-01", valuationCurrency: "USD"),
                       ["start": "2026-09-01", "end": "2026-10-01", "valuationCurrency": "USD"])
        XCTAssertEqual(LocalLedgerRepository.overviewQuery(start: "2026-09-01", end: "2026-10-01", valuationCurrency: nil),
                       ["start": "2026-09-01", "end": "2026-10-01"])
    }

    func testCurrencyHistorySamplesLedgerPriceDatesAndBoundsSeriesToNinetyPoints() {
        var prices = (1...200).map { index in
            LedgerPrice(
                date: String(format: "2026-%03d", index),
                currency: "QQQ",
                amount: 40_000 + index,
                quoteCurrency: "USD"
            )
        }
        prices.append(contentsOf: [
            LedgerPrice(date: "2025-07-31", currency: "USD", amount: 720, quoteCurrency: "CNY"),
            LedgerPrice(date: "2025-07-31", currency: "EUR", amount: 780, quoteCurrency: "CNY"),
            LedgerPrice(date: "2025-08-31", currency: "USD", amount: 713, quoteCurrency: "CNY"),
            LedgerPrice(date: "2025-08-31", currency: "EUR", amount: 776, quoteCurrency: "CNY"),
        ])

        let bridgeHistory = CurrencyAnalysis.rateHistory(
            currency: "EUR",
            targetCurrency: "USD",
            prices: prices
        )
        XCTAssertEqual(bridgeHistory.count, 90)
        XCTAssertEqual(bridgeHistory.first?.date, "2026-111")
        XCTAssertEqual(bridgeHistory.last?.date, "2026-200")
        XCTAssertEqual(bridgeHistory.first?.rate ?? 0, 7.76 / 7.13, accuracy: 0.000_001)
        XCTAssertEqual(bridgeHistory.last?.rate ?? 0, 7.76 / 7.13, accuracy: 0.000_001)

        let baseHistory = CurrencyAnalysis.rateHistory(
            currency: "USD",
            targetCurrency: "USD",
            prices: prices
        )
        XCTAssertEqual(baseHistory.count, 90)
        XCTAssertEqual(baseHistory.last?.date, "2026-200")
    }

    func testTransactionIdentityIncludesSourceLocationForDuplicateHashes() throws {
        let payload = try JSONDecoder().decode(LedgerBootstrap.self, from: Data(Self.bootstrapJSON.utf8))
        let transaction = try XCTUnwrap(payload.transactions.first)
        let duplicateAtAnotherLine = LedgerTransaction(
            date: transaction.date,
            payee: transaction.payee,
            narration: transaction.narration,
            tags: transaction.tags,
            postings: transaction.postings,
            source: TransactionSource(
                file: transaction.source.file,
                line: transaction.source.line + 10,
                hash: transaction.source.hash,
                gitSHA: transaction.source.gitSHA
            )
        )

        XCTAssertNotEqual(transaction.id, duplicateAtAnotherLine.id)
    }

    func testHealthCompatibilityRequiresExpectedVersionAndCapabilities() throws {
        XCTAssertNoThrow(
            try HealthStatus(apiVersion: 1, capabilities: ["cookie-auth", "full-backend"]).validateForMobileClient()
        )
        XCTAssertThrowsError(
            try HealthStatus(apiVersion: 2, capabilities: ["cookie-auth", "full-backend"]).validateForMobileClient()
        )
        XCTAssertThrowsError(
            try HealthStatus(apiVersion: 1, capabilities: ["cookie-auth"]).validateForMobileClient()
        )
        XCTAssertTrue(
            HealthStatus(
                apiVersion: 1,
                capabilities: ["cookie-auth", "full-backend", HealthStatus.accountPeriodBalancesCapability]
            ).supportsAccountPeriodBalances
        )
        XCTAssertFalse(
            HealthStatus(apiVersion: 1, capabilities: ["cookie-auth", "full-backend"])
                .supportsAccountPeriodBalances
        )
    }

    func testTransactionPresentationClassifiesExpenseAndIncome() throws {
        let payload = try JSONDecoder().decode(LedgerBootstrap.self, from: Data(Self.bootstrapJSON.utf8))
        let expense = TransactionPresentation(transaction: payload.transactions[0])
        let income = TransactionPresentation(transaction: payload.transactions[1])

        XCTAssertEqual(expense.kind, .expense)
        XCTAssertEqual(expense.minorUnits, 8_500)
        XCTAssertEqual(expense.title, "海底捞")
        XCTAssertEqual(income.kind, .income)
        XCTAssertEqual(income.minorUnits, 400_000)
    }

    func testTransactionPresentationClassifiesRefundsAndClawbacks() {
        let refundTxn = LedgerTransaction(
            date: "2026-09-02",
            payee: "淘宝",
            narration: "退款 - 衣服",
            postings: [
                LedgerPosting(account: "Assets:Alipay", amount: 10000, currency: "CNY"),
                LedgerPosting(account: "Expenses:Clothing", amount: -10000, currency: "CNY"),
            ],
            source: TransactionSource(file: "test.bean", line: 1, hash: nil, gitSHA: nil)
        )
        let refundPres = TransactionPresentation(transaction: refundTxn)
        XCTAssertEqual(refundPres.kind, .income)
        XCTAssertTrue(refundPres.isRefund)
        XCTAssertEqual(refundPres.minorUnits, 10000)

        let clawbackTxn = LedgerTransaction(
            date: "2026-09-03",
            payee: "公司",
            narration: "扣回公积金",
            postings: [
                LedgerPosting(account: "Assets:Bank", amount: -2000, currency: "CNY"),
                LedgerPosting(account: "Income:Salary", amount: 2000, currency: "CNY"),
            ],
            source: TransactionSource(file: "test.bean", line: 2, hash: nil, gitSHA: nil)
        )
        let clawbackPres = TransactionPresentation(transaction: clawbackTxn)
        XCTAssertEqual(clawbackPres.kind, .expense)
        XCTAssertFalse(clawbackPres.isRefund)
        XCTAssertEqual(clawbackPres.minorUnits, 2000)
    }

    #if os(iOS)
    func testMoneyFlowPreservesPostingCurrenciesSignsAndAccountSides() {
        let transaction = LedgerTransaction(date: "2026-09-01", payee: "Exchange", narration: "",
            postings: [LedgerPosting(account: "Assets:USD", amount: -10000, currency: "USD"),
                       LedgerPosting(account: "Assets:CNY", amount: 70000, currency: "CNY"),
                       LedgerPosting(account: "Expenses:Fee", amount: 0, currency: "CNY")],
            source: TransactionSource(file: "test.bean", line: 1, hash: nil, gitSHA: nil))
        let flow = TransactionMoneyFlow.build(transaction: transaction,
            accountLabels: ["Assets:USD": "Assets:USD", "Assets:CNY": "人民币账户"], defaultCurrency: "CNY")
        XCTAssertEqual(flow.fromLegs.map(\.account), ["Assets:USD"])
        XCTAssertEqual(flow.fromLegs.map(\.currency), ["USD"])
        XCTAssertEqual(flow.fromLegs.map(\.amount), [-10000])
        XCTAssertEqual(flow.fromLegs.map(\.label), ["USD"])
        XCTAssertEqual(flow.toLegs.map(\.currency), ["CNY"])
        XCTAssertEqual(flow.toLegs.map(\.amount), [70000])
        XCTAssertEqual(flow.toLegs.map(\.label), ["人民币账户"])
    }
    #endif

    func testTransactionCategoryUsesLabelsForExpenseIncomeAndRefund() {
        XCTAssertEqual(categoryLabel([("Expenses:Food:Dining", 8500)], labels: ["Expenses:Food:Dining": "餐饮"]), "餐饮")
        XCTAssertEqual(categoryLabel([("Expenses:Food:Dining", -8500)], labels: ["Expenses:Food:Dining": "餐饮"]), "餐饮")
        XCTAssertEqual(categoryLabel([("Income:Salary", -400000)], labels: ["Income:Salary": "工资"]), "工资")
        XCTAssertEqual(categoryLabel([("Expenses:Food:Dining", 8500)]), "Food › Dining")
    }

    func testTransactionCategoryDeduplicatesAccountsAndIgnoresZeroPostings() {
        XCTAssertEqual(categoryLabel([
            ("Expenses:Food", 100), ("Expenses:Food", 200), ("Expenses:Books", 0),
        ], labels: ["Expenses:Food": "餐饮"]), "餐饮")
        XCTAssertEqual(categoryLabel([("Expenses:Food", 100), ("Expenses:Books", 200)]), "多分类")
        XCTAssertEqual(categoryLabel([("Income:Salary", -500), ("Expenses:Tax", 100)]), "多分类")
    }

    func testTransactionCategoryShowsTransferDirectionAndAdjustmentFallback() {
        let labels = ["Assets:Bank": "银行卡", "Liabilities:Card": "信用卡"]
        XCTAssertEqual(categoryLabel([("Liabilities:Card", 500), ("Assets:Bank", -500)], labels: labels), "银行卡 → 信用卡")
        XCTAssertEqual(categoryLabel([("Assets:Bank", -500), ("Assets:Cash", -200), ("Liabilities:Card", 700)], labels: labels), "多个账户 → 信用卡")
        XCTAssertEqual(categoryLabel([("Assets:Bank", 500), ("Equity:Opening", -500)]), "权益调整")
        XCTAssertEqual(categoryLabel([]), "未分类")
    }

    func testTransactionCategoryAccountLabelsFallBackToAliasAndHandleDuplicates() {
        let account = LedgerAccount(account: "Expenses:Books", openDate: "2026-01-01", closeDate: nil, currency: "CNY", alias: "图书", label: "Expenses:Books", group: "expense", active: true)
        let labels = TransactionCategoryPresentation.accountLabels([account, account])
        XCTAssertEqual(labels[account.account], "图书")
    }

    private func categoryLabel(_ postings: [(String, Int)], labels: [String: String] = [:]) -> String {
        let transaction = LedgerTransaction(
            date: "2026-09-07", payee: "分类测试", narration: "",
            postings: postings.map { LedgerPosting(account: $0.0, amount: $0.1, currency: "CNY") },
            source: TransactionSource(file: "example.bean", line: 1, hash: nil, gitSHA: nil)
        )
        return TransactionCategoryPresentation(transaction: transaction, accountLabels: labels).label
    }

    func testTransactionFilterMatchesWordsKindAccountAndTags() throws {
        let payload = try JSONDecoder().decode(LedgerBootstrap.self, from: Data(Self.bootstrapJSON.utf8))
        let expense = payload.transactions[0]
        let income = payload.transactions[1]

        XCTAssertTrue(LedgerTransactionFilter(query: "海底 晚餐").matches(expense))
        XCTAssertTrue(LedgerTransactionFilter(query: "#dining").matches(expense))
        XCTAssertFalse(LedgerTransactionFilter(query: "不存在").matches(expense))
        XCTAssertTrue(LedgerTransactionFilter(kind: .expense).matches(expense))
        XCTAssertFalse(LedgerTransactionFilter(kind: .income).matches(expense))
        XCTAssertTrue(LedgerTransactionFilter(account: "Assets:Bank:Daily").matches(income))
        XCTAssertFalse(LedgerTransactionFilter(account: "Liabilities:CreditCard:Visa").matches(income))
        XCTAssertTrue(LedgerTransactionFilter(tags: ["travel", "dining"]).matches(expense))
        XCTAssertFalse(LedgerTransactionFilter(tags: ["travel"]).matches(expense))
        XCTAssertFalse(LedgerTransactionFilter(tags: ["dining"]).matches(income))
        XCTAssertTrue(LedgerTransactionFilter(tags: ["dining"]).isActive)
        XCTAssertFalse(
            LedgerTransactionFilter(
                query: "海底",
                kind: .expense,
                account: "Assets:Bank:Daily",
                tags: ["travel"]
            ).matches(expense)
        )
        XCTAssertTrue(
            LedgerTransactionFilter(
                query: "晚餐",
                kind: .expense,
                account: "Expenses:Food:Dining",
                tags: ["dining"]
            ).matches(expense)
        )
    }

    func testPreparedTagBatchRequiresUnchangedSelectionAndActiveSelectionMode() {
        XCTAssertTrue(TransactionTagSelectionRules.canPresentPreparedBatch(
            captured: ["a", "b"], current: ["b", "a"], isSelecting: true))
        XCTAssertFalse(TransactionTagSelectionRules.canPresentPreparedBatch(
            captured: ["a", "b"], current: ["a", "c"], isSelecting: true))
        XCTAssertFalse(TransactionTagSelectionRules.canPresentPreparedBatch(
            captured: ["a", "b"], current: ["a"], isSelecting: true))
        XCTAssertFalse(TransactionTagSelectionRules.canPresentPreparedBatch(
            captured: ["a", "b"], current: ["a", "b"], isSelecting: false))
        XCTAssertFalse(TransactionTagSelectionRules.canPresentPreparedBatch(
            captured: [], current: [], isSelecting: true))
    }

    func testBulkTagSelectionKeepsExistingSelectionsWithinTwoHundredLimit() {
        let current = Set((0..<150).map { "existing-\($0)" })
        let candidates = (0..<200).map { "candidate-\($0)" }

        let updated = TransactionTagSelectionRules.adding(candidates, to: current)

        XCTAssertEqual(updated.count, 200)
        XCTAssertTrue(current.isSubset(of: updated))
        XCTAssertEqual(candidates.filter(updated.contains).count, 50)
    }

    func testMoneyWithoutRepeatedSymbolPreservesCurrencyPrecisionAndSigns() {
        XCTAssertEqual(MoneyText.format(minorUnits: 123456, currency: "CNY", showsCurrency: false), "1,234.56")
        XCTAssertEqual(MoneyText.format(minorUnits: -123456, currency: "USD", showsCurrency: false), "-1,234.56")
        XCTAssertEqual(MoneyText.format(minorUnits: 123456, currency: "JPY", showsCurrency: false), "1,235")
        XCTAssertEqual(MoneyText.format(minorUnits: 0, currency: "CNY", showsCurrency: false), "0.00")
        XCTAssertEqual(MoneyText.format(minorUnits: 100, currency: "CNY", showSign: true, showsCurrency: false), "+1.00")
        XCTAssertEqual(MoneyText.format(minorUnits: 100, currency: "CNY"), "¥1.00")
    }

    func testCompactMoneyUsesChineseAndInternationalUnits() {
        XCTAssertEqual(MoneyText.formatCompact(minorUnits: 999_999, currency: "CNY"), "¥9,999.99")
        XCTAssertEqual(MoneyText.formatCompact(minorUnits: 1_234_567, currency: "CNY"), "¥1.2w")
        XCTAssertEqual(MoneyText.formatCompact(minorUnits: 12_345_678_900, currency: "CNY"), "¥1.2亿")
        XCTAssertEqual(MoneyText.formatCompact(minorUnits: 1_234_567, currency: "USD"), "$12.3k")
        XCTAssertEqual(MoneyText.formatCompact(minorUnits: -1_234_567, currency: "CNY"), "-¥1.2w")
        XCTAssertEqual(MoneyText.formatWidget(minorUnits: 555_180, currency: "CNY"), "¥5,552")
        XCTAssertEqual(MoneyText.formatWidget(minorUnits: 1_234_567, currency: "CNY"), "¥1.2w")
        XCTAssertEqual(MoneyText.magnitude(.min), .max)
    }

    func testMonthRangeShiftKeepsInclusiveCalendarBounds() {
        let august = LedgerDateRange.month(year: 2026, month: 8)
        let july = august.shifted(by: -1)
        let september = august.shifted(by: 1)

        XCTAssertEqual(august.start, "2026-08-01")
        XCTAssertEqual(august.end, "2026-08-31")
        XCTAssertEqual(july.start, "2026-07-01")
        XCTAssertEqual(july.end, "2026-07-31")
        XCTAssertEqual(september.start, "2026-09-01")
        XCTAssertEqual(september.end, "2026-09-30")
        XCTAssertEqual(august.queryEndExclusive, "2026-09-01")
        XCTAssertEqual(july.queryEndExclusive, "2026-08-01")
    }

    func testBQLDynamicCellsDecodeAllJSONShapesAndNullCollections() throws {
        let json = #"""
        {
          "columns":null,
          "rows":[[null,true,12.5,"text",["a",2],{"tag":"food"}]],
          "query":"SELECT * FROM transactions",
          "warnings":null,
          "valuationCurrency":"CNY",
          "limit":100,
          "rowCount":1
        }
        """#
        let result = try JSONDecoder().decode(BQLResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.columns, [])
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(
            result.rows[0],
            [.null, .bool(true), .number(12.5), .string("text"), .array([.string("a"), .number(2)]), .object(["tag": .string("food")])]
        )
    }

    func testBQLStatementSplitterKeepsQuotedSemicolonsAndEscapes() {
        let raw = "SELECT payee FROM transactions WHERE narration = '午餐;咖啡'; SELECT account FROM postings WHERE account = \"Assets:\\\"Daily\";"

        XCTAssertEqual(
            BQLStatements.split(raw),
            [
                "SELECT payee FROM transactions WHERE narration = '午餐;咖啡'",
                "SELECT account FROM postings WHERE account = \"Assets:\\\"Daily\"",
            ]
        )
    }

    func testBQLHistoryMergePreservesChangesMadeWhileLoading() {
        let original = Self.bqlHistoryRecord(id: "existing", title: "旧标题", lastRunAt: "2026-08-01T00:00:00Z")
        let stale = Self.bqlHistoryRecord(id: "existing", title: "旧标题", lastRunAt: "2026-08-01T00:00:00Z")
        let renamed = Self.bqlHistoryRecord(id: "existing", title: "新标题", lastRunAt: "2026-08-01T00:00:00Z")
        let saved = Self.bqlHistoryRecord(id: "saved", title: "刚保存", lastRunAt: "2026-08-02T00:00:00Z")

        let merged = BQLHistoryMerge.reconcile(
            loaded: [
                stale,
                Self.bqlHistoryRecord(id: "existing", title: "重复旧标题", lastRunAt: "2026-08-01T00:00:00Z"),
                Self.bqlHistoryRecord(id: "deleted", title: "待删除", lastRunAt: "2026-07-31T00:00:00Z"),
            ],
            snapshot: [original, Self.bqlHistoryRecord(id: "deleted", title: "待删除", lastRunAt: "2026-07-31T00:00:00Z")],
            current: [renamed, saved]
        )

        XCTAssertEqual(Set(merged.map(\.id)), ["existing", "saved"])
        XCTAssertEqual(merged.first(where: { $0.id == "existing" })?.title, "新标题")
    }

    private static func bqlHistoryRecord(id: String, title: String, lastRunAt: String) -> BQLHistoryRecord {
        BQLHistoryRecord(
            id: id,
            query: "SELECT * FROM transactions",
            title: title,
            titleSource: "manual",
            createdAt: "2026-08-01T00:00:00Z",
            lastRunAt: lastRunAt,
            runCount: 1
        )
    }

    private static func trendBootstrapJSON(netWorthTrend: String?, monthlyExpenseTrend: String? = nil) -> String {
        let trend = (netWorthTrend.map { "\n      \"netWorthTrend\": \($0)," } ?? "")
            + (monthlyExpenseTrend.map { "\n      \"monthlyExpenseTrend\": \($0)," } ?? "")
        return """
        {
          "start": "2026-08-01",
          "end": "2026-08-31",
          "summary": { "currency": "CNY", "income": 0, "expense": 0, "net": 0 },\(trend)
          "accountBalances": [],
          "netWorthHistory": [
            { "date": "2026-08-01", "assets": 20, "liabilities": 0, "netWorth": 20 }
          ],
          "transactions": [],
          "accounts": [],
          "valuationCurrency": "CNY",
          "sensitiveUnlocked": true
        }
        """
    }

    static let bootstrapJSON = #"""
    {
      "start": "2026-08-01",
      "end": "2026-08-31",
      "summary": { "currency": "CNY", "income": 400000, "expense": 85000, "net": 315000 },
      "comparisons": {
        "income": {
          "monthOverMonth": {
            "currentRange": { "start": "2026-08-01", "end": "2026-08-31" },
            "baselineRange": { "start": "2026-07-01", "end": "2026-07-31" },
            "current": 400000, "baseline": 380000, "delta": 20000, "percentage": 0.0526315789
          },
          "yearOverYear": {
            "currentRange": { "start": "2026-08-01", "end": "2026-08-31" },
            "baselineRange": { "start": "2025-08-01", "end": "2025-08-31" },
            "current": 400000, "baseline": 266667, "delta": 133333, "percentage": 0.5
          }
        },
        "expense": {
          "monthOverMonth": {
            "currentRange": { "start": "2026-08-01", "end": "2026-08-31" },
            "baselineRange": { "start": "2026-07-01", "end": "2026-07-31" },
            "current": 85000, "baseline": 86000, "delta": -1000, "percentage": -0.011627907
          },
          "yearOverYear": {
            "currentRange": { "start": "2026-08-01", "end": "2026-08-31" },
            "baselineRange": { "start": "2025-08-01", "end": "2025-08-31" },
            "current": 85000, "baseline": 0, "delta": 85000, "percentage": null
          }
        },
        "totalAssets": null
      },
      "accountBalances": [
        { "account": "Assets:Bank:Daily", "currency": "CNY", "amount": 1235000, "valuationCurrency": "CNY", "valuation": 1235000, "openingAmount": 1243500, "closingAmount": 1235000, "periodChange": -8500, "openingValuation": 1243500, "closingValuation": 1235000, "periodValuationChange": -8500, "periodAvailable": true },
        { "account": "Liabilities:CreditCard:Visa", "currency": "CNY", "amount": -235000, "valuationCurrency": "CNY", "valuation": -235000, "openingAmount": -226500, "closingAmount": -235000, "periodChange": -8500, "openingValuation": -226500, "closingValuation": -235000, "periodValuationChange": -8500, "periodAvailable": true }
      ],
      "netWorthHistory": [
        { "date": "2026-08-01", "assets": 1220000, "liabilities": 235000, "netWorth": 985000 },
        { "date": "2026-08-31", "assets": 1235000, "liabilities": 235000, "netWorth": 1000000 }
      ],
      "netWorthTrend": [
        { "date": "2026-02-28", "assets": 1100000, "liabilities": 235000, "netWorth": 865000 },
        { "date": "2026-07-31", "assets": 1220000, "liabilities": 235000, "netWorth": 985000 },
        { "date": "2026-08-31", "assets": 1235000, "liabilities": 235000, "netWorth": 1000000 }
      ],
      "monthEndNetWorth": [
        { "date": "2026-08-31", "assets": 1235000, "liabilities": 235000, "netWorth": 1000000 }
      ],
      "netWorthWindows": {
        "latest": { "date": "2026-08-31", "assets": 1235000, "liabilities": 235000, "netWorth": 1000000 },
        "previousMonthEnd": { "date": "2026-07-31", "assets": 1220000, "liabilities": 235000, "netWorth": 985000 },
        "monthChange": 15000,
        "sixMonth": { "baseline": null, "change": null, "changeRatio": null },
        "twelveMonth": { "baseline": null, "change": null, "changeRatio": null }
      },
      "transactions": [
        {
          "date": "2026-08-20", "payee": "海底捞", "narration": "晚餐", "metadata": { "verified": true, "reviewedAt": null }, "tags": ["dining"],
          "postings": [
            { "account": "Expenses:Food:Dining", "amount": 8500, "currency": "CNY" },
            { "account": "Assets:Bank:Daily", "amount": -8500, "currency": "CNY" }
          ],
          "entry": {
            "kind": "transaction", "date": "2026-08-20", "flag": "!", "payee": "海底捞", "narration": "晚餐",
            "metadata": { "verified": true, "reviewedAt": null }, "tags": ["dining"], "links": ["receipt-2026"],
            "postings": [
              { "account": "Assets:Broker", "flag": "!", "amount": "1.23456789", "currency": "VT", "costKind": "total", "costAmount": "123.456789", "costCurrency": "USD", "costSpec": "{{ 123.456789 USD, 2026-05-01, \"lot-a\" }}", "priceKind": "unit", "priceAmount": "160.1234567", "priceCurrency": "USD" },
              { "account": "Assets:Bank:Daily", "amount": "-197.530862", "currency": "USD" }
            ],
            "currency": "VT", "confidence": 1, "needsReview": false, "questions": []
          },
          "source": { "file": "transactions/2026/08.bean", "line": 18, "hash": "expense-hash", "gitSha": "abc123" }
        },
        {
          "date": "2026-08-10", "payee": "Huya", "narration": "工资",
          "postings": [
            { "account": "Income:Salary", "amount": -400000, "currency": "CNY" },
            { "account": "Assets:Bank:Daily", "amount": 400000, "currency": "CNY" }
          ],
          "source": { "file": "transactions/2026/08.bean", "line": 4 }
        }
      ],
      "accounts": [
        { "account": "Assets:Bank:Daily", "openDate": "2024-01-01", "closeDate": null, "currency": "CNY", "alias": "日常账户/银行卡", "label": "日常账户", "group": "cash", "active": true },
        { "account": "Liabilities:CreditCard:Visa", "openDate": "2024-01-01", "closeDate": null, "currency": "CNY", "alias": "Visa", "label": "Visa", "group": "credit", "active": true }
      ],
      "commodities": ["CNY", "USD"],
      "prices": [
        { "date": "2026-08-20", "currency": "USD", "amount": 713, "quoteCurrency": "CNY" }
      ],
      "valuationCurrency": "CNY",
      "sensitiveUnlocked": true
    }
    """#

    static let accountDetailJSON = #"""
    {
      "account": "Assets:Bank:Daily",
      "label": "日常账户",
      "alias": "日常账户/银行卡",
      "group": "cash",
      "active": true,
      "currency": "CNY",
      "currentBalance": 1235000,
      "start": "2026-08-01",
      "end": "2026-09-01",
      "openingBalance": 1243500,
      "closingBalance": 1235000,
      "periodChange": -8500,
      "rows": [
        {
          "date": "2026-08-20",
          "payee": "海底捞",
          "narration": "晚餐",
          "change": -8500,
          "balance": 1235000,
          "txn": {
            "date": "2026-08-20",
            "payee": "海底捞",
            "narration": "晚餐",
            "postings": [
              { "account": "Expenses:Food:Dining", "amount": 8500, "currency": "CNY" },
              { "account": "Assets:Bank:Daily", "amount": -8500, "currency": "CNY" }
            ],
            "source": { "file": "transactions/2026/08.bean", "line": 18 }
          }
        }
      ]
    }
    """#

    func testPendingTransactionClassifierIdentifiesUncategorizedAndFlagged() {
        let uncategorizedTx = LedgerTransaction(
            date: "2026-09-17",
            payee: "某商户",
            narration: "购物",
            tags: ["待确认"],
            postings: [
                LedgerPosting(account: "Expenses:Unknown", amount: 5000, currency: "CNY"),
                LedgerPosting(account: "Assets:WeChat:Wallet", amount: -5000, currency: "CNY")
            ],
            editableEntry: LedgerTransactionEntry(
                date: "2026-09-17",
                flag: "!",
                payee: "某商户",
                narration: "购物",
                metadata: [:],
                tags: ["待确认"],
                postings: [
                    LedgerTransactionEntryPosting(account: "Expenses:Unknown", amount: "50.00", currency: "CNY"),
                    LedgerTransactionEntryPosting(account: "Assets:WeChat:Wallet", amount: "-50.00", currency: "CNY")
                ]
            ),
            source: TransactionSource(file: "2026.bean", line: 1)
        )

        let reasons = uncategorizedTx.pendingReasons
        XCTAssertTrue(uncategorizedTx.isPendingReview)
        XCTAssertTrue(reasons.contains { if case .uncategorized = $0 { return true }; return false })
        XCTAssertTrue(reasons.contains { if case .needsReviewFlag = $0 { return true }; return false })
        XCTAssertTrue(reasons.contains { if case .pendingTag = $0 { return true }; return false })

        // Test replacing account
        let updated = uncategorizedTx.entryReplacingAccount(from: "Expenses:Unknown", to: "Expenses:Food:Dinner")
        XCTAssertEqual(updated.postings.first?.account, "Expenses:Food:Dinner")

        // Test marking verified
        let verified = uncategorizedTx.entryMarkingVerified()
        XCTAssertNil(verified.flag)
        XCTAssertFalse(verified.tags.contains("待确认"))
    }

    func testPendingNativeEvidenceMatchesSourceEntryFlagWithoutDraft() {
        for flag in [false, true] {
            let tx = LedgerTransaction(date: "2026-09-24", payee: "Synthetic", narration: "Known",
                postings: [.init(account: "Expenses:Food", amount: 100, currency: "CNY")],
                pendingReviewFlag: flag, source: .init(file: "fixture.bean", line: 1))
            XCTAssertEqual(tx.pendingReasons, flag ? [.needsReviewFlag] : [])
            XCTAssertNil(tx.editableEntry)
        }
    }

    func testNarrationOnlyTransactionIsNeitherPendingNorUndecodable() throws {
        func tx(payee: String, narration: String) -> LedgerTransaction {
            LedgerTransaction(date: "2026-11-10", payee: payee, narration: narration,
                postings: [.init(account: "Expenses:Food", amount: 5050, currency: "CNY")],
                source: .init(file: "fixture.bean", line: 1))
        }
        XCTAssertEqual(tx(payee: "", narration: "餐饮").pendingReasons, [])
        XCTAssertEqual(tx(payee: "", narration: "").pendingReasons, [.missingPayee])
        XCTAssertEqual(tx(payee: "", narration: "支付宝").pendingReasons, [.missingPayee])

        // The server omits an empty payee, so the key is absent.
        let json = #"{"kind":"transaction","date":"2026-11-10","narration":"餐饮","postings":[{"account":"Expenses:Food","amount":"50.50","currency":"CNY"}],"currency":"CNY"}"#
        let entry = try JSONDecoder().decode(LedgerTransactionEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.payee, "")
        XCTAssertEqual(entry.narration, "餐饮")
    }

    func testEventTagCalculatorAggregatesSpendAndDailyRhythm() {
        let tx1 = LedgerTransaction(
            date: "2026-04-01",
            payee: "新干线",
            narration: "东京-京都",
            tags: ["2026-日本旅行"],
            postings: [
                LedgerPosting(account: "Expenses:Transport:Train", amount: 15000, currency: "CNY"),
                LedgerPosting(account: "Assets:Bank:Card", amount: -15000, currency: "CNY")
            ],
            source: TransactionSource(file: "2026.bean", line: 10)
        )

        let tx2 = LedgerTransaction(
            date: "2026-04-02",
            payee: "一兰拉面",
            narration: "午餐",
            tags: ["2026-日本旅行"],
            postings: [
                LedgerPosting(account: "Expenses:Food:Dining", amount: 5000, currency: "CNY"),
                LedgerPosting(account: "Assets:Cash", amount: -5000, currency: "CNY")
            ],
            source: TransactionSource(file: "2026.bean", line: 20)
        )

        let txRefund = LedgerTransaction(
            date: "2026-04-03",
            payee: "新干线",
            narration: "车票退款",
            tags: ["2026-日本旅行"],
            postings: [
                LedgerPosting(account: "Expenses:Transport:Train", amount: -3000, currency: "CNY"),
                LedgerPosting(account: "Assets:Bank:Card", amount: 3000, currency: "CNY")
            ],
            source: TransactionSource(file: "2026.bean", line: 30)
        )

        let report = EventTagCalculator.generateReport(tag: "2026-日本旅行", from: [tx1, tx2, txRefund])
        XCTAssertEqual(report.tag, "2026-日本旅行")
        XCTAssertEqual(report.transactions.count, 3)
        // tx1: 15000 + tx2: 5000 - txRefund: 3000 = 17000
        XCTAssertEqual(report.totalExpense, 17000)
        XCTAssertEqual(report.startDate, "2026-04-01")
        XCTAssertEqual(report.endDate, "2026-04-03")
        XCTAssertEqual(report.daysCount, 3)
        XCTAssertEqual(report.dailyAverage, 17000 / 3)
        XCTAssertEqual(report.categoryBreakdown.count, 2)

        let summaries = EventTagCalculator.summarizeAllTags(from: [tx1, tx2, txRefund])
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.tag, "2026-日本旅行")
        XCTAssertEqual(summaries.first?.totalExpense, 17000)
    }

    private func reconciliationRow(status: String, ledgerBalance: Int = 95_000) -> LedgerReconciliationRow {
        LedgerReconciliationRow(account: "Assets:Bank", alias: nil, label: "Bank", currency: "CNY",
            ledgerBalance: ledgerBalance, status: status, lastAssertion: nil)
    }

    private func accountStatus(_ status: String, assertion: Int? = nil, computed: Int? = nil) -> LedgerAccountStatus {
        LedgerAccountStatus(account: "Assets:Bank", status: status, lastEntryDate: "2026-11-05",
            lastEntryType: status == "yellow" ? "transaction" : "balance", assertionAmount: assertion, computedBalance: computed)
    }

    func testReconciliationStateGivesEachRowOneClassification() {
        // Asserted in range, then a later transaction turned it yellow: pending only.
        XCTAssertEqual(reconciliationRow(status: "asserted").reconciliationState(status: accountStatus("yellow")), .pending)
        XCTAssertEqual(reconciliationRow(status: "asserted").reconciliationState(status: accountStatus("green")), .asserted)
        XCTAssertEqual(reconciliationRow(status: "pending").reconciliationState(status: accountStatus("green")), .asserted)
        XCTAssertEqual(reconciliationRow(status: "asserted").reconciliationState(status: accountStatus("red", assertion: 1, computed: 2)), .error)
        XCTAssertEqual(reconciliationRow(status: "asserted").reconciliationState(status: nil), .asserted)
        XCTAssertEqual(reconciliationRow(status: "pending").reconciliationState(status: accountStatus("grey")), .pending)
    }

    func testAssertionDifferenceUsesTheBalanceTheAssertionWasCheckedAgainst() {
        // A same-day -50.00 is in the all-time balance (950.00) but not in the
        // balance before the assertion's day (1000.00) that made it fail.
        let row = reconciliationRow(status: "asserted", ledgerBalance: 95_000)
        XCTAssertEqual(row.assertionDifference(status: accountStatus("red", assertion: 95_000, computed: 100_000)), 5_000)
        XCTAssertEqual(row.assertionDifference(status: accountStatus("red", assertion: 90_000)), 5_000)
        XCTAssertNil(row.assertionDifference(status: accountStatus("green", assertion: 95_000, computed: 95_000)))
        XCTAssertNil(row.assertionDifference(status: nil))
    }

    func testReconciliationBalanceDecodesServerShape() throws {
        let json = Data(#"{"account":"Assets:Bank","date":"2026-11-10","currency":"CNY","ledgerBalance":100000}"#.utf8)
        let balance = try JSONDecoder().decode(LedgerReconciliationBalance.self, from: json)
        XCTAssertEqual(balance, LedgerReconciliationBalance(account: "Assets:Bank", date: "2026-11-10", currency: "CNY", ledgerBalance: 100_000))
    }
}

