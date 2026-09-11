import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Files shared into Ledger remain local until the user reviews and submits them.
struct LedgerSharedImportInbox: Sendable {
    static let appGroupIdentifier = LedgerSharedAccess.current.appGroupIdentifier
    static let maximumBytes = 10 * 1024 * 1024
    static let maximumItems = 20
    static let maximumSharedItems = 5
    static let supportedExtensions: Set<String> = ["csv", "xlsx", "xls", "pdf", "eml", "html", "htm", "zip"]

    struct Item: Codable, Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
        let byteCount: Int
        let createdAt: Date
    }

    enum InboxError: LocalizedError {
        case unavailable, invalidFile, unsupported, empty, tooLarge, full, missing

        var errorDescription: String? {
            switch self {
            case .unavailable: "无法访问待导入收件箱，请稍后重试"
            case .invalidFile: "请选择有效的账单文件"
            case .unsupported: "支持 CSV、Excel、PDF、邮件、HTML 和 ZIP 账单"
            case .empty: "账单文件为空"
            case .tooLarge: "单个账单文件最多 10MB"
            case .full: "待导入收件箱已满，请先在 Ledger 中核对或移除文件"
            case .missing: "该待导入文件已被移除，请重新分享"
            }
        }
    }

    let directory: URL

    init(directory: URL) {
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
    }

    static func live() throws -> Self {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw InboxError.unavailable
        }
        return Self(directory: container.appendingPathComponent("SharedImportInbox", isDirectory: true))
    }

    func items() throws -> [Item] {
        try withLock { try storedItems() }
    }

    @discardableResult
    func enqueue(fileURL: URL, originalName: String? = nil) throws -> Item {
        guard fileURL.isFileURL else { throw InboxError.invalidFile }
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw InboxError.invalidFile }
        let name = originalName ?? fileURL.lastPathComponent
        try validateName(name)
        guard (values.fileSize ?? 0) <= Self.maximumBytes else { throw InboxError.tooLarge }
        let data = try boundedData(at: fileURL)
        return try withLock {
            guard try storedItems().count < Self.maximumItems else { throw InboxError.full }
            let item = Item(id: UUID(), name: name, byteCount: data.count, createdAt: Date())
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

    private func itemDirectory(_ item: Item) -> URL {
        directory.appendingPathComponent(item.id.uuidString, isDirectory: true)
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 255,
              name == (name as NSString).lastPathComponent,
              !name.contains("\\"), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw InboxError.invalidFile
        }
        guard Self.supportedExtensions.contains((name as NSString).pathExtension.lowercased()) else {
            throw InboxError.unsupported
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
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard !data.isEmpty else { throw InboxError.empty }
        guard data.count <= Self.maximumBytes else { throw InboxError.tooLarge }
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
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 4096 else { throw InboxError.invalidFile }
        let item = try JSONDecoder().decode(Item.self, from: Data(contentsOf: metadata))
        guard item.id.uuidString == url.lastPathComponent, (1...Self.maximumBytes).contains(item.byteCount) else {
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
