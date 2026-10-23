import Foundation
import XCTest
@testable import LedgerMobile

final class FolderLocalStorageTests: XCTestCase {
    private struct Device {
        let workspace: LocalLedgerWorkspace
        let storage: FolderLocalStorage
        let id: UUID
    }

    private let accept: LocalLedgerWorkspace.Validator = { _ in }
    private let ledger = LocalLedgerDescriptor(id: UUID(), name: "家庭账本", entrypoint: "main.bean", createdAt: Date())

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("FolderLocalStorageTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func device(_ name: String, sharing folder: URL, in root: URL, files: [String: String] = [:],
                        now: @escaping @Sendable () -> Date = { Date() }) async throws -> Device {
        let workspace = LocalLedgerWorkspace(rootDirectory: root.appendingPathComponent(name, isDirectory: true))
        if !files.isEmpty {
            try await workspace.commit(changes: files.map { LocalLedgerWorkspace.Change.write(Data($0.value.utf8), to: $0.key) }) { _ in }
        }
        let id = UUID()
        let configuration = LocalFolderSyncConfiguration(id: id, bookmark: Data(), folderName: "Ledger", deviceName: name)
        let storage = FolderLocalStorage(workspace: workspace, configuration: configuration, ledger: ledger,
            location: .directory(folder), now: now)
        return Device(workspace: workspace, storage: storage, id: id)
    }

