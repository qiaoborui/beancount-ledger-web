import Foundation

struct DeviceLocalStorage: LogicalLocalStorage {
    let workspace: LocalLedgerWorkspace
    func didCommit(_ revision: LocalLedgerWorkspace.Revision) async { }
    func status() async throws -> LocalStorageSyncStatus {
        LocalStorageSyncStatus(mode: .device, phase: .localOnly)
    }
    func synchronize(validator: @escaping LocalLedgerWorkspace.Validator) async throws -> LocalStorageSyncStatus {
        try await status()
    }
}
