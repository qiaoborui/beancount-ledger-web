import Foundation
import Security
import XCTest
@testable import LedgerMobile

final class LocalGitBackgroundCredentialTests: XCTestCase {
    func testDeviceOnlyCredentialMigratesAccessibilityWithoutChangingToken() throws {
        #if os(iOS)
        let id = UUID()
        let store = DeviceLocalGitCredentialStore()
        let credential = LocalGitCredential(username: "synthetic", token: "fixture-only-no-remote-access")
        try store.save(credential, for: id)
        defer { try? store.remove(for: id) }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.qiaoborui.ledger.local-git", kSecAttrAccount: id.uuidString,
            kSecAttrSynchronizable: false]
        func accessibility() throws -> String? {
            var attributesQuery = query
            attributesQuery[kSecReturnAttributes] = true
            var result: CFTypeRef?
            XCTAssertEqual(SecItemCopyMatching(attributesQuery as CFDictionary, &result), errSecSuccess)
            return (result as? [String: Any])?[kSecAttrAccessible as String] as? String
        }
        XCTAssertEqual(try accessibility(), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(SecItemUpdate(query as CFDictionary,
            [kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary), errSecSuccess)
        XCTAssertEqual(try accessibility(), kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        try store.prepareForBackgroundSync(for: id)
        XCTAssertEqual(try accessibility(), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(try store.load(for: id), credential)
        #else
        throw XCTSkip("Validates the app-host iOS Keychain without prompting the Mac login keychain")
        #endif
    }
}
