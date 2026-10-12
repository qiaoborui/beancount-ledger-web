import Foundation

/// A resumable import review scoped to one local ledger.
///
/// The source file is deliberately kept outside the JSON metadata so a
/// classification update does not rewrite a potentially large bill file.
struct LedgerImportDraft: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    var savedAt: Date
    let ledgerID: UUID
    let fileID: UUID
    let fileName: String
    var fileData: Data
    var providerOverride: String?
    var alipayFundRounding: Bool
    var preview: LedgerImportPreview?
    var reviewedEntries: [LedgerImportEntry]
    var includedEntryIDs: Set<String>
    var classificationResults: [String: ImportClassificationSuggestion]
    var classificationOriginals: [String: LedgerImportEntry]
    var manuallyReviewedIDs: Set<String>
    var classificationCompletedIDs: Set<String>
    var classificationAcceptedFields: [String: Set<String>]
    var classificationManualReasons: [String: String]
    var classificationEvidence: [String: [ImportClassificationRequest.Example]]
    var onlyClassificationReview: Bool

    var selectedFile: LedgerImportSelectedFile {
        LedgerImportSelectedFile(id: fileID, name: fileName, data: fileData)
    }

    private enum CodingKeys: String, CodingKey {
        case version, savedAt, ledgerID, fileID, fileName, providerOverride,
             alipayFundRounding, preview, reviewedEntries, includedEntryIDs,
             classificationResults, classificationOriginals, manuallyReviewedIDs,
             classificationCompletedIDs, classificationAcceptedFields,
             classificationManualReasons, classificationEvidence, onlyClassificationReview
    }

    init(
        savedAt: Date = Date(),
        ledgerID: UUID,
        file: LedgerImportSelectedFile,
        providerOverride: String?,
        alipayFundRounding: Bool,
        preview: LedgerImportPreview?,
        reviewedEntries: [LedgerImportEntry],
        includedEntryIDs: Set<String>,
        classificationResults: [String: ImportClassificationSuggestion],
        classificationOriginals: [String: LedgerImportEntry],
        manuallyReviewedIDs: Set<String>,
        classificationCompletedIDs: Set<String>,
        classificationAcceptedFields: [String: Set<String>],
        classificationManualReasons: [String: String],
        classificationEvidence: [String: [ImportClassificationRequest.Example]],
        onlyClassificationReview: Bool
    ) {
        self.version = Self.currentVersion
        self.savedAt = savedAt
        self.ledgerID = ledgerID
        fileID = file.id
        fileName = file.name
        fileData = file.data
        self.providerOverride = providerOverride
        self.alipayFundRounding = alipayFundRounding
        self.preview = preview
        self.reviewedEntries = reviewedEntries
        self.includedEntryIDs = includedEntryIDs
        self.classificationResults = classificationResults
        self.classificationOriginals = classificationOriginals
        self.manuallyReviewedIDs = manuallyReviewedIDs
        self.classificationCompletedIDs = classificationCompletedIDs
        self.classificationAcceptedFields = classificationAcceptedFields
        self.classificationManualReasons = classificationManualReasons
        self.classificationEvidence = classificationEvidence
        self.onlyClassificationReview = onlyClassificationReview
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        ledgerID = try container.decode(UUID.self, forKey: .ledgerID)
        fileID = try container.decode(UUID.self, forKey: .fileID)
        fileName = try container.decode(String.self, forKey: .fileName)
        providerOverride = try container.decodeIfPresent(String.self, forKey: .providerOverride)
        alipayFundRounding = try container.decode(Bool.self, forKey: .alipayFundRounding)
        preview = try container.decodeIfPresent(LedgerImportPreview.self, forKey: .preview)
        reviewedEntries = try container.decode([LedgerImportEntry].self, forKey: .reviewedEntries)
        includedEntryIDs = try container.decode(Set<String>.self, forKey: .includedEntryIDs)
        classificationResults = try container.decode([String: ImportClassificationSuggestion].self, forKey: .classificationResults)
        classificationOriginals = try container.decode([String: LedgerImportEntry].self, forKey: .classificationOriginals)
        manuallyReviewedIDs = try container.decode(Set<String>.self, forKey: .manuallyReviewedIDs)
        classificationCompletedIDs = try container.decode(Set<String>.self, forKey: .classificationCompletedIDs)
        classificationAcceptedFields = try container.decode([String: Set<String>].self, forKey: .classificationAcceptedFields)
        classificationManualReasons = try container.decode([String: String].self, forKey: .classificationManualReasons)
        classificationEvidence = try container.decode([String: [ImportClassificationRequest.Example]].self, forKey: .classificationEvidence)
        onlyClassificationReview = try container.decode(Bool.self, forKey: .onlyClassificationReview)
        fileData = Data()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(savedAt, forKey: .savedAt)
        try container.encode(ledgerID, forKey: .ledgerID)
        try container.encode(fileID, forKey: .fileID)
        try container.encode(fileName, forKey: .fileName)
        try container.encodeIfPresent(providerOverride, forKey: .providerOverride)
        try container.encode(alipayFundRounding, forKey: .alipayFundRounding)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encode(reviewedEntries, forKey: .reviewedEntries)
        try container.encode(includedEntryIDs, forKey: .includedEntryIDs)
        try container.encode(classificationResults, forKey: .classificationResults)
        try container.encode(classificationOriginals, forKey: .classificationOriginals)
        try container.encode(manuallyReviewedIDs, forKey: .manuallyReviewedIDs)
        try container.encode(classificationCompletedIDs, forKey: .classificationCompletedIDs)
        try container.encode(classificationAcceptedFields, forKey: .classificationAcceptedFields)
        try container.encode(classificationManualReasons, forKey: .classificationManualReasons)
        try container.encode(classificationEvidence, forKey: .classificationEvidence)
        try container.encode(onlyClassificationReview, forKey: .onlyClassificationReview)
    }
}

