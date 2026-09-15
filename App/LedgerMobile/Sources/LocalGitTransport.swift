import Foundation
#if canImport(LedgerCore)
import LedgerCore
#endif

struct LocalGitRequest: Encodable, Sendable {
    let version = 1
    let operation: String
    var requestID: String = UUID().uuidString
    var storageRoot: String? = nil
    var url: String? = nil
    var branch: String? = nil
    var username: String? = nil
    var password: String? = nil
    var timeoutSeconds: Int? = 45
    var commit: String? = nil
    var directory: String? = nil
    var parent: String? = nil
    var expectedRemoteHead: String? = nil
    var message: String? = nil
    var authorName: String? = nil
    var authorEmail: String? = nil
}

protocol LocalGitTransport: Sendable {
    func dispatch(_ request: LocalGitRequest) async throws -> Data
}

struct LocalGitTransportFailure: LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
    var requiresAttention: Bool {
        ["git.authentication", "git.authorization", "git.invalid_request", "git.unsafe_path",
         "git.limit_exceeded"].contains(code)
    }
}

/// Calls the bundled Go Git implementation directly, with no shell subprocess.
struct EmbeddedLocalGitTransport: LocalGitTransport {
    func dispatch(_ request: LocalGitRequest) async throws -> Data {
        #if canImport(LedgerCore)
        let encoded = try JSONEncoder().encode(request)
        let requestID = request.requestID
        let text = String(decoding: encoded, as: UTF8.self)
        let response = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return await Task.detached(priority: .utility) { MobilegitDispatchJSON(text) }.value
        } onCancel: {
            Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(LocalGitRequest(operation: "cancel", requestID: requestID)) {
                    _ = MobilegitDispatchJSON(String(decoding: data, as: UTF8.self))
                }
            }
        }
        try Task.checkCancellation()
        struct Envelope: Decodable {
            struct Failure: Decodable { let code: String; let message: String }
            let ok: Bool
            let result: BQLCell?
            let error: Failure?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(response.utf8))
        guard envelope.ok else {
            throw LocalGitTransportFailure(code: envelope.error?.code ?? "git.failed",
                message: envelope.error?.message ?? "Git 同步失败")
        }
        return try JSONEncoder().encode(envelope.result ?? .null)
        #else
        throw LocalStorageError.gitUnavailable
        #endif
    }
}
