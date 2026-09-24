import Foundation
import XCTest
@testable import LedgerMobile

final class LocalLedgerRepositoryTests: XCTestCase {
    func testPreparedImportRetainsOriginalUntilExactChangeIsConfirmed() async throws {
        let engine = Engine()
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: engine, validator: { root, entry in
            _ = try Data(contentsOf: root.appendingPathComponent(entry))
        })
        let descriptor = try await catalog.create(name: "Prepared import fixture")
        let repository = catalog.repository(for: descriptor)
        let source = try await repository.previewImport(file: .init(name: "prepared", data: Data("fixture".utf8)),
            provider: "alipay", alipayFundRounding: false, archivePassword: "")
        let before = try await repository.readFile(path: "main.bean")
        await engine.configure(text: "; prepared archive\n", response: Data(#"{"ok":true,"count":0}"#.utf8))
        let preview = try await repository.prepareImport(.init(importID: source.importID, provider: "alipay", entries: []))
        let original = repository.workspace.rootDirectory.appendingPathComponent("runtime/imports/prepared/original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let unchanged = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(unchanged.text, before.text)
        XCTAssertEqual(unchanged.revisionID, before.revisionID)
        let result = try await repository.commitPrepared(preview)
        XCTAssertEqual(result?.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let saved = try await repository.readFile(path: "main.bean")
        XCTAssertTrue(saved.text.hasSuffix("; prepared archive\n"))
    }

    func testEnvelopeFailuresAfterStageWriteNeverPublish() async throws {
        actor EnvelopeEngine: LocalLedgerEngine {
            let legacy = Engine()
            var failure = Data(#"{"ok":false,"status":400,"result":{"error":"synthetic rejection"}}"#.utf8)
            func configure(_ raw: String) { failure = Data(raw.utf8) }
            func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
                try await legacy.dispatch(request)
            }
            func response(_ request: LocalLedgerEngineRequest) async throws -> LocalLedgerResponse {
                let result = try await legacy.dispatch(request)
                return request.staging ? LocalLedgerResponse(envelope: failure) : LocalLedgerResponse(result: result)
            }
        }
        let engine = EnvelopeEngine()
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: engine, validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Envelope rollback")
        let repository = catalog.repository(for: descriptor)
        _ = try await repository.runBQL(query: "SELECT 1", valuationCurrency: "CNY")
        let before = try await repository.readFile(path: "main.bean")
        let entry = LedgerTransactionEntry(date: "2026-09-15", payee: "", narration: "Synthetic", postings: [.init(account: "Expenses:Food", amount: "1", currency: "CNY"), .init(account: "Assets:Cash", amount: "-1", currency: "CNY")])
        for raw in [#"{"ok":false,"status":400,"result":{"error":"synthetic rejection"}}"#,
                    #"{"ok":"true","status":200,"result":{}}"#, "invalid JSON"] {
            await engine.configure(raw)
            do {
                try await repository.addTransaction(entry: entry)
                XCTFail("Failed envelope published a financial write")
            } catch { }
            let after = try await repository.readFile(path: "main.bean")
            XCTAssertEqual(after.revisionID, before.revisionID)
            XCTAssertEqual(after.text, before.text)
            do {
                _ = try await repository.prepareBookkeeping(.manual(entry))
                XCTFail("Failed envelope produced a preview")
            } catch { }
            let afterPreview = try await repository.readFile(path: "main.bean")
            XCTAssertEqual(afterPreview.revisionID, before.revisionID)
        }
    }

    func testNativePagePreservesCursorFiltersAndRequiredArrays() async throws {
        actor PageEngine: LocalLedgerEngine {
            var last: LocalLedgerEngineRequest?
            func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
                last = request
                return Data(#"{"revision":"one","transactions":[],"nextCursor":"opaque-next","sensitiveUnlocked":true}"#.utf8)
            }
        }
        let engine = PageEngine()
        let workspace = LocalLedgerWorkspace(rootDirectory: try root())
        _ = try await workspace.commit(changes: [.write(Data(";fixture".utf8), to: "main.bean")]) { _ in }
        let descriptor = LocalLedgerDescriptor(id: UUID(), name: "Page", entrypoint: "main.bean", createdAt: Date())
        let repository = LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: engine, validator: { _, _ in })
        let page = try await repository.transactionPage(query: "payee:shop", cursor: "opaque-before", limit: 25)
        XCTAssertEqual(page.revision, "one")
        XCTAssertEqual(page.nextCursor, "opaque-next")
        XCTAssertEqual(page.transactions, [])
        let request = await engine.last
        XCTAssertEqual(request?.path, "/api/ledger/transactions/page")
        XCTAssertEqual(request?.query["q"], "payee:shop")
        XCTAssertEqual(request?.query["cursor"], "opaque-before")
        XCTAssertEqual(request?.query["limit"], "25")
        _ = try await repository.classificationHistoryPage(cursor: "history-cursor")
        let evidenceRequest = await engine.last
        XCTAssertEqual(evidenceRequest?.path, "/api/ledger/transactions/history-page")
        XCTAssertEqual(evidenceRequest?.query["cursor"], "history-cursor")
        XCTAssertEqual(evidenceRequest?.query["limit"], "500")
        do { _ = try await repository.transactionPage(limit: 501); XCTFail("oversized page accepted") }
        catch is LocalLedgerError { }
    }

    func testNativeDetailUsesExactLocatorAndRichPayload() async throws {
        actor DetailEngine: LocalLedgerEngine {
            var last: LocalLedgerEngineRequest?
            func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
                last = request
                return Data(#"{"date":"2026-09-01","payee":"Synthetic","narration":"detail","metadata":{"method":"Cash"},"postings":[],"source":{"file":"main.bean","line":1,"hash":"exact"}}"#.utf8)
            }
        }
        let engine = DetailEngine()
        let workspace = LocalLedgerWorkspace(rootDirectory: try root())
        _ = try await workspace.commit(changes: [.write(Data("; fixture".utf8), to: "main.bean")]) { _ in }
        let descriptor = LocalLedgerDescriptor(id: UUID(), name: "Detail", entrypoint: "main.bean", createdAt: Date())
        let repository = LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: engine, validator: { _, _ in })
        let source = TransactionSource(file: "main.bean", line: 1, hash: "exact")
        let detail = try await repository.transactionDetail(source: source)
        XCTAssertEqual(detail.source, source)
        XCTAssertEqual(detail.metadata?["method"], .string("Cash"))
        let request = await engine.last
        XCTAssertEqual(request?.path, "/api/ledger/transactions/detail")
        XCTAssertEqual(request?.query["hash"], "exact")
        XCTAssertEqual(request?.query["line"], "1")
    }

    private actor CommitGateStorage: LogicalLocalStorage {
        nonisolated let workspace: LocalLedgerWorkspace
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var committed: LocalLedgerWorkspace.Revision?
        init(workspace: LocalLedgerWorkspace, entered: XCTestExpectation) {
            self.workspace = workspace; self.entered = entered
        }
        func didCommit(_ revision: LocalLedgerWorkspace.Revision) async {
            committed = revision
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
        }
        func release() { continuation?.resume(); continuation = nil }
        func status() async throws -> LocalStorageSyncStatus { .init(mode: .device, phase: .localOnly) }
        func synchronize(validator: @escaping LocalLedgerWorkspace.Validator) async throws -> LocalStorageSyncStatus {
            try await status()
        }
    }

    func testExplicitMutationReceiptsNameValidatedCommittedGeneration() async throws {
        let engine = Engine()
        let workspace = LocalLedgerWorkspace(rootDirectory: try root())
        var current = try await workspace.commit(changes: [.write(Data("; synthetic\n".utf8), to: "main.bean")]) { _ in }
        let descriptor = LocalLedgerDescriptor(id: UUID(), name: "Receipt fixture", entrypoint: "main.bean", createdAt: Date())
        let repository = LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: engine,
            validator: { _, _ in })
        let source = TransactionSource(file: "main.bean", line: 1, hash: "synthetic")
        let entry = LedgerTransactionEntry(date: "2026-09-24", payee: "Synthetic", narration: "receipt", postings: [])
        for operation in 0..<3 {
            let before = current
            let receipt: LocalLedgerRepository.TransactionCommitReceipt
            switch operation {
            case 0: receipt = try await repository.updateTransaction(source: source, entry: entry, expectedRevisionID: before.id)
            case 1: receipt = try await repository.addTransactionTags(sources: [source], tags: ["synthetic"], expectedRevisionID: before.id)
            default: receipt = try await repository.deleteTransaction(source: source, reason: "Synthetic", expectedRevisionID: before.id)
            }
            let actual = try await workspace.currentRevision()
            current = try XCTUnwrap(actual)
            XCTAssertEqual(receipt.ledgerID, descriptor.id)
            XCTAssertEqual(receipt.baseRevisionID, before.id)
            XCTAssertEqual(receipt.revisionID, current.id)
            XCTAssertEqual(current.parentID, before.id)
            XCTAssertNotEqual(receipt.revisionID, receipt.baseRevisionID)
        }
        let requests = await engine.requests.filter(\.staging)
        XCTAssertEqual(requests.map(\.method), ["PUT", "POST", "DELETE"])
    }

