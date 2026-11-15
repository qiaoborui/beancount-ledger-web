import Foundation
#if canImport(LedgerCore)
import LedgerCore
#endif
#if canImport(LedgerLinux)
import LedgerLinux
#endif

/// The App's built-in Linux, where the assistant's `bash` tool runs: an Alpine
/// root filesystem run by the iSH AArch64 engine inside this process (see
/// Linux/LedgerLinux.h). The conversation's draft is mounted at /workspace for
/// each command; nothing else of the App's files is visible to the guest.
///
/// The root filesystem ships in the App as a tarball and is unpacked into
/// Application Support/Linux on first use, kept out of backups. The machine
/// boots on the first command and lives until the App ends.
final class LedgerLinuxMachine: @unchecked Sendable {
    static let shared = LedgerLinuxMachine()

    /// Whether the assistant gets the `bash` tool. On by default.
    static let enabledKey = "ledger.agent.linux"
    /// Set by 重置 while the machine is running; the reset happens at the next
    /// launch, before anything could boot it.
    static let pendingResetKey = "ledger.agent.linux.pending-reset"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Whether this build carries the engine. The x86_64 simulator does not.
    static var engineAvailable: Bool {
        #if canImport(LedgerLinux)
        return ledger_linux_available()
        #else
        return false
        #endif
    }

    let directory: URL
    var rootfs: URL { directory.appendingPathComponent("alpine", isDirectory: true) }
    private var devDirectory: URL { directory.appendingPathComponent("dev", isDirectory: true) }

