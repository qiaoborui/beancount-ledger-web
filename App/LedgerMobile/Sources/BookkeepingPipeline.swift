import Foundation
import CryptoKit

/// Portable input to the local writer. Amounts remain decimal strings all the
/// way to Beancount; model/provider types never enter the writer contract.
struct BookkeepingDraft: Codable, Equatable, Sendable {
    struct Evidence: Codable, Equatable, Sendable {
        enum Origin: String, Codable, Sendable { case manual, statement, beancount }
        let origin: Origin
        let fingerprint: String
        let locator: String
        let original: String
        static func make(_ origin: Origin, original: String, locator: String = "") -> Self {
            .init(origin: origin, fingerprint: SHA256.hash(data: Data(original.utf8)).map { String(format: "%02x", $0) }.joined(),
                  locator: locator, original: original)
        }
    }
    var id = UUID()
    var revision = UUID()
    var records: [LedgerTransactionEntry]
    var evidence: [Evidence]

    static func manual(_ entry: LedgerTransactionEntry) -> Self {
        .init(records: [entry], evidence: [.make(.manual, original: sourceJSON(entry))])
    }
    static func imported(_ entries: [LedgerImportEntry]) -> Self {
        .init(records: entries.map { entry in
            LedgerTransactionEntry(date: entry.date, flag: entry.flag, payee: entry.payee, narration: entry.narration,
                metadata: entry.metadata.mapValues(LedgerMetadataValue.string),
                tags: entry.tags ?? [], postings: entry.postings.map {
                    .init(account: $0.account, amount: $0.amount, currency: $0.currency,
                          priceKind: $0.priceKind, priceAmount: $0.priceAmount, priceCurrency: $0.priceCurrency)
                })
        }, evidence: entries.map { .make(.statement, original: sourceJSON($0), locator: $0.id) })
    }
    private static func sourceJSON<T: Encodable>(_ source: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(source)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    func validate() throws {
        guard !records.isEmpty, records.count <= 5000 else { throw BookkeepingError.reviewRequired(String(localized: "请先补充交易。")) }
        for record in records {
            guard LedgerDateRange.parse(record.date) != nil, record.postings.count >= 2 else {
                throw BookkeepingError.reviewRequired(String(localized: "请补充日期和至少两条分录。"))
            }
            for posting in record.postings {
                guard !posting.account.isEmpty, posting.amount.isEmpty || !posting.currency.isEmpty,
                      posting.amount.isEmpty || ExactBookkeepingAmount.parse(posting.amount) != nil else {
                    throw BookkeepingError.reviewRequired(String(localized: "请核对分录的账户、金额和币种。"))
                }
            }
        }
    }
}

enum BookkeepingError: LocalizedError {
    case reviewRequired(String), expiredPreview
    var errorDescription: String? {
        switch self {
        case .reviewRequired(let message): message
        case .expiredPreview: String(localized: "草稿或账本已变化，请重新生成预览。")
        }
    }
}

enum ExactBookkeepingAmount {
    static func parse(_ text: String) -> Decimal? {
        guard text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              text.filter(\.isNumber).count <= 28,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }
    static func text(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
}

struct PreparedBookkeepingChange: Identifiable, Sendable {
    let id: UUID
    let ledgerID: UUID
    let draftRevision: UUID
    let files: LocalLedgerWorkspace.PreparedFiles
    let createdAt: Date
    /// Transactions the change writes, when preparing already counted them
    /// (a pasted .bean file), so callers need not parse the input again.
    var entryCount: Int? = nil
}
