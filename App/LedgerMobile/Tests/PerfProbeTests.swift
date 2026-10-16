import Foundation
import XCTest
@testable import LedgerMobile

// TEMPORARY performance probe — not for commit.
final class PerfProbeTests: XCTestCase {
    private func ms(_ d: Duration) -> String {
        let c = d.components
        return String(format: "%8.1f ms", Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
    }

    private func time<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await body()
        print("PERF \(label.padding(toLength: 44, withPad: " ", startingAt: 0)) \(ms(clock.now - start))")
        return value
    }

    private func makeLedger(at dir: URL, transactions: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let assets = ["Assets:Bank:Daily", "Assets:Bank:Savings", "Assets:Cash", "Assets:Alipay", "Assets:WeChat", "Assets:Broker"]
        let liabilities = ["Liabilities:CreditCard:CMB", "Liabilities:CreditCard:ICBC", "Liabilities:Huabei"]
        let expenses = (0..<24).map { "Expenses:Cat\($0 / 6):Sub\($0)" }
        let income = ["Income:Salary", "Income:Bonus", "Income:Interest"]
        var main = "option \"title\" \"Perf\"\noption \"operating_currency\" \"CNY\"\n"
        for a in assets + liabilities + expenses + income { main += "2020-01-01 open \(a)\n" }
        main += "2020-01-01 commodity HOOL\n"
        var rng = SystemRandomNumberGenerator()
        let days = 365 * 4
        let base = ISO8601DateFormatter().date(from: "2022-10-01T00:00:00Z")!
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        var byMonth: [String: String] = [:]
        for i in 0..<transactions {
            let day = base.addingTimeInterval(Double(i * days / transactions) * 86400)
            let date = f.string(from: day)
            let month = String(date.prefix(7))
            var tx: String
            if i % 40 == 0 {
                tx = "\(date) * \"Employer\" \"Salary\"\n  Income:Salary  -20000.00 CNY\n  Assets:Bank:Daily  20000.00 CNY\n"
            } else if i % 97 == 0 {
                tx = "\(date) * \"Broker\" \"Buy\"\n  Assets:Broker  1 HOOL {100.00 CNY}\n  Assets:Bank:Daily  -100.00 CNY\n"
            } else {
                let amount = Double(Int.random(in: 100...50000, using: &rng)) / 100
                let e = expenses[Int.random(in: 0..<expenses.count, using: &rng)]
                let funding = (assets.prefix(5) + liabilities).randomElement(using: &rng)!
                tx = "\(date) * \"Payee \(i % 300)\" \"Note \(i)\" #tag\(i % 7)\n  id: \"tx-\(i)\"\n  \(e)  \(String(format: "%.2f", amount)) CNY\n  \(funding)\n"
            }
            byMonth[month, default: ""] += tx + "\n"
            if i % 50 == 0 { byMonth[month, default: ""] += "\(date) price HOOL \(100 + i % 30).00 CNY\n" }
        }
        try fm.createDirectory(at: dir.appendingPathComponent("transactions"), withIntermediateDirectories: true)
        for (month, text) in byMonth.sorted(by: { $0.key < $1.key }) {
            try Data(text.utf8).write(to: dir.appendingPathComponent("transactions/\(month).bean"))
            main += "include \"transactions/\(month).bean\"\n"
        }
        try Data(main.utf8).write(to: dir.appendingPathComponent("main.bean"))
    }

