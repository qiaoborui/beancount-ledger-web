import Foundation

/// Shared signing configuration used by the app and both extensions.
struct LedgerSharedAccess: Equatable, Sendable {
    static let originalAppGroupIdentifier = "group.com.qiaoborui.ledger.mobile"
    static let widgetKeychainInfoKey = "LedgerWidgetKeychainAccessGroup"
    static let current = LedgerSharedAccess(infoDictionary: Bundle.main.infoDictionary ?? [:])

    let appGroupIdentifier: String
    let widgetKeychainAccessGroup: String?

    init(infoDictionary: [String: Any]) {
        // SideStore/AltStore writes the provisioned groups into every bundle's
        // Info.plist. Bundle identifiers differ across extensions; this mapping
        // is shared and remains stable when the signing certificate is renewed.
        if let mapping = infoDictionary["ALTAppGroups"] {
            let groups = (mapping as? [String]).map { Set($0.filter(Self.isLedgerAppGroup)) } ?? []
            guard groups.count == 1, let group = groups.first else {
                appGroupIdentifier = Self.originalAppGroupIdentifier
                widgetKeychainAccessGroup = nil
                return
            }
            appGroupIdentifier = group
            // iOS includes entitled App Groups in the Keychain access list.
            // Explicitly selecting this group shares only the widget credential;
            // it does not rely on a build-time team prefix surviving re-signing.
            widgetKeychainAccessGroup = group
            return
        }

        // iLoader omits ALTAppGroups for ordinary apps. It inserts the team
        // after the main bundle ID, before each extension suffix, and assigns
        // group.<rewritten main bundle ID> to all three provisioning profiles.
        if let identifier = infoDictionary["CFBundleIdentifier"] as? String,
           let group = Self.iLoaderAppGroup(bundleIdentifier: identifier) {
            appGroupIdentifier = group
            widgetKeychainAccessGroup = group
            return
        }

        // Preserve credentials of installations signed directly by Xcode.
        appGroupIdentifier = Self.originalAppGroupIdentifier
        let value = (infoDictionary[Self.widgetKeychainInfoKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        widgetKeychainAccessGroup = value.flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 }
    }

    private static func iLoaderAppGroup(bundleIdentifier: String) -> String? {
        var mainIdentifier = bundleIdentifier
        for suffix in [".widgets", ".share"] where mainIdentifier.hasSuffix(suffix) {
            mainIdentifier = String(mainIdentifier.dropLast(suffix.count))
            break
        }
        let group = "group." + mainIdentifier
        guard group != originalAppGroupIdentifier, isLedgerAppGroup(group) else { return nil }
        return group
    }

    private static func isLedgerAppGroup(_ group: String) -> Bool {
        if group == originalAppGroupIdentifier { return true }
        let prefix = originalAppGroupIdentifier + "."
        guard group.hasPrefix(prefix) else { return false }
        let team = group.dropFirst(prefix.count)
        return team.utf8.count == 10 && team.utf8.allSatisfy {
            (65...90).contains($0) || (48...57).contains($0)
        }
    }
}
