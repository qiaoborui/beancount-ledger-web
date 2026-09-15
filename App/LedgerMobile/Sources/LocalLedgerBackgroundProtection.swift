import Foundation

/// Prepares an existing, app-private workspace after foreground authentication.
/// Includes catalog metadata, immutable generations, runtime files and Git caches.
/// The caller records background authorization only after this operation succeeds.
enum LocalLedgerBackgroundProtection {
    static func prepareForBackgroundSync(
        rootDirectory: URL,
        configurationID: UUID,
        credentials: any LocalGitCredentialStoring = DeviceLocalGitCredentialStore()
    ) async throws {
        let task = Task.detached(priority: .utility) {
            try migrateTree(at: rootDirectory)
            try Task.checkCancellation()
            try credentials.prepareForBackgroundSync(for: configurationID)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func migrateTree(at rootDirectory: URL) throws {
        let root = try validatedRoot(rootDirectory)
        let manager = FileManager.default
        // Preflight the entire tree before changing attributes. Explicit directory
        // reads propagate inaccessible-entry errors instead of skipping a subtree.
        var items = [root]
        var index = 0
        while index < items.count {
            try Task.checkCancellation()
            let item = items[index]
            index += 1
            let type = try itemType(item)
            if type == .typeDirectory {
                let children = try manager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
                for child in children {
                    let normalized = child.standardizedFileURL
                    guard normalized.path.hasPrefix(root.path + "/") else {
                        throw LocalStorageError.unsafeFile(child.lastPathComponent)
                    }
                    _ = try itemType(normalized)
                    items.append(normalized)
                }
            }
        }
        for item in items {
            try Task.checkCancellation()
            // Recheck links immediately before setting attributes. Workspace
            // publication uses immutable generations; preparation runs before sync.
            guard item.resolvingSymlinksInPath().standardizedFileURL == item else {
                throw LocalStorageError.unsafeFile(item.lastPathComponent)
            }
            _ = try itemType(item)
            #if os(iOS)
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: item.path
            )
            #endif
        }
    }

    private static func validatedRoot(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw LocalStorageError.unsafeFile(url.lastPathComponent) }
        let root = url.standardizedFileURL
        // Apple container and temporary URLs can use /var or /private/var.
        // Foundation canonicalizes /private/var back to /var on some platforms.
        guard root.pathComponents.count > 2 else {
            throw LocalStorageError.unsafeFile(root.lastPathComponent)
        }
        var ancestor = root
        while ancestor.path != "/" {
            if ["/var", "/tmp"].contains(ancestor.path),
               let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path),
               destination == "private" + ancestor.path || destination == "/private" + ancestor.path {
                ancestor.deleteLastPathComponent()
                continue
            }
            guard try itemType(ancestor) == .typeDirectory else {
                throw LocalStorageError.unsafeFile(ancestor.lastPathComponent)
            }
            ancestor.deleteLastPathComponent()
        }
        return root.standardizedFileURL
    }

    private static func itemType(_ url: URL) throws -> FileAttributeType {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType,
              type == .typeDirectory || type == .typeRegular else {
            throw LocalStorageError.unsafeFile(url.lastPathComponent)
        }
        return type
    }
}
