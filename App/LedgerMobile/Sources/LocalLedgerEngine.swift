import Foundation
#if canImport(LedgerCore)
import LedgerCore
#endif

enum LocalLedgerError: LocalizedError, Equatable {
    case runtimeUnavailable
    case invalidConfiguration(String)
    case operationFailed(String)
    case previewRequired
    case staleTransactionCursor

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable: "此版本缺少设备端账本引擎，请安装完整的本地账本版本"
        case let .invalidConfiguration(message), let .operationFailed(message): message
        case .staleTransactionCursor: "账本版本已变更，请重新加载交易列表"
        case .previewRequired: "请刷新账本并预览修改后再保存"
        }
    }
}

struct LocalLedgerEngineRequest: Encodable, Sendable {
    struct ImportFile: Encodable, Sendable { let name: String; let data: Data }
    let version = 1
    var operation = "request"
    let workspaceRoot: String
    let runtimeRoot: String
    let entrypoint: String
    let method: String
    let path: String
    var query: [String: String] = [:]
    var body: BQLCell? = nil
    var importFile: ImportFile? = nil
    var staging = false
    var canonical: BQLCell? = nil
    var modelHandle: String? = nil
    var streamFile: String? = nil
    var sourceVersion: String? = nil
}

/// A process-local JSON boundary. Implementations never open an HTTP listener.
protocol LocalLedgerEngine: Sendable {
    func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data
    func response(_ request: LocalLedgerEngineRequest) async throws -> LocalLedgerResponse
}

extension LocalLedgerEngine {
    // Existing engines/mocks keep returning result-only JSON.
    func response(_ request: LocalLedgerEngineRequest) async throws -> LocalLedgerResponse {
        LocalLedgerResponse(result: try await dispatch(request))
    }
}

/// Retain the native envelope until the caller knows its result type. Only the
/// persisted bootstrap presentation/legacy callers need materialized result JSON.
struct LocalLedgerResponse: Sendable {
    private let data: Data
    private let isEnvelope: Bool

    init(result: Data) { data = result; isEnvelope = false }
    init(envelope: Data) { data = envelope; isEnvelope = true }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if isEnvelope { return try LocalLedgerJSON.decodeResult(type, from: data) }
        return try JSONDecoder().decode(type, from: data)
    }

    var modelUnavailable: Bool {
        guard isEnvelope else { return false }
        struct Envelope: Decodable {
            struct Diagnostic: Decodable { let code: String }
            let diagnostics: [Diagnostic]
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data).diagnostics.contains { $0.code == "model.unavailable" }) ?? false
    }

    /// Bound the complete wire response (including a native envelope) before any
    /// JSON decoding. The native page encoder reserves envelope headroom.
    func decodeTransactionPage(maximumBytes: Int? = nil) throws -> LedgerTransactionPage {
        if let maximumBytes, maximumBytes < 0 || data.count > maximumBytes {
            throw LocalLedgerError.operationFailed("交易分页响应超过容量限制")
        }
        do { return try decode(LedgerTransactionPage.self) }
        catch let error as LocalLedgerError {
            // Interpret conflict only at this endpoint; other mutation conflicts
            // retain their existing error behavior and messages.
            struct Header: Decodable { let status: Int }
            if isEnvelope, case .operationFailed = error,
               (try? JSONDecoder().decode(Header.self, from: data).status) == 409 {
                throw LocalLedgerError.staleTransactionCursor
            }
            throw error
        }
    }

    func resultData() throws -> Data {
        if isEnvelope { return try LocalLedgerJSON.resultData(data) }
        return data
    }
}

/// Process-wide FIFO gate prevents actor reentrancy from duplicating canonical
/// registration or replacing handles while another native request is preparing.
private actor LocalModelRequestGate {
    static let shared = LocalModelRequestGate()
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }
}

