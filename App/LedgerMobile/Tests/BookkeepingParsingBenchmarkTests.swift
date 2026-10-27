import Foundation
import XCTest
@testable import LedgerMobile

final class BookkeepingParsingBenchmarkTests: XCTestCase {
    func testLocalParserReadsTheBenchmarkCorpus() {
        let dev = BookkeepingBenchmark.evaluateLocalParser()
        let heldOut = BookkeepingBenchmark.evaluateLocalParser(BookkeepingBenchmark.heldOut, accounts: BookkeepingBenchmark.presetAccounts)
        print("Local parser, development set:\n\(dev)\nLocal parser, held-out set:\n\(heldOut)")
        for field in ["records", "amount", "date", "currency", "category", "funding", "complete"] {
            XCTAssertGreaterThanOrEqual(dev.rate(field), 0.95, "\(field)\n" + dev.misses.joined(separator: "\n"))
            XCTAssertGreaterThanOrEqual(heldOut.rate(field), 0.9, "\(field)\n" + heldOut.misses.joined(separator: "\n"))
        }
    }

    func testScoredMatcherBeatsTheKeywordBaseline() {
        for (cases, accounts) in [(BookkeepingBenchmark.cases, BookkeepingBenchmark.accounts),
                                  (BookkeepingBenchmark.heldOut, BookkeepingBenchmark.presetAccounts)] {
            let legacy = BookkeepingBenchmark.evaluateMatcher(cases, accounts: accounts, perRecord: false) {
                LegacyBookkeepingAccountMatcher.match(role: $0, text: $1, accounts: $2)
            }
            let scored = BookkeepingBenchmark.evaluateMatcher(cases, accounts: accounts, perRecord: true) {
                BookkeepingAccountMatcher.match(role: $0, text: $1, accounts: $2)
            }
            print("Keyword baseline:\n\(legacy)\nScored matcher:\n\(scored)")
            XCTAssertGreaterThanOrEqual(scored.rate("category"), 0.95, scored.misses.joined(separator: "\n"))
            XCTAssertGreaterThanOrEqual(scored.rate("funding"), 0.95, scored.misses.joined(separator: "\n"))
            XCTAssertGreaterThan(scored.rate("category"), legacy.rate("category"))
        }
    }

    func testAmountSpellings() {
        let expectations: [(String, [String])] = [
            ("午饭35", ["35"]), ("¥1,280 显示器", ["1280"]), ("１２８元", ["128"]), ("35块5", ["35.5"]), ("3 块 5", ["3.5"]),
            ("三十五块", ["35"]), ("十八块五", ["18.5"]), ("五十三块二", ["53.2"]), ("八毛五", ["0.85"]), ("一块半", ["1.5"]),
            ("1.5万", ["15000"]), ("3k", ["3000"]), ("两千三的房租", ["2300"]), ("一百零五元", ["105"]), ("花了一百二", ["120"]),
            ("25 美元", ["25"]), ("地铁2号线 4 元", ["4"]), ("看电影 2 张票 90", ["90"]), ("2026-10-20 体检 450", ["450"]),
            ("18:30 晚饭 60", ["60"]), ("尾号 8888 消费 12", ["12"]), ("iPhone 15 花了 5999", ["5999"]), ("12306 买票 553.5", ["553.5"]),
            ("十一假期", []), ("和同事一块吃饭 120", ["120"]), ("午餐 32 晚餐 45", ["32", "45"]), ("交电费 200 支付宝", ["200"]),
        ]
        for (text, values) in expectations {
            let dates = BookkeepingText.dates(in: text, reference: BookkeepingBenchmark.today)
            let readings = BookkeepingText.amounts(in: text).filter { amount in
                !amount.weak && !dates.contains { NSIntersectionRange($0.range, amount.range).length > 0 }
            }
            XCTAssertEqual(readings.map(\.text), values, text)
        }
        XCTAssertEqual(BookkeepingText.amounts(in: "25 美元").first?.currency, "USD")
        XCTAssertEqual(BookkeepingText.amounts(in: "HK$ 120").first?.currency, "HKD")
        XCTAssertNil(BookkeepingText.amounts(in: "35 元").first?.currency, "块/元 keep the ledger default")
    }

