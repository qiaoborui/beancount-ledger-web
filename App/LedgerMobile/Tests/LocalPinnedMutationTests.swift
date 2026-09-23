import Foundation
import XCTest
@testable import LedgerMobile

final class LocalPinnedMutationTests: XCTestCase {
    private static let source = TransactionSource(file: "main.bean", line: 1, hash: "pinned-source")
    private static let entry = LedgerTransactionEntry(date: "2026-09-23", payee: "Fixture",
        narration: "Pinned edit", postings: [
            .init(account: "Expenses:Food", amount: "1", currency: "CNY"),
            .init(account: "Assets:Cash", amount: "-1", currency: "CNY")])
    private static let stagedBytes = Data("; engine staging write\n".utf8)

    private enum Mutation: CaseIterable, Sendable {
        case update, delete, tags

        var method: String {
            switch self { case .update: "PUT"; case .delete: "DELETE"; case .tags: "POST" }
        }
        var path: String {
            self == .tags ? "/api/ledger/transactions/tags" : "/api/ledger/transactions"
        }
        func body() throws -> BQLCell {
            let encoder = JSONEncoder()
            let data: Data
            switch self {
            case .update:
                data = try encoder.encode(LedgerTransactionUpdateRequest(source: source, entry: entry))
            case .delete:
                data = try encoder.encode(LedgerTransactionDeleteRequest(source: source, reason: "Duplicate fixture"))
            case .tags:
                data = try encoder.encode(LedgerTransactionTagsRequest(sources: [source], tags: ["trip", "fixture"]))
            }
            return try JSONDecoder().decode(BQLCell.self, from: data)
        }
        func apply(_ repository: LocalLedgerRepository, revision: UUID) async throws {
            switch self {
            case .update: try await repository.updateTransaction(source: source, entry: entry, expectedRevisionID: revision)
            case .delete: try await repository.deleteTransaction(source: source, reason: "Duplicate fixture", expectedRevisionID: revision)
            case .tags: try await repository.addTransactionTags(sources: [source], tags: ["trip", "fixture"], expectedRevisionID: revision)
            }
        }
        func applyLegacy(_ repository: any LedgerRepository) async throws {
            switch self {
            case .update: try await repository.updateTransaction(source: source, entry: entry)
            case .delete: try await repository.deleteTransaction(source: source, reason: "Duplicate fixture")
            case .tags: try await repository.addTransactionTags(sources: [source], tags: ["trip", "fixture"])
            }
        }
    }

