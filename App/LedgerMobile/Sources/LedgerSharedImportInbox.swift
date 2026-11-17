import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Files shared into Ledger remain local until the user reviews and submits them.
///
/// The share sheet fills one of two inboxes: the import inbox, which waits in
/// 导入 for review, or the assistant's, which the app empties into a new
/// 账本助手 conversation the next time it comes to the front.
struct LedgerSharedImportInbox: Sendable {
    static let appGroupIdentifier = LedgerSharedAccess.current.appGroupIdentifier
    static let maximumBytes = 10 * 1024 * 1024
    static let maximumItems = 20
    static let maximumSharedItems = 5
    static let supportedExtensions: Set<String> = ["csv", "xlsx", "xls", "pdf", "eml", "html", "htm", "zip"]
    /// What 账本助手 can read as an attachment (`LedgerAgentAttachments.kind`),
    /// listed here because the share extension does not build the assistant.
    static let agentExtensions: Set<String> = [
        "csv", "tsv", "xlsx", "xlsm", "xls", "html", "htm", "pdf", "txt",
        "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "bmp", "tif", "tiff",
    ]
    /// The assistant's own attachment limit (`LedgerAgentAttachments.maximumBytes`).
    static let agentMaximumBytes = 25 * 1024 * 1024
    /// What the user typed for the assistant in the share sheet.
    static let maximumNoteLength = 2000

    enum Purpose: Sendable {
        /// Bills for 导入 to review and submit.
        case imports
        /// Files for 账本助手 to read in a new conversation.
        case agent

        var directoryName: String {
            switch self {
            case .imports: "SharedImportInbox"
            case .agent: "SharedAgentInbox"
            }
        }

        var extensions: Set<String> {
            switch self {
            case .imports: LedgerSharedImportInbox.supportedExtensions
            case .agent: LedgerSharedImportInbox.agentExtensions
            }
        }

        var maximumBytes: Int {
            switch self {
            case .imports: LedgerSharedImportInbox.maximumBytes
            case .agent: LedgerSharedImportInbox.agentMaximumBytes
            }
        }
    }