    private func contents(_ device: Device) async throws -> [String: String] {
        try await device.workspace.withCurrentSnapshot { _, root in
            var result: [String: String] = [:]
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
            while let url = enumerator.nextObject() as? URL {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let path = String(url.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1))
                result[path] = try String(contentsOf: url, encoding: .utf8)
            }
            return result
        }
    }

    private func edit(_ device: Device, _ files: [String: String]) async throws {
        let current = try await device.workspace.currentRevision()?.id
        try await device.workspace.commit(expectedRevisionID: current,
            changes: files.map { LocalLedgerWorkspace.Change.write(Data($0.value.utf8), to: $0.key) }) { _ in }
    }

    private func head(of device: Device, in folder: URL) throws -> FolderSyncLayout.Head {
        let url = folder.appendingPathComponent("devices").appendingPathComponent(device.id.uuidString + ".json")
        return try FolderSyncLayout.decoder.decode(FolderSyncLayout.Head.self, from: Data(contentsOf: url))
    }

    func testFirstDevicePublishesSnapshotHeadAndMarker() async throws {
        let root = try directory(), folder = root.appendingPathComponent("iCloud")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let phone = try await device("phone", sharing: folder, in: root, files: ["main.bean": "; phone\n"])

        let status = try await phone.storage.synchronize(validator: accept)
        XCTAssertEqual(status.mode, .folder)
        XCTAssertEqual(status.phase, .synced)

        let head = try head(of: phone, in: folder)
        XCTAssertEqual(head.history, [head.head])
        XCTAssertEqual(status.baseCommit, head.head)
        let snapshot = folder.appendingPathComponent("snapshots").appendingPathComponent(head.head + ".ledgerbackup")
        XCTAssertEqual(try LedgerBackupArchive.readManifest(at: snapshot).contentDigest, head.head)
        XCTAssertEqual(try FolderSyncLayout.readMarker(in: folder)?.entrypoint, "main.bean")
    }

    func testJoiningDeviceDownloadsLedgerAndEmptyFolderIsRejected() async throws {
        let root = try directory(), folder = root.appendingPathComponent("iCloud")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let early = try await device("early", sharing: folder, in: root)
        do { _ = try await early.storage.synchronize(validator: accept); XCTFail("empty folder accepted") }
        catch { XCTAssertEqual(error as? LocalStorageError, .emptySyncFolder) }

        let phone = try await device("phone", sharing: folder, in: root, files: ["main.bean": "; phone\n", "2026/10.bean": "; oct\n"])
        _ = try await phone.storage.synchronize(validator: accept)
        let pad = try await device("pad", sharing: folder, in: root)
        let status = try await pad.storage.synchronize(validator: accept)

        XCTAssertEqual(status.phase, .synced)
        let padContents = try await contents(pad)
        XCTAssertEqual(padContents, ["main.bean": "; phone\n", "2026/10.bean": "; oct\n"])
        XCTAssertEqual(try head(of: pad, in: folder).head, try head(of: phone, in: folder).head)
    }

    func testConcurrentEditsToDifferentFilesConverge() async throws {
        let root = try directory(), folder = root.appendingPathComponent("iCloud")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let phone = try await device("phone", sharing: folder, in: root, files: ["main.bean": "; base\n", "a.bean": "a0\n", "b.bean": "b0\n"])
        _ = try await phone.storage.synchronize(validator: accept)
        let pad = try await device("pad", sharing: folder, in: root)
        _ = try await pad.storage.synchronize(validator: accept)

        try await edit(phone, ["a.bean": "a1\n"])
        try await edit(pad, ["b.bean": "b1\n"])
        _ = try await phone.storage.synchronize(validator: accept)
        _ = try await pad.storage.synchronize(validator: accept)
        _ = try await phone.storage.synchronize(validator: accept)

        let expected = ["main.bean": "; base\n", "a.bean": "a1\n", "b.bean": "b1\n"]
        let phoneContents = try await contents(phone)
        let padContents = try await contents(pad)
        XCTAssertEqual(phoneContents, expected)
        XCTAssertEqual(padContents, expected)
        XCTAssertEqual(try head(of: phone, in: folder).head, try head(of: pad, in: folder).head)
        let phoneStatus = try await phone.storage.status()
        XCTAssertEqual(phoneStatus.phase, .synced)
    }

    func testSimultaneousMergesReachTheSameDigest() async throws {
        let root = try directory(), folder = root.appendingPathComponent("iCloud")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let phone = try await device("phone", sharing: folder, in: root, files: ["main.bean": "; base\n", "a.bean": "a0\n", "b.bean": "b0\n"])
        _ = try await phone.storage.synchronize(validator: accept)
        let pad = try await device("pad", sharing: folder, in: root)
        _ = try await pad.storage.synchronize(validator: accept)
        let phoneHeadURL = folder.appendingPathComponent("devices/\(phone.id.uuidString).json")
        let stash = root.appendingPathComponent("stash.json")

        // Both publish an edit without seeing the other's.
        try await edit(phone, ["a.bean": "a1\n"])
        try await edit(pad, ["b.bean": "b1\n"])
        _ = try await phone.storage.synchronize(validator: accept)
        let phoneEdit = try Data(contentsOf: phoneHeadURL)
        try FileManager.default.removeItem(at: phoneHeadURL)
        _ = try await pad.storage.synchronize(validator: accept)
        try phoneEdit.write(to: phoneHeadURL)

        // Each then merges the other's edit before the other's merge arrives.
        _ = try await phone.storage.synchronize(validator: accept)
        let phoneMerge = try Data(contentsOf: phoneHeadURL)
        try phoneMerge.write(to: stash)
        try phoneEdit.write(to: phoneHeadURL)
        _ = try await pad.storage.synchronize(validator: accept)
        try phoneMerge.write(to: phoneHeadURL)

        XCTAssertEqual(try head(of: phone, in: folder).head, try head(of: pad, in: folder).head)
        // A further exchange on either side changes nothing.
        let settledPhone = try head(of: phone, in: folder), settledPad = try head(of: pad, in: folder)
        _ = try await phone.storage.synchronize(validator: accept)
        _ = try await pad.storage.synchronize(validator: accept)
        XCTAssertEqual(try head(of: phone, in: folder), settledPhone)
        XCTAssertEqual(try head(of: pad, in: folder), settledPad)
        let padContents = try await contents(pad)
        XCTAssertEqual(padContents, ["main.bean": "; base\n", "a.bean": "a1\n", "b.bean": "b1\n"])
    }

    func testConflictIsReviewedThenPublishedAndAdoptedByPeer() async throws {
        let root = try directory(), folder = root.appendingPathComponent("iCloud")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let phone = try await device("phone", sharing: folder, in: root, files: ["main.bean": "; base\n"])
        _ = try await phone.storage.synchronize(validator: accept)
        let pad = try await device("pad", sharing: folder, in: root)
        _ = try await pad.storage.synchronize(validator: accept)

        try await edit(phone, ["main.bean": "; phone\n"])
        try await edit(pad, ["main.bean": "; pad\n"])
        _ = try await phone.storage.synchronize(validator: accept)
        do { _ = try await pad.storage.synchronize(validator: accept); XCTFail("conflict accepted") }
        catch { XCTAssertEqual(error as? LocalStorageError, .conflicts(["main.bean"])) }
        let conflicted = try await pad.storage.status()
        XCTAssertEqual(conflicted.phase, .conflicted)
        XCTAssertEqual(conflicted.conflictPaths, ["main.bean"])
        let exported = try await pad.storage.exportConflictVersions()
        XCTAssertEqual(try String(contentsOf: exported.appendingPathComponent("remote/main.bean"), encoding: .utf8), "; phone\n")
        XCTAssertEqual(try String(contentsOf: exported.appendingPathComponent("local/main.bean"), encoding: .utf8), "; pad\n")

        let resolved = try await pad.storage.resolveConflicts(keepingLocal: true, validator: accept)
        XCTAssertEqual(resolved.phase, .pending)
        let published = try await pad.storage.synchronize(validator: accept)
        XCTAssertEqual(published.phase, .synced)
        _ = try await phone.storage.synchronize(validator: accept)

        let phoneContents = try await contents(phone)
        XCTAssertEqual(phoneContents, ["main.bean": "; pad\n"])
        XCTAssertEqual(try head(of: phone, in: folder).head, try head(of: pad, in: folder).head)
    }

    func testUnchangedExchangeWritesNothingAndMissingSnapshotIsRetried() async throws {
        let root = try directory(), folder = root.appendingPathComponent("iCloud")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let phone = try await device("phone", sharing: folder, in: root, files: ["main.bean": "; base\n"], now: { clock })
        _ = try await phone.storage.synchronize(validator: accept)
        let pad = try await device("pad", sharing: folder, in: root)
        _ = try await pad.storage.synchronize(validator: accept)
        let before = try head(of: phone, in: folder)
        _ = try await phone.storage.synchronize(validator: accept)
        XCTAssertEqual(try head(of: phone, in: folder), before)

        // The pad's head arrives before its snapshot: the phone keeps its tree.
        try await edit(pad, ["main.bean": "; pad\n"])
        _ = try await pad.storage.synchronize(validator: accept)
        let padHead = try head(of: pad, in: folder)
        let snapshot = folder.appendingPathComponent("snapshots").appendingPathComponent(padHead.head + ".ledgerbackup")
        let parked = root.appendingPathComponent("parked.ledgerbackup")
        try FileManager.default.moveItem(at: snapshot, to: parked)
        _ = try await phone.storage.synchronize(validator: accept)
        let waiting = try await contents(phone)
        XCTAssertEqual(waiting, ["main.bean": "; base\n"])

        try FileManager.default.moveItem(at: parked, to: snapshot)
        _ = try await phone.storage.synchronize(validator: accept)
        let arrived = try await contents(phone)
        XCTAssertEqual(arrived, ["main.bean": "; pad\n"])
    }

    func testDescriptorWithoutFolderStillDecodes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"Old","entrypoint":"main.bean","createdAt":0}"#
        let descriptor = try JSONDecoder().decode(LocalLedgerDescriptor.self, from: Data(json.utf8))
        XCTAssertNil(descriptor.folder)
        XCTAssertNil(descriptor.syncConfigurationID)
    }

    func testHistoryPrependDeduplicatesAndCaps() {
        let digests = (0..<80).map { String(format: "%064x", $0) }
        let history = FolderLocalStorage.prepend([digests[1], digests[0]], to: Array(digests.prefix(70)))
        XCTAssertEqual(Array(history.prefix(3)), [digests[1], digests[0], digests[2]])
        XCTAssertEqual(history.count, FolderSyncLayout.historyLimit)
        XCTAssertEqual(Set(history).count, history.count)
    }
}
