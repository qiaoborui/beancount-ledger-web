import XCTest
@testable import LedgerMobile

final class ImportPostDateMatchTests: XCTestCase {
    private let previewJSON = #"""
    {"importId":"p1","provider":"hsbchk-credit",
     "providerDetection":{"provider":"hsbchk-credit","reason":"test","confidence":"high"},
     "originalFilename":"hsbc.csv","dedupReport":"","candidateCount":2,"rawRowCount":3,
     "filteredRowCount":3,"generatedCount":3,"excludedRowCount":0,"skippedDuplicateCount":0,
     "dateStart":"2026-10-12","dateEnd":"2026-10-20","warnings":[],
     "entries":[
       {"id":"2026-10-13-0","date":"2026-10-13","flag":"*","payee":"ELEME PLATFORM MERCHANT","narration":"ELEME",
        "categoryAccount":"Expenses:Unknown","fundingAccount":"Liabilities:HK:HSBC:CreditCard","amount":33.33,
        "currency":"CNY","metadata":{"post_date":"15/10/2026"},"postings":[],
        "duplicateHint":{"reason":"amount-differs","date":"2026-10-13","payee":"河南早点","narration":"外卖",
                         "amount":"-33.48","currency":"CNY","source":"支付宝"}},
       {"id":"2026-10-20-1","date":"2026-10-20","flag":"*","payee":"TAXI","narration":"APPLEPAY TAXI",
        "categoryAccount":"Expenses:Unknown","fundingAccount":"Liabilities:HK:HSBC:CreditCard","amount":88,
        "currency":"CNY","metadata":{},"postings":[]}
     ],
     "postDateFills":[
       {"id":"fill-1","date":"2026-10-12","payee":"茶庄","narration":"会员","account":"Liabilities:HK:HSBC:CreditCard",
        "amount":"-7.50","currency":"CNY","postDate":"13/10/2026","bankDate":"2026-10-12","bankPayee":"APPLEPAY TEA"}
     ]}
    """#

    func testPreviewDecodesFillsAndStartsProbableDuplicatesUnchecked() throws {
        let preview = try JSONDecoder().decode(LedgerImportPreview.self, from: Data(previewJSON.utf8))
        XCTAssertEqual(preview.postDateFills?.map(\.postDate), ["13/10/2026"])
        XCTAssertEqual(preview.defaultIncludedEntryIDs, ["2026-10-20-1"])
        let hint = try XCTUnwrap(preview.entries.first?.duplicateHint)
        XCTAssertTrue(hint.summary.contains("河南早点"))
        XCTAssertTrue(hint.summary.contains("33.48"))
    }

    func testPreviewWithoutMatchesStillDecodesAndChecksEverything() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(previewJSON.utf8)) as? [String: Any])
        object.removeValue(forKey: "postDateFills")
        object["entries"] = (object["entries"] as? [[String: Any]])?.map { entry in
            var entry = entry
            entry.removeValue(forKey: "duplicateHint")
            return entry
        }
        let preview = try JSONDecoder().decode(LedgerImportPreview.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(preview.postDateFills)
        XCTAssertEqual(preview.defaultIncludedEntryIDs, Set(preview.entries.map(\.id)))
    }

    func testCommitRequestSendsDeclinedFillsOnlyWhenPresent() throws {
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            LedgerImportCommitRequest(importID: "p1", provider: "hsbchk-credit", entries: []))) as? [String: Any]
        XCTAssertNil(plain?["excludedPostDateFills"])
        let declined = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            LedgerImportCommitRequest(importID: "p1", provider: "hsbchk-credit", entries: [],
                                      excludedPostDateFills: ["fill-1"]))) as? [String: Any]
        XCTAssertEqual(declined?["excludedPostDateFills"] as? [String], ["fill-1"])
    }

    func testCommitResultDecodesFillCount() throws {
        let result = try JSONDecoder().decode(LedgerImportCommitResult.self,
            from: Data(#"{"ok":true,"count":1,"postDateFillCount":2}"#.utf8))
        XCTAssertEqual(result.postDateFillCount, 2)
    }

    func testDraftKeepsDeclinedFillsAndReadsOlderDrafts() throws {
        let preview = try JSONDecoder().decode(LedgerImportPreview.self, from: Data(previewJSON.utf8))
        let draft = LedgerImportDraft(
            ledgerID: UUID(), file: LedgerImportSelectedFile(name: "hsbc.csv", data: Data("x".utf8)),
            providerOverride: nil, alipayFundRounding: false, preview: preview,
            reviewedEntries: preview.entries, includedEntryIDs: preview.defaultIncludedEntryIDs,
            classificationResults: [:], classificationOriginals: [:], manuallyReviewedIDs: [],
            classificationCompletedIDs: [], classificationAcceptedFields: [:], classificationManualReasons: [:],
            classificationEvidence: [:], onlyClassificationReview: false, excludedPostDateFillIDs: ["fill-1"])
        let encoded = try JSONEncoder().encode(draft)
        XCTAssertEqual(try JSONDecoder().decode(LedgerImportDraft.self, from: encoded).excludedPostDateFillIDs, ["fill-1"])

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "excludedPostDateFillIDs")
        let older = try JSONDecoder().decode(LedgerImportDraft.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(older.excludedPostDateFillIDs, [])
    }
}
