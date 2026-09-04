import Foundation

struct LedgerImportProviderInfo: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let detail: String
    let extensions: [String]
    let accept: String
    let engine: String?
}

enum LedgerMobileImportCapabilities {
    static let supportsAutomaticEmailImport = false

    static let supportedManualFileExtensions = [
        ".csv", ".xlsx", ".xls", ".pdf", ".eml", ".html", ".htm", ".zip",
    ]

    private static let supportedManualFileExtensionSet = Set(supportedManualFileExtensions)

    static func fileImportProviders(from providers: [LedgerImportProviderInfo]) -> [LedgerImportProviderInfo] {
        guard !supportsAutomaticEmailImport else { return providers }
        return providers.filter { !isAutomaticEmailProvider($0) }
    }

    static func supportedExtensions(from providers: [LedgerImportProviderInfo]) -> Set<String> {
        let providerExtensions = normalizedExtensions(providers.flatMap(\.extensions))
            .filter(supportedManualFileExtensionSet.contains)
        return providers.isEmpty
            ? supportedManualFileExtensionSet
            : Set(providerExtensions).union([".zip"])
    }

    private static func isAutomaticEmailProvider(_ provider: LedgerImportProviderInfo) -> Bool {
        let id = provider.id.lowercased()
        let engine = provider.engine?.lowercased() ?? ""
        return id == "gmail"
            || id.hasPrefix("gmail-")
            || id.contains("email-auto")
            || id.contains("mail-auto")
            || engine == "gmail"
            || engine.hasPrefix("gmail-")
    }

    private static func normalizedExtensions(_ values: [String]) -> [String] {
        Array(Set(values.map { value in
            let normalized = value.lowercased()
            return normalized.hasPrefix(".") ? normalized : "." + normalized
        })).sorted()
    }
}

enum LedgerImportCommitFailureDisposition: Equatable {
    case failed
    case outcomeUnknown

    init(error: Error) {
        guard let apiError = error as? LedgerAPIError else {
            self = .failed
            return
        }
        switch apiError {
        case .transport, .decoding, .invalidResponse:
            self = .outcomeUnknown
        case .incompatibleServer, .server:
            self = .failed
        }
    }
}

enum LedgerImportCommitReconciliation {
    static func archivedDocument(
        importID: String,
        in documents: [LedgerImportDocument]
    ) -> LedgerImportDocument? {
        let suffix = "-" + importID
        return documents.first { document in
            let filename = document.name ?? document.path.map { ($0 as NSString).lastPathComponent }
            guard let filename else { return false }
            return (filename as NSString).deletingPathExtension.hasSuffix(suffix)
        }
    }
}

struct LedgerImportSelectedFile: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let data: Data

    init(id: UUID = UUID(), name: String, data: Data) {
        self.id = id
        self.name = name
        self.data = data
    }

    var fileExtension: String {
        let value = (name as NSString).pathExtension.lowercased()
        return value.isEmpty ? "" : "." + value
    }

    var isZIP: Bool { fileExtension == ".zip" }
}

enum LedgerImportFileValidationError: LocalizedError, Equatable {
    case empty
    case notRegularFile
    case tooLarge
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            "账单文件为空"
        case .notRegularFile:
            "请选择单个账单文件"
        case .tooLarge:
            "账单文件超过 10MB"
        case let .unsupported(fileExtension):
            "服务器暂不支持 \(fileExtension.isEmpty ? "该文件类型" : fileExtension)"
        }
    }
}

enum LedgerImportFileValidator {
    static let maximumBytes = 10 * 1024 * 1024

