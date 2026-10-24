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
        case .runtimeUnavailable: String(localized: "此版本缺少设备端账本引擎，请安装完整的本地账本版本")
        case let .invalidConfiguration(message), let .operationFailed(message): message
        case .staleTransactionCursor: String(localized: "账本版本已变更，请重新加载交易列表")
        case .previewRequired: String(localized: "请刷新账本并预览修改后再保存")
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
            throw LocalLedgerError.operationFailed(String(localized: "交易分页响应超过容量限制"))
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

    func decodeBootstrapPage(maximumBytes: Int = 1 << 20) throws -> LocalBootstrapPage {
        // The native result reserves 4KiB for the bridge envelope. Bound the
        // entire response here so a valid near-limit enveloped result still fits.
        guard (0...(1 << 20)).contains(maximumBytes), data.count <= maximumBytes else {
            throw LocalLedgerError.operationFailed(String(localized: "启动分页响应超过容量限制"))
        }
        do { return try decode(LocalBootstrapPage.self) }
        catch let error as LocalLedgerError {
            struct Header: Decodable { let status: Int }
            if isEnvelope, case .operationFailed = error,
               (try? JSONDecoder().decode(Header.self, from: data).status) == 409 {
                throw LocalLedgerError.staleTransactionCursor
            }
            throw error
        }
    }

    func decodeReconciliationSnapshot() throws -> LocalReconciliationSnapshot {
        guard data.count <= 1 << 20 else { throw LocalLedgerError.operationFailed(String(localized: "对账快照响应超过容量限制")) }
        return try decode(LocalReconciliationSnapshot.self)
    }

    func decodeAccountPage() throws -> LedgerAccountPage {
        guard data.count <= 1 << 20 else {
            throw LocalLedgerError.operationFailed(String(localized: "账户分页响应超过容量限制"))
        }
        do { return try decode(LedgerAccountPage.self) }
        catch let error as LocalLedgerError {
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

/// One committed generation's native model handle. Committed generation
/// directories are immutable, so a handle stays valid until it is released or
/// the core evicts it.
struct LocalCanonicalHandle: Equatable, Sendable {
    let workspace: String
    let entrypoint: String
    let handle: String
}

/// Native control operations configure the runtime or drop cached models. They
/// carry no ledger data, so they are valid standalone requests; the Go
/// dispatcher rejects unknown fields, hence the exact property list.
struct LocalModelControlRequest: Encodable, Sendable {
    let version = 1
    let operation: String
    var modelHandle: String? = nil
    var availableBytes: Int64? = nil
}

/// Recency-ordered committed handles. Pure value logic, so the eviction and
/// memory-pressure policy stays testable without the native core.
struct LocalCanonicalHandleCache {
    private(set) var handles: [LocalCanonicalHandle] = []
    static let limit = 4

    func handle(workspace: String, entrypoint: String) -> String? {
        handles.first { $0.workspace == workspace && $0.entrypoint == entrypoint }?.handle
    }

    mutating func forget(_ handle: String) {
        handles.removeAll { $0.handle == handle }
    }

    /// One ledger across its immutable generations
    /// (<ledger>/generations/<id>/workspace); other roots key by themselves.
    static func ledgerKey(_ workspace: String) -> String {
        let generations = URL(fileURLWithPath: workspace).deletingLastPathComponent().deletingLastPathComponent()
        return generations.lastPathComponent == "generations" ? generations.path : workspace
    }

    /// Insert a newly registered handle and return the handles it supersedes or
    /// pushes beyond the limit.
    mutating func remember(_ handle: LocalCanonicalHandle) -> [String] {
        var released: [String] = []
        handles.removeAll { cached in
            let superseded = cached.entrypoint == handle.entrypoint
                && Self.ledgerKey(cached.workspace) == Self.ledgerKey(handle.workspace)
            if superseded { released.append(cached.handle) }
            return superseded
        }
        handles.insert(handle, at: 0)
        while handles.count > Self.limit {
            released.append(handles.removeLast().handle)
        }
        return released
    }

    /// A memory warning only drops idle ledgers: the current (most recently
    /// used) committed ledger is what the visible view is reading, and dropping
    /// it would force an expensive re-register. Returns the kept handle and the
    /// ones the native core must release.
    mutating func releaseIdleModels() -> (keep: String?, released: [String]) {
        guard let current = handles.first else { return (nil, []) }
        let released = handles.dropFirst().map(\.handle)
        handles = [current]
        return (current.handle, Array(released))
    }
}

actor EmbeddedLocalLedgerEngine: LocalLedgerEngine {
    static let shared = EmbeddedLocalLedgerEngine()
    private var canonicalHandles = LocalCanonicalHandleCache()

    // Committed generation directories are immutable. Keep a handle for each of
    // the few most recently used ledgers (the core holds a bounded LRU of the
    // same size and may evict earlier); mutable stages always load their
    // current contents independently. Most recently registered first.
    private func cachedHandle(_ request: LocalLedgerEngineRequest) -> String? {
        canonicalHandles.handle(workspace: request.workspaceRoot, entrypoint: request.entrypoint)
    }

    private func forget(_ handle: String) {
        canonicalHandles.forget(handle)
    }

    /// Record a new committed handle, releasing the one it supersedes (an older
    /// generation of the same ledger) and any beyond the limit.
    private func remember(_ handle: String, request: LocalLedgerEngineRequest) {
        let entry = LocalCanonicalHandle(workspace: request.workspaceRoot,
            entrypoint: request.entrypoint, handle: handle)
        for old in canonicalHandles.remember(entry) { releaseHandle(old, request: request) }
    }

    func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
        try await response(request).resultData()
    }

    func response(_ request: LocalLedgerEngineRequest) async throws -> LocalLedgerResponse {
        // Fast path: an already-registered, committed generation is read-only, so
        // pages and analysis reads share the gate instead of queueing. Anything
        // that may register, export or release a handle falls through to the
        // exclusive path below.
        await LocalModelRequestGate.shared.acquireRead()
        do {
            if let live = try concurrentResponse(request) {
                await LocalModelRequestGate.shared.releaseRead()
                return live
            }
        } catch {
            await LocalModelRequestGate.shared.releaseRead()
            throw error
        }
        await LocalModelRequestGate.shared.releaseRead()

        await LocalModelRequestGate.shared.acquireWrite()
        do {
            try Task.checkCancellation()
            let result = try await serializedResponse(request)
            await LocalModelRequestGate.shared.releaseWrite()
            return result
        } catch {
            await LocalModelRequestGate.shared.releaseWrite()
            throw error
        }
    }

    /// Serve a request from the live committed handle. Caller must hold the read
    /// lock: there is no suspension point between the handle check and
    /// `nativeResponse`, so the handle cannot be released underneath it.
    /// Returns nil when this request needs the exclusive path.
    private func concurrentResponse(_ original: LocalLedgerEngineRequest) throws -> LocalLedgerResponse? {
        #if canImport(LedgerCore)
        let request = normalized(original)
        guard !request.staging, let cached = cachedHandle(request) else { return nil }
        var small = request
        small.canonical = nil
        small.modelHandle = cached
        let result = try nativeResponse(small)
        guard !result.modelUnavailable else {
            // The generation moved or the core evicted the model. Drop the stale
            // handle and redo this request through the exclusive path, which
            // re-registers.
            forget(cached)
            releaseHandle(cached, request: request)
            return nil
        }
        return result
        #else
        // The portable package build has no native core; every request takes the
        // exclusive path, which reports `runtimeUnavailable`.
        return nil
        #endif
    }

    /// Publication validation performs a GET against a mutable stage too, so the
    /// staging scope is derived from the workspace, not only the POST flag.
    private func normalized(_ original: LocalLedgerEngineRequest) -> LocalLedgerEngineRequest {
        var request = original
        let container = URL(fileURLWithPath: request.workspaceRoot)
            .deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        request.staging = request.staging || container == "staging"
        return request
    }

    private func serializedResponse(_ original: LocalLedgerEngineRequest) async throws -> LocalLedgerResponse {
        #if canImport(LedgerCore)
        let request = normalized(original)
        let handle: String
        if !request.staging, let cached = cachedHandle(request) {
            handle = cached
        } else {
            handle = try await register(request)
            if !request.staging { remember(handle, request: request) }
        }
        defer { if request.staging { releaseHandle(handle, request: request) } }
        var small = request
        small.canonical = nil
        small.modelHandle = handle
        let result = try nativeResponse(small)
        // Fail stale reads safely; do not retry financial writes automatically.
        if result.modelUnavailable {
            forget(handle)
            releaseHandle(handle, request: request)
        }
        return result
        #else
        throw LocalLedgerError.runtimeUnavailable
        #endif
    }

    /// Canonical validation for a staged or imported tree. A successful export
    /// is a successful validation, so the export is kept: the generation this
    /// tree becomes then registers without a second Python pass, and a tree
    /// whose exact bytes were already validated skips the loader entirely.
    func validateCanonical(workspaceRoot: String, runtimeRoot: String, entrypoint: String) async throws {
        // Export writes the shared scratch directory and can replace the cached
        // stream, so it takes the gate exclusively.
        await LocalModelRequestGate.shared.acquireWrite()
        do {
            try Task.checkCancellation()
            try await serializedValidateCanonical(workspaceRoot: workspaceRoot, runtimeRoot: runtimeRoot, entrypoint: entrypoint)
            await LocalModelRequestGate.shared.releaseWrite()
        } catch {
            await LocalModelRequestGate.shared.releaseWrite()
            throw error
        }
    }

    private func serializedValidateCanonical(workspaceRoot: String, runtimeRoot: String, entrypoint: String) async throws {
        #if canImport(LedgerCore)
        var command = LocalLedgerEngineRequest(workspaceRoot: workspaceRoot, runtimeRoot: runtimeRoot,
            entrypoint: entrypoint, method: "GET", path: "/api/ledger/version")
        command.operation = "model-source"
        struct Version: Decodable { let sourceVersion: String }
        let version = try nativeResponse(command).decode(Version.self)
        let runtime = URL(fileURLWithPath: runtimeRoot)
        let cache = LocalCanonicalStreamCache(runtimeRoot: runtime)
        if cache.contains(version.sourceVersion) { return }
        let directory = runtime.appendingPathComponent("canonical-stream")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw LocalLedgerError.invalidConfiguration(String(localized: "模型导出目录不允许符号链接"))
        }
        let output = directory.appendingPathComponent(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".records")
        defer { try? FileManager.default.removeItem(at: output) }
        let descriptor = try await EmbeddedBeancountValidator.shared.exportCanonical(
            workspace: URL(fileURLWithPath: workspaceRoot), entryFile: entrypoint, to: output)
        cache.store(output, sourceVersion: version.sourceVersion, descriptor: descriptor)
        #else
        throw LocalLedgerError.runtimeUnavailable
        #endif
    }

    #if canImport(LedgerCore)
    private func nativeResponse(_ request: LocalLedgerEngineRequest) throws -> LocalLedgerResponse {
        let encoded = try JSONEncoder().encode(request)
        return LocalLedgerResponse(envelope: Data(MobilecoreDispatchJSON(String(decoding: encoded, as: UTF8.self)).utf8))
    }

    private static func nativeControlResponse(_ request: LocalModelControlRequest) throws -> LocalLedgerResponse {
        let encoded = try JSONEncoder().encode(request)
        return LocalLedgerResponse(envelope: Data(MobilecoreDispatchJSON(String(decoding: encoded, as: UTF8.self)).utf8))
    }
    #endif

    /// Reclaim committed models after an iOS memory warning. The exclusive gate
    /// keeps an in-flight read from observing a released handle, and the current
    /// (most recently used) ledger stays registered so the visible view keeps
    /// serving without a canonical re-register. The native side trims its LRU in
    /// one atomic operation instead of a per-handle release loop, so it cannot be
    /// observed half-evicted; staged models are intentionally left alone.
    func releaseIdleModelsForMemoryPressure() async {
        await LocalModelRequestGate.shared.acquireWrite()
        let plan = canonicalHandles.releaseIdleModels()
        #if canImport(LedgerCore)
        _ = try? Self.nativeControlResponse(
            LocalModelControlRequest(operation: "model-release-idle", modelHandle: plan.keep))
        #else
        _ = plan
        #endif
        await LocalModelRequestGate.shared.releaseWrite()
    }

    /// Apply the native Go soft heap limit (GOMEMLIMIT) from the shell's
    /// available-memory reading. Called once at launch; a zero reading (unknown,
    /// or unsupported on the simulator) keeps the runtime default. The limit is
    /// soft: it targets GC rather than capping allocations.
    static func configureNativeMemoryLimit(availableBytes: Int64) {
        #if canImport(LedgerCore)
        _ = try? nativeControlResponse(
            LocalModelControlRequest(operation: "memory-limit", availableBytes: availableBytes))
        #endif
    }

    /// Report os_proc_available_memory() during launch, before the first model
    /// registration, when the reading is closest to the process's full budget.
    static func configureNativeMemoryLimitFromSystem() {
        #if os(iOS) && canImport(LedgerCore)
        configureNativeMemoryLimit(availableBytes: Int64(os_proc_available_memory()))
        #endif
    }

    #if os(iOS)
    /// The app delegate forwards UIApplication.didReceiveMemoryWarning here:
    /// drop idle ledgers while the current one keeps working.
    static func handleMemoryPressure() {
        Task { await shared.releaseIdleModelsForMemoryPressure() }
    }
    #endif

    /// `model-release` needs the native core; without it there is no handle to
    /// release either.
    private func releaseHandle(_ handle: String, request: LocalLedgerEngineRequest) {
        #if canImport(LedgerCore)
        var command = request
        command.operation = "model-release"
        command.modelHandle = handle
        command.body = nil; command.importFile = nil; command.canonical = nil
        _ = try? nativeResponse(command)
        #endif
    }

    #if canImport(LedgerCore)

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
            throw LocalLedgerError.invalidConfiguration(String(localized: "模型导出目录不允许符号链接"))
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
                throw LocalLedgerError.invalidConfiguration(String(localized: "模型临时文件无效"))
            }
            try FileManager.default.removeItem(at: file)
        }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        let filename = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".records"
        let output = directory.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: output) }
        // Same source bytes, same bundled runtime: reuse the earlier export
        // instead of re-running the Python loader over the whole ledger.
        let cache = LocalCanonicalStreamCache(runtimeRoot: runtime)
        if !cache.restore(version.sourceVersion, to: output) {
            let descriptor = try await EmbeddedBeancountValidator.shared.exportCanonical(
                workspace: URL(fileURLWithPath: request.workspaceRoot), entryFile: request.entrypoint, to: output)
            cache.store(output, sourceVersion: version.sourceVersion, descriptor: descriptor)
        }
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
                    ?? String(localized: "本地账本操作失败"))
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
                ?? String(localized: "本地账本操作失败")
            throw LocalLedgerError.operationFailed(message)
        }
        return try JSONSerialization.data(withJSONObject: object?["result"] ?? NSNull(), options: [.fragmentsAllowed])
    }
}
