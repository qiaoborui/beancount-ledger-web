import Foundation

extension LedgerSharedImportInbox {
    static func appInbox() throws -> Self {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--safe-preview") {
            return Self(directory: FileManager.default.temporaryDirectory.appendingPathComponent("LedgerSafePreviewSharedInbox", isDirectory: true))
        }
        #endif
        return try live()
    }
}
