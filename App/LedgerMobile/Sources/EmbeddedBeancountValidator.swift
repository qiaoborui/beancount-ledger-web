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

    /// Points the Python loader at a per-ledger cache so a second load of the
    /// same source reuses beancount's pickled result instead of repeating the
    /// parse and booking stages. On a 100k ledger that is ~27s down to ~2s.
    ///
    /// The directory is derived from the workspace and must already be owned by
    /// this app; the Python side refuses anything else, so a workspace that
    /// cannot offer a cache simply runs uncached. The file name there is a
    /// digest of every source file, so different content cannot reuse an entry.
    static func prepareLoaderCache(workspace: URL) {
        #if canImport(Darwin)
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL
        let directory = root.appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("loader-cache", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory,
            withIntermediateDirectories: true)) != nil else { return }
        _ = setenv(loaderCacheEnvironment, directory.path, 1)
        #endif
    }

    static let loaderCacheEnvironment = "LEDGER_LOAD_CACHE_DIR"

    func validate(workspace: URL, entryFile: String = "main.bean") throws {
        _ = try load(workspace: workspace, entryFile: entryFile, includeCanonical: false)
    }

    /// The canonical loader's booked, plugin-transformed entries are the
    /// financial read model. Source files remain the editable representation.
    func canonicalModel(workspace: URL, entryFile: String = "main.bean") throws -> Data {
        let result = try load(workspace: workspace, entryFile: entryFile, includeCanonical: true)
        guard let canonical = result.canonical else {
            throw ValidationError(message: String(localized: "本地 Beancount 运行时缺少完整读取模型，请重新构建运行时"))
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
        /// Per-stage loader milliseconds (parse/booking/plugins/validate).
        /// Present only when the Python timing sink was explicitly enabled;
        /// older exporters omit it and decoding stays compatible.
        var timings: [String: Double]? = nil
    }

    func exportCanonical(workspace: URL, entryFile: String = "main.bean", to output: URL) throws -> StreamDescriptor {
        #if canImport(BeancountRuntime)
        // Ask the Python loader for its stage breakdown for this export only.
        // The canonical records themselves are unaffected; the timings ride in
        // the reply descriptor, never in the stream.
        LocalLedgerPerformance.preparePythonTimings()
        Self.prepareLoaderCache(workspace: workspace)
        let interval = LocalLedgerPerformance.begin(.pythonExport)
        defer { LocalLedgerPerformance.end(interval) }
        try initializeIfNeeded()
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL
        let parent = output.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let target = parent.appendingPathComponent(output.lastPathComponent)
        guard parent != root, !parent.path.hasPrefix(root.path + "/"),
              !FileManager.default.fileExists(atPath: target.path) else {
            throw ValidationError(message: String(localized: "模型导出必须使用账本外的独立临时文件"))
        }
        let pointer = root.path.withCString { root in
            entryFile.withCString { entry in
                target.path.withCString { BRExportCanonical(root, entry, $0) }
            }
        }
        guard let pointer else { throw ValidationError(message: String(localized: "本地导出内存不足")) }
        defer { BRFree(pointer) }
        struct Reply: Decodable {
            let errors: [Result.Diagnostic]
            let stream: StreamDescriptor?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: Data(String(cString: pointer).utf8))
        // Exports now stand in for validate-only publication checks, so report
        // diagnostics with the same file:line prefix.
        guard reply.errors.isEmpty else { throw ValidationError(message: Self.message(for: reply.errors)) }
        guard let descriptor = reply.stream, descriptor.version == 1,
              descriptor.bytes > 0, descriptor.bytes <= 256 * 1024 * 1024,
              descriptor.entries >= 0, descriptor.sha256.count == 64 else {
            throw ValidationError(message: String(localized: "本地模型导出描述无效"))
        }
        if let timings = descriptor.timings {
            LocalLedgerPerformance.recordPythonTimings(timings)
        }
        // Opt-in measurement recording only (a no-op otherwise): this is the one
        // place where the exporter reports the canonical entry count, stream
        // bytes and stream digest, and the report quotes them from here rather
        // than re-reading the stream cache.
        LocalLedgerPerformance.recorder.recordLedgerIdentity(
            .init(canonicalEntries: descriptor.entries, streamBytes: descriptor.bytes,
                  streamSha256: descriptor.sha256))
        return descriptor
        #else
        throw ValidationError(message: String(localized: "此构建缺少本地 Beancount 校验运行时"))
        #endif
    }

    private static func message(for errors: [Result.Diagnostic]) -> String {
        errors.prefix(20).map { diagnostic in
            let location = diagnostic.filename.map { "\($0):\(diagnostic.lineno ?? 0) " } ?? ""
            return location + diagnostic.message
        }.joined(separator: "\n")
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
        throw ValidationError(message: String(localized: "此构建缺少本地 Beancount 校验运行时"))
        #endif
    }

    private func load(workspace: URL, entryFile: String, includeCanonical: Bool) throws -> Result {
        #if canImport(BeancountRuntime)
        let interval = LocalLedgerPerformance.begin(.pythonLoad)
        defer { LocalLedgerPerformance.end(interval) }
        Self.prepareLoaderCache(workspace: workspace)
        try initializeIfNeeded()
        let pointer = workspace.path.withCString { root in
            entryFile.withCString { entry in
                includeCanonical ? BRValidate(root, entry) : BRValidateOnly(root, entry)
            }
        }
        guard let pointer else { throw ValidationError(message: String(localized: "本地校验器内存不足")) }
        defer { BRFree(pointer) }
        let result = try Result(data: Data(String(cString: pointer).utf8), includeCanonical: includeCanonical)
        guard result.errors.isEmpty else { throw ValidationError(message: Self.message(for: result.errors)) }
        return result
        #else
        throw ValidationError(message: String(localized: "此构建缺少本地 Beancount 校验运行时"))
        #endif
    }
}
