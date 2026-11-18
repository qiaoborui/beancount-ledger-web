import Foundation

/// The app's own iCloud Documents container (paid-team builds only).
///
/// ```
/// <container>/Documents/Ledgers/<ledger folder>/   one FolderLocalStorage layout per ledger
/// <container>/Documents/Assistant/                 LedgerAgentCloudSync layout
/// ```
///
/// Why iCloud Documents and not CloudKit: a ledger is a tree of text files
/// that already syncs as content-addressed snapshots plus one head file per
/// device (FolderLocalStorage), merged three ways with the same conflict
/// review as Git. The container gives that layout a home on every device of
/// the Apple ID without a folder picker, offline writes upload on their own,
/// and nothing new has to be modelled as records.
///
/// The code always asks for the first container in the entitlements and
/// never names its ID, so a build without the entitlement (SideStore) simply
/// finds no container and keeps offering a picked folder instead.
enum LedgerICloud {
    static let ledgersName = "Ledgers"
    static let assistantName = "Assistant"

    /// `<container>/Documents`, or nil without iCloud or the entitlement.
    /// Blocks while iCloud prepares the container: never call it on the main
    /// thread; use `available()` there.
    static func documentsDirectory() -> URL? {
        guard FileManager.default.ubiquityIdentityToken != nil,
              let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }

    static func ledgersDirectory() -> URL? {
        documentsDirectory()?.appendingPathComponent(ledgersName, isDirectory: true)
    }

    static func assistantDirectory() -> URL? {
        documentsDirectory()?.appendingPathComponent(assistantName, isDirectory: true)
    }

    /// Whether this build can use the container right now, off the main thread.
    static func available() async -> Bool {
        await Task.detached(priority: .userInitiated) { documentsDirectory() != nil }.value
    }

    /// A ledger's folder name in the container: one path component.
    static func isValidFolderName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name != "." && name != ".." && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    /// A ledger already in the container, shared by another device.
    struct SharedLedger: Identifiable, Equatable, Sendable {
        let folder: String
        let name: String
        let entrypoint: String
        let createdAt: Date
        /// The devices that have published to it, newest first.
        let devices: [String]
        let updatedAt: Date?
        var id: String { folder }
    }

    /// The ledgers in the container. Markers that have not downloaded yet are
    /// read through a coordinated read, which downloads them.
    static func sharedLedgers() -> [SharedLedger] {
        guard let root = ledgersDirectory() else { return [] }
        return ((try? FolderFiles.names(in: root)) ?? []).compactMap { folder -> SharedLedger? in
            guard isValidFolderName(folder) else { return nil }
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            guard let marker = try? FolderSyncLayout.readMarker(in: directory) else { return nil }
            let heads = FolderSyncLayout.heads(in: directory).sorted { $0.updatedAt > $1.updatedAt }
            return SharedLedger(folder: folder, name: marker.ledgerName, entrypoint: marker.entrypoint,
                createdAt: marker.createdAt, devices: heads.map(\.deviceName), updatedAt: heads.first?.updatedAt)
        }.sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
    }

    static func sharedLedgersAsync() async -> [SharedLedger] {
        await Task.detached(priority: .userInitiated) { sharedLedgers() }.value
    }
}

/// iCloud keeps the other side of a simultaneous write as an unresolved
/// conflict version and shows one winner. The sync layouts avoid most of
/// these (one head per device, immutable snapshots), but files that every
/// device writes, such as the assistant's memory.md, can still collide. This
/// folds the losing versions into the current file, so no device's write is
/// silently dropped, and then clears them.
enum FolderConflictVersions {
    /// `merge(current, other)` returns the combined content. Returns true
    /// when the file changed. Does nothing for a file without conflicts or
    /// outside iCloud.
    @discardableResult
    static func resolve(at url: URL, merge: (Data, Data) -> Data) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty else { return false }
        let current = try FolderFiles.read(url)
        var merged = current
        for version in versions.sorted(by: { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }) {
            if let other = try? Data(contentsOf: version.url) { merged = merge(merged, other) }
        }
        if merged != current { try FolderFiles.write(merged, to: url) }
        for version in versions { version.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        return merged != current
    }

    /// Keeps the current version and drops the others, for files whose
    /// copies are equal by construction (content-addressed snapshots).
    static func discard(at url: URL) {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty else { return }
        for version in versions { version.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }
}

/// Watches the container for files that other devices changed, so a write
/// on one phone reaches the other within seconds instead of at the next
/// periodic sync. The query also makes iCloud fetch metadata for new items.
@MainActor
final class LedgerICloudMonitor {
    static let shared = LedgerICloudMonitor()

    /// Called with the container paths that were added or changed.
    private var observers: [UUID: ([String]) -> Void] = [:]
    private var query: NSMetadataQuery?
    private var tokens: [NSObjectProtocol] = []

    /// Starts watching while at least one observer is registered.
    func observe(_ body: @escaping ([String]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = body
        start()
        return id
    }

    func remove(_ id: UUID) {
        observers[id] = nil
        if observers.isEmpty { stop() }
    }

    private func start() {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.json' OR %K LIKE '*.md'",
                                      NSMetadataItemFSNameKey, NSMetadataItemFSNameKey)
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] note in
                let changed = (note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] ?? [])
                    + (note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? [])
                let paths = changed.compactMap { ($0.value(forAttribute: NSMetadataItemURLKey) as? URL)?.path }
                guard !paths.isEmpty else { return }
                Task { @MainActor in self?.notify(paths) }
            },
        ]
        self.query = query
        query.start()
    }

    private func stop() {
        query?.stop()
        query = nil
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }

    private func notify(_ paths: [String]) {
        for observer in observers.values { observer(paths) }
    }
}