    func testRelativeDates() {
        let expectations: [(String, String?)] = [
            ("今天", "2026-10-27"), ("昨晚", "2026-10-26"), ("前天", "2026-10-25"), ("大前天", "2026-10-24"),
            ("上周五", "2026-10-23"), ("周日", "2026-10-25"), ("这周一", "2026-10-26"), ("3天前", "2026-10-24"),
            ("10月1日", "2026-10-01"), ("十月一号", "2026-10-01"), ("12月24日", "2025-12-24"), ("3号", "2026-10-03"),
            ("28号", "2026-09-28"), ("上个月15号", "2026-09-15"), ("2026/10/20", "2026-10-20"), ("地铁2号线", nil),
        ]
        for (text, date) in expectations {
            XCTAssertEqual(BookkeepingText.dates(in: text, reference: "2026-10-27").first?.date, date, text)
        }
    }

    /// The service may normalise what it read; it may still never invent it.
    func testSemanticResponseAcceptsFormattedAmountsButNotInventedOnes() throws {
        let accounts = [BookkeepingBenchmark.cmbCredit, "Expenses:Shopping:Digital"].map {
            LedgerAccount(account: $0, openDate: "2020-01-01", closeDate: nil, currency: "CNY", alias: nil, label: $0, group: "test", active: true)
        }
        func response(_ value: String, evidence: String) -> SemanticBookkeepingResponse {
            .init(records: [.init(date: "2026-10-27", payee: "", narration: "fixture", postings: [
                .init(account: "Expenses:Shopping:Digital", role: "expense", currency: "CNY", terms: [.init(value: value, sign: 1)], evidence: evidence),
                .init(account: BookkeepingBenchmark.cmbCredit, role: "funding", currency: "CNY", terms: [.init(value: value, sign: -1)], evidence: evidence)])],
                questions: [])
        }
        let accepted: [(String, String, String, String)] = [
            ("¥1,280 买了个显示器", "1280", "¥1,280 买了个显示器", "1280"),
            ("¥1,280 买了个显示器", "1,280", "¥1,280", "1280"),
            ("咖啡35块5", "35.5", "咖啡35块5", "35.5"),
            ("午饭三十五块", "35", "午饭三十五块", "35"),
            ("工资 1.5万", "15000", "工资 1.5万", "15000"),
            ("买书 128 元", "128", "买书128元", "128"),
            ("１２８元 午餐", "128", "１２８元", "128"),
            ("显示器 1288.50", "1288.5", "显示器 1288.50", "1288.5"),
        ]
        for (text, value, evidence, amount) in accepted {
            let input = BookkeepingParseInput(text: text, referenceDate: "2026-10-27", timeZone: "Asia/Shanghai", accounts: accounts, currency: "CNY")
            let draft = try response(value, evidence: evidence).draft(for: input)
            XCTAssertEqual(draft.records[0].postings[0].amount, amount, text)
            XCTAssertEqual(draft.recordEvidence, [evidence])
        }
        let rejected: [(String, String, String)] = [
            ("买书 12 元", "128", "买书 12 元"), ("午饭三十五块", "36", "午饭三十五块"), ("买书 128 元", "128", "买书 128 元，送货"),
            ("地铁2号线 4 元", "2", "地铁"),
        ]
        for (text, value, evidence) in rejected {
            let input = BookkeepingParseInput(text: text, referenceDate: "2026-10-27", timeZone: "Asia/Shanghai", accounts: accounts, currency: "CNY")
            XCTAssertThrowsError(try response(value, evidence: evidence).draft(for: input), text)
        }
    }

    func testUnknownCategoryStaysAQuestionInsteadOfAGuess() {
        let input = BookkeepingParseInput(text: "随手记一笔 50", referenceDate: "2026-10-27", timeZone: "Asia/Shanghai",
                                          accounts: BookkeepingBenchmark.accounts, currency: "CNY")
        let draft = LocalBookkeepingParser().draft(for: input)
        XCTAssertEqual(draft.records.first?.postings.first?.account, "")
        XCTAssertEqual(draft.records.first?.postings.first?.amount, "50")
        XCTAssertTrue(draft.questions.contains { $0.contains("选择账户") })
        XCTAssertNil(BookkeepingAccountMatcher.match(role: "expense", text: "随手记一笔", accounts: BookkeepingBenchmark.accounts))
    }

