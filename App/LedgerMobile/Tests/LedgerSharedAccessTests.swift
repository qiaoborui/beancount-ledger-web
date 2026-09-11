import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerSharedAccessTests: XCTestCase {
    private let original = "group.com.qiaoborui.ledger.mobile"
    private let legacyKeychain = "ORIGINAL01.com.qiaoborui.ledger.mobile.shared"

    func testOriginalSigningPreservesExistingWidgetKeychain() {
        let access = configuration()
        XCTAssertEqual(access.appGroupIdentifier, original)
        XCTAssertEqual(access.widgetKeychainAccessGroup, legacyKeychain)
    }

    func testSideStoreUsesItsAppGroupForBothPreferencesAndKeychain() {
        let resigned = original + ".NEWTEAM123"
        let access = configuration(groups: [resigned])
        XCTAssertEqual(access.appGroupIdentifier, resigned)
        XCTAssertEqual(access.widgetKeychainAccessGroup, resigned)
    }

    func testAppWidgetAndShareResolveTheSameGroupAfterResigning() {
        let resigned = original + ".NEWTEAM123"
        let bundles = ["com.qiaoborui.ledger.mobile", "com.qiaoborui.ledger.mobile.widgets", "com.qiaoborui.ledger.mobile.share"]
        let configurations = bundles.map { identifier in
            LedgerSharedAccess(infoDictionary: [
                "CFBundleIdentifier": identifier + ".NEWTEAM123",
                "ALTBundleIdentifier": identifier,
                "ALTAppGroups": [resigned],
                LedgerSharedAccess.widgetKeychainInfoKey: legacyKeychain,
            ])
        }
        XCTAssertEqual(Set(configurations.map(\.appGroupIdentifier)), [resigned])
        XCTAssertEqual(Set(configurations.compactMap(\.widgetKeychainAccessGroup)), [resigned])
    }

    func testRenewingCertificateKeepsCredentialNamespace() {
        let resigned = original + ".NEWTEAM123"
        var info: [String: Any] = ["ALTAppGroups": [resigned], "ALTCertificateID": "old-certificate"]
        let before = LedgerSharedAccess(infoDictionary: info)
        info["ALTCertificateID"] = "new-certificate"
        XCTAssertEqual(before, LedgerSharedAccess(infoDictionary: info))
        XCTAssertEqual(before.widgetKeychainAccessGroup, resigned)
    }

    func testUnrelatedGroupsAndDuplicatesDoNotChangeSelection() {
        let resigned = original + ".NEWTEAM123"
        for groups in [["group.example.other", resigned, resigned], [resigned, "group.example.other"]] {
            XCTAssertEqual(configuration(groups: groups).appGroupIdentifier, resigned)
        }
    }

    func testSideStoreCanKeepTheOriginalAppGroup() {
        let access = configuration(groups: [original])
        XCTAssertEqual(access.appGroupIdentifier, original)
        XCTAssertEqual(access.widgetKeychainAccessGroup, original)
    }

    func testAmbiguousMappingsDisableWidgetCredentials() {
        for groups in [[original, original + ".NEWTEAM123"], [original + ".NEWTEAM123", original + ".OTHER12345"]] {
            XCTAssertNil(configuration(groups: groups).widgetKeychainAccessGroup)
        }
    }

    func testMalformedOrUnrelatedMappingsDisableWidgetCredentials() {
        let invalid: [Any] = [
            [], "not-an-array", [17], ["group.example.other"],
            [original + "extra.NEWTEAM123"], [original + "."],
            [original + ".NEWTEAM123.extra"], [original + ".short"],
            [original + ".NEWTEAM12/"], ["prefix." + original],
        ]
        for groups in invalid {
            XCTAssertNil(configuration(groups: groups).widgetKeychainAccessGroup, "Invalid mapping: \(groups)")
        }
    }

    func testOriginalSigningRejectsUnexpandedOrMissingKeychainConfiguration() {
        for raw in ["", "  ", "$(AppIdentifierPrefix)com.qiaoborui.ledger.mobile.shared"] {
            XCTAssertNil(LedgerSharedAccess(infoDictionary: [LedgerSharedAccess.widgetKeychainInfoKey: raw]).widgetKeychainAccessGroup)
        }
        XCTAssertNil(LedgerSharedAccess(infoDictionary: [:]).widgetKeychainAccessGroup)
    }

    func testSideStoreMappingWorksWithoutOriginalTeamKeychainMetadata() {
        let resigned = original + ".NEWTEAM123"
        let access = LedgerSharedAccess(infoDictionary: ["ALTAppGroups": [resigned]])
        XCTAssertEqual(access.widgetKeychainAccessGroup, resigned)
    }

    func testLiveStoresUseTheSameResolvedConfiguration() {
        XCTAssertEqual(LedgerWidgetSnapshotStore.appGroupIdentifier, LedgerSharedImportInbox.appGroupIdentifier)
        XCTAssertEqual(LedgerWidgetSnapshotStore().suiteName, LedgerSharedAccess.current.appGroupIdentifier)
        XCTAssertEqual(LedgerWidgetRefreshStatusStore.shared.suiteName, LedgerSharedAccess.current.appGroupIdentifier)
    }

    private func configuration(groups: Any? = nil) -> LedgerSharedAccess {
        var info: [String: Any] = [LedgerSharedAccess.widgetKeychainInfoKey: legacyKeychain]
        info["ALTAppGroups"] = groups
        return LedgerSharedAccess(infoDictionary: info)
    }
}