struct LedgerImportDraftStore {
    static let retention: TimeInterval = 24 * 60 * 60

    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        self.fileManager = fileManager
    }

    static var shared: LedgerImportDraftStore { LedgerImportDraftStore() }

    func load(ledgerID: UUID, now: Date = Date()) -> LedgerImportDraft? {
        do {
            let metadata = try Data(contentsOf: metadataURL(for: ledgerID))
            var draft = try JSONDecoder().decode(LedgerImportDraft.self, from: metadata)
            guard draft.version == LedgerImportDraft.currentVersion,
                  draft.ledgerID == ledgerID,
                  now.timeIntervalSince(draft.savedAt) < Self.retention else {
                remove(ledgerID: ledgerID)
                return nil
            }
            let sourceData = try Data(contentsOf: sourceURL(for: ledgerID))
            guard sourceData.count <= LedgerImportFileValidator.maximumBytes else {
                remove(ledgerID: ledgerID)
                return nil
            }
            draft.fileData = sourceData
            return draft
        } catch {
            return nil
        }
    }

    func save(_ draft: LedgerImportDraft) throws {
        guard draft.fileData.count <= LedgerImportFileValidator.maximumBytes else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var metadataDraft = draft
        metadataDraft.fileData = Data()
        let metadata = try JSONEncoder().encode(metadataDraft)
        try metadata.write(to: metadataURL(for: draft.ledgerID), options: [.atomic, .completeFileProtection])
        try draft.fileData.write(to: sourceURL(for: draft.ledgerID), options: [.atomic, .completeFileProtection])
    }

    func remove(ledgerID: UUID) {
        try? fileManager.removeItem(at: metadataURL(for: ledgerID))
        try? fileManager.removeItem(at: sourceURL(for: ledgerID))
    }

    private func metadataURL(for ledgerID: UUID) -> URL {
        directory.appendingPathComponent(ledgerID.uuidString + ".json")
    }

    private func sourceURL(for ledgerID: UUID) -> URL {
        directory.appendingPathComponent(ledgerID.uuidString + ".source")
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("LedgerMobile/ImportDrafts", isDirectory: true)
    }
}