actor EmbeddedLocalLedgerEngine: LocalLedgerEngine {
    static let shared = EmbeddedLocalLedgerEngine()
    // Committed generation directories are immutable. Keep only the most recent
    // model; mutable stages always load their current contents independently.
    private var canonicalCache: (workspace: String, entrypoint: String, handle: String)?

    func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
        try await response(request).resultData()
    }

    func response(_ request: LocalLedgerEngineRequest) async throws -> LocalLedgerResponse {
        await LocalModelRequestGate.shared.acquire()
        do {
            try Task.checkCancellation()
            let result = try await serializedResponse(request)
            await LocalModelRequestGate.shared.release()
            return result
        } catch {
            await LocalModelRequestGate.shared.release()
            throw error
        }
    }

    private func serializedResponse(_ original: LocalLedgerEngineRequest) async throws -> LocalLedgerResponse {
        #if canImport(LedgerCore)
        var request = original
        // Publication validation performs a GET against a mutable stage too.
        // Scope by actual workspace, not merely the POST mutation flag.
        let container = URL(fileURLWithPath: request.workspaceRoot).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        request.staging = request.staging || container == "staging"
        let handle: String
        if !request.staging, let cached = canonicalCache,
           cached.workspace == request.workspaceRoot, cached.entrypoint == request.entrypoint {
            handle = cached.handle
        } else {
            if !request.staging, let old = canonicalCache {
                release(old.handle, request: request)
                canonicalCache = nil
            }
            handle = try await register(request)
            if !request.staging { canonicalCache = (request.workspaceRoot, request.entrypoint, handle) }
        }
        defer { if request.staging { release(handle, request: request) } }
        var small = request
        small.canonical = nil
        small.modelHandle = handle
        let result = try nativeResponse(small)
        // Fail stale reads safely; do not retry financial writes automatically.
        if result.modelUnavailable {
            if canonicalCache?.handle == handle { canonicalCache = nil }
            release(handle, request: request)
        }
        return result
        #else
        throw LocalLedgerError.runtimeUnavailable
        #endif
    }

    #if canImport(LedgerCore)
    private func nativeResponse(_ request: LocalLedgerEngineRequest) throws -> LocalLedgerResponse {
        let encoded = try JSONEncoder().encode(request)
        return LocalLedgerResponse(envelope: Data(MobilecoreDispatchJSON(String(decoding: encoded, as: UTF8.self)).utf8))
    }

    private func release(_ handle: String, request: LocalLedgerEngineRequest) {
        var command = request
        command.operation = "model-release"
        command.modelHandle = handle
        command.body = nil; command.importFile = nil; command.canonical = nil
        _ = try? nativeResponse(command)
    }

    private func register(_ request: LocalLedgerEngineRequest) async throws -> String {
        var command = request
        command.operation = "model-source"
        command.body = nil; command.importFile = nil; command.canonical = nil; command.modelHandle = nil
        struct Version: Decodable { let sourceVersion: String }
        let version = try nativeResponse(command).decode(Version.self)
        let runtime = URL(fileURLWithPath: request.runtimeRoot)
        let directory = runtime.appendingPathComponent("canonical-stream")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw LocalLedgerError.invalidConfiguration("模型导出目录不允许符号链接")
        }
        // All exporter/ingestion work is serialized by the process-wide gate.
        // Only exact owned scratch names are removed; imports/receipts untouched.
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            let name = file.lastPathComponent
            let token = String(name.prefix(32))
            guard name.count == 40, name.hasSuffix(".records"),
                  token.allSatisfy({ "0123456789abcdef".contains($0) }) else { continue }
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
                throw LocalLedgerError.invalidConfiguration("模型临时文件无效")
            }
            try FileManager.default.removeItem(at: file)
        }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        let filename = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".records"
        let output = directory.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await EmbeddedBeancountValidator.shared.exportCanonical(
            workspace: URL(fileURLWithPath: request.workspaceRoot), entryFile: request.entrypoint, to: output)
        try Task.checkCancellation()
        command.operation = "model-register"
        command.sourceVersion = version.sourceVersion
        command.streamFile = filename
        struct Registration: Decodable { let handle: String }
        return try nativeResponse(command).decode(Registration.self).handle
    }
    #endif

}

/// Keep large bridge payloads in JSON form. BQLCell remains the typed value for
/// user queries; decoding every ledger field into it adds a full recursive pass.
enum LocalLedgerJSON {
    static func requestData(_ request: LocalLedgerEngineRequest, canonical: Data) throws -> Data {
        var request = request
        request.canonical = nil
        var encoded = try JSONEncoder().encode(request)
        // Both fragments are encoder-produced JSON objects. Splice the model
        // without decoding/re-encoding thousands of booked entries per page.
        encoded.removeLast()
        encoded.append(Data(",\"canonical\":".utf8))
        encoded.append(canonical)
        encoded.append(UInt8(ascii: "}"))
        return encoded
    }

    private struct TypedEnvelope<T: Decodable>: Decodable {
        let result: T
        private enum Keys: String, CodingKey { case ok, status, diagnostics, result }
        private struct Diagnostic: Decodable { let message: String }
        private struct Failure: Decodable { let error: String? }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            let ok = try container.decode(Bool.self, forKey: .ok)
            let status = try container.decode(Int.self, forKey: .status)
            // Preserve strict diagnostic types and result.error precedence.
            let diagnostics = try container.decodeIfPresent([Diagnostic].self, forKey: .diagnostics)
            guard ok, (200..<300).contains(status) else {
                let failure = try? container.decode(Failure.self, forKey: .result)
                throw LocalLedgerError.operationFailed(failure?.error
                    ?? diagnostics?.map(\.message).joined(separator: "\n")
                    ?? "本地账本操作失败")
            }
            // superDecoder supplies null for an absent result, matching the
            // legacy resultData path; Optional<T> can decode it, concrete T fails.
            let value = try container.superDecoder(forKey: .result).singleValueContainer()
            result = try value.decode(T.self)
        }
    }

    static func decodeResult<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(TypedEnvelope<T>.self, from: data).result
    }

    static func resultData(_ data: Data) throws -> Data {
        struct Envelope: Decodable {
            struct Diagnostic: Decodable { let message: String }
            let ok: Bool
            let status: Int
            let diagnostics: [Diagnostic]?
        }
        // Decode only the small header with strict types; preserve result
        // integers and nested JSON without a BQLCell/Double round trip.
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard envelope.ok, (200..<300).contains(envelope.status) else {
            let result = object?["result"] as? [String: Any]
            let message = result?["error"] as? String
                ?? envelope.diagnostics?.map(\.message).joined(separator: "\n")
                ?? "本地账本操作失败"
            throw LocalLedgerError.operationFailed(message)
        }
        return try JSONSerialization.data(withJSONObject: object?["result"] ?? NSNull(), options: [.fragmentsAllowed])
    }
}