    private actor Engine: LocalLedgerEngine {
        var mutations: [LocalLedgerEngineRequest] = []
        var malformed = false
        func returnMalformedResponse() { malformed = true }
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
            if request.staging {
                mutations.append(request)
                try stagedBytes.write(to: URL(fileURLWithPath: request.workspaceRoot).appendingPathComponent("main.bean"))
                return Data((malformed ? "not JSON" : #"{"ok":true}"#).utf8)
            }
            guard request.method == "GET", request.path == "/api/ledger/transactions/detail" else {
                throw LocalLedgerError.operationFailed("Unexpected fixture request")
            }
            return Data(#"{"date":"2026-09-23","payee":"Fixture","narration":"Detail","postings":[],"source":{"file":"main.bean","line":1,"hash":"pinned-source"}}"#.utf8)
        }
    }

    private enum ValidationFailure: Error { case rejected }
    private actor Validator {
        var roots: [URL] = []
        var contents: [Data] = []
        var rejects = false
        func reject() { rejects = true }
        func validate(_ root: URL, entry: String) throws {
            roots.append(root)
            contents.append(try Data(contentsOf: root.appendingPathComponent(entry)))
            if rejects { throw ValidationFailure.rejected }
        }
    }

    private struct Fixture: Sendable {
        let workspace: LocalLedgerWorkspace
        let repository: LocalLedgerRepository
        let engine: Engine
        let validator: Validator
        let a: LocalLedgerWorkspace.Revision
        let b: LocalLedgerWorkspace.Revision
    }

    private func fixture(presentB: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = LocalLedgerWorkspace(rootDirectory: root)
        let a = try await workspace.commit(changes: [.write(Data("; original transaction\n".utf8), to: "main.bean")]) { _ in }
        let engine = Engine(), validator = Validator()
        let repository = LocalLedgerRepository(descriptor: .init(id: UUID(), name: "Pinned fixture",
            entrypoint: "main.bean", createdAt: Date()), workspace: workspace, engine: engine,
            validator: { root, entry in try await validator.validate(root, entry: entry) })
        _ = try await repository.transactionDetail(source: Self.source)
        let presentedA = await repository.presentedRevisionID
        XCTAssertEqual(presentedA, a.id)
        let b = try await workspace.commit(expectedRevisionID: a.id,
            changes: [.write(Data("; unrelated commit\n".utf8), to: "unrelated.bean")]) { _ in }
        if presentB {
            _ = try await repository.transactionDetail(source: Self.source)
            let presentedB = await repository.presentedRevisionID
            XCTAssertEqual(presentedB, b.id)
        }
        return Fixture(workspace: workspace, repository: repository, engine: engine, validator: validator, a: a, b: b)
    }

    /// Include the revision pointer and all generation bytes, not just the edited file.
    private func files(_ fixture: Fixture) throws -> [String: Data] {
        let root = fixture.workspace.rootDirectory
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private func assertUnchanged(_ f: Fixture, files before: [String: Data], presented: UUID) async throws {
        let current = try await f.workspace.currentRevision()
        let actualPresented = await f.repository.presentedRevisionID
        XCTAssertEqual(current, f.b)
        XCTAssertEqual(actualPresented, presented)
        XCTAssertEqual(try files(f), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: f.workspace.rootDirectory.appendingPathComponent("staging").path), [])
    }

    private func assertPublished(_ f: Fixture, mutation: Mutation) async throws {
        let current = try await f.workspace.currentRevision()
        let saved = try XCTUnwrap(current)
        XCTAssertNotEqual(saved.id, f.b.id)
        XCTAssertEqual(saved.parentID, f.b.id)
        XCTAssertEqual(saved.changedPaths, ["main.bean"])
        let presented = await f.repository.presentedRevisionID
        XCTAssertEqual(presented, saved.id)
        let main = try await f.workspace.readFile(at: "main.bean")
        let unrelated = try await f.workspace.readFile(at: "unrelated.bean")
        XCTAssertEqual(main, Self.stagedBytes)
        XCTAssertEqual(unrelated, Data("; unrelated commit\n".utf8))
        let requests = await f.engine.mutations
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.path, mutation.path)
        XCTAssertEqual(request.method, mutation.method)
        XCTAssertEqual(request.body, try mutation.body())
        XCTAssertEqual(request.query, [:])
        XCTAssertEqual(request.entrypoint, "main.bean")
        XCTAssertTrue(request.staging)
        XCTAssertTrue(request.workspaceRoot.hasPrefix(f.workspace.rootDirectory.appendingPathComponent("staging").path + "/"))
        let roots = await f.validator.roots
        let contents = await f.validator.contents
        XCTAssertEqual(roots.map(\.path), [request.workspaceRoot])
        XCTAssertEqual(contents, [Self.stagedBytes])
    }

    func testStalePinnedMutationsRejectBeforeEngineEvenAfterLegacyReadPresentsB() async throws {
        for mutation in Mutation.allCases {
            let f = try await fixture()
            let before = try files(f)
            do {
                try await mutation.apply(f.repository, revision: f.a.id)
                XCTFail("Stale pinned \(mutation) succeeded")
            } catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
            let requests = await f.engine.mutations
            let validations = await f.validator.contents
            XCTAssertTrue(requests.isEmpty)
            XCTAssertTrue(validations.isEmpty)
            try await assertUnchanged(f, files: before, presented: f.b.id)
        }
    }

    func testCurrentPinnedMutationsRouteExactRequestsAndValidateRealStageWrites() async throws {
        for mutation in Mutation.allCases {
            let f = try await fixture()
            try await mutation.apply(f.repository, revision: f.b.id)
            try await assertPublished(f, mutation: mutation)
        }
    }

    func testValidatorFailureRollsBackEveryPinnedMutation() async throws {
        for mutation in Mutation.allCases {
            let f = try await fixture()
            await f.validator.reject()
            let before = try files(f)
            do {
                try await mutation.apply(f.repository, revision: f.b.id)
                XCTFail("Rejected stage published")
            } catch { XCTAssertTrue(error is ValidationFailure) }
            let requests = await f.engine.mutations
            let contents = await f.validator.contents
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(contents, [Self.stagedBytes])
            try await assertUnchanged(f, files: before, presented: f.b.id)
        }
    }

    func testMalformedEngineResponseRollsBackBeforeValidation() async throws {
        for mutation in Mutation.allCases {
            let f = try await fixture()
            await f.engine.returnMalformedResponse()
            let before = try files(f)
            do {
                try await mutation.apply(f.repository, revision: f.b.id)
                XCTFail("Malformed response published")
            } catch { XCTAssertTrue(error is DecodingError) }
            let requests = await f.engine.mutations
            let contents = await f.validator.contents
            XCTAssertEqual(requests.count, 1)
            XCTAssertTrue(contents.isEmpty)
            try await assertUnchanged(f, files: before, presented: f.b.id)
        }
    }

    func testCancellationBeforeMutationNeverReachesEngineOrChangesFiles() async throws {
        for mutation in Mutation.allCases {
            let f = try await fixture()
            let before = try files(f)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await mutation.apply(f.repository, revision: f.b.id)
            }
            do { try await task.value; XCTFail("Cancelled mutation succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            let requests = await f.engine.mutations
            let contents = await f.validator.contents
            XCTAssertTrue(requests.isEmpty)
            XCTAssertTrue(contents.isEmpty)
            try await assertUnchanged(f, files: before, presented: f.b.id)
        }
    }

    func testReadOnlyPinnedDetailDoesNotAdvancePresentationButExplicitBMayWrite() async throws {
        for mutation in Mutation.allCases {
            let f = try await fixture(presentB: false)
            let before = try files(f)
            let detail = try await f.repository.transactionDetail(source: Self.source, expectedRevisionID: f.b.id)
            XCTAssertEqual(detail.source, Self.source)
            try await assertUnchanged(f, files: before, presented: f.a.id)
            try await mutation.apply(f.repository, revision: f.b.id)
            try await assertPublished(f, mutation: mutation)
        }
    }

    func testProtocolLegacyMutationsStillUsePresentedRevisionAndSharedValidator() async throws {
        for mutation in Mutation.allCases {
            let f = try await fixture(presentB: false)
            let before = try files(f)
            do { try await mutation.applyLegacy(f.repository); XCTFail("Legacy stale presentation accepted") }
            catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
            try await assertUnchanged(f, files: before, presented: f.a.id)
            _ = try await f.repository.transactionDetail(source: Self.source)
            try await mutation.applyLegacy(f.repository)
            try await assertPublished(f, mutation: mutation)
        }
    }
}
