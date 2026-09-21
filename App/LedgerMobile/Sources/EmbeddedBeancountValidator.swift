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

    struct StreamSummary: Decodable, Sendable, Equatable {
        let records: Int64
        let directives: Int64
        let postings: Int64
        let sourceDigest: String
        let sha256: String
        enum CodingKeys: String, CodingKey {
            case records, directives, postings, sourceDigest = "source_digest", sha256
        }
    }

    /// The source must already be frozen; derivedDirectory must already exist,
    /// be private/protected, and be outside the source. This only exports bytes;
    /// it never reads the spool or publishes a generation. The caller owns cleanup
    /// even if cancellation arrives after successful export. Python is synchronous:
    /// cancellation suppresses delivery, not an in-progress canonical load.
    func exportStream(workspace: URL, entryFile: String = "main.bean",
                      derivedDirectory: URL, spoolName: String) throws -> StreamSummary {
        try Task.checkCancellation()
        let paths = try Self.streamPaths(workspace: workspace, entryFile: entryFile,
                                         derivedDirectory: derivedDirectory, spoolName: spoolName)
        #if canImport(BeancountRuntime)
        if !initialized {
            let failure = Bundle.main.bundlePath.withCString { BRInitialize($0) }
            if let failure {
                BRFree(failure)
                throw BoundedReadIndexError.unavailable
            }
            initialized = true
        }
        let pointer = paths.workspace.withCString { root in
            entryFile.withCString { entry in
                paths.derived.withCString { derived in
                    spoolName.withCString { name in BRExportStream(root, entry, derived, name) }
                }
            }
        }
        guard let pointer else { throw BoundedReadIndexError.unavailable }
        defer { BRFree(pointer) }
        // Never use unbounded String(cString:) for this ABI. Include the NUL check
        // but allocate/copy only after the small-response cap has passed.
        let limit = 1024 // BR_EXPORT_STREAM_MAX_RESPONSE_BYTES
        var count = 0
        while count <= limit && pointer[count] != 0 { count += 1 }
        guard count <= limit else { throw BoundedReadIndexError.resourceLimit }
        let data = Data(bytes: pointer, count: count)
        guard let json = String(data: data, encoding: .utf8) else { throw BoundedReadIndexError.corrupt }
        let summary = try Self.decodeStreamSummary(json)
        try Task.checkCancellation()
        return summary
        #else
        _ = paths
        throw BoundedReadIndexError.unavailable
        #endif
    }

    nonisolated static func streamPaths(workspace: URL, entryFile: String,
                                       derivedDirectory: URL, spoolName: String) throws -> (workspace: String, derived: String) {
        let root = try BoundedIndexWire.resolvedDirectory(workspace)
        let derived = try BoundedIndexWire.resolvedDirectory(derivedDirectory)
        _ = try BoundedIndexWire.path(entryFile)
        guard !entryFile.hasPrefix("/"), entryFile.split(separator: "/").allSatisfy({ $0 != "." }),
              derived != root, !derived.hasPrefix(root.hasSuffix("/") ? root : root + "/"),
              (1...128).contains(spoolName.utf8.count) else { throw BoundedReadIndexError.invalidRequest }
        let bytes = Array(spoolName.utf8)
        func alphanumeric(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) }
        guard let first = bytes.first, alphanumeric(first),
              bytes.allSatisfy({ alphanumeric($0) || $0 == 46 || $0 == 95 || $0 == 45 }) else { throw BoundedReadIndexError.invalidRequest }
        return (root, derived)
    }

    nonisolated static func decodeStreamSummary(_ json: String) throws -> StreamSummary {
        struct Response: Decodable {
            let ok: Bool
            let summary: StreamSummary?
        }
        let response = try BoundedIndexWire.decode(Response.self, json: json, limit: 1024)
        guard response.ok, let summary = response.summary else { throw BoundedReadIndexError.invalidStream }
        func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard summary.records >= 0, summary.directives >= 0, summary.postings >= 0,
              summary.directives <= summary.records, summary.postings <= summary.records,
              digest(summary.sourceDigest), digest(summary.sha256) else { throw BoundedReadIndexError.corrupt }
        return summary
    }

    private func load(workspace: URL, entryFile: String, includeCanonical: Bool) throws -> Result {
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