    private let lock = NSLock()
    /// One command at a time, from the request to the result.
    private let gate = NSLock()
    private var bootAttempted = false
    private var bootError: String?
    private var activeID: String?
    private var cancelledIDs: Set<String> = []

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = support.appendingPathComponent("Linux", isDirectory: true)
    }

    // MARK: Settings

    /// Called once at launch: carries out a pending reset and hands the native
    /// assistant the runner when the tool is on.
    static func install() {
        if UserDefaults.standard.bool(forKey: pendingResetKey) {
            UserDefaults.standard.removeObject(forKey: pendingResetKey)
            try? FileManager.default.removeItem(at: shared.directory)
        }
        applyRunner()
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        applyRunner()
    }

    private static func applyRunner() {
        #if canImport(LedgerCore)
        MobileagentSetLinuxRunner(isEnabled && engineAvailable ? Bridge() : nil)
        #endif
    }

    /// Whether the machine has booted in this process.
    var hasBooted: Bool { lock.withLock { bootAttempted && bootError == nil } }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: rootfs.appendingPathComponent("bin/busybox").path) }

    /// Removes the unpacked system now, or at the next launch when the
    /// machine is running. Answers whether it had to wait.
    @discardableResult
    func reset() -> Bool {
        let running = lock.withLock { bootAttempted }
        if running {
            UserDefaults.standard.set(true, forKey: Self.pendingResetKey)
            return true
        }
        try? FileManager.default.removeItem(at: directory)
        return false
    }

    /// Bytes the unpacked system takes on disk.
    func diskUsage() -> Int64 {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                                                         options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    // MARK: Install and boot

    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): text
            }
        }
    }

    /// Unpacks the bundled root filesystem if it is not there yet. The
    /// archive goes into a fresh directory that is moved into place only when
    /// it is complete, so an interrupted unpack leaves nothing half-made.
    func installIfNeeded() throws {
        if isInstalled { return }
        guard let archive = Bundle.main.url(forResource: "alpine-minirootfs", withExtension: "tar.gz") else {
            throw Failure.message(String(localized: "这个版本的 App 没有带内置 Linux。"))
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        let staging = directory.appendingPathComponent("alpine.partial-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        #if canImport(LedgerCore)
        let request = try JSONSerialization.data(withJSONObject: ["archive": archive.path, "destination": staging.path])
        let message = MobileagentExtractRootfsJSON(String(decoding: request, as: UTF8.self))
        if !message.isEmpty { throw Failure.message(String(localized: "内置 Linux 解包失败：\(message)")) }
        #else
        throw Failure.message(String(localized: "这个版本的 App 没有带内置 Linux。"))
        #endif
        try manager.createDirectory(at: staging.appendingPathComponent("workspace"), withIntermediateDirectories: true)
        // The guest resolves names itself; a minirootfs has no resolver set.
        let resolver = staging.appendingPathComponent("etc/resolv.conf")
        if !manager.fileExists(atPath: resolver.path) {
            try? Data("nameserver 223.5.5.5\nnameserver 1.1.1.1\n".utf8).write(to: resolver)
        }
        try? manager.removeItem(at: rootfs)
        try manager.moveItem(at: staging, to: rootfs)
    }

    /// Unpacks and boots on first use. A failed boot is remembered: the
    /// engine cannot boot twice in one process.
    private func ensureBooted() throws {
        if let error = lock.withLock({ bootAttempted ? (bootError ?? "") : nil }) {
            if !error.isEmpty { throw Failure.message(error) }
            #if canImport(LedgerLinux)
            if !ledger_linux_running() {
                throw Failure.message(String(localized: "内置 Linux 已经停止，重新打开 App 后再试。"))
            }
            #endif
            return
        }
        try installIfNeeded()
        #if canImport(LedgerLinux)
        let code = ledger_linux_boot(rootfs.path, devDirectory.path)
        let failure = code == 0 ? nil : String(localized: "内置 Linux 启动失败（\(code)）。")
        lock.withLock {
            bootAttempted = true
            bootError = failure
        }
        if let failure { throw Failure.message(failure) }
        #else
        throw Failure.message(String(localized: "这台设备上没有内置 Linux。"))
        #endif
    }

    // MARK: Running

    private struct Request: Decodable {
        var id: String
        var workspace: String
        var command: String
        var timeoutSeconds: Int
        var maxOutputBytes: Int
    }

    private struct RunResult: Encodable {
        var exitCode = 0
        var output = ""
        var outputBytes: Int64 = 0
        var truncated = false
        var timedOut = false
        var cancelled = false
        var error: String?
    }

    /// Runs one command for the native assistant and answers in JSON. Called
    /// on a Go thread, which it blocks until the command ends.
    func run(_ requestJSON: String) -> String {
        let result: RunResult
        if let request = try? JSONDecoder().decode(Request.self, from: Data(requestJSON.utf8)) {
            result = run(request)
        } else {
            result = RunResult(exitCode: -1, error: "bad request")
        }
        let data = (try? JSONEncoder().encode(result)) ?? Data(#"{"error":"encode"}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func run(_ request: Request) -> RunResult {
        gate.lock()
        defer { gate.unlock() }
        let cancelledEarly = lock.withLock { () -> Bool in
            if cancelledIDs.remove(request.id) != nil { return true }
            activeID = request.id
            return false
        }
        if cancelledEarly { return RunResult(exitCode: 137, cancelled: true) }
        defer { lock.withLock { activeID = nil } }
        do {
            try ensureBooted()
        } catch {
            return RunResult(exitCode: -1, error: error.localizedDescription)
        }
        #if canImport(LedgerLinux)
        var raw = ledger_linux_result()
        let code = ledger_linux_run(request.workspace, request.command, Int32(clamping: request.timeoutSeconds * 1000),
                                    Int32(clamping: request.maxOutputBytes), &raw)
        defer { ledger_linux_result_free(&raw) }
        if code != 0 {
            return RunResult(exitCode: -1, error: String(localized: "内置 Linux 没能运行这条命令（\(code)）。"))
        }
        var result = RunResult()
        result.exitCode = Int(raw.exit_code)
        result.timedOut = raw.timed_out
        result.cancelled = raw.cancelled
        result.truncated = raw.truncated
        result.outputBytes = raw.output_bytes
        if let output = raw.output, raw.output_length > 0 {
            let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(output).assumingMemoryBound(to: UInt8.self),
                                            count: Int(raw.output_length))
            result.output = String(decoding: bytes, as: UTF8.self)
        }
        return result
        #else
        return RunResult(exitCode: -1, error: String(localized: "这台设备上没有内置 Linux。"))
        #endif
    }

    /// Stops the command with this id, or keeps it from starting.
    func cancel(_ id: String) {
        let active = lock.withLock { () -> Bool in
            if activeID == id { return true }
            cancelledIDs.insert(id)
            return false
        }
        #if canImport(LedgerLinux)
        if active { ledger_linux_cancel() }
        #endif
    }

    #if canImport(LedgerCore)
    /// Called on Go threads, never on the main thread.
    private final class Bridge: NSObject, MobileagentLinuxRunnerProtocol {
        func run(_ requestJSON: String?) -> String {
            LedgerLinuxMachine.shared.run(requestJSON ?? "")
        }

        func cancel(_ id: String?) {
            LedgerLinuxMachine.shared.cancel(id ?? "")
        }
    }
    #endif
}