    func testLocalDraftBalancesAndPassesValidation() throws {
        let input = BookkeepingParseInput(text: "昨天用招行信用卡买书 128 元，其中 48 元替同事垫付。", referenceDate: "2026-10-27",
                                          timeZone: "Asia/Shanghai", accounts: BookkeepingBenchmark.accounts, currency: "CNY")
        let draft = LocalBookkeepingParser().draft(for: input)
        XCTAssertEqual(draft.records.count, 1)
        XCTAssertEqual(draft.records[0].postings.map(\.account),
                       ["Expenses:Education:Books", BookkeepingBenchmark.colleagues, BookkeepingBenchmark.cmbCredit])
        XCTAssertEqual(draft.records[0].postings.map(\.amount), ["80", "48", "-128"])
        XCTAssertEqual(draft.accountRoles, [["expense", "receivable", "funding"]])
        XCTAssertEqual(draft.evidence.first?.original, input.text)
        try draft.validate()
    }

    func testHistoryDecidesARepeatedPayee() {
        let history = [LedgerTransaction(date: "2026-10-01", payee: "楼下小店", narration: "", postings: [
            .init(account: "Expenses:Food:Snacks", amount: 1200, currency: "CNY"),
            .init(account: BookkeepingBenchmark.cash, amount: -1200, currency: "CNY")], source: .init(file: "main.bean", line: 1))]
        XCTAssertEqual(BookkeepingAccountMatcher.match(role: "expense", text: "楼下小店 12", accounts: BookkeepingBenchmark.accounts,
                                                       history: history, payee: "楼下小店"), "Expenses:Food:Snacks")
        XCTAssertEqual(BookkeepingAccountMatcher.match(role: "funding", text: "楼下小店 12", accounts: BookkeepingBenchmark.accounts,
                                                       history: history, payee: "楼下小店"), BookkeepingBenchmark.cash)
    }

    /// Whatever the user types, a local draft balances and carries a real date.
    func testArbitraryFragmentsAlwaysYieldBalancedDrafts() {
        let pieces = ["", " ", "，", "😀", "35", "块", "毛", "五", "十", "万", "号", "月", "周", "上", "¥", "$", "1,", ",000", ".", "-",
                      "/", ":", "尾号", "其中", "共", "微信", "招行", "信用卡", "还", "到", "K", "\n", "零", "半", "2026-", "13月40日", "2月30日"]
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        for _ in 0..<1500 {
            let text = (0..<next(12)).map { _ in pieces[next(pieces.count)] }.joined()
            let input = BookkeepingParseInput(text: text, referenceDate: "2026-10-27", timeZone: "UTC",
                                              accounts: BookkeepingBenchmark.accounts, currency: "CNY")
            for record in LocalBookkeepingParser().draft(for: input).records {
                let sum = record.postings.compactMap { ExactBookkeepingAmount.parse($0.amount) }.reduce(Decimal(0), +)
                XCTAssertEqual(sum, 0, text)
                XCTAssertNotNil(LedgerDateRange.parse(record.date), text)
            }
        }
    }

    private struct FailingParser: BookkeepingSemanticParser {
        func parse(_ input: BookkeepingParseInput) async throws -> BookkeepingDraft { throw BookkeepingError.invalidModelResponse }
    }

    func testHybridParserFallsBackToLocalRulesWhenTheServiceFails() async throws {
        let input = BookkeepingParseInput(text: "午饭35，打车20", referenceDate: "2026-10-27", timeZone: "Asia/Shanghai",
                                          accounts: BookkeepingBenchmark.accounts, currency: "CNY")
        let offline = try await HybridBookkeepingParser(remote: nil).parse(input)
        XCTAssertEqual(offline.records.map { $0.postings[0].account }, ["Expenses:Food:Meals", "Expenses:Transport:Taxi"])
        XCTAssertTrue(offline.questions.isEmpty)
        let fallback = try await HybridBookkeepingParser(remote: FailingParser()).parse(input)
        XCTAssertEqual(fallback.records, offline.records)
        XCTAssertEqual(fallback.questions.count, 1)
        do {
            _ = try await HybridBookkeepingParser(remote: FailingParser()).parse(.init(text: "随便写写", referenceDate: "2026-10-27",
                timeZone: "Asia/Shanghai", accounts: [], currency: "CNY"))
            XCTFail("Nothing to fall back to")
        } catch { XCTAssertEqual(error.localizedDescription, BookkeepingError.invalidModelResponse.localizedDescription) }
    }
}
