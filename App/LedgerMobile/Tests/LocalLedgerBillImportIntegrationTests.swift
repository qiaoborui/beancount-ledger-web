import Foundation
import XCTest
@testable import LedgerMobile

/// Uses the app-linked Go importer and canonical Beancount runtime with a
/// synthetic bill. The catalog and every ledger file belong to this test.
final class LocalLedgerBillImportIntegrationTests: XCTestCase {
    func testAlipayPreviewCanonicalRollbackCommitDedupAndReopen() async throws {
        #if os(iOS)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalBillIntegration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = LocalLedgerCatalog(rootDirectory: root)
        let descriptor = try await catalog.create(name: "Offline bill integration")
        let repository = catalog.repository(for: descriptor)
        let visibleFiles = try await repository.files()
        XCTAssertTrue(visibleFiles.contains("main.bean"), "File browser paths: \(visibleFiles)")
        let file = LedgerImportSelectedFile(name: "synthetic-alipay.csv", data: Self.alipayCSV)
        let initialRevision = try await repository.workspace.currentRevision()
        let initialFiles = try await Self.committedFiles(repository)

        let providers = try await repository.importProviders()
        XCTAssertTrue(providers.contains { $0.id == "alipay" })
        let preview = try await repository.previewImport(file: file, provider: "alipay",
            alipayFundRounding: false, archivePassword: "")
        XCTAssertEqual(preview.provider, "alipay")
        XCTAssertEqual(preview.originalFilename, file.name)
        XCTAssertEqual(preview.generatedCount, 1)
        XCTAssertEqual(preview.candidateCount, 1)
        XCTAssertEqual(preview.skippedDuplicateCount, 0)
        XCTAssertEqual(preview.entries.count, 1)
        let proposed = try XCTUnwrap(preview.entries.first)
        XCTAssertEqual(proposed.amount, 6.50, accuracy: 0.001)
        XCTAssertEqual(proposed.orderID, "offline-import-order-1")
        let afterPreviewRevision = try await repository.workspace.currentRevision()
        let afterPreviewFiles = try await Self.committedFiles(repository)
        XCTAssertEqual(initialRevision?.id, afterPreviewRevision?.id)
        XCTAssertEqual(initialFiles, afterPreviewFiles)

        let reviewed = proposed.applyingReviewEdits(date: "2026-05-24", flag: "*",
            payee: "Offline fixture shop", narration: "Reviewed bill import", amount: 6.50,
            categoryAccount: "Expenses:Food", fundingAccount: "Assets:Bank", tags: ["offline-import"])
        // Both accounts open in 1970. This syntactically valid transaction
        // reaches canonical validation and must fail the account-date check.
        let invalid = reviewed.applyingReviewEdits(date: "1969-12-31", flag: reviewed.flag,
            payee: reviewed.payee, narration: reviewed.narration, amount: reviewed.amount,
            categoryAccount: reviewed.categoryAccount, fundingAccount: reviewed.fundingAccount)
        var canonicalRejected = false
        do {
            _ = try await repository.commitImport(request: .init(importID: preview.importID,
                provider: preview.provider, entries: [invalid]))
        } catch let error as EmbeddedBeancountValidator.ValidationError {
            canonicalRejected = true
            XCTAssertFalse(error.message.isEmpty)
        }
        XCTAssertTrue(canonicalRejected, "Canonical validation must reject a transaction before account opening")
        let afterInvalidRevision = try await repository.workspace.currentRevision()
        let afterInvalidFiles = try await Self.committedFiles(repository)
        let afterInvalidTransactions = try await repository.globalTransactions()
        let afterInvalidDocuments = try await repository.importDocuments()
        XCTAssertEqual(initialRevision?.id, afterInvalidRevision?.id)
        XCTAssertEqual(initialFiles, afterInvalidFiles)
        XCTAssertTrue(afterInvalidTransactions.transactions.isEmpty)
        XCTAssertTrue(afterInvalidDocuments.isEmpty)

        // Reuse the same preview after rejection. This also verifies its
        // temporary source survives a discarded staging transaction.
        let committed = try await repository.commitImport(request: .init(importID: preview.importID,
            provider: preview.provider, entries: [reviewed]))
        XCTAssertTrue(committed.ok)
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.readModelPending, false)
        XCTAssertNil(committed.indexGitSHA)
        XCTAssertNil(committed.runtimeCleanupError)
        let committedRevision = try await repository.workspace.currentRevision()
        XCTAssertNotEqual(initialRevision?.id, committedRevision?.id)
        let transactions = try await repository.globalTransactions()
        XCTAssertEqual(transactions.transactions.count, 1)
        let transaction = try XCTUnwrap(transactions.transactions.first)
        XCTAssertEqual(transaction.date, "2026-05-24")
        XCTAssertEqual(transaction.payee, reviewed.payee)
        XCTAssertEqual(transaction.narration, reviewed.narration)
        XCTAssertEqual(Set(transaction.postings.map(\.account)), ["Expenses:Food", "Assets:Bank"])
        XCTAssertFalse(transaction.source.file.hasPrefix("/"))
        let committedFiles = try await Self.committedFiles(repository)
        let importedBean = try XCTUnwrap(committedFiles[transaction.source.file],
            "Expected \(transaction.source.file); snapshot keys: \(committedFiles.keys.sorted())")
        XCTAssertTrue(String(decoding: importedBean, as: UTF8.self).contains("offline-import-order-1"))
        let documents = try await repository.importDocuments()
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents.first?.provider, "alipay")
        let archivedBills = committedFiles.filter { $0.key.hasSuffix(".csv") }
        XCTAssertEqual(archivedBills.count, 1)
        XCTAssertEqual(archivedBills.first?.value, file.data)

        let duplicate = try await repository.previewImport(file: file, provider: "alipay",
            alipayFundRounding: false, archivePassword: "")
        XCTAssertEqual(duplicate.generatedCount, 1)
        XCTAssertEqual(duplicate.skippedDuplicateCount, 1)
        XCTAssertEqual(duplicate.candidateCount, 0)
        XCTAssertTrue(duplicate.entries.isEmpty)
        let afterDuplicateRevision = try await repository.workspace.currentRevision()
        let afterDuplicateFiles = try await Self.committedFiles(repository)
        XCTAssertEqual(committedRevision?.id, afterDuplicateRevision?.id)
        XCTAssertEqual(committedFiles, afterDuplicateFiles)

        let reopenedCatalog = LocalLedgerCatalog(rootDirectory: root)
        let descriptors = try await reopenedCatalog.list()
        XCTAssertEqual(descriptors, [descriptor])
        let restored = reopenedCatalog.repository(for: descriptor)
        let restoredTransactions = try await restored.globalTransactions()
        let restoredDocuments = try await restored.importDocuments()
        let restoredFiles = try await Self.committedFiles(restored)
        XCTAssertEqual(restoredTransactions.transactions.count, 1)
        XCTAssertEqual(restoredTransactions.transactions.first?.source, transaction.source)
        XCTAssertEqual(restoredTransactions.transactions.first?.narration, reviewed.narration)
        XCTAssertEqual(restoredDocuments, documents)
        XCTAssertEqual(restoredFiles, committedFiles)
        try await restored.workspace.withCurrentSnapshot { _, snapshot in
            try await EmbeddedBeancountValidator.shared.validate(workspace: snapshot, entryFile: descriptor.entrypoint)
        }
        #else
        throw XCTSkip("Requires the app-linked iOS Go importer and canonical Beancount runtime")
        #endif
    }

    #if os(iOS)
    private static func committedFiles(_ repository: LocalLedgerRepository) async throws -> [String: Data] {
        try await repository.workspace.withCurrentSnapshot { _, root in
            let root = root.resolvingSymlinksInPath().standardizedFileURL
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey]))
            var files: [String: Data] = [:]
            while let url = enumerator.nextObject() as? URL {
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    let normalized = url.standardizedFileURL
                    XCTAssertTrue(normalized.path.hasPrefix(root.path + "/"))
                    let relative = String(normalized.path.dropFirst(root.path.count + 1))
                    files[relative] = try Data(contentsOf: url)
                }
            }
            return files
        }
    }

    private static let alipayCSV = Data([
        "------------------------------------------------------------------------------------",
        "导出信息：",
        "姓名：离线测试用户",
        "支付宝账户：offline-fixture@example.invalid",
        "起始时间：[2026-05-24 00:00:00]    终止时间：[2026-05-24 23:59:59]",
        "导出交易类型：[全部]",
        "导出时间：[2026-05-24 23:24:06]",
        "共1笔记录",
        "收入：0笔 0.00元",
        "支出：1笔 6.50元",
        "不计收支：0笔 0.00元",
        "",
        "特别提示：",
        "1.测试提示", "2.测试提示", "3.测试提示", "4.测试提示",
        "5.测试提示", "6.测试提示", "7.测试提示", "8.测试提示",
        "",
        "------------------------支付宝支付科技有限公司  电子客户回单------------------------",
        "交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注,",
        "2026-05-24 17:55:17,日用百货,离线测试商店,fixture-account,测试零食,支出,6.50,储蓄卡,交易成功,offline-import-order-1,offline-merchant-1,,",
    ].joined(separator: "\n").utf8)
    #endif
}
