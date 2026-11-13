import Foundation
#if os(iOS)
import MetricKit
import UIKit
#endif

/// One fixed line of context for a crash report. No free-form user text.
struct LedgerCrashBreadcrumb: Codable, Equatable, Sendable {
    var at: Date
    var appVersion: String
    var ledgerMode: String
    var page: String
    var scene: String
    var message: String
}

/// One log file, newest first from `LedgerCrashLog.entries()`.
struct LedgerCrashEntry: Identifiable, Equatable, Sendable {
    let url: URL
    let title: String
    let date: Date
    let size: Int
    let text: String

    var id: URL { url }
}

/// MetricKit's crash values, lifted out of the framework type so the writer is
/// a plain value and the callback's thread stays out of the actor.
struct LedgerMetricKitCrash: Sendable {
    var applicationVersion: String
    var exceptionType: String?
    var exceptionCode: String?
    var signal: String?
    var terminationReason: String?
    var virtualMemoryRegionInfo: String?
    var callStackTree: String
}

/// A small, dependency-free crash log that survives the app process.
///
/// Two kinds of report land in `Application Support/LedgerDiagnostics/`:
/// `crash-*.log` written from `NSSetUncaughtExceptionHandler` (an Objective-C
/// exception, which covers most of the runtime traps the system does not kill
/// outright) and `metrickit-*.json` written from MetricKit's diagnostic
/// payloads. The newest 20 files are kept.
///
/// Every report carries the latest breadcrumbs, so the path that led to it is
/// visible even when the report itself is only "SIGABRT". A breadcrumb is a
/// fixed, app-authored line with the time, app version, ledger mode, page and
/// scene; it never includes a question, an amount, an account or an API key.
/// The same breadcrumbs stay in memory and in `UserDefaults` (30 at most) so
/// the uncaught-exception handler, which runs on the crashing thread, can read
/// them without hopping to the main actor.
@MainActor
final class LedgerCrashLog {
    static let shared = LedgerCrashLog()

    nonisolated static let directoryName = "LedgerDiagnostics"
    nonisolated static let maximumEntries = 20
    nonisolated static let maximumBreadcrumbs = 30
    nonisolated static let breadcrumbsKey = "ledger.diagnostics.breadcrumbs"
    nonisolated static let maximumMessageLength = 200
    nonisolated static let maximumReportBytes = 256_000

    private let directory: URL
    private let defaults: UserDefaults
    private let now: () -> Date
    private let version: () -> (version: String, build: String)
    private var crumbs: [LedgerCrashBreadcrumb] = []
    private var ledgerMode = "未打开"
    private var page = "app"
    private var installed = false
    #if os(iOS)
    private var metricKitSubscriber: MetricKitSubscriber?
    #endif

    init(directory: URL? = nil,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         version: @escaping () -> (version: String, build: String) = LedgerCrashLog.bundleVersion) {
        self.directory = directory ?? LedgerCrashLog.defaultDirectory()
        self.defaults = defaults
        self.now = now
        self.version = version
        crumbs = LedgerCrashLog.loadBreadcrumbs(defaults: defaults)
    }

    // MARK: Public API

    /// Called once, as early as possible at launch: creates the directory and
    /// starts the MetricKit and uncaught-exception hooks. Recording "启动"
    /// here makes the first line of any later report the launch itself.
    func install() {
        guard !installed else { return }
        installed = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune()
        #if os(iOS)
        let subscriber = MetricKitSubscriber()
        metricKitSubscriber = subscriber
        MXMetricManager.shared.add(subscriber)
        ledgerCrashLogPreviousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(ledgerCrashLogHandleException)
        #endif
        record("启动")
    }

    /// Records one breadcrumb, keeping the newest `maximumBreadcrumbs`.
    func record(_ message: String) {
        let app = version()
        let clean = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let crumb = LedgerCrashBreadcrumb(
            at: now(),
            appVersion: app.version,
            ledgerMode: ledgerMode,
            page: page,
            scene: Self.sceneState,
            message: String(clean.prefix(Self.maximumMessageLength)))
        crumbs.append(crumb)
        if crumbs.count > Self.maximumBreadcrumbs {
            crumbs.removeFirst(crumbs.count - Self.maximumBreadcrumbs)
        }
        if let data = try? JSONEncoder().encode(crumbs) {
            defaults.set(data, forKey: Self.breadcrumbsKey)
        }
    }

