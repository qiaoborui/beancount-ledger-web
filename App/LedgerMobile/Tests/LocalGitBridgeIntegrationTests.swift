import Foundation
import XCTest
@testable import LedgerMobile

/// Uses the actual app-linked Git bridge and disposable files. These tests
/// create local Git objects without accessing any remote repository.
final class LocalGitBridgeIntegrationTests: XCTestCase {
    func testEmbeddedGitCommitsExportsAndPreservesParentSnapshots() async throws {
        #if os(iOS)
        struct Commit: Decodable { let commit: String; let parent: String }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitBridge-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let original = Data("; safe bridge fixture\n".utf8)
        try original.write(to: source.appendingPathComponent("main.bean"))
        let transport = EmbeddedLocalGitTransport()
        var request = LocalGitRequest(operation: "commit", storageRoot: root.appendingPathComponent("cache.git").path)
        request.directory = source.path
        request.parent = ""
        request.message = "Create safe bridge fixture"
        let first = try JSONDecoder().decode(Commit.self, from: await transport.dispatch(request))
        XCTAssertEqual(first.commit.count, 40)
        XCTAssertEqual(first.parent, "")

        let edited = Data("; safe bridge fixture edited\n".utf8)
        try edited.write(to: source.appendingPathComponent("main.bean"))
        request.requestID = UUID().uuidString
        request.parent = first.commit
        let second = try JSONDecoder().decode(Commit.self, from: await transport.dispatch(request))
        XCTAssertEqual(second.parent, first.commit)
        XCTAssertNotEqual(first.commit, second.commit)

        for (commit, content) in [(first.commit, original), (second.commit, edited)] {
            let destination = root.appendingPathComponent("export-" + commit)
            var export = LocalGitRequest(operation: "export", storageRoot: request.storageRoot)
            export.commit = commit
            export.directory = destination.path
            _ = try await transport.dispatch(export)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("main.bean")), content)
        }
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("main.bean")), edited)
        #else
        throw XCTSkip("Requires the app-linked iOS Git runtime")
        #endif
    }

    func testEmbeddedGitRejectsSymlinksAndInsecureRemoteBeforeTransport() async throws {
        #if os(iOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitBridgeSafety-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.bean")
        try Data("; outside fixture\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("main.bean"), withDestinationURL: outside)
        let transport = EmbeddedLocalGitTransport()
        var commit = LocalGitRequest(operation: "commit", storageRoot: root.appendingPathComponent("cache.git").path)
        commit.directory = source.path
        commit.message = "Must reject symlink"
        do { _ = try await transport.dispatch(commit); XCTFail("Accepted a symlink snapshot") }
        catch let error as LocalGitTransportFailure { XCTAssertTrue(error.localizedDescription.contains("symlink")) }
        let fetch = LocalGitRequest(operation: "fetch", storageRoot: root.appendingPathComponent("remote.git").path,
            url: "http://example.invalid/fixture.git", branch: "main")
        do { _ = try await transport.dispatch(fetch); XCTFail("Accepted insecure remote") }
        catch let error as LocalGitTransportFailure { XCTAssertTrue(error.localizedDescription.contains("HTTPS")) }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "; outside fixture\n")
        #else
        throw XCTSkip("Requires the app-linked iOS Git runtime")
        #endif
    }
}
