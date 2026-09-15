import Foundation
#if canImport(LedgerCore)
import LedgerCore
#endif

enum LocalLedgerError: LocalizedError, Equatable {
    case runtimeUnavailable
    case invalidConfiguration(String)
    case operationFailed(String)
    case previewRequired

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable: "此版本缺少设备端账本引擎，请安装完整的本地账本版本"
        case let .invalidConfiguration(message), let .operationFailed(message): message
        case .previewRequired: "请刷新账本并预览修改后再保存"
        }
    }
}

struct LocalLedgerEngineRequest: Encodable, Sendable {
    struct ImportFile: Encodable, Sendable { let name: String; let data: Data }
    let version = 1
    let operation = "request"
    let workspaceRoot: String
    let runtimeRoot: String
    let entrypoint: String
    let method: String
    let path: String
    var query: [String: String] = [:]
    var body: BQLCell? = nil
    var importFile: ImportFile? = nil
    var staging = false
}

/// A process-local JSON boundary. Implementations never open an HTTP listener.
protocol LocalLedgerEngine: Sendable {
    func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data
}

actor EmbeddedLocalLedgerEngine: LocalLedgerEngine {
    static let shared = EmbeddedLocalLedgerEngine()

    func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data {
        #if canImport(LedgerCore)
        let encoded = try JSONEncoder().encode(request)
        let response = MobilecoreDispatchJSON(String(decoding: encoded, as: UTF8.self))
        let data = Data(response.utf8)
        struct Envelope: Decodable {
            struct Diagnostic: Decodable { let message: String }
            let ok: Bool
            let status: Int
            let result: BQLCell?
            let diagnostics: [Diagnostic]?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.ok, (200..<300).contains(envelope.status) else {
            var message = envelope.diagnostics?.map(\.message).joined(separator: "\n") ?? "本地账本操作失败"
            if case let .object(result) = envelope.result, case let .string(error) = result["error"] {
                message = error
            }
            throw LocalLedgerError.operationFailed(message)
        }
        return try JSONEncoder().encode(envelope.result ?? .null)
        #else
        throw LocalLedgerError.runtimeUnavailable
        #endif
    }
}
