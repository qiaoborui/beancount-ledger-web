import Foundation

@MainActor
extension LedgerSession {
    private static var automaticBackupRunning = false

    /// Writes a backup of the open local ledger to the chosen backup folder.
    func backupCurrentLocalLedger() async throws -> LedgerBackupStore.Outcome {
        guard phase == .ready, let repository = localRepository else {
            throw LocalLedgerError.operationFailed("请先解锁本地账本")
        }
        guard let folder = LedgerBackupFolder.current else { throw LedgerBackupError.folderNotConfigured }
        let descriptor = currentLocalLedgerDescriptor ?? repository.descriptor
        let outcome = try await folder.withAccess { root in
            try await LedgerBackupStore(rootDirectory: root).backup(workspace: repository.workspace, descriptor: descriptor)
        }
        LedgerBackupFolder.recordBackup(for: descriptor.id, at: Date())
        return outcome
    }

    /// Runs at most once a day per ledger while the app is open and unlocked.
    /// Unchanged ledgers are recognised by content and write nothing.
    func runAutomaticLedgerBackupIfDue() async {
        guard !Self.automaticBackupRunning, phase == .ready, !isStorageSyncBusy, !isLocalOperationBusy,
              let id = currentLocalLedgerDescriptor?.id, LedgerBackupFolder.automaticBackupDue(for: id) else { return }
        Self.automaticBackupRunning = true
        defer { Self.automaticBackupRunning = false }
        // A failure leaves the due date unchanged, so the next foreground retries.
        _ = try? await backupCurrentLocalLedger()
    }

    func listLedgerBackups() async throws -> [LedgerBackupEntry] {
        guard let folder = LedgerBackupFolder.current else { throw LedgerBackupError.folderNotConfigured }
        return try await folder.withAccess { root in try await LedgerBackupStore(rootDirectory: root).list() }
    }

    /// Replaces the open ledger with `entry`. The current state is backed up
    /// first, so a restore can always be undone from the same folder. A Git
    /// workspace pushes the restored tree as an ordinary local change; if the
    /// remote moved meanwhile, the usual conflict review applies.
    func restoreCurrentLocalLedger(from entry: LedgerBackupEntry) async throws {
        guard phase == .ready, !isStorageSyncBusy, let repository = localRepository else {
            throw LocalLedgerError.operationFailed("请先解锁本地账本，等待当前同步结束。")
        }
        guard let folder = LedgerBackupFolder.current else { throw LedgerBackupError.folderNotConfigured }
        let descriptor = currentLocalLedgerDescriptor ?? repository.descriptor
        let expectedRevisionID = try await repository.workspace.currentRevision()?.id
        try await folder.withAccess { root in
            let store = LedgerBackupStore(rootDirectory: root)
            _ = try await store.backup(workspace: repository.workspace, descriptor: descriptor)
            let extracted = try await store.extract(entry)
            defer { LedgerBackupStore.discardExtraction(extracted.directory) }
            try await repository.restoreBackup(from: extracted.directory, expectedRevisionID: expectedRevisionID)
        }
        await refresh()
    }

    /// Restores a backup from the folder as an additional local ledger.
    func restoreLedgerBackupAsNew(_ entry: LedgerBackupEntry) async {
        guard let folder = LedgerBackupFolder.current else {
            errorMessage = LedgerBackupError.folderNotConfigured.localizedDescription
            return
        }
        do {
            let extracted = try await folder.withAccess { root in
                try await LedgerBackupStore(rootDirectory: root).extract(entry)
            }
            await importExtractedBackup(extracted)
        } catch { errorMessage = error.localizedDescription }
    }

    /// Restores any `.ledgerbackup` file picked in Files, for example on a new
    /// device before any backup folder is configured.
    func restoreLedgerBackupAsNew(fileAt url: URL) async {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let extracted = try await Task.detached { try LedgerBackupStore.extract(fileAt: url) }.value
            await importExtractedBackup(extracted)
        } catch { errorMessage = error.localizedDescription }
    }

    private func importExtractedBackup(_ extracted: (manifest: LedgerBackupManifest, directory: URL)) async {
        defer { LedgerBackupStore.discardExtraction(extracted.directory) }
        let existingNames = Set(localLedgers.map(\.name))
        var name = extracted.manifest.ledgerName
        if existingNames.contains(name) { name = String(name.prefix(110)) + "（恢复）" }
        await importLocalLedger(from: extracted.directory, name: name, entrypoint: extracted.manifest.entrypoint)
    }
}
