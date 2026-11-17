import Foundation

extension LedgerSharedImportInbox {
    static func appInbox(_ purpose: Purpose = .imports) throws -> Self {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--safe-preview") {
            let name = purpose == .agent ? "LedgerSafePreviewSharedAgentInbox" : "LedgerSafePreviewSharedInbox"
            return Self(directory: FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true),
                        purpose: purpose)
        }
        #endif
        return try live(purpose)
    }

    /// Whether files shared to 账本助手 are waiting for the app.
    static func hasAgentDeliveries() -> Bool {
        guard let inbox = try? appInbox(.agent), let items = try? inbox.items() else { return false }
        return !items.isEmpty
    }
}
