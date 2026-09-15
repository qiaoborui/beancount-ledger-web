import Foundation
#if canImport(BeancountRuntime)
import BeancountRuntime
#endif

/// Serializes the canonical Beancount interpreter within the app process.
actor EmbeddedBeancountValidator {
    static let shared = EmbeddedBeancountValidator()
    private var initialized = false
    private init() {}

    struct ValidationError: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Result: Decodable {
        struct Diagnostic: Decodable {
            let message: String
            let filename: String?
            let lineno: Int?
        }
        let errors: [Diagnostic]
    }

    func validate(workspace: URL, entryFile: String = "main.bean") throws {
        #if canImport(BeancountRuntime)
        if !initialized {
            let failure = Bundle.main.bundlePath.withCString { BRInitialize($0) }
            if let failure {
                defer { BRFree(failure) }
                throw ValidationError(message: String(cString: failure))
            }
            initialized = true
        }
        let pointer = workspace.path.withCString { root in
            entryFile.withCString { BRValidate(root, $0) }
        }
        guard let pointer else { throw ValidationError(message: "本地校验器内存不足") }
        defer { BRFree(pointer) }
        let result = try JSONDecoder().decode(Result.self, from: Data(String(cString: pointer).utf8))
        guard result.errors.isEmpty else {
            let message = result.errors.prefix(20).map { diagnostic in
                let location = diagnostic.filename.map { "\($0):\(diagnostic.lineno ?? 0) " } ?? ""
                return location + diagnostic.message
            }.joined(separator: "\n")
            throw ValidationError(message: message)
        }
        #else
        throw ValidationError(message: "此构建缺少本地 Beancount 校验运行时")
        #endif
    }
}
