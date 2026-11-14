import Foundation
#if canImport(LedgerCore)
import LedgerCore
#endif

/// One remote MCP server the user added to the assistant. Only the list is
/// saved, in `UserDefaults`; the token lives in this device's Keychain and is
/// read at the start of each turn, so nothing secret is ever written to a
/// ledger, a backup or Git.
struct LedgerAgentMCPServer: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var url: String
    var enabled: Bool = true

    static let nameLimit = 40
    static let urlLimit = 512
    static let tokenLimit = 4096

    /// What one turn sends: the server, with its token as a header.
    struct Payload: Encodable, Equatable, Sendable {
        let id: String
        let name: String
        let url: String
        var headers: [String: String]? = nil
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The host, for a server the user did not name.
    var host: String { URL(string: trimmedURL)?.host ?? trimmedURL }

    /// What a list row calls it.
    var title: String { trimmedName.isEmpty ? host : trimmedName }

    /// An address a turn may reach: https anywhere, plain http only on this
    /// device or a local network. The native side checks this again before it
    /// dials; this is so the screen can say so before a turn.
    static func isValid(url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= urlLimit, let parsed = URLComponents(string: trimmed),
              let scheme = parsed.scheme?.lowercased(), let host = parsed.host, !host.isEmpty,
              parsed.user == nil, parsed.password == nil, parsed.query == nil, parsed.fragment == nil else { return false }
        switch scheme {
        case "https": return true
        case "http": return isLocalHost(host)
        default: return false
        }
    }

    /// localhost, an mDNS `.local` name, or a private IP literal. A name is not
    /// resolved: one that happens to resolve to a private address is no reason
    /// to send a token in clear text.
    static func isLocalHost(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") { return true }
        if name.hasPrefix("[") && name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name == "::1" { return true }
        if name.hasPrefix("fe80:") || name.hasPrefix("fc") || name.hasPrefix("fd") { return true }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]),
              parts.allSatisfy({ Int($0).map { $0 >= 0 && $0 <= 255 } == true }) else { return false }
        return first == 127 || first == 10 || first == 0 || (first == 192 && second == 168)
            || (first == 172 && (16...31).contains(second)) || (first == 169 && second == 254)
    }
}

/// The tool names the native loop gives a server's tools:
/// `mcp__<server id>__<tool>`.
enum LedgerAgentMCPToolName {
    static let prefix = "mcp__"