    static func validate(
        name: String,
        byteCount: Int,
        providers: [LedgerImportProviderInfo]
    ) throws {
        guard byteCount > 0 else { throw LedgerImportFileValidationError.empty }
        guard byteCount <= maximumBytes else { throw LedgerImportFileValidationError.tooLarge }
        let rawExtension = (name as NSString).pathExtension.lowercased()
        let fileExtension = rawExtension.isEmpty ? "" : "." + rawExtension
        let supported = LedgerMobileImportCapabilities.supportedExtensions(from: providers)
        guard supported.contains(fileExtension) else {
            throw LedgerImportFileValidationError.unsupported(fileExtension)
        }
    }
}

struct LedgerImportProviderDetection: Decodable, Equatable, Sendable {
    let provider: String
    let reason: String
    let confidence: String
}

struct LedgerImportPosting: Codable, Equatable, Identifiable, Sendable {
    let account: String
    let amount: String
    let currency: String
    let priceKind: String?
    let priceAmount: String?
    let priceCurrency: String?

    var id: String {
        [account, amount, currency, priceKind, priceAmount, priceCurrency]
            .compactMap { $0 }
            .joined(separator: ":")
    }
}

struct LedgerImportEntry: Codable, Equatable, Identifiable, Sendable {
    static let maximumEditableMainAmount = 9_000_000_000_000_000.0

    let id: String
    let date: String
    let flag: String
    let payee: String
    let narration: String
    let source: String?
    let orderID: String?
    let merchantID: String?
    let payTime: String?
    let method: String?
    let transactionType: String?
    let status: String?
    let type: String?
    let categoryAccount: String
    let fundingAccount: String
    let amount: Double
    let currency: String
    var tags: [String]? = nil
    let metadata: [String: String]
    let postings: [LedgerImportPosting]

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case flag
        case payee
        case narration
        case source
        case orderID = "orderId"
        case merchantID = "merchantId"
        case payTime
        case method
        case transactionType = "txType"
        case status
        case type
        case categoryAccount
        case fundingAccount
        case amount
        case currency
        case tags
        case metadata
        case postings
    }

    var supportsMainAmountEditing: Bool {
        guard postings.count == 2,
              categoryAccount != fundingAccount,
              postings.allSatisfy({ posting in
                  posting.currency == currency
                      && posting.priceKind == nil
                      && posting.priceAmount == nil
                      && posting.priceCurrency == nil
                      && Double(posting.amount) != nil
                      && Self.hasAtMostTwoFractionDigits(posting.amount)
              }) else { return false }
        let accounts = Set(postings.map(\.account))
        return accounts.contains(categoryAccount) && accounts.contains(fundingAccount)
    }

    func applyingReviewEdits(
        date: String,
        flag: String,
        payee: String,
        narration: String,
        amount: Double,
        categoryAccount: String,
        fundingAccount: String,
        tags: [String]? = nil
    ) -> LedgerImportEntry {
        let categoryIndex = postings.firstIndex { $0.account == self.categoryAccount }
        let fundingIndex = postings.firstIndex { $0.account == self.fundingAccount }
        var updatedPostings = postings.map { posting in
            posting.replacing(
                account: posting.account == self.categoryAccount
                    ? categoryAccount
                    : posting.account == self.fundingAccount
                        ? fundingAccount
                        : posting.account
            )
        }
        var updatedAmount = self.amount

        if supportsMainAmountEditing,
           amount.isFinite,
           amount > 0,
           amount <= Self.maximumEditableMainAmount,
           let categoryIndex,
           let fundingIndex,
           let originalFundingAmount = Double(postings[fundingIndex].amount) {
            let fundingSign = originalFundingAmount < 0 ? -1.0 : 1.0
            let fundingAmount = fundingSign * amount
            updatedPostings[fundingIndex] = updatedPostings[fundingIndex].replacing(
                amount: Self.decimalText(fundingAmount)
            )
            updatedPostings[categoryIndex] = updatedPostings[categoryIndex].replacing(
                amount: Self.decimalText(-fundingAmount)
            )
            updatedAmount = amount
        }

        return LedgerImportEntry(
            id: id,
            date: date,
            flag: flag,
            payee: payee.trimmingCharacters(in: .whitespacesAndNewlines),
            narration: narration.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source,
            orderID: orderID,
            merchantID: merchantID,
            payTime: payTime,
            method: method,
            transactionType: transactionType,
            status: status,
            type: type,
            categoryAccount: categoryAccount,
            fundingAccount: fundingAccount,
            amount: updatedAmount,
            currency: currency,
            tags: tags ?? self.tags,
            metadata: metadata,
            postings: updatedPostings
        )
    }

    func applyingTags(_ rawTags: [String]) -> LedgerImportEntry {
        LedgerImportEntry(
            id: id,
            date: date,
            flag: flag,
            payee: payee,
            narration: narration,
            source: source,
            orderID: orderID,
            merchantID: merchantID,
            payTime: payTime,
            method: method,
            transactionType: transactionType,
            status: status,
            type: type,
            categoryAccount: categoryAccount,
            fundingAccount: fundingAccount,
            amount: amount,
            currency: currency,
            tags: rawTags,
            metadata: metadata,
            postings: postings
        )
    }

    private static func decimalText(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func hasAtMostTwoFractionDigits(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let unsigned = trimmed.first == "-" || trimmed.first == "+" ? trimmed.dropFirst() : trimmed[...]
        let components = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count <= 2,
              let whole = components.first,
              !whole.isEmpty,
              whole.allSatisfy(\.isWholeNumber) else { return false }
        guard components.count == 2 else { return true }
        let fraction = components[1]
        return (1...2).contains(fraction.count) && fraction.allSatisfy(\.isWholeNumber)
    }
}

