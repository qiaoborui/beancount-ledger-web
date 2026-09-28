import Foundation
import Darwin

/// An ephemeral, caller-owned export. This is not a ledger file or a persistent
/// cache. The owner must discard it on dismissal, lock, cancellation or revision
/// change; deinit is a final fallback, not the privacy lifecycle mechanism.
final class TransactionShareFile {
    enum ExportError: Error { case unavailable, closed, chunkTooLarge }
    private let parent: Int32
    private let directory: Int32
    private let name: String
    private let fileName = "transactions.txt"
    private let destination: URL
    private var output: FileHandle?
    private var discarded = false
    private(set) var isFinished = false
    private(set) var byteCount = 0

    /// `parentDirectory` must be an app-owned runtime/temp directory, never a
    /// ledger source or a path from an import. Resolve trusted platform aliases
    /// (e.g. /var) before this call. The final parent component cannot be a link.
    init(parentDirectory: URL) throws {
        guard parentDirectory.isFileURL else { throw ExportError.unavailable }
        let parent = open(parentDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ExportError.unavailable }
        let name = "ledger-share-" + UUID().uuidString
        guard mkdirat(parent, name, S_IRWXU) == 0 else {
            close(parent)
            throw ExportError.unavailable
        }
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            unlinkat(parent, name, AT_REMOVEDIR)
            close(parent)
            throw ExportError.unavailable
        }
        let destination = parentDirectory.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("transactions.txt")
        do {
            var folder = destination.deletingLastPathComponent()
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: folder.path)
            #endif
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            let file = openat(directory, "transactions.txt", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR)
            guard file >= 0 else { throw ExportError.unavailable }
            let output = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            do {
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
                #endif
                self.output = output
            } catch {
                try? output.close()
                throw error
            }
        } catch {
            unlinkat(directory, "transactions.txt", 0)
            close(directory)
            unlinkat(parent, name, AT_REMOVEDIR)
            close(parent)
            throw error
        }
        self.parent = parent
        self.directory = directory
        self.name = name
        self.destination = destination
    }

    func append(_ bytes: Data) throws {
        guard !discarded, !isFinished, let output else { throw ExportError.closed }
        do {
            try Task.checkCancellation()
            guard bytes.count <= 16 * 1_024 else { throw ExportError.chunkTooLarge }
            let (total, overflow) = byteCount.addingReportingOverflow(bytes.count)
            guard !overflow else { throw ExportError.unavailable }
            try output.write(contentsOf: bytes)
            byteCount = total
        } catch { discard(); throw error }
    }

    /// No URL is available before a successful complete-stream finalization.
    /// The caller must finish its formatter AND revalidate revision/privacy first.
    func finish() throws -> URL {
        guard !discarded, !isFinished, let output else { throw ExportError.closed }
        do {
            try Task.checkCancellation()
            try output.synchronize()
            try output.close()
            self.output = nil
            isFinished = true
            return destination
        } catch { discard(); throw error }
    }

    func discard() {
        guard !discarded else { return }
        discarded = true
        isFinished = false
        try? output?.close()
        output = nil
        // Descriptor-relative cleanup cannot follow a replaced file symlink.
        unlinkat(directory, fileName, 0)
        unlinkat(parent, name, AT_REMOVEDIR)
    }

    deinit {
        discard()
        close(directory)
        close(parent)
    }
}