    /// Splits a tool name back into its server id and the server's own tool
    /// name; nil for a tool that is not one of a remote server's.
    static func split(_ name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let separator = rest.range(of: "__") else { return nil }
        let server = String(rest[rest.startIndex..<separator.lowerBound])
        let tool = String(rest[separator.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }
}

/// The saved servers' names by id, for a step row, which draws outside the
/// main actor and so cannot ask the settings object. It reads what the
/// settings wrote and is replaced when the list changes.
final class LedgerAgentMCPServerIndex: @unchecked Sendable {
    nonisolated(unsafe) static var shared = LedgerAgentMCPServerIndex()

    private let lock = NSLock()
    private var cachedData: Data?
    private var names: [String: String] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Replaces the names without waiting for the saved list to change.
    func replace(_ servers: [LedgerAgentMCPServer]) {
        lock.lock()
        defer { lock.unlock() }
        cachedData = defaults.data(forKey: LedgerAgentMCPStorage.serversKey)
        names = Dictionary(servers.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// The server's own name, nil when no saved server has that id.
    func name(for id: String) -> String? {
        let data = defaults.data(forKey: LedgerAgentMCPStorage.serversKey)
        lock.lock()
        defer { lock.unlock() }
        if data != cachedData {
            cachedData = data
            let saved = data.flatMap { try? JSONDecoder().decode([LedgerAgentMCPServer].self, from: $0) } ?? []
            names = Dictionary(saved.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        }
        return names[id]
    }
}

/// Where the list is saved, and how it is read back.
enum LedgerAgentMCPStorage {
    static let serversKey = "ledger.agent.mcp-servers"

    static func load(from defaults: UserDefaults) -> [LedgerAgentMCPServer] {
        guard let data = defaults.data(forKey: serversKey),
              let servers = try? JSONDecoder().decode([LedgerAgentMCPServer].self, from: data) else { return [] }
        return servers.filter { !$0.id.isEmpty }
    }
}

/// Where one server's token lives: this device's Keychain in the app, a
/// dictionary in tests.
protocol LedgerAgentMCPTokenStore: AnyObject {
    func load() throws -> String?
    func save(_ token: String) throws
    func remove() throws
}

/// The Keychain item of one server, in the same service as the model keys.
final class LedgerAgentKeychainMCPTokenStore: LedgerAgentMCPTokenStore {
    private let key: ClassificationKeyStore

    init(account: String, service: String = LedgerAgentSettings.keychainService) {
        key = .init(service: service, account: account)
    }

    func load() throws -> String? { try key.load() }
    func save(_ token: String) throws { try key.save(token) }
    func remove() throws { try key.remove() }
}

/// The remote MCP servers the assistant may use. Each one is a Streamable HTTP
/// server the user runs; its tools join the ledger assistant's own.
@MainActor
final class LedgerAgentMCPSettings: ObservableObject {
    static let shared = LedgerAgentMCPSettings()
    static let serverLimit = 8
    /// The Keychain account of a server's token: `mcp.<id>`.
    static let tokenAccountPrefix = "mcp."

    @Published private(set) var servers: [LedgerAgentMCPServer]
    private let defaults: UserDefaults
    private let tokenStore: (String) -> any LedgerAgentMCPTokenStore

    init(defaults: UserDefaults = .standard,
         tokenStore: @escaping (String) -> any LedgerAgentMCPTokenStore = {
             LedgerAgentKeychainMCPTokenStore(account: LedgerAgentMCPSettings.tokenAccountPrefix + $0)
         }) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        servers = LedgerAgentMCPStorage.load(from: defaults)
    }

    /// Whether a token for the server is saved on this device.
    func hasToken(for id: String) -> Bool { ((try? tokenStore(id).load()) ?? nil) != nil }

    /// Adds a server and, when given, its token. The id is new each time, so a
    /// token never outlives the server it belongs to.
    @discardableResult
    func add(name: String, url: String, token: String) throws -> LedgerAgentMCPServer {
        guard servers.count < Self.serverLimit else {
            throw LedgerAgentError.failed(String(localized: "最多接入 \(Self.serverLimit) 个 MCP 服务器"))
        }
        var server = LedgerAgentMCPServer(id: Self.newID(), name: name, url: url)
        try prepare(&server)
        let cleaned = try cleanToken(token)
        if let cleaned { try tokenStore(server.id).save(cleaned) }
        servers.append(server)
        store()
        return server
    }

    /// Changes a server. `token` nil keeps the saved one, an empty string
    /// removes it.
    func update(id: String, name: String, url: String, token: String?) throws {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        var server = servers[index]
        server.name = name
        server.url = url
        try prepare(&server)
        if let token {
            let cleaned = try cleanToken(token)
            if let cleaned {
                try tokenStore(id).save(cleaned)
            } else {
                try tokenStore(id).remove()
            }
        }
        servers[index] = server
        store()
    }

    func setEnabled(_ on: Bool, for id: String) {
        guard let index = servers.firstIndex(where: { $0.id == id }), servers[index].enabled != on else { return }
        servers[index].enabled = on
        store()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where servers.indices.contains(index) {
            try? tokenStore(servers[index].id).remove()
            servers.remove(at: index)
        }
        store()
    }

    func remove(id: String) {
        remove(at: IndexSet(servers.indices.filter { servers[$0].id == id }))
    }

    /// The token of one server, for the settings page's 测试连接.
    func token(for id: String) -> String? { ((try? tokenStore(id).load()) ?? nil) }

    /// What one turn sends: every enabled server, with its token as a header.
    /// A token the Keychain will not give up (a locked device) is left out,
    /// so the turn still runs and the server answers 401 if it needs one.
    func payloads() -> [LedgerAgentMCPServer.Payload] {
        servers.filter(\.enabled).map { server in
            var headers: [String: String]? = nil
            if let token = token(for: server.id), !token.isEmpty {
                headers = ["Authorization": "Bearer " + token]
            }
            return LedgerAgentMCPServer.Payload(id: server.id, name: server.title, url: server.trimmedURL, headers: headers)
        }
    }

    /// Trims and checks a server before it is saved.
    private func prepare(_ server: inout LedgerAgentMCPServer) throws {
        server.name = server.trimmedName
        server.url = server.trimmedURL
        guard !server.name.isEmpty, server.name.count <= LedgerAgentMCPServer.nameLimit else {
            throw LedgerAgentError.failed(String(localized: "名称要填写，最多 \(LedgerAgentMCPServer.nameLimit) 个字"))
        }
        guard LedgerAgentMCPServer.isValid(url: server.url) else {
            throw LedgerAgentError.failed(String(localized: "地址要以 https:// 开头；本机或局域网的服务可以用 http://，不能带账号密码或查询参数"))
        }
    }

    /// A token as the Keychain should hold it: nil for none.
    private func cleanToken(_ raw: String) throws -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        guard token.utf8.count <= LedgerAgentMCPServer.tokenLimit, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw LedgerAgentError.failed(String(localized: "令牌格式不正确"))
        }
        return token
    }

    private func store() {
        defaults.set(try? JSONEncoder().encode(servers), forKey: LedgerAgentMCPStorage.serversKey)
        LedgerAgentMCPServerIndex.shared.replace(servers)
    }

    /// A short lowercase id, which is also part of the tool names the model
    /// sees, so it stays within `[a-z0-9]`.
    static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}

/// A tool one server lists, as `MCPProbeJSON` reports it.
struct LedgerAgentMCPProbeTool: Decodable, Equatable, Identifiable, Sendable {
    let name: String
    var title: String? = nil
    var description: String? = nil

    var id: String { name }
    /// The line under the name in the 测试连接 list.
    var summary: String {
        let text = (description ?? title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = text.split(whereSeparator: \.isNewline).first else { return "" }
        return String(line.prefix(120))
    }
}

/// The blocking JSON boundary to the native MCP probe. Tests substitute it.
struct LedgerAgentMCPProber: Sendable {
    private struct Request: Encodable {
        struct Server: Encodable {
            let id: String
            let name: String
            let url: String
            let headers: [String: String]?
        }
        let version = 1
        let server: Server
    }
    private struct Response: Decodable {
        let ok: Bool
        var name: String? = nil
        var tools: [LedgerAgentMCPProbeTool] = []
        var error: String? = nil
    }

    var run: @Sendable (Data) async throws -> Data

    static let native = LedgerAgentMCPProber(run: { request in
        #if canImport(LedgerCore)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Data(MobileagentMCPProbeJSON(String(decoding: request, as: UTF8.self)).utf8))
            }
        }
        #else
        throw LocalLedgerError.runtimeUnavailable
        #endif
    })

    /// The tools the server lists now; throws with the server's own words
    /// when it cannot be reached or the address is refused.
    func tools(for server: LedgerAgentMCPServer, token: String?) async throws -> [LedgerAgentMCPProbeTool] {
        let headers = token.map { ["Authorization": "Bearer " + $0] }
        let request = Request(server: .init(id: server.id, name: server.title, url: server.trimmedURL, headers: headers))
        let response = try JSONDecoder().decode(Response.self, from: try await run(try JSONEncoder().encode(request)))
        guard response.ok else {
            throw LedgerAgentError.failed(response.error ?? String(localized: "连接失败"))
        }
        return response.tools
    }
}
