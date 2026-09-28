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

        init(data: Data, includeCanonical: Bool) throws {
            struct Diagnostics: Decodable { let errors: [Diagnostic] }
            errors = try JSONDecoder().decode(Diagnostics.self, from: data).errors
            if includeCanonical, errors.isEmpty,
               let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let model = object["canonical"] as? [String: Any] {
                canonical = try JSONSerialization.data(withJSONObject: model)
            } else {
                canonical = nil
            }
        }
    }

    func validate(workspace: URL, entryFile: String = "main.bean") throws {
        _ = try load(workspace: workspace, entryFile: entryFile, includeCanonical: false)
    }

    /// The canonical loader's booked, plugin-transformed entries are the
    /// financial read model. Source files remain the editable representation.
    func canonicalModel(workspace: URL, entryFile: String = "main.bean") throws -> Data {
        let result = try load(workspace: workspace, entryFile: entryFile, includeCanonical: true)
        guard let canonical = result.canonical else {
            throw ValidationError(message: "本地 Beancount 运行时缺少完整读取模型，请重新构建运行时")
        }
        return canonical
    }

    /// Output directory must be caller-owned, protected and outside the source.
    /// The caller removes the exclusive file when ingestion completes/fails.
    struct StreamDescriptor: Decodable, Sendable {
        let version: Int
        let entries: Int
        let bytes: Int
        let sha256: String
    }

    func exportCanonical(workspace: URL, entryFile: String = "main.bean", to output: URL) throws -> StreamDescriptor {
        #if canImport(BeancountRuntime)
        try initializeIfNeeded()
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL
        let parent = output.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let target = parent.appendingPathComponent(output.lastPathComponent)
        guard parent != root, !parent.path.hasPrefix(root.path + "/"),
              !FileManager.default.fileExists(atPath: target.path) else {
            throw ValidationError(message: "模型导出必须使用账本外的独立临时文件")
        }
        let pointer = root.path.withCString { root in
            entryFile.withCString { entry in
                target.path.withCString { BRExportCanonical(root, entry, $0) }
            }
        }
        guard let pointer else { throw ValidationError(message: "本地导出内存不足") }
        defer { BRFree(pointer) }
        struct Reply: Decodable {
            struct Diagnostic: Decodable { let message: String }
            let errors: [Diagnostic]
            let stream: StreamDescriptor?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: Data(String(cString: pointer).utf8))
        guard reply.errors.isEmpty else { throw ValidationError(message: reply.errors.prefix(20).map(\.message).joined(separator: "\n")) }
        guard let descriptor = reply.stream, descriptor.version == 1,
              descriptor.bytes > 0, descriptor.bytes <= 256 * 1024 * 1024,
              descriptor.entries >= 0, descriptor.sha256.count == 64 else {
            throw ValidationError(message: "本地模型导出描述无效")
        }
        return descriptor
        #else
        throw ValidationError(message: "此构建缺少本地 Beancount 校验运行时")
        #endif
    }

    private func initializeIfNeeded() throws {
        #if canImport(BeancountRuntime)
        if !initialized {
            let failure = Bundle.main.bundlePath.withCString { BRInitialize($0) }
            if let failure {
                defer { BRFree(failure) }
                throw ValidationError(message: String(cString: failure))
            }
            initialized = true
        }
        #else
        throw ValidationError(message: "此构建缺少本地 Beancount 校验运行时")
        #endif
    }

    private func load(workspace: URL, entryFile: String, includeCanonical: Bool) throws -> Result {
        #if canImport(BeancountRuntime)
        try initializeIfNeeded()
        let pointer = workspace.path.withCString { root in
            entryFile.withCString { entry in
                includeCanonical ? BRValidate(root, entry) : BRValidateOnly(root, entry)
            }
        }
        guard let pointer else { throw ValidationError(message: "本地校验器内存不足") }
        defer { BRFree(pointer) }
        let result = try Result(data: Data(String(cString: pointer).utf8), includeCanonical: includeCanonical)
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
