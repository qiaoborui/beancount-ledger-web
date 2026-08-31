import SwiftUI
import UIKit
import WidgetKit
import XCTest

@MainActor
final class LedgerWidgetVisualTests: XCTestCase {
    func testRenderSupportedWidgetFamilies() throws {
        let snapshot = LedgerWidgetSnapshot.placeholder
        let expenseEntry = ExpenseOverviewEntry(date: snapshot.updatedAt, snapshot: snapshot)
        let accountEntry = AccountBalanceEntry(
            date: snapshot.updatedAt,
            snapshot: snapshot,
            selectedAccountID: snapshot.accounts.first?.id
        )
        let calendarEntry = ExpenseCalendarEntry(date: snapshot.updatedAt, snapshot: snapshot)
        let importEntry = ImportStatusEntry(date: snapshot.updatedAt, snapshot: snapshot)

        try render(
            ExpenseOverviewWidgetView(entry: expenseEntry, familyOverride: .systemSmall),
            size: CGSize(width: 158, height: 158),
            name: "expense-small"
        )
        try render(
            ExpenseOverviewWidgetView(entry: expenseEntry, familyOverride: .systemMedium),
            size: CGSize(width: 338, height: 158),
            name: "expense-medium"
        )
        try render(
            AccountBalanceWidgetView(entry: accountEntry, familyOverride: .systemSmall),
            size: CGSize(width: 158, height: 158),
            name: "account-small"
        )
        try render(
            AccountBalanceWidgetView(entry: accountEntry, familyOverride: .systemMedium),
            size: CGSize(width: 338, height: 158),
            name: "account-medium"
        )
        try render(
            ExpenseCalendarWidgetView(entry: calendarEntry, familyOverride: .systemMedium),
            size: CGSize(width: 338, height: 158),
            name: "expense-calendar-medium"
        )
        try render(
            ExpenseCalendarWidgetView(entry: calendarEntry, familyOverride: .systemLarge),
            size: CGSize(width: 338, height: 354),
            name: "expense-calendar-large"
        )
        try render(
            ImportStatusWidgetView(entry: importEntry, familyOverride: .systemMedium),
            size: CGSize(width: 338, height: 158),
            name: "import-status-medium"
        )
        try render(
            ImportStatusWidgetView(entry: importEntry, familyOverride: .systemLarge),
            size: CGSize(width: 338, height: 354),
            name: "import-status-large"
        )
    }

    func testExpenseCalendarHandlesLeapMonthAndAggregatesDailyValues() {
        let expense = LedgerWidgetExpenseSnapshot(
            periodTitle: "2028年2月",
            start: "2028-02-01",
            end: "2028-03-01",
            currency: "CNY",
            amount: 6_000,
            transactionCount: 3,
            yearOverYearPercentage: nil,
            categories: [],
            dailySeries: [
                LedgerWidgetDailyExpense(date: "2028-02-29", amount: 1_000),
                LedgerWidgetDailyExpense(date: "2028-02-29", amount: 2_000),
                LedgerWidgetDailyExpense(date: "2028-02-28", amount: 3_000),
                LedgerWidgetDailyExpense(date: "2028-03-01", amount: 9_999),
            ]
        )

        let layout = ExpenseCalendarLayout(expense: expense)

        XCTAssertEqual(layout.cells.count, 42)
        XCTAssertEqual(layout.cells.compactMap { $0 }.count, 29)
        XCTAssertNil(layout.cells.first ?? nil)
        XCTAssertEqual(layout.cells[1], 1)
        XCTAssertEqual(layout.amounts[29], 3_000)
        XCTAssertEqual(layout.peakDay, 28)
        XCTAssertEqual(layout.spendingDayCount, 2)
    }

    private func render<V: View>(
        _ view: V,
        size: CGSize,
        name: String
    ) throws {
        let content = view
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(LedgerWidgetColors.panel)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size, size)

        let directory = URL(fileURLWithPath: "/tmp/ledger-widget-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url, options: .atomic)

        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = XCTAttachment.Lifetime.keepAlways
        add(attachment)
    }
}