    func testReceiptRemainsExactAfterConcurrentRevisionReadAndPostCommitCancellation() async throws {
        let workspace = LocalLedgerWorkspace(rootDirectory: try root())
        let before = try await workspace.commit(changes: [.write(Data("; synthetic\n".utf8), to: "main.bean")]) { _ in }
        let entered = expectation(description: "receipt committed before storage acknowledgement")
        let storage = CommitGateStorage(workspace: workspace, entered: entered)
        let descriptor = LocalLedgerDescriptor(id: UUID(), name: "Receipt race", entrypoint: "main.bean", createdAt: Date())
        let repository = LocalLedgerRepository(descriptor: descriptor, storage: storage, engine: Engine(), validator: { _, _ in })
        let operation = Task {
            try await repository.deleteTransaction(source: .init(file: "main.bean", line: 1, hash: "synthetic"),
                reason: "Synthetic", expectedRevisionID: before.id)
        }
        await fulfillment(of: [entered], timeout: 3)
        let committed = await storage.committed
        let committedRevision = try XCTUnwrap(committed)
        let newer = try await workspace.commit(expectedRevisionID: committedRevision.id,
            changes: [.write(Data("; later generation\n".utf8), to: "main.bean")]) { _ in }
        // Ordinary read advances mutable authority while the first operation is
        // suspended. A receipt must not borrow that newer value.
        _ = try await repository.runBQL(query: "SELECT 1", valuationCurrency: "CNY")
        let presented = await repository.presentedRevisionID
        XCTAssertEqual(presented, newer.id)
        operation.cancel() // Commit already happened: do not falsely report rollback.
        await storage.release()
        let receipt = try await operation.value
        XCTAssertEqual(receipt.baseRevisionID, before.id)
        XCTAssertEqual(receipt.revisionID, committedRevision.id)
        XCTAssertNotEqual(receipt.revisionID, newer.id)
    }

