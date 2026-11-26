import Foundation

/// Replaces the two account roles of a simple imported entry: the payment
/// side (`fundingAccount`) and the category side (`categoryAccount`). Used by
/// the import review's bulk category edit.
enum ImportEntryAccounts {
    /// A plain two-posting entry whose roles can be swapped without touching
    /// amounts: one funding posting, one category posting, one currency and no
    /// prices.
    static func supports(_ entry: LedgerImportEntry) -> Bool {
        entry.postings.count == 2 && entry.categoryAccount != entry.fundingAccount
            && entry.postings.filter { $0.account == entry.categoryAccount }.count == 1
            && entry.postings.filter { $0.account == entry.fundingAccount }.count == 1
            && entry.postings.allSatisfy {
                $0.currency == entry.currency && $0.priceKind == nil && $0.priceAmount == nil
                    && $0.priceCurrency == nil && decimal($0.amount) != nil
            }
            && entry.amount.isFinite
    }

    static func isFunding(_ account: String) -> Bool {
        account.hasPrefix("Assets:") || account.hasPrefix("Liabilities:")
    }

    static func applying(category: String, funding: String, tags: [String]? = nil,
                         to entry: LedgerImportEntry, allowed: [String]) -> LedgerImportEntry? {
        guard supports(entry), allowed.contains(category) || category == entry.categoryAccount,
              allowed.contains(funding) || funding == entry.fundingAccount, category != funding,
              isFunding(funding) else { return nil }
        guard let checkedTags = try? LedgerTagRules.validating(tags ?? entry.tags ?? []) else { return nil }
        // Simultaneous role replacement supports transfer endpoints swapping
        // while retaining exact decimal strings, polarity and source evidence.
        return LedgerImportEntry(
            id: entry.id, date: entry.date, flag: entry.flag, payee: entry.payee, narration: entry.narration,
            source: entry.source, orderID: entry.orderID, merchantID: entry.merchantID, payTime: entry.payTime,
            method: entry.method, transactionType: entry.transactionType, status: entry.status, type: entry.type,
            categoryAccount: category, fundingAccount: funding, amount: entry.amount, currency: entry.currency,
            tags: entry.tags == nil && checkedTags.isEmpty ? nil : checkedTags, metadata: entry.metadata,
            postings: entry.postings.map {
                $0.replacing(account: $0.account == entry.categoryAccount ? category : funding)
            }
        )
    }

    private static func decimal(_ raw: String) -> Decimal? {
        guard let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }
}