private extension LedgerImportPosting {
    func replacing(account: String? = nil, amount: String? = nil) -> LedgerImportPosting {
        LedgerImportPosting(
            account: account ?? self.account,
            amount: amount ?? self.amount,
            currency: currency,
            priceKind: priceKind,
            priceAmount: priceAmount,
            priceCurrency: priceCurrency
        )
    }
}

struct LedgerImportPreview: Decodable, Equatable, Sendable {
    let importID: String
    let provider: String
    let providerDetection: LedgerImportProviderDetection
    let originalFilename: String
    let dedupReport: String
    let entries: [LedgerImportEntry]
    let candidateCount: Int
    let rawRowCount: Int
    let filteredRowCount: Int
    let generatedCount: Int
    let excludedRowCount: Int
    let skippedDuplicateCount: Int
    let dateStart: String?
    let dateEnd: String?
    let warnings: [String]

    private enum CodingKeys: String, CodingKey {
        case importID = "importId"
        case provider
        case providerDetection
        case originalFilename
        case dedupReport
        case entries
        case candidateCount
        case rawRowCount
        case filteredRowCount
        case generatedCount
        case excludedRowCount
        case skippedDuplicateCount
        case dateStart
        case dateEnd
        case warnings
    }
}

struct LedgerImportCommitRequest: Encodable, Equatable, Sendable {
    let importID: String
    let provider: String
    let entries: [LedgerImportEntry]

    private enum CodingKeys: String, CodingKey {
        case importID = "importId"
        case provider
        case entries
    }
}

struct LedgerImportCommitResult: Decodable, Equatable, Sendable {
    let ok: Bool
    let outputFile: String?
    let includeFile: String?
    let documentFile: String?
    let count: Int
    let beanText: String?
    let readModelPending: Bool?
    let indexGitSHA: String?
    let runtimeCleanupError: String?
}

struct LedgerIndexInfo: Decodable, Equatable, Sendable {
    let enabled: Bool
    let active: Bool?
    let gitSHA: String?
    let indexedAt: String?
    let requestCompleted: Bool?
}

enum LedgerImportIndexPhase: Equatable, Sendable {
    case indexing
    case indexed
}

struct LedgerImportIndexProgress: Equatable, Sendable {
    let providerLabel: String
    let entryCount: Int
    let phase: LedgerImportIndexPhase
}
