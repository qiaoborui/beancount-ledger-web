import Foundation
import XCTest
@testable import LedgerMobile

@MainActor
final class LedgerCrashLogTests: XCTestCase {
    private struct Fixture {
        let log: LedgerCrashLog
        let directory: URL
        let defaults: UserDefaults
        let now: Date
    }

    private func fixture(now: Date = Date(timeIntervalSince1970: 1_764_000_000)) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LedgerCrashLogTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "ledger-crash-log-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return Fixture(
            log: LedgerCrashLog(directory: directory, defaults: defaults, now: { now },
                                version: { ("1.4.3", "10403") }),
            directory: directory, defaults: defaults, now: now)
    }

    func testBreadcrumbsKeepTheNewestThirtyInOrder() throws {
        let fixture = try fixture()
        fixture.log.updateContext(ledgerMode: "本机", page: "overview")
        for index in 0..<35 {
            fixture.log.record("step \(index)")
        }
        XCTAssertEqual(fixture.log.breadcrumbs.count, LedgerCrashLog.maximumBreadcrumbs)
        XCTAssertEqual(fixture.log.breadcrumbs.first?.message, "step 5")
        XCTAssertEqual(fixture.log.breadcrumbs.last?.message, "step 34")
        XCTAssertEqual(fixture.log.breadcrumbs.last?.ledgerMode, "本机")
        XCTAssertEqual(fixture.log.breadcrumbs.last?.page, "overview")
        XCTAssertEqual(fixture.log.breadcrumbs.last?.appVersion, "1.4.3")
        XCTAssertEqual(fixture.log.breadcrumbs.last?.at, fixture.now)
        let stored = LedgerCrashLog.loadBreadcrumbs(defaults: fixture.defaults)
        XCTAssertEqual(stored.count, LedgerCrashLog.maximumBreadcrumbs)
        XCTAssertEqual(stored.last?.message, "step 34")
    }

    func testBreadcrumbsSurviveANewInstanceAndTrimLineBreaks() throws {
        let fixture = try fixture()
        fixture.log.record("line one\nline two")
        let reopened = LedgerCrashLog(directory: fixture.directory, defaults: fixture.defaults,
                                      now: { fixture.now }, version: { ("1.4.3", "10403") })
        XCTAssertEqual(reopened.breadcrumbs.last?.message, "line one line two")
    }

    func testBreadcrumbLineCarriesTimeVersionAndContext() {
        // 2026-11-13T09:41:02Z
        let crumb = LedgerCrashBreadcrumb(
            at: Date(timeIntervalSince1970: 1_794_562_862),
            appVersion: "1.4.3", ledgerMode: "本机", page: "overview",
            scene: "active", message: "打开账本助手")
        let line = LedgerCrashLog.breadcrumbLine(crumb)
        XCTAssertTrue(line.contains("2026-11-13T09:41:02Z"), line)
        XCTAssertTrue(line.contains("1.4.3"), line)
        XCTAssertTrue(line.contains("本机"), line)
        XCTAssertTrue(line.contains("overview"), line)
        XCTAssertTrue(line.contains("active"), line)
        XCTAssertTrue(line.contains("打开账本助手"), line)
    }

    func testReportTextCarriesVersionTimeAndBreadcrumbs() {
        let date = Date(timeIntervalSince1970: 1_794_562_862)
        let crumb = LedgerCrashBreadcrumb(
            at: date, appVersion: "1.4.3", ledgerMode: "本机", page: "diagnostics",
            scene: "inactive", message: "scene background")
        let text = LedgerCrashLog.render(
            title: "未捕获的异常",
            details: [("异常", "NSInternalInconsistencyException")],
            at: date, appVersion: "1.4.3", build: "10403", breadcrumbs: [crumb])
        XCTAssertTrue(text.contains("1.4.3 (10403)"), text)
        XCTAssertTrue(text.contains("2026-11-13T09:41:02Z"), text)
        XCTAssertTrue(text.contains("NSInternalInconsistencyException"), text)
        XCTAssertTrue(text.contains("scene background"), text)
        XCTAssertTrue(text.contains("本机"), text)
        XCTAssertTrue(text.contains("diagnostics"), text)
    }

    func testEntriesAreNewestFirstAndPruneTheOldest() throws {
        let fixture = try fixture()
        let base = Date(timeIntervalSince1970: 1_764_000_000)
        for index in 0..<(LedgerCrashLog.maximumEntries + 1) {
            LedgerCrashLog.write("report \(index)", prefix: "crash",
                                 date: base.addingTimeInterval(Double(index) * 10),
                                 directory: fixture.directory)
        }
        let entries = fixture.log.entries()
        XCTAssertEqual(entries.count, LedgerCrashLog.maximumEntries)
        XCTAssertEqual(entries.first?.text, "report 20")
        XCTAssertEqual(entries.last?.text, "report 1")
        XCTAssertEqual(Set(entries.map(\.title)).count, 1)
        let oldest = fixture.directory
            .appendingPathComponent("crash-\(LedgerCrashLog.stamp(base)).log")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
    }

    func testEntriesOrderCrashAndMetricKitReportsTogether() throws {
        let fixture = try fixture()
        let base = Date(timeIntervalSince1970: 1_764_000_000)
        LedgerCrashLog.write("older crash", prefix: "crash", date: base, directory: fixture.directory)
        let crash = LedgerMetricKitCrash(
            applicationVersion: "1.4.3", exceptionType: "1", exceptionCode: nil,
            signal: "6", terminationReason: nil, virtualMemoryRegionInfo: nil,
            callStackTree: "{}")
        LedgerCrashLog.writeMetricKitReport(crash, at: base.addingTimeInterval(60),
                                            directory: fixture.directory)
        let entries = fixture.log.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].text.contains("callStackTree"), entries[0].text)
        XCTAssertEqual(entries[1].text, "older crash")
    }

    func testUncaughtExceptionReportIsWrittenWithTheException() throws {
        let fixture = try fixture()
        let exception = NSException(name: NSExceptionName(rawValue: "TestException"),
                                    reason: "assertion from a test", userInfo: nil)
        LedgerCrashLog.writeUncaughtException(exception, at: fixture.now,
                                              directory: fixture.directory,
                                              defaults: fixture.defaults)
        let entries = fixture.log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].text.contains("TestException"), entries[0].text)
        XCTAssertTrue(entries[0].text.contains("assertion from a test"), entries[0].text)
    }

    func testDeleteAndClearRemoveOnlyReports() throws {
        let fixture = try fixture()
        let base = Date(timeIntervalSince1970: 1_764_000_000)
        LedgerCrashLog.write("first", prefix: "crash", date: base, directory: fixture.directory)
        let metric = fixture.directory
            .appendingPathComponent("metrickit-\(LedgerCrashLog.stamp(base.addingTimeInterval(10))).json")
        try Data("{}".utf8).write(to: metric)
        let entries = fixture.log.entries()
        XCTAssertEqual(entries.count, 2)
        // A file in the directory that this log does not own stays.
        let other = fixture.directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: other)

        fixture.log.delete(entries[0])
        XCTAssertEqual(fixture.log.entries().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))

        fixture.log.clear()
        XCTAssertTrue(fixture.log.entries().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testStampUsesTheReportedFileFormat() {
        // 2026-11-13T09:41:02Z
        XCTAssertEqual(LedgerCrashLog.stamp(Date(timeIntervalSince1970: 1_794_562_862)),
                       "2026-11-13T09-41-02Z")
    }
}