    func testReceiptIsNotReturnedForStaleFailedValidationOrMalformedMutation() async throws {
        for failure in 0..<3 {
            let engine = Engine()
            let workspace = LocalLedgerWorkspace(rootDirectory: try root())
            let before = try await workspace.commit(changes: [.write(Data("; synthetic\n".utf8), to: "main.bean")]) { _ in }
            let descriptor = LocalLedgerDescriptor(id: UUID(), name: "Receipt rollback", entrypoint: "main.bean", createdAt: Date())
            let repository = LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: engine,
                validator: { _, _ in
                    if failure == 1 { throw LocalLedgerError.operationFailed("Synthetic canonical rejection") }
                })
            if failure == 2 { await engine.configure(text: "; changed\n", response: Data("invalid JSON".utf8)) }
            do {
                _ = try await repository.deleteTransaction(source: .init(file: "main.bean", line: 1, hash: "synthetic"),
                    reason: "Synthetic", expectedRevisionID: failure == 0 ? UUID() : before.id)
                XCTFail("failed operation returned a receipt")
            } catch {}
            let after = try await workspace.currentRevision()
            XCTAssertEqual(after?.id, before.id)
            let authority = await repository.presentedRevisionID
            XCTAssertNil(authority)
        }
    }

    private actor Engine: LocalLedgerEngine {
        var requests: [LocalLedgerEngineRequest] = []
        var mutationText = "; accepted\n"
        var mutationResponse = Data("{\"ok\":true}".utf8)
        var readabilityError: String?
        func rejectReadability(_ message: String) { readabilityError = message }
        func configure(text: String, response: Data = Data("{\"ok\":true}".utf8)) {
            mutationText = text
            mutationResponse = response
        }
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            requests.append(request)
            if request.path == "/api/ledger/version" {
                if let readabilityError { throw LocalLedgerError.operationFailed(readabilityError) }
                return Data("{}".utf8)
            }
            if request.path == "/api/ledger/imports/preview" {
                let id = (request.importFile?.name ?? "preview").replacingOccurrences(of: ".", with: "-")
                let runtime = URL(fileURLWithPath: request.runtimeRoot).appendingPathComponent("imports/" + id)
                try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
                try Data("synthetic original".utf8).write(to: runtime.appendingPathComponent("original"))
                return try JSONSerialization.data(withJSONObject: [
                    "importId": id, "provider": "alipay",
                    "providerDetection": ["provider": "alipay", "reason": "fixture", "confidence": "high"],
                    "originalFilename": id, "dedupReport": "", "entries": [],
                    "candidateCount": 0, "rawRowCount": 0, "filteredRowCount": 0,
                    "generatedCount": 0, "excludedRowCount": 0, "skippedDuplicateCount": 0, "warnings": [],
                ])
            }
            if request.staging {
                let file = URL(fileURLWithPath: request.workspaceRoot).appendingPathComponent(request.entrypoint)
                var content = try Data(contentsOf: file)
                content.append(Data(mutationText.utf8))
                try content.write(to: file)
                return mutationResponse
            }
            return Data("{\"columns\":[],\"rows\":[],\"query\":\"SELECT 1\",\"valuationCurrency\":\"CNY\",\"limit\":100,\"rowCount\":0}".utf8)
        }
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalLedgerRepositoryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func validator(_ root: URL, _ entry: String) async throws {
        let text = try String(contentsOf: root.appendingPathComponent(entry), encoding: .utf8)
        if text.contains("INVALID") { throw LocalLedgerError.operationFailed("canonical validation rejected fixture") }
    }

    func testCatalogPersistsRealEmptyLedgerAndExportsCurrentGeneration() async throws {
        let directory = try root()
        let catalog = LocalLedgerCatalog(rootDirectory: directory, engine: Engine(), validator: { root, entry in
            _ = try Data(contentsOf: root.appendingPathComponent(entry))
        })
        let descriptor = try await catalog.create(name: "本地账本")
        let reopened = LocalLedgerCatalog(rootDirectory: directory)
        let records = try await reopened.list()
        XCTAssertEqual(records, [descriptor])
        let repository = catalog.repository(for: descriptor)
        let draft = try await repository.readFile(path: "main.bean")
        XCTAssertTrue(draft.text.contains("option \"operating_currency\" \"CNY\""))
        XCTAssertTrue(draft.text.contains("open Assets:Cash"))
        XCTAssertTrue(draft.text.contains("1970-01-01 commodity CNY"))
        XCTAssertFalse(draft.text.contains(" * "))
        let exported = try await repository.exportLedger()
        defer { try? FileManager.default.removeItem(at: exported) }
        XCTAssertEqual(try String(contentsOf: exported.appendingPathComponent("main.bean"), encoding: .utf8), draft.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.appendingPathComponent("ledger.json").path))
    }

    func testFailedValidationPublishesNoCatalogEntry() async throws {
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: Engine(), validator: { _, _ in
            throw LocalLedgerError.operationFailed("canonical error")
        })
        do {
            _ = try await catalog.create(name: "Invalid")
            XCTFail("Invalid ledger must fail closed")
        } catch { XCTAssertEqual(error as? LocalLedgerError, .operationFailed("canonical error")) }
        let records = try await catalog.list()
        XCTAssertTrue(records.isEmpty)
    }

    func testCatalogPublicationUsesWorkspaceNormalizedRoot() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CatalogPath-" + UUID().uuidString)
        let path = temporary.path.hasPrefix("/var/") ? "/private" + temporary.path : temporary.path
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = Engine()
        let catalog = LocalLedgerCatalog(rootDirectory: directory, engine: engine, validator: { _, _ in })
        _ = try await catalog.create(name: "Path contract fixture")
        let requests = await engine.requests
        let request = try XCTUnwrap(requests.first { $0.path == "/api/ledger/version" })
        // Compare raw bridge strings: URL normalization here could hide the bug.
        let ledgerPath = "/" + request.workspaceRoot.split(separator: "/").dropLast(3).joined(separator: "/")
        XCTAssertEqual(request.runtimeRoot, ledgerPath + "/runtime")
    }

    func testLedgerExportExcludesImportedGitMetadataAndPreservesWorkspace() async throws {
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: Engine(), validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Export fixture")
        let repository = catalog.repository(for: descriptor)
        let revision = try await repository.workspace.currentRevision()
        let metadata = Data("[remote \"origin\"]\nurl = https://fixture.invalid/ledger.git\n".utf8)
        try await repository.workspace.commit(expectedRevisionID: revision?.id,
            changes: [.write(metadata, to: ".git/config"), .write(metadata, to: "nested/.git/config")]) { _ in }
        let exported = try await repository.exportLedger()
        defer { try? FileManager.default.removeItem(at: exported) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("main.bean").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.appendingPathComponent(".git").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.appendingPathComponent("nested/.git").path))
        try await repository.workspace.withCurrentSnapshot { _, root in
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), metadata)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("nested/.git/config")), metadata)
        }
    }

    func testTextSaveRejectsStalePreviewAndPreservesCommittedTextOnValidationFailure() async throws {
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: Engine(), validator: { root, entry in
            if try String(contentsOf: root.appendingPathComponent(entry), encoding: .utf8).contains("INVALID") {
                throw LocalLedgerError.operationFailed("canonical error")
            }
        })
        let descriptor = try await catalog.create(name: "Test")
        let repository = catalog.repository(for: descriptor)
        let draft = try await repository.readFile(path: "main.bean")
        try await repository.saveFile(draft, text: draft.text + "; saved\n")
        do {
            try await repository.saveFile(draft, text: draft.text + "; stale\n")
            XCTFail("Stale preview accepted")
        } catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
        let current = try await repository.readFile(path: "main.bean")
        do {
            try await repository.saveFile(current, text: "INVALID")
            XCTFail("Invalid text accepted")
        } catch {}
        let after = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(after.text, current.text)
        XCTAssertEqual(after.revisionID, current.revisionID)
    }

    func testFinancialMutationRunsInsideStageAndCanonicalFailureLeavesCurrentGenerationIntact() async throws {
        let engine = Engine()
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: engine, validator: { root, entry in
            if try String(contentsOf: root.appendingPathComponent(entry), encoding: .utf8).contains("INVALID") {
                throw LocalLedgerError.operationFailed("canonical error")
            }
        })
        let descriptor = try await catalog.create(name: "Test")
        let repository = catalog.repository(for: descriptor)
        _ = try await repository.runBQL(query: "SELECT 1", valuationCurrency: "CNY")
        let before = try await repository.readFile(path: "main.bean")
        await engine.configure(text: "INVALID")
        let entry = LedgerTransactionEntry(date: "2026-09-15", payee: "", narration: "Test", metadata: [:], tags: [], postings: [])
        do {
            try await repository.addTransaction(entry: entry)
            XCTFail("Mutation skipped validation")
        } catch {}
        let afterFailure = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(before.text, afterFailure.text)
        XCTAssertEqual(before.revisionID, afterFailure.revisionID)
        await engine.configure(text: "; accepted\n")
        try await repository.addTransaction(entry: entry)
        let afterSuccess = try await repository.readFile(path: "main.bean")
        XCTAssertTrue(afterSuccess.text.hasSuffix("; accepted\n"))
        let revision = try await repository.workspace.currentRevision()
        XCTAssertEqual(revision?.changedPaths, ["main.bean"])
        let writes = await engine.requests.filter(\.staging)
        XCTAssertEqual(writes.count, 2)
        XCTAssertTrue(writes.allSatisfy { $0.workspaceRoot.contains("/staging/") && $0.workspaceRoot.hasSuffix("/workspace") })
    }

    func testSecureFileDraftRejectsSymbolicLinkInsideCommittedGeneration() async throws {
        let directory = try root()
        let catalog = LocalLedgerCatalog(rootDirectory: directory.appendingPathComponent("managed"), engine: Engine(), validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Test")
        let repository = catalog.repository(for: descriptor)
        let outside = directory.appendingPathComponent("outside.bean")
        try Data("private outside ledger".utf8).write(to: outside)
        try await repository.workspace.withCurrentSnapshot { _, root in
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.bean"), withDestinationURL: outside)
        }
        do {
            _ = try await repository.readFile(path: "alias.bean")
            XCTFail("Symbolic link read escaped ledger")
        } catch let error as LocalLedgerWorkspace.WorkspaceError {
            switch error {
            case .symbolicLink, .corruptRevision: break
            default: XCTFail("Expected rejection of modified tree: \(error)")
            }
        }
    }

    func testStagedMutationRevisionIncludesCreatedAndRemovedFiles() async throws {
        let workspace = LocalLedgerWorkspace(rootDirectory: try root())
        let initial = try await workspace.commit(changes: [
            .write(Data("stable".utf8), to: "main.bean"),
            .write(Data("removed".utf8), to: "remove.bean"),
        ], validator: { _ in })
        let revision = try await workspace.commit(expectedRevisionID: initial.id, changes: [], mutateStage: { root in
            try FileManager.default.removeItem(at: root.appendingPathComponent("remove.bean"))
            try Data("created".utf8).write(to: root.appendingPathComponent("new.bean"))
        }, validator: { _ in })
        XCTAssertEqual(revision.changedPaths, ["new.bean", "remove.bean"])
    }

    func testImportCopiesDirectoryAndValidatesEntrypointBeforeCatalogPublication() async throws {
        let directory = try root()
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("; imported\n".utf8).write(to: source.appendingPathComponent("custom.bean"))
        let catalog = LocalLedgerCatalog(rootDirectory: directory.appendingPathComponent("managed"), engine: Engine(), validator: { root, entry in
            _ = try Data(contentsOf: root.appendingPathComponent(entry))
        })
        let descriptor = try await catalog.importLedger(from: source, name: "Imported", entrypoint: "custom.bean")
        try Data("; source changed\n".utf8).write(to: source.appendingPathComponent("custom.bean"))
        let draft = try await catalog.repository(for: descriptor).readFile(path: "custom.bean")
        XCTAssertEqual(draft.text, "; imported\n")
        do {
            _ = try await catalog.importLedger(from: source, name: "Traversal", entrypoint: "../custom.bean")
            XCTFail("Traversal accepted")
        } catch {}
    }

    func testEachImportPreviewKeepsItsOwnRevisionAcrossAnotherPreview() async throws {
        let engine = Engine()
        await engine.configure(text: "; imported\n", response: Data("{\"ok\":true,\"count\":0}".utf8))
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: engine, validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Import revision test")
        let repository = catalog.repository(for: descriptor)
        let first = try await repository.previewImport(file: .init(name: "first.csv", data: Data()),
            provider: "alipay", alipayFundRounding: false, archivePassword: "")
        let draft = try await repository.readFile(path: "main.bean")
        try await repository.saveFile(draft, text: draft.text + "; changed after first preview\n")
        let second = try await repository.previewImport(file: .init(name: "second.csv", data: Data()),
            provider: "alipay", alipayFundRounding: false, archivePassword: "")
        do {
            _ = try await repository.commitImport(request: .init(importID: first.importID, provider: first.provider, entries: []))
            XCTFail("Another import preview replaced the first preview's expected revision")
        } catch {
            XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision)
        }
        let writesBeforeValidCommit = await engine.requests.filter(\.staging)
        XCTAssertTrue(writesBeforeValidCommit.isEmpty)
        let result = try await repository.commitImport(request: .init(importID: second.importID, provider: second.provider, entries: []))
        XCTAssertTrue(result.ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.workspace.rootDirectory
            .appendingPathComponent("runtime/imports/" + second.importID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.workspace.rootDirectory
            .appendingPathComponent("runtime/imports/" + first.importID + "/original").path))
        do {
            _ = try await repository.commitImport(request: .init(importID: second.importID, provider: second.provider, entries: []))
            XCTFail("Committed preview remained reusable")
        } catch { XCTAssertEqual(error as? LocalLedgerError, .previewRequired) }
    }

    func testReopenedReadOnlyRepositoryExpiresAbandonedPreview() async throws {
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: Engine(), validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Retention fixture")
        let repository = catalog.repository(for: descriptor)
        let preview = try await repository.previewImport(file: .init(name: "abandoned", data: Data()),
            provider: "alipay", alipayFundRounding: false, archivePassword: "")
        let directory = repository.workspace.rootDirectory.appendingPathComponent("runtime/imports/" + preview.importID)
        for item in [directory.appendingPathComponent("original"), directory] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)],
                ofItemAtPath: item.path)
        }
        let reopened = catalog.repository(for: descriptor)
        _ = try await reopened.runBQL(query: "SELECT 1", valuationCurrency: "CNY")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testUnreadableCreateAndImportPublishNoDescriptorOrRevision() async throws {
        let directory = try root()
        let engine = Engine()
        await engine.rejectReadability("ledger include must be a regular file of at most 8 MiB")
        let catalogRoot = directory.appendingPathComponent("managed")
        let catalog = LocalLedgerCatalog(rootDirectory: catalogRoot, engine: engine, validator: { _, _ in })
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("; valid canonical source\n".utf8).write(to: source.appendingPathComponent("main.bean"))
        for importing in [false, true] {
            do {
                if importing { _ = try await catalog.importLedger(from: source, name: "Unreadable") }
                else { _ = try await catalog.create(name: "Unreadable") }
                XCTFail("Read-engine rejection published a local ledger")
            } catch {
                XCTAssertEqual(error as? LocalLedgerError,
                    .operationFailed("ledger include must be a regular file of at most 8 MiB"))
            }
        }
        let descriptors = try await catalog.list()
        XCTAssertTrue(descriptors.isEmpty)
        let children = try FileManager.default.contentsOfDirectory(at: catalogRoot, includingPropertiesForKeys: nil)
        for child in children {
            XCTAssertFalse(FileManager.default.fileExists(atPath: child.appendingPathComponent("current.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: child.appendingPathComponent("ledger.json").path))
        }
    }

    func testUnreadableFileEditPreservesCurrentGeneration() async throws {
        let engine = Engine()
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: engine, validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Readable ledger")
        let repository = catalog.repository(for: descriptor)
        let before = try await repository.readFile(path: "main.bean")
        await engine.rejectReadability("read limit exceeded")
        do {
            try await repository.saveFile(before, text: before.text + "; canonical valid but too large\n")
            XCTFail("File edit bypassed the read-engine limit")
        } catch { XCTAssertEqual(error as? LocalLedgerError, .operationFailed("read limit exceeded")) }
        let after = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(after.revisionID, before.revisionID)
        XCTAssertEqual(after.text, before.text)
    }
}