    func testProbeLaunchCost() async throws {
        let sizes = (ProcessInfo.processInfo.environment["PERF_SIZES"] ?? "3000,15000").split(separator: ",").compactMap { Int($0) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Perf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Interpreter start-up is paid once per process.
        let tiny = root.appendingPathComponent("tiny")
        try makeLedger(at: tiny, transactions: 5)
        try await time("python init + validate tiny") { try await EmbeddedBeancountValidator.shared.validate(workspace: tiny) }
        for n in sizes {
            print("PERF ===== \(n) transactions =====")
            let source = root.appendingPathComponent("src-\(n)")
            try makeLedger(at: source, transactions: n)
            try await time("python validate only") { try await EmbeddedBeancountValidator.shared.validate(workspace: source) }
            let out = root.appendingPathComponent("export-\(n).records")
            let descriptor0 = try await time("python exportCanonical") {
                try await EmbeddedBeancountValidator.shared.exportCanonical(workspace: source, to: out)
            }
            print("PERF   canonical stream \(descriptor0.entries) entries, \(descriptor0.bytes / 1024) KiB")
            let catalog = LocalLedgerCatalog(rootDirectory: root.appendingPathComponent("managed-\(n)"))
            let descriptor = try await time("catalog.importLedger") { try await catalog.importLedger(from: source, name: "Perf \(n)") }
            let repo = catalog.repository(for: descriptor)
            let revision = try await repo.workspace.currentRevision()!
            let start = "2026-09-01", end = "2026-10-01", today = "2026-09-15"
            _ = try await time("bootstrapPage #1 (export+register)") {
                try await repo.bootstrapPage(start: start, end: end, today: today, valuationCurrency: "CNY", expectedRevisionID: revision.id)
            }
            _ = try await time("bootstrapPage #2 (warm)") {
                try await repo.bootstrapPage(start: start, end: end, today: today, valuationCurrency: "CNY", expectedRevisionID: revision.id)
            }
            _ = try await time("overviewCategories") { try await repo.overviewCategories(start: start, end: end, expectedRevisionID: revision.id) }
            _ = try await time("homeReport month") { try await repo.homeReport(start: start, end: end, valuationCurrency: "CNY") }
            _ = try await time("homeReport month (again)") { try await repo.homeReport(start: start, end: end, valuationCurrency: "CNY") }
            _ = try await time("homeReport year") { try await repo.homeReport(start: "2026-01-01", end: "2027-01-01", valuationCurrency: "CNY") }
            _ = try await time("importDocuments") { try await repo.importDocuments() }
            _ = try await time("transactionPage 100") { try await repo.transactionPage(start: start, end: end) }
            _ = try await time("accountPage Daily") {
                try await repo.accountPage(account: "Assets:Bank:Daily", currency: "CNY", start: start, end: end, expectedRevisionID: revision.id)
            }
            let version = try await time("raw /api/ledger/version") {
                try await repo.workspace.withCurrentSnapshot { _, snapshot in
                    try await EmbeddedLocalLedgerEngine.shared.dispatch(.init(workspaceRoot: snapshot.path,
                        runtimeRoot: repo.workspace.rootDirectory.appendingPathComponent("runtime").path,
                        entrypoint: descriptor.entrypoint, method: "GET", path: "/api/ledger/version"))
                }
            }
            _ = version
            let tx = try await repo.transactionPage(start: start, end: end, limit: 1).transactions.first!
            try await time("addTransactionTags (write path)") { try await repo.addTransactionTags(sources: [tx.source], tags: ["perf"]) }
            let revision2 = try await repo.workspace.currentRevision()!
            _ = try await time("bootstrapPage after write") {
                try await repo.bootstrapPage(start: start, end: end, today: today, valuationCurrency: "CNY", expectedRevisionID: revision2.id)
            }
            // A fresh engine actor has no in-memory handle, like a relaunch.
            let cold = LocalLedgerCatalog(rootDirectory: root.appendingPathComponent("managed-\(n)"), engine: EmbeddedLocalLedgerEngine())
            let coldRepo = cold.repository(for: descriptor)
            _ = try await time("bootstrapPage cold relaunch") {
                try await coldRepo.bootstrapPage(start: start, end: end, today: today, valuationCurrency: "CNY", expectedRevisionID: revision2.id)
            }
            let tx2 = try await coldRepo.transactionPage(start: start, end: end, limit: 2).transactions.last!
            try await time("addTransactionTags #2") { try await coldRepo.addTransactionTags(sources: [tx2.source], tags: ["perf2"]) }
            let revision3 = try await coldRepo.workspace.currentRevision()!
            _ = try await time("bootstrapPage after write #2") {
                try await coldRepo.bootstrapPage(start: start, end: end, today: today, valuationCurrency: "CNY", expectedRevisionID: revision3.id)
            }
        }
    }
}