    struct Item: Codable, Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
        let byteCount: Int
        let createdAt: Date
        /// The request typed with the files for 账本助手; nil for imports and
        /// for items saved before there was one.
        var note: String? = nil
    }

    enum InboxError: LocalizedError {
        case unavailable, invalidFile, unsupported, empty, tooLarge, full, missing
        case agentUnsupported, agentTooLarge

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "无法访问待导入收件箱，请稍后重试")
            case .invalidFile: String(localized: "请选择有效的账单文件")
            case .unsupported: String(localized: "支持 CSV、Excel、PDF、邮件、HTML 和 ZIP 账单")
            case .empty: String(localized: "账单文件为空")
            case .tooLarge: String(localized: "单个账单文件最多 10MB")
            case .full: String(localized: "待导入收件箱已满，请先在 Ledger 中核对或移除文件")
            case .missing: String(localized: "该待导入文件已被移除，请重新分享")
            case .agentUnsupported: String(localized: "账本助手支持 CSV、Excel、PDF、HTML、文本和图片")
            case .agentTooLarge: String(localized: "单个文件最多 25MB")
            }
        }
    }

    let directory: URL
    let purpose: Purpose

    init(directory: URL, purpose: Purpose = .imports) {
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
        self.purpose = purpose
    }

    static func live(_ purpose: Purpose = .imports) throws -> Self {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw InboxError.unavailable
        }
        return Self(directory: container.appendingPathComponent(purpose.directoryName, isDirectory: true), purpose: purpose)
    }

    /// Whether a shared file of this name can go to this inbox.
    func accepts(name: String) -> Bool {
        purpose.extensions.contains((name as NSString).pathExtension.lowercased())
    }

    func items() throws -> [Item] {
        try withLock { try storedItems() }
    }

    @discardableResult
    func enqueue(fileURL: URL, originalName: String? = nil, note: String? = nil) throws -> Item {
        guard fileURL.isFileURL else { throw InboxError.invalidFile }
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw InboxError.invalidFile }
        let name = originalName ?? fileURL.lastPathComponent
        try validateName(name)
        guard (values.fileSize ?? 0) <= purpose.maximumBytes else { throw tooLarge }
        let note = Self.normalizedNote(note)
        let data = try boundedData(at: fileURL)
        return try withLock {
            guard try storedItems().count < Self.maximumItems else { throw InboxError.full }
            let item = Item(id: UUID(), name: name, byteCount: data.count, createdAt: Date(), note: note)
            let staging = directory.appendingPathComponent(".pending-" + item.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: staging) }
            try protect(staging)
            try data.write(to: staging.appendingPathComponent("payload"), options: .atomic)
            try protect(staging.appendingPathComponent("payload"))
            try JSONEncoder().encode(item).write(to: staging.appendingPathComponent("item.json"), options: .atomic)
            try protect(staging.appendingPathComponent("item.json"))
            try FileManager.default.moveItem(at: staging, to: itemDirectory(item))
            return item
        }
    }

    func read(_ item: Item) throws -> Data {
        try withLock {
            guard try storedItem(at: itemDirectory(item)) == item else { throw InboxError.missing }
            let data = try boundedData(at: itemDirectory(item).appendingPathComponent("payload"))
            guard data.count == item.byteCount else { throw InboxError.invalidFile }
            return data
        }
    }

    func remove(_ item: Item) throws {
        try withLock {
            let location = itemDirectory(item)
            guard FileManager.default.fileExists(atPath: location.path) else { return }
            guard try storedItem(at: location) == item else { throw InboxError.missing }
            try FileManager.default.removeItem(at: location)
        }
    }

    /// A trimmed note, nil when empty, cut to `maximumNoteLength` characters.
    static func normalizedNote(_ note: String?) -> String? {
        guard let text = note?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(maximumNoteLength))
    }

    private var tooLarge: InboxError { purpose == .agent ? .agentTooLarge : .tooLarge }

    private func itemDirectory(_ item: Item) -> URL {
        directory.appendingPathComponent(item.id.uuidString, isDirectory: true)
    }

    // Keep the explicit scalar call: the bound Foundation method misclassifies
    // ASCII names on physical iOS 27 (24A437) with Xcode 27 Release builds.
    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 255,
              name == (name as NSString).lastPathComponent,
              !name.contains("\\"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw InboxError.invalidFile
        }
        guard accepts(name: name) else {
            throw purpose == .agent ? InboxError.agentUnsupported : InboxError.unsupported
        }
    }

    private func boundedData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw InboxError.invalidFile }
        #if canImport(Darwin)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw InboxError.invalidFile }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw InboxError.invalidFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #else
        let handle = try FileHandle(forReadingFrom: url)
        #endif
        defer { try? handle.close() }
        let data = try handle.read(upToCount: purpose.maximumBytes + 1) ?? Data()
        guard !data.isEmpty else { throw InboxError.empty }
        guard data.count <= purpose.maximumBytes else { throw tooLarge }
        return data
    }

    private func storedItems() throws -> [Item] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { try? storedItem(at: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func storedItem(at url: URL) throws -> Item {
        guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else { throw InboxError.invalidFile }
        let metadata = url.appendingPathComponent("item.json")
        let values = try metadata.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        // A note of `maximumNoteLength` characters, escaped, still fits.
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 32 * 1024 else { throw InboxError.invalidFile }
        let item = try JSONDecoder().decode(Item.self, from: Data(contentsOf: metadata))
        guard item.id.uuidString == url.lastPathComponent, (1...purpose.maximumBytes).contains(item.byteCount),
              (item.note?.count ?? 0) <= Self.maximumNoteLength else {
            throw InboxError.invalidFile
        }
        try validateName(item.name)
        return item
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        guard directory.isFileURL,
              directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
            throw InboxError.invalidFile
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory)
        #if canImport(Darwin)
        let lockPath = directory.appendingPathComponent(".lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw InboxError.unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw InboxError.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        #endif
        return try operation()
    }

    private func protect(_ url: URL) throws {
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
}
