import Foundation

enum LedgerWidgetSnapshotBuilder {
    static func make(
        report: LedgerHomeReport,
        ledger: LedgerBootstrap,
        importDocuments: [LedgerImportDocument] = [],
        importsUpdatedAt: Date? = nil,
        fallbackDate: Date = Date()
    ) -> LedgerWidgetSnapshot {
        LedgerWidgetSnapshot(
            updatedAt: generatedDate(report.generatedAt) ?? fallbackDate,
            expense: LedgerWidgetExpenseSnapshot(
                periodTitle: LedgerDateText.monthTitle(start: report.start),
                start: report.start,
                end: report.end,
                currency: report.currency,
                amount: report.current.kpis.expense,
                transactionCount: report.current.kpis.transactionCount,
                yearOverYearPercentage: percentageChange(
                    current: report.current.kpis.expense,
                    baseline: report.previous.kpis.expense
                ),
                categories: report.current.categorySeries
                    .filter { $0.total > 0 }
                    .sorted { $0.total > $1.total }
                    .prefix(3)
                    .map {
                        LedgerWidgetExpenseCategory(
                            account: $0.account,
                            label: $0.label,
                            amount: $0.total
                        )
                    },
                dailySeries: report.dailyExpenseSeries
                    .sorted { $0.date < $1.date }
                    .map { LedgerWidgetDailyExpense(date: $0.date, amount: $0.amount) }
            ),
            accounts: accountSnapshots(from: ledger),
            imports: importSnapshots(from: importDocuments),
            importsUpdatedAt: importsUpdatedAt
        )
    }

    private static func importSnapshots(
        from documents: [LedgerImportDocument]
    ) -> [LedgerWidgetImportSnapshot] {
        var latest: [String: LedgerImportDocument] = [:]
        for document in documents {
            guard let provider = document.provider,
                  LedgerImportProvider.provider(provider) != nil else { continue }
            if let current = latest[provider], !isLater(document, than: current) { continue }
            latest[provider] = document
        }
        return LedgerImportProvider.all.compactMap { provider in
            guard let document = latest[provider.id] else { return nil }
            return LedgerWidgetImportSnapshot(
                provider: provider.id,
                label: provider.compactLabel,
                coverageStart: document.dateStart,
                coverageEnd: document.dateEnd
            )
        }
    }

    private static func isLater(_ candidate: LedgerImportDocument, than current: LedgerImportDocument) -> Bool {
        let candidateCoverage = candidate.dateEnd ?? candidate.dateStart ?? ""
        let currentCoverage = current.dateEnd ?? current.dateStart ?? ""
        if candidateCoverage != currentCoverage { return candidateCoverage > currentCoverage }
        return candidate.modTime > current.modTime
    }

    private static func accountSnapshots(from ledger: LedgerBootstrap) -> [LedgerWidgetAccountSnapshot] {
        var accounts: [String: LedgerAccount] = [:]
        for account in ledger.accounts {
            accounts[account.account] = account
        }
        return ledger.accountBalances.compactMap { balance in
            guard balance.account.hasPrefix("Assets:") || balance.account.hasPrefix("Liabilities:"),
                  let account = accounts[balance.account],
                  account.active else {
                return nil
            }
            return LedgerWidgetAccountSnapshot(
                account: balance.account,
                label: account.displayLabel,
                group: account.group,
                currency: balance.currency,
                balance: balance.amount,
                valuationCurrency: balance.valuationCurrency,
                valuation: balance.valuationMissing == true ? nil : balance.valuation
            )
        }
        .sorted {
            if $0.isLiability != $1.isLiability { return !$0.isLiability }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    private static func percentageChange(current: Int, baseline: Int) -> Double? {
        guard baseline != 0 else { return nil }
        return (Double(current) - Double(baseline)) / abs(Double(baseline))
    }

    private static func generatedDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
