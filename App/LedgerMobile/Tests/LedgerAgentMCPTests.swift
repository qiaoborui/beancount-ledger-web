import Foundation
import XCTest
@testable import LedgerMobile

/// A token store that keeps everything in memory, so a test can see exactly
/// what reached the Keychain and what did not.
private final class FakeMCPTokens {
    var saved: [String: String] = [:]
    var unreadable = false

    func store(account: String) -> any LedgerAgentMCPTokenStore { Account(owner: self, account: account) }

    private final class Account: LedgerAgentMCPTokenStore {
        let owner: FakeMCPTokens
        let account: String

        init(owner: FakeMCPTokens, account: String) {
            self.owner = owner
            self.account = account
        }

        func load() throws -> String? {
            if owner.unreadable { throw LedgerAgentError.failed("locked") }
            return owner.saved[account]
        }

        func save(_ token: String) throws { owner.saved[account] = token }
        func remove() throws { owner.saved[account] = nil }
    }
}

/// What a probe sent, written from whichever thread runs the request.
private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    var value: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: [String: Any]) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

final class LedgerAgentMCPTests: XCTestCase {
    private var suite = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        suite = "LedgerAgentMCPTests-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    @MainActor
    private func makeSettings(_ tokens: FakeMCPTokens) -> LedgerAgentMCPSettings {
        LedgerAgentMCPSettings(defaults: defaults, tokenStore: tokens.store(account:))
    }

    @MainActor
    func testAddingAServerKeepsItsTokenOutOfDefaults() throws {
        let tokens = FakeMCPTokens()
        let settings = makeSettings(tokens)
        let server = try settings.add(name: " 我的笔记 ", url: " https://mcp.example.com/mcp ", token: " secret-token ")
        XCTAssertEqual(server.name, "我的笔记")
        XCTAssertEqual(server.url, "https://mcp.example.com/mcp")
        XCTAssertTrue(server.enabled)
        XCTAssertEqual(settings.servers, [server])
        XCTAssertEqual(tokens.saved["mcp." + server.id], "secret-token")
        XCTAssertTrue(settings.hasToken(for: server.id))

        // The saved list carries the address and nothing secret.
        let saved = try XCTUnwrap(defaults.data(forKey: LedgerAgentMCPStorage.serversKey))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("secret-token"))

