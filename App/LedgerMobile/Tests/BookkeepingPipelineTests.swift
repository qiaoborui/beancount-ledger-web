import Foundation
import XCTest
@testable import LedgerMobile

final class BookkeepingPipelineTests: XCTestCase {
    /// 128 on the card for books, 48 of it advanced for a colleague.
    private var splitDraft: BookkeepingDraft {
        .manual(.init(date: "2026-09-18", payee: "书店", narration: "买书，替同事垫付", postings: [
            .init(account: "Expenses:Books", amount: "80", currency: "CNY"),
            .init(account: "Assets:Receivable", amount: "48", currency: "CNY"),
            .init(account: "Liabilities:Card", amount: "-128", currency: "CNY")]))
    }

    func testExactAmountsRejectNonDecimalText() throws {
        XCTAssertEqual(ExactBookkeepingAmount.parse("9007199254740993.000001").map(ExactBookkeepingAmount.text),
                       "9007199254740993.000001")
        for text in ["NaN", "1e100", "1.2junk", "1,200", "9999999999999999999999999999999999999999"] {
            XCTAssertNil(ExactBookkeepingAmount.parse(text))
        }
    }

    func testDraftWithoutAccountsOrDateFailsValidation() throws {
        try splitDraft.validate()
        let missingAccount = BookkeepingDraft.manual(.init(date: "2026-09-18", narration: "fixture", postings: [
            .init(account: "", amount: "10", currency: "CNY"), .init(account: "Liabilities:Card", amount: "-10", currency: "CNY")]))
        XCTAssertThrowsError(try missingAccount.validate())
        let badDate = BookkeepingDraft.manual(.init(date: "2026-13-01", narration: "fixture", postings: splitDraft.records[0].postings))
        XCTAssertThrowsError(try badDate.validate())
    }

    private func repository() async throws -> LocalLedgerRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookkeepingTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("""
        ; preserve source comment
        option "operating_currency" "CNY"
        2020-01-01 commodity CNY
        2020-01-01 open Expenses:Books CNY
        2020-01-01 open Assets:Receivable CNY
        2020-01-01 open Liabilities:Card CNY

        """.utf8).write(to: source.appendingPathComponent("main.bean"))
        let catalog = LocalLedgerCatalog(rootDirectory: root.appendingPathComponent("managed"))
        let descriptor = try await catalog.importLedger(from: source, name: "Synthetic bookkeeping")
        return catalog.repository(for: descriptor)
    }

    func testFullEnginePreviewDoesNotWriteAndConfirmationPublishesExactBytes() async throws {
        #if os(iOS)
        let repository = try await repository()
        let before = try await repository.workspace.currentRevision()
        let preview = try await repository.prepareBookkeeping(splitDraft)
        let unchanged = try await repository.workspace.currentRevision()
        XCTAssertEqual(unchanged, before)
        XCTAssertFalse(preview.files.files.isEmpty)
        let oldTransactions = try await repository.globalTransactions()
        XCTAssertTrue(oldTransactions.transactions.isEmpty)
        _ = try await repository.commitPrepared(preview)
        for file in preview.files.files {
            if let expected = file.after {
                let saved = try await repository.workspace.readFile(at: file.path)
                XCTAssertEqual(saved, expected)
            }
        }
        let transactions = try await repository.globalTransactions()
        XCTAssertEqual(transactions.transactions.count, 1)
        XCTAssertEqual(transactions.transactions.first?.postings.count, 3)
        do { _ = try await repository.commitPrepared(preview); XCTFail("Token was reused") } catch { }
        #else
        throw XCTSkip("Requires the app-linked iOS Go and canonical Beancount runtimes")
        #endif
    }

    func testManualInferredPostingAndExistingNumericSyntaxReachCanonicalValidation() async throws {
        #if os(iOS)
        let repository = try await repository()
        for amount in ["+10", "10.", "12.123456789"] {
            let draft = BookkeepingDraft.manual(.init(date: "2026-09-18", payee: "Fixture", narration: "manual fixture", postings: [
                .init(account: "Expenses:Books", amount: amount, currency: "CNY"),
                .init(account: "Liabilities:Card", amount: "", currency: "")]))
            let preview = try await repository.prepareBookkeeping(draft)
            let text = preview.files.files.compactMap { $0.after.flatMap { String(data: $0, encoding: .utf8) } }.joined()
            if amount == "12.123456789" { XCTAssertTrue(text.contains(amount), text) }
            await repository.discardPrepared(preview)
        }
        #else
        throw XCTSkip("Requires the app-linked iOS Go and canonical Beancount runtimes")
        #endif
    }

    func testCanonicalFailureAndStaleRevisionLeaveWorkspaceUntouched() async throws {
        #if os(iOS)
        let repository = try await repository()
        let initial = try await repository.readFile(path: "main.bean")
        let invalid = BookkeepingDraft.manual(.init(date: "2026-09-18", payee: "Fixture", narration: "Unbalanced fixture", postings: [
            .init(account: "Expenses:Books", amount: "10", currency: "CNY"),
            .init(account: "Liabilities:Card", amount: "-9", currency: "CNY")]))
        do { _ = try await repository.prepareBookkeeping(invalid); XCTFail("Invalid draft passed canonical validator") } catch { }
        let afterFailure = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(initial.revisionID, afterFailure.revisionID)
        let preview = try await repository.prepareBookkeeping(splitDraft)
        try await repository.saveFile(initial, text: initial.text + "; concurrent edit\n")
        do { _ = try await repository.commitPrepared(preview); XCTFail("Stale preview published") }
        catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
        let final = try await repository.readFile(path: "main.bean")
        XCTAssertTrue(final.text.hasSuffix("; concurrent edit\n"))
        let transactions = try await repository.globalTransactions()
        XCTAssertTrue(transactions.transactions.isEmpty)
        #else
        throw XCTSkip("Requires the app-linked iOS Go and canonical Beancount runtimes")
        #endif
    }

    func testBeanImportPreservesBytesAndRejectsDuplicateOrWorkspaceDirectives() async throws {
        #if os(iOS)
        let repository = try await repository()
        let text = """
        ; untouched comment
        2026-09-18 * "Books" "precise" #reading
          purpose: "retain metadata"
          Expenses:Books  1.123456789 CNY
          Liabilities:Card  -1.123456789 CNY

        """
        let preview = try await repository.prepareBeanTransactions(text)
        let mainFile = try XCTUnwrap(preview.files.files.first { $0.path == "main.bean" })
        let afterText = String(decoding: mainFile.after ?? Data(), as: UTF8.self)
        XCTAssertTrue(afterText.contains("Expenses:Books"))
        _ = try await repository.commitPrepared(preview)
        do { _ = try await repository.prepareBeanTransactions(text); XCTFail("Duplicate accepted") } catch { }
        for directive in ["include \"other.bean\"", "plugin \"beancount.plugins.auto_accounts\"", "2020-01-01 open Assets:New CNY"] {
            XCTAssertThrowsError(try BeanTransactionParser.transactionCount(directive + "\n" + text))
        }
        let main = try await repository.readFile(path: "main.bean")
        XCTAssertTrue(main.text.contains("Expenses:Books"))
        XCTAssertTrue(main.text.hasPrefix("; preserve source comment"))
        #else
        throw XCTSkip("Requires the app-linked iOS Go and canonical Beancount runtimes")
        #endif
    }
}
