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

    private struct Result {
        struct Diagnostic: Decodable {
            let message: String
            let filename: String?
            let lineno: Int?
        }
        let errors: [Diagnostic]
        let canonical: Data?

        init(data: Data) throws {
            struct Diagnostics: Decodable { let errors: [Diagnostic] }
            errors = try JSONDecoder().decode(Diagnostics.self, from: data).errors
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if errors.isEmpty, let model = object?["canonical"] as? [String: Any] {
                canonical = try JSONSerialization.data(withJSONObject: model)
            } else {
                canonical = nil
            }
        }
    }

    func validate(workspace: URL, entryFile: String = "main.bean") throws {
        _ = try load(workspace: workspace, entryFile: entryFile)
    }

    /// The canonical loader's booked, plugin-transformed entries are the
    /// financial read model. Source files remain the editable representation.
    func canonicalModel(workspace: URL, entryFile: String = "main.bean") throws -> Data {
        let result = try load(workspace: workspace, entryFile: entryFile)
        guard let canonical = result.canonical else {
            throw ValidationError(message: "本地 Beancount 运行时缺少完整读取模型，请重新构建运行时")
        }
        return canonical
    }

    private func load(workspace: URL, entryFile: String) throws -> Result {
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
        let result = try Result(data: Data(String(cString: pointer).utf8))
        guard result.errors.isEmpty else {
            let message = result.errors.prefix(20).map { diagnostic in
                let location = diagnostic.filename.map { "\($0):\(diagnostic.lineno ?? 0) " } ?? ""
                return location + diagnostic.message
            }.joined(separator: "\n")
            throw ValidationError(message: message)
        }
        return result
        #else
        throw ValidationError(message: "此构建缺少本地 Beancount 校验运行时")
        #endif
    }
}