        // It survives a relaunch.
        let reopened = makeSettings(tokens)
        XCTAssertEqual(reopened.servers, [server])
        XCTAssertEqual(reopened.token(for: server.id), "secret-token")
    }

    @MainActor
    func testUpdatingAServerKeepsReplacesOrRemovesItsToken() throws {
        let tokens = FakeMCPTokens()
        let settings = makeSettings(tokens)
        let server = try settings.add(name: "笔记", url: "https://mcp.example.com/mcp", token: "one")

        try settings.update(id: server.id, name: "笔记 2", url: "https://mcp.example.com/v2", token: nil)
        XCTAssertEqual(tokens.saved["mcp." + server.id], "one")
        XCTAssertEqual(settings.servers.first?.name, "笔记 2")
        XCTAssertEqual(settings.servers.first?.url, "https://mcp.example.com/v2")

        try settings.update(id: server.id, name: "笔记 2", url: "https://mcp.example.com/v2", token: "two")
        XCTAssertEqual(tokens.saved["mcp." + server.id], "two")

        try settings.update(id: server.id, name: "笔记 2", url: "https://mcp.example.com/v2", token: "")
        XCTAssertNil(tokens.saved["mcp." + server.id])
        XCTAssertFalse(settings.hasToken(for: server.id))

        // A refused address changes nothing.
        XCTAssertThrowsError(try settings.update(id: server.id, name: "笔记 3", url: "http://example.com/mcp", token: nil))
        XCTAssertEqual(settings.servers.first?.name, "笔记 2")
        XCTAssertThrowsError(try settings.add(name: " ", url: "https://mcp.example.com/mcp", token: ""))
        XCTAssertThrowsError(try settings.add(name: "笔记", url: "https://mcp.example.com/mcp", token: "has space"))
    }

    @MainActor
    func testRemovingAServerRemovesItsToken() throws {
        let tokens = FakeMCPTokens()
        let settings = makeSettings(tokens)
        let first = try settings.add(name: "甲", url: "https://a.example.com/mcp", token: "a")
        let second = try settings.add(name: "乙", url: "https://b.example.com/mcp", token: "b")
        settings.remove(id: first.id)
        XCTAssertEqual(settings.servers, [second])
        XCTAssertNil(tokens.saved["mcp." + first.id])
        XCTAssertEqual(tokens.saved["mcp." + second.id], "b")
        settings.remove(at: IndexSet(integer: 0))
        XCTAssertTrue(settings.servers.isEmpty)
        XCTAssertNil(tokens.saved["mcp." + second.id])
    }

    @MainActor
    func testPayloadsCarryTheTokenAsAHeaderAndSkipDisabledServers() throws {
        let tokens = FakeMCPTokens()
        let settings = makeSettings(tokens)
        let keyed = try settings.add(name: "我的笔记", url: "https://mcp.example.com/mcp", token: "secret")
        let open = try settings.add(name: "", url: "http://192.168.1.8:3000/mcp", token: "")
        XCTAssertEqual(settings.payloads(), [
            .init(id: keyed.id, name: "我的笔记", url: "https://mcp.example.com/mcp",
                  headers: ["Authorization": "Bearer secret"]),
            .init(id: open.id, name: "192.168.1.8", url: "http://192.168.1.8:3000/mcp", headers: nil),
        ])

        settings.setEnabled(false, for: keyed.id)
        XCTAssertEqual(settings.payloads().map(\.id), [open.id])

        // A Keychain the app cannot read costs the turn its token, not the server.
        tokens.unreadable = true
        settings.setEnabled(true, for: keyed.id)
        XCTAssertEqual(settings.payloads().first?.headers, nil)
    }

    @MainActor
    func testTheServerLimitHolds() throws {
        let settings = makeSettings(FakeMCPTokens())
        for index in 0..<LedgerAgentMCPSettings.serverLimit {
            try settings.add(name: "服务器 \(index)", url: "https://mcp.example.com/\(index)", token: "")
        }
        XCTAssertThrowsError(try settings.add(name: "多一个", url: "https://mcp.example.com/one-more", token: ""))
    }

    func testServerAddresses() {
        for url in ["https://mcp.example.com/mcp", "http://localhost:3000/mcp", "http://127.0.0.1:8000/mcp",
                    "http://192.168.1.8:8080", "http://10.0.0.4/mcp", "http://172.20.1.1/mcp", "http://mac.local:1234",
                    "http://[::1]:9000/mcp"] {
            XCTAssertTrue(LedgerAgentMCPServer.isValid(url: url), url)
        }
        for url in ["", "mcp.example.com", "ftp://example.com/mcp", "http://example.com/mcp", "http://8.8.8.8/mcp",
                    "https://user:pass@example.com/mcp", "https://example.com/mcp?key=1", "https://example.com/mcp#frag"] {
            XCTAssertFalse(LedgerAgentMCPServer.isValid(url: url), url)
        }
    }

    func testToolNamesSplitBackIntoServerAndTool() {
        XCTAssertEqual(LedgerAgentMCPToolName.split("mcp__ab12cd34__search_notes")?.server, "ab12cd34")
        XCTAssertEqual(LedgerAgentMCPToolName.split("mcp__ab12cd34__search_notes")?.tool, "search_notes")
        XCTAssertNil(LedgerAgentMCPToolName.split("get_accounts"))
        XCTAssertNil(LedgerAgentMCPToolName.split("mcp__ab12cd34"))
        XCTAssertNil(LedgerAgentMCPToolName.split("mcp____search"))
        XCTAssertNil(LedgerAgentMCPToolName.split("mcp__ab12cd34__"))
    }

    func testAToolCallShowsTheServersName() throws {
        let server = LedgerAgentMCPServer(id: "ab12cd34", name: "我的笔记", url: "https://mcp.example.com/mcp")
        defaults.set(try JSONEncoder().encode([server]), forKey: LedgerAgentMCPStorage.serversKey)
        let previous = LedgerAgentMCPServerIndex.shared
        LedgerAgentMCPServerIndex.shared = LedgerAgentMCPServerIndex(defaults: defaults)
        addTeardownBlock { LedgerAgentMCPServerIndex.shared = previous }

        let calls = try JSONDecoder().decode([LedgerAgentToolCall].self, from: Data("""
        [{"name":"mcp__ab12cd34__search_notes","isError":false},
         {"name":"mcp__gone__search_notes","isError":false},
         {"name":"get_accounts","isError":false}]
        """.utf8))
        XCTAssertEqual(calls.map(\.title), ["我的笔记 · search_notes", "gone · search_notes", "账户"])
    }

    func testTheTurnRequestCarriesTheServersLast() throws {
        let payload = LedgerAgentMCPServer.Payload(id: "ab12cd34", name: "我的笔记",
            url: "https://mcp.example.com/mcp", headers: ["Authorization": "Bearer secret"])
        let request = LedgerAgentTurnRequest(turnId: "turn", workspaceRoot: "/w", runtimeRoot: "/r",
            entrypoint: "main.bean", modelHandle: nil, sensitiveUnlocked: true, provider: "anthropic",
            model: "claude-sonnet-4-5", apiKey: "key", history: [], message: "你好", mcpServers: [payload])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [[String: Any]])
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0]["id"] as? String, "ab12cd34")
        XCTAssertEqual(servers[0]["name"] as? String, "我的笔记")
        XCTAssertEqual(servers[0]["url"] as? String, "https://mcp.example.com/mcp")
        XCTAssertEqual((servers[0]["headers"] as? [String: String])?["Authorization"], "Bearer secret")

        // No server configured: the key stays out of the request.
        let plain = LedgerAgentTurnRequest(turnId: "turn", workspaceRoot: "/w", runtimeRoot: "/r",
            entrypoint: "main.bean", modelHandle: nil, sensitiveUnlocked: true, provider: "anthropic",
            model: "claude-sonnet-4-5", apiKey: "key", history: [], message: "你好")
        let empty = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(plain)) as? [String: Any])
        XCTAssertNil(empty["mcpServers"])
    }

    func testTheProberDecodesToolsAndReportsTheServersWords() async throws {
        let server = LedgerAgentMCPServer(id: "ab12cd34", name: "我的笔记", url: "https://mcp.example.com/mcp")
        let seen = Captured()
        let prober = LedgerAgentMCPProber { request in
            seen.set(JSONSerialization.jsonObject(with: request) as? [String: Any] ?? [:])
            return Data("""
            {"version":1,"ok":true,"name":"我的笔记","tools":[
              {"name":"search_notes","description":"搜索笔记\\n更多说明"},
              {"name":"list_notes","title":"列出"}]}
            """.utf8)
        }
        let tools = try await prober.tools(for: server, token: "secret")
        XCTAssertEqual(tools.map(\.name), ["search_notes", "list_notes"])
        XCTAssertEqual(tools[0].summary, "搜索笔记")
        XCTAssertEqual(tools[1].summary, "列出")
        let sent = try XCTUnwrap(seen.value["server"] as? [String: Any])
        XCTAssertEqual(sent["id"] as? String, "ab12cd34")
        XCTAssertEqual((sent["headers"] as? [String: String])?["Authorization"], "Bearer secret")

        let failing = LedgerAgentMCPProber { _ in
            Data(#"{"version":1,"ok":false,"tools":[],"error":"连不上"}"#.utf8)
        }
        do {
            _ = try await failing.tools(for: server, token: nil)
            XCTFail("a failed probe was reported as a success")
        } catch {
            XCTAssertEqual(error.localizedDescription, "连不上")
        }
    }
}
