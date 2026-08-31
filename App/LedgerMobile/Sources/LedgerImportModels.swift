import Foundation

struct LedgerImportProviderInfo: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let detail: String
    let extensions: [String]
    let accept: String
    let engine: String?
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

    private static let fallbackExtensions: Set<String> = [
        ".csv", ".xlsx", ".xls", ".pdf", ".eml", ".html", ".htm", ".zip",
    ]

    static func validate(
        name: String,
        byteCount: Int,
        providers: [LedgerImportProviderInfo]
    ) throws {
        guard byteCount > 0 else { throw LedgerImportFileValidationError.empty }
        guard byteCount <= maximumBytes else { throw LedgerImportFileValidationError.tooLarge }
        let rawExtension = (name as NSString).pathExtension.lowercased()
        let fileExtension = rawExtension.isEmpty ? "" : "." + rawExtension
        let providerExtensions = Set(providers.flatMap(\.extensions).map { value in
            value.hasPrefix(".") ? value.lowercased() : "." + value.lowercased()
        })
        let supported = providerExtensions.isEmpty ? fallbackExtensions : providerExtensions.union([".zip"])
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
        case metadata
        case postings
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
    let runtimeCleanupError: String?
}
