import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerAgentCloudSyncTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("LedgerAgentCloudSyncTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// One device's runtime/ and its engine against the shared folder.
    private struct Device {
        let runtime: URL
        let engine: LedgerAgentSyncEngine

        func write(_ path: String, _ text: String) throws {
            let url = runtime.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }

        func read(_ path: String) -> String? {
            (try? Data(contentsOf: runtime.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
        }

        func remove(_ path: String) throws {
            try FileManager.default.removeItem(at: runtime.appendingPathComponent(path))
        }

        @discardableResult
        func sync() async throws -> LedgerAgentSyncReport {
            let runtime = runtime
            return try await engine.run { LedgerAgentSyncEngine.applyLocally($0, runtime: runtime) }
        }
    }

    private func device(_ name: String, root: URL, remote: URL) throws -> Device {
        let runtime = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        return Device(runtime: runtime, engine: LedgerAgentSyncEngine(runtime: runtime, remote: remote, identity: "ledger|folder"))
    }

    private func record(_ id: UUID, title: String, updatedAt: Date) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let saved = LedgerAgentSavedConversation(id: id, createdAt: Date(timeIntervalSince1970: 0), updatedAt: updatedAt,
            messages: [.init(role: "user", text: title)])
        return String(decoding: try! encoder.encode(saved), as: UTF8.self)
    }

    func testFreshInstallRestoresHistoryMemoryAndAttachments() async throws {
        let root = try directory()
        let remote = root.appendingPathComponent("folder/files", isDirectory: true)
        let phone = try device("phone", root: root, remote: remote)
        let id = UUID()
        try phone.write("agent-history/\(id.uuidString).json", record(id, title: "上个月吃饭花了多少", updatedAt: Date()))
        try phone.write("agent-history/\(id.uuidString).transcript", "transcript")
        try phone.write("agent-attachments/\(id.uuidString)/statement.csv", "a,b")
        try phone.write("agent-memory.md", "- 美团记 Expenses:Food\n")
        try phone.write("agent-starters.json", "[]")
        let first = try await phone.sync()
        XCTAssertEqual(first.uploaded, 4)

        let reinstalled = try device("reinstalled", root: root, remote: remote)
        let report = try await reinstalled.sync()
        XCTAssertEqual(report.downloaded, 4)
        XCTAssertEqual(reinstalled.read("agent-memory.md"), "- 美团记 Expenses:Food\n")
        XCTAssertEqual(reinstalled.read("agent-history/\(id.uuidString).transcript"), "transcript")
        XCTAssertEqual(reinstalled.read("agent-attachments/\(id.uuidString)/statement.csv"), "a,b")
        // Starters are a cache and stay on the device.
        XCTAssertNil(reinstalled.read("agent-starters.json"))

        let again = try await reinstalled.sync()
        XCTAssertEqual(again, LedgerAgentSyncReport())
    }

    func testDeletionAndEditsReachTheOtherDevice() async throws {
        let root = try directory()
        let remote = root.appendingPathComponent("folder/files", isDirectory: true)
        let phone = try device("phone", root: root, remote: remote)
        let pad = try device("pad", root: root, remote: remote)
        let kept = UUID(), deleted = UUID()
        try phone.write("agent-history/\(kept.uuidString).json", record(kept, title: "一", updatedAt: Date()))
        try phone.write("agent-history/\(deleted.uuidString).json", record(deleted, title: "二", updatedAt: Date()))
        try await phone.sync()
        try await pad.sync()
        XCTAssertNotNil(pad.read("agent-history/\(deleted.uuidString).json"))

        try pad.remove("agent-history/\(deleted.uuidString).json")
        try pad.write("agent-history/\(kept.uuidString).json", record(kept, title: "改过", updatedAt: Date()))
        try await pad.sync()
        try await phone.sync()
        XCTAssertNil(phone.read("agent-history/\(deleted.uuidString).json"))
        XCTAssertTrue(phone.read("agent-history/\(kept.uuidString).json")?.contains("改过") == true)
    }

    func testBothSidesChangedKeepsTheLaterRecordAndItsTranscript() async throws {
        let root = try directory()
        let remote = root.appendingPathComponent("folder/files", isDirectory: true)
        let phone = try device("phone", root: root, remote: remote)
        let pad = try device("pad", root: root, remote: remote)
        let id = UUID()
        let now = Date()
        try phone.write("agent-history/\(id.uuidString).json", record(id, title: "原来", updatedAt: now))
        try await phone.sync()
        try await pad.sync()

        try phone.write("agent-history/\(id.uuidString).json", record(id, title: "手机", updatedAt: now.addingTimeInterval(10)))
        try phone.write("agent-history/\(id.uuidString).transcript", "phone transcript")
        try pad.write("agent-history/\(id.uuidString).json", record(id, title: "平板", updatedAt: now.addingTimeInterval(60)))
        try pad.write("agent-history/\(id.uuidString).transcript", "pad transcript")
        try await pad.sync()
        let report = try await phone.sync()
        XCTAssertGreaterThan(report.merged, 0)
        XCTAssertTrue(phone.read("agent-history/\(id.uuidString).json")?.contains("平板") == true)
        XCTAssertEqual(phone.read("agent-history/\(id.uuidString).transcript"), "pad transcript")
    }

    func testDeletedOnOneSideAndChangedOnTheOtherKeepsTheChange() async throws {
        let root = try directory()
        let remote = root.appendingPathComponent("folder/files", isDirectory: true)
        let phone = try device("phone", root: root, remote: remote)
        let pad = try device("pad", root: root, remote: remote)
        let id = UUID()
        try phone.write("agent-history/\(id.uuidString).json", record(id, title: "原来", updatedAt: Date()))
        try await phone.sync()
        try await pad.sync()

        try phone.remove("agent-history/\(id.uuidString).json")
        try pad.write("agent-history/\(id.uuidString).json", record(id, title: "还在聊", updatedAt: Date().addingTimeInterval(5)))
        try await pad.sync()
        try await phone.sync()
        XCTAssertTrue(phone.read("agent-history/\(id.uuidString).json")?.contains("还在聊") == true)
    }

    func testMemoryEditedOnTwoDevicesIsMerged() async throws {
        let root = try directory()
        let remote = root.appendingPathComponent("folder/files", isDirectory: true)
        let phone = try device("phone", root: root, remote: remote)
        let pad = try device("pad", root: root, remote: remote)
        try phone.write("agent-memory.md", "## 分类\n- 美团记 Food\n- 滴滴记 Taxi\n")
        try await phone.sync()
        try await pad.sync()

        try phone.write("agent-memory.md", "## 分类\n- 美团记 Food\n- 滴滴记 Taxi\n- 星巴克记 Coffee\n")
        try pad.write("agent-memory.md", "## 分类\n- 美团记 Food\n- 房租每月 1 号\n")
        try await pad.sync()
        try await phone.sync()
        let merged = "## 分类\n- 美团记 Food\n- 房租每月 1 号\n- 星巴克记 Coffee\n"
        XCTAssertEqual(phone.read("agent-memory.md"), merged)
        try await pad.sync()
        XCTAssertEqual(pad.read("agent-memory.md"), merged)
    }

    func testMergeMemoryPlacesAddedLinesAfterTheirNeighbour() {
        let merged = LedgerAgentSyncLayout.mergeMemory(
            base: "## A\n- a1\n\n## B\n- b1\n",
            local: "## A\n- a1\n- a2\n\n## B\n- b1\n",
            remote: "## A\n- a1\n\n## B\n- b1\n- b2\n")
        XCTAssertEqual(merged, "## A\n- a1\n- a2\n\n## B\n- b1\n- b2\n")
    }

    func testOnlyAssistantFilesSync() {
        let id = UUID().uuidString, leaf = UUID().uuidString
        XCTAssertTrue(LedgerAgentSyncLayout.isSynced("agent-memory.md"))
        XCTAssertTrue(LedgerAgentSyncLayout.isSynced("agent-history/\(id).json"))
        XCTAssertTrue(LedgerAgentSyncLayout.isSynced("agent-history/\(id).\(leaf).transcript"))
        XCTAssertTrue(LedgerAgentSyncLayout.isSynced("agent-attachments/\(id)/a.pdf"))
        XCTAssertFalse(LedgerAgentSyncLayout.isSynced("agent-attachments/\(id)/a.pdf", attachments: false))
        XCTAssertFalse(LedgerAgentSyncLayout.isSynced("agent-history/notes.json"))
        XCTAssertFalse(LedgerAgentSyncLayout.isSynced("agent-starters.json"))
        XCTAssertFalse(LedgerAgentSyncLayout.isSynced("agent/\(id)/workspace/main.bean"))
        XCTAssertFalse(LedgerAgentSyncLayout.isSynced("agent-attachments/\(id)/../x"))
    }

    func testLedgerKeyFollowsTheGitRemoteAcrossInstalls() throws {
        let first = LocalLedgerDescriptor(id: UUID(), name: "家庭账本", entrypoint: "main.bean", createdAt: Date(),
            git: try LocalGitConfiguration(repositoryURL: "https://github.com/me/ledger.git"))
        let second = LocalLedgerDescriptor(id: UUID(), name: "账本", entrypoint: "main.bean", createdAt: Date(),
            git: try LocalGitConfiguration(repositoryURL: "https://github.com/me/ledger"))
        XCTAssertEqual(LedgerAgentSyncLayout.key(for: first), LedgerAgentSyncLayout.key(for: second))
        let local = LocalLedgerDescriptor(id: UUID(), name: "家庭账本", entrypoint: "main.bean", createdAt: Date())
        XCTAssertNotEqual(LedgerAgentSyncLayout.key(for: first), LedgerAgentSyncLayout.key(for: local))
    }

    func testLedgerKeyFollowsTheICloudFolderWhateverTheLocalName() {
        func joined(_ name: String, device: String) -> LocalLedgerDescriptor {
            LocalLedgerDescriptor(id: UUID(), name: name, entrypoint: "main.bean", createdAt: Date(),
                folder: LocalFolderSyncConfiguration(id: UUID(), bookmark: Data(), folderName: "iCloud",
                                                     deviceName: device, container: "shared-ledger"))
        }
        let phone = joined("家庭账本", device: "phone"), pad = joined("家庭账本（iCloud）", device: "pad")
        XCTAssertEqual(LedgerAgentSyncLayout.key(for: phone), LedgerAgentSyncLayout.key(for: pad))
        let local = LocalLedgerDescriptor(id: UUID(), name: "家庭账本", entrypoint: "main.bean", createdAt: Date())
        XCTAssertNotEqual(LedgerAgentSyncLayout.key(for: phone), LedgerAgentSyncLayout.key(for: local))
    }

    func testPreferencesLeaveOutKeysAndTokenURLs() throws {
        let suite = "LedgerAgentCloudSyncTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaults.set("high", forKey: "ledger.agent.thinking")
        defaults.set(Data(#"{"provider":"custom","model":"m","custom":{"api":"openai","baseURL":"https://x.example/v1?key=secret"}}"#.utf8),
                     forKey: "ledger.agent.custom-choice")
        defaults.set("sk-secret", forKey: "unrelated.api-key")
        let data = try XCTUnwrap(LedgerAgentSyncPreferences.snapshot(defaults))

        let fresh = try XCTUnwrap(UserDefaults(suiteName: suite + "-fresh"))
        addTeardownBlock { UserDefaults(suiteName: suite + "-fresh")?.removePersistentDomain(forName: suite + "-fresh") }
        XCTAssertTrue(LedgerAgentSyncPreferences.isFresh(fresh))
        XCTAssertTrue(LedgerAgentSyncPreferences.restore(data, into: fresh))
        XCTAssertEqual(fresh.string(forKey: "ledger.agent.thinking"), "high")
        XCTAssertNil(fresh.object(forKey: "ledger.agent.custom-choice"))
        XCTAssertNil(fresh.object(forKey: "unrelated.api-key"))
    }
}