    /// Updates the fixed context a later breadcrumb carries.
    func updateContext(ledgerMode: String? = nil, page: String? = nil) {
        if let ledgerMode { self.ledgerMode = ledgerMode }
        if let page { self.page = page }
    }

    /// The stored breadcrumbs, oldest first.
    var breadcrumbs: [LedgerCrashBreadcrumb] { crumbs }

    /// The reports, newest first. Old files beyond `maximumEntries` are
    /// removed first, so a crash loop cannot fill the device.
    func entries() -> [LedgerCrashEntry] {
        prune()
        // Newest first; the file name is the timestamp.
        return Self.reportFiles(in: directory).reversed().compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? now()
            let size = values?.fileSize ?? data.count
            let text = String(decoding: data.prefix(Self.maximumReportBytes), as: UTF8.self)
            return LedgerCrashEntry(url: url, title: Self.title(for: url.lastPathComponent),
                                    date: date, size: size, text: text)
        }
    }

    /// Removes a single report, after it has been copied or shared.
    func delete(_ entry: LedgerCrashEntry) {
        try? FileManager.default.removeItem(at: entry.url)
    }

    /// Removes every report this log wrote; breadcrumbs stay for the next one.
    func clear() {
        for url in Self.reportFiles(in: directory) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Reports

    /// The text of an uncaught Objective-C exception, including the app build
    /// and the breadcrumbs that led to it. `UserDefaults` and the bundle are
    /// safe to read on the crashing thread; the actor-isolated state is not.
    nonisolated static func uncaughtExceptionReport(_ exception: NSException,
                                                    at date: Date = Date()) -> String {
        let app = bundleVersion()
        let details: [(String, String)] = [
            ("异常", exception.name.rawValue),
            ("原因", exception.reason ?? ""),
            ("调用栈", exception.callStackSymbols.prefix(128).joined(separator: "\n")),
        ]
        return render(title: String(localized: "未捕获的异常"),
                      details: details, at: date,
                      appVersion: app.version, build: app.build,
                      breadcrumbs: loadBreadcrumbs(defaults: .standard))
    }

    /// The report text. Fixed labels, the build and the breadcrumbs only: no
    /// ledger text or credentials are ever passed in here.
    nonisolated static func render(title: String, details: [(String, String)], at date: Date,
                                   appVersion: String, build: String,
                                   breadcrumbs: [LedgerCrashBreadcrumb]) -> String {
        var lines = [
            String(localized: "Ledger 崩溃日志"),
            String(localized: "标题: \(title)"),
            String(localized: "时间: \(isoTimestamp(date))"),
            String(localized: "App: \(appVersion) (\(build))"),
        ]
        for (name, value) in details where !value.isEmpty {
            // The labels are diagnostic field names, not UI copy: keep them
            // fixed so a report reads the same whatever the app language.
            lines.append("\(name): \(value)")
        }
        lines.append(String(localized: "面包屑 (\(breadcrumbs.count)):"))
        if breadcrumbs.isEmpty {
            lines.append("-")
        } else {
            for crumb in breadcrumbs {
                lines.append(breadcrumbLine(crumb))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `2026-11-13T09:41:02Z · 1.4.3 · 本机 · overview · active · 打开账本助手`
    nonisolated static func breadcrumbLine(_ crumb: LedgerCrashBreadcrumb) -> String {
        [isoTimestamp(crumb.at), crumb.appVersion, crumb.ledgerMode, crumb.page,
         crumb.scene, crumb.message].joined(separator: " · ")
    }

    /// Writes a crash report from the crashing thread.
    nonisolated static func writeUncaughtException(_ exception: NSException, at date: Date = Date()) {
        let text = uncaughtExceptionReport(exception, at: date)
        write(text, prefix: "crash", date: date, directory: defaultDirectory())
    }

    /// Writes one MetricKit crash diagnostic as JSON. The call stack tree is
    /// the JSON MetricKit already provides, so nothing is re-interpreted.
    nonisolated static func writeMetricKitReport(_ crash: LedgerMetricKitCrash, at date: Date = Date()) {
        let crumbs = loadBreadcrumbs(defaults: .standard)
        var object: [String: Any] = [
            "title": String(localized: "MetricKit 崩溃诊断"),
            "capturedAt": isoTimestamp(date),
            "appVersion": crash.applicationVersion,
            "build": bundleVersion().build,
            "callStackTree": crash.callStackTree,
            "breadcrumbs": crumbs.map { crumb in
                [
                    "at": isoTimestamp(crumb.at),
                    "appVersion": crumb.appVersion,
                    "ledgerMode": crumb.ledgerMode,
                    "page": crumb.page,
                    "scene": crumb.scene,
                    "message": crumb.message,
                ]
            },
        ]
        if let value = crash.exceptionType { object["exceptionType"] = value }
        if let value = crash.exceptionCode { object["exceptionCode"] = value }
        if let value = crash.signal { object["signal"] = value }
        if let value = crash.terminationReason { object["terminationReason"] = value }
        if let value = crash.virtualMemoryRegionInfo { object["virtualMemoryRegionInfo"] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                    options: [.prettyPrinted, .sortedKeys]) else { return }
        let directory = defaultDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("metrickit-\(stamp(date)).json")
        try? data.write(to: url, options: .atomic)
        pruneDirectory(directory)
    }

    // MARK: Files

    nonisolated static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// `2026-11-13T09-41-02Z`, the format the files are named with.
    nonisolated static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter.string(from: date)
    }

    nonisolated static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    nonisolated static func title(for fileName: String) -> String {
        fileName.hasPrefix("metrickit-")
            ? String(localized: "MetricKit 崩溃诊断")
            : String(localized: "意外退出")
    }

    /// The reports this log owns, oldest first (the file name is the time).
    nonisolated static func reportFiles(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return files
            .filter { url in
                let name = url.lastPathComponent
                return (name.hasPrefix("crash-") && url.pathExtension == "log")
                    || (name.hasPrefix("metrickit-") && url.pathExtension == "json")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated static func pruneDirectory(_ directory: URL) {
        let files = reportFiles(in: directory)
        guard files.count > maximumEntries else { return }
        for url in files.prefix(files.count - maximumEntries) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func prune() {
        Self.pruneDirectory(directory)
    }

    nonisolated static func write(_ text: String, prefix: String, date: Date, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(prefix)-\(stamp(date)).log")
        guard let data = text.data(using: .utf8) else { return }
        try? data.write(to: url, options: .atomic)
        pruneDirectory(directory)
    }

    nonisolated static func loadBreadcrumbs(defaults: UserDefaults) -> [LedgerCrashBreadcrumb] {
        guard let data = defaults.data(forKey: breadcrumbsKey),
              let decoded = try? JSONDecoder().decode([LedgerCrashBreadcrumb].self, from: data) else { return [] }
        return Array(decoded.suffix(maximumBreadcrumbs))
    }

    nonisolated static func bundleVersion() -> (version: String, build: String) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return (version, build)
    }

    static var sceneState: String {
        #if os(iOS)
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
        #else
        return "unknown"
        #endif
    }

    #if os(iOS)
    /// The snapshot the MetricKit callback hands to the writer.
    nonisolated static func snapshot(_ crash: MXCrashDiagnostic) -> LedgerMetricKitCrash {
        LedgerMetricKitCrash(
            applicationVersion: crash.applicationVersion,
            exceptionType: crash.exceptionType.map { String(describing: $0) },
            exceptionCode: crash.exceptionCode.map { String(describing: $0) },
            signal: crash.signal.map { String(describing: $0) },
            terminationReason: crash.terminationReason,
            virtualMemoryRegionInfo: crash.virtualMemoryRegionInfo,
            callStackTree: String(decoding: crash.callStackTree.jsonRepresentation(), as: UTF8.self))
    }
    #endif
}

#if os(iOS)
/// MetricKit's subscriber must be an `NSObject`; it stays a separate value so
/// the log itself keeps its main-actor API.
private final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                LedgerCrashLog.writeMetricKitReport(LedgerCrashLog.snapshot(crash))
            }
        }
    }
}

private nonisolated(unsafe) var ledgerCrashLogPreviousExceptionHandler: NSUncaughtExceptionHandler?

/// Runs on the crashing thread: writes the report, then lets whoever installed
/// a handler before us see the exception.
private func ledgerCrashLogHandleException(_ exception: NSException) {
    LedgerCrashLog.writeUncaughtException(exception)
    ledgerCrashLogPreviousExceptionHandler?(exception)
}
#endif
