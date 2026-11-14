import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerAgentTests: XCTestCase {
    func testToolCallTitlesUseTheArguments() throws {
        let calls = try JSONDecoder().decode([LedgerAgentToolCall].self, from: Data("""
        [{"name":"get_ledger_summary","arguments":{"start":"2026-10-01","end":"2026-10-31"},"isError":false},
         {"name":"search_transactions","arguments":{"query":"巷口小馆"},"isError":false},
         {"name":"run_bql","arguments":{"query":"  SELECT 1  "},"isError":true},
         {"name":"get_accounts","isError":false},
         {"name":"list_saved_conversations","isError":false},
         {"name":"read_saved_conversation","arguments":{"conversation":"11111111-1111-1111-1111-111111111111"},"isError":false}]
        """.utf8))
        XCTAssertEqual(calls.map(\.title), ["汇总 · 10-01 至 10-31", "搜索流水 · 巷口小馆", "BQL 查询", "账户", "查看历史对话", "读取历史对话"])
        XCTAssertEqual(calls[2].source, "SELECT 1")
        XCTAssertTrue(calls[2].isError)
        XCTAssertNil(calls[0].source)
    }

    func testHistoryReplaysAnsweredExchangesWithinTheBudget() {
        var messages: [LedgerAgentMessage] = []
        for index in 0..<10 {
            messages.append(.init(role: .user, text: "q\(index)"))
            messages.append(.init(role: .assistant, text: "a\(index)"))
        }
        // A stopped question has no answer and is not replayed.
        messages.append(.init(role: .user, text: "stopped"))
        let history = LedgerAgentHistory.entries(from: messages)
        XCTAssertEqual(history.count, LedgerAgentHistory.maximumMessages)
        XCTAssertEqual(history.first, .init(role: "user", content: "q4"))
        XCTAssertEqual(history.last, .init(role: "assistant", content: "a9"))

        let long = String(repeating: "x", count: LedgerAgentHistory.maximumBytes)
        let trimmed = LedgerAgentHistory.entries(from: [
            .init(role: .user, text: "old"), .init(role: .assistant, text: long),
            .init(role: .user, text: "new"), .init(role: .assistant, text: "ok"),
        ])
        XCTAssertEqual(trimmed.map(\.content), ["new", "ok"])
    }

    func testReplySegmentsAndBeancountDraft() {
        let reply = """
        这一版还不能直接写入账本。按你的账户，这一笔应该是：
        ```beancount
        2026-10-31 * "午饭"
          Expenses:Food:Lunch     38.00 CNY
          Assets:WeChat:Balance  -38.00 CNY
        ```
        """
        let segments = LedgerAgentReplyText.segments(reply)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first, .prose("这一版还不能直接写入账本。按你的账户，这一笔应该是："))
        XCTAssertEqual(LedgerAgentReplyText.beancountDraft(in: reply)?.hasPrefix("2026-10-31 * \"午饭\""), true)
        XCTAssertNil(LedgerAgentReplyText.beancountDraft(in: "```sql\nSELECT 1\n```"))
        XCTAssertNil(LedgerAgentReplyText.beancountDraft(in: "十月餐饮一共 ¥2,486.40。"))
    }

    func testReplySegmentsParseBlockMarkdown() {
        let reply = """
        ## 十月支出
        一共 **¥2,486.40**，比九月少一些。
        - 餐饮 ¥1,120.00
          含外卖
        - 交通
          1. 地铁
          2. 打车
        - [x] 已对账

        | 分类 | 金额 |
        |:---|---:|
        | 餐饮 | 1,120.00 |
        | 交通 | 86.50 | 多余 |
        ---
        > 只读了已提交的账本。
        """
        XCTAssertEqual(LedgerAgentReplyText.segments(reply), [
            .heading(level: 2, text: "十月支出"),
            .prose("一共 **¥2,486.40**，比九月少一些。"),
            .list(ordered: false, items: [
                .init(marker: "•", text: "餐饮 ¥1,120.00\n含外卖", depth: 0),
                .init(marker: "•", text: "交通", depth: 0),
                .init(marker: "1.", text: "地铁", depth: 1),
                .init(marker: "2.", text: "打车", depth: 1),
                .init(marker: "☑", text: "已对账", depth: 0),
            ]),
            .table(header: ["分类", "金额"], rows: [["餐饮", "1,120.00"], ["交通", "86.50"]]),
            .rule,
            .quote("只读了已提交的账本。"),
        ])
        XCTAssertEqual(LedgerAgentReplyText.segments("#话题 不是标题\n**加粗**开头"), [.prose("#话题 不是标题\n**加粗**开头")])
    }

    func testChartBlocksBecomeChartsAndBadOnesStayCode() {
        let reply = """
        近两个月：
        ```chart
        {"type":"bar","title":"餐饮","unit":"元","labels":["9月","10月"],
         "series":[{"name":"餐厅","values":[1934.5,1744]},{"name":"买菜","values":[620,580]}]}
        ```
        餐厅在下降。
        """
        let chart = LedgerAgentChart(type: .bar, title: "餐饮", unit: "元", labels: ["9月", "10月"],
                                     series: [.init(name: "餐厅", values: [1934.5, 1744]), .init(name: "买菜", values: [620, 580])])
        XCTAssertEqual(LedgerAgentReplyText.segments(reply).filter { $0 != .prose("") && $0 != .code("") },
                       [.prose("近两个月："), .chart(chart), .prose("餐厅在下降。")])
        XCTAssertEqual(chart.points.count, 4)
        XCTAssertEqual(chart.points.first, .init(label: "9月", series: "餐厅", value: 1934.5))

        // Values that do not match the labels, a pie with two series, or a
        // negative slice are shown as the code the model wrote.
        for json in [#"{"type":"bar","labels":["a","b"],"series":[{"name":"x","values":[1]}]}"#,
                     #"{"type":"pie","labels":["a"],"series":[{"name":"x","values":[1]},{"name":"y","values":[2]}]}"#,
                     #"{"type":"pie","labels":["a","b"],"series":[{"name":"x","values":[1,-2]}]}"#,
                     #"{"type":"radar","labels":["a"],"series":[{"name":"x","values":[1]}]}"#] {
            XCTAssertEqual(LedgerAgentReplyText.segments("```chart\n\(json)\n```").filter { $0 != .prose("") }, [.code(json)], json)
        }
    }

    func testVisualBlocksDecodeEveryComponentAndDropWhatDoesNotFit() throws {
        let json = """
        {"title":"10 月支出","unit":"元","blocks":[
         {"type":"stats","items":[{"label":"支出","value":"5,230.50","delta":-0.12,"better":"lower","link":"ledger://search?q=10月","spark":[1,2,3]},
                                  {"label":"状态","value":"正常"},{"label":"坏的"}]},
         {"type":"tabs","tabs":[{"label":"3 个月","blocks":[{"type":"chart","kind":"bar","labels":["8月","9月"],
             "series":[{"name":"支出","values":[1,2]},{"name":"均值","kind":"line","values":[1.5,1.5]}],
             "rules":[{"value":1.8,"label":"预算"}],"links":["ledger://search?q=8月","https://evil.example"]}]},
           {"label":"6 个月","blocks":[{"type":"chart","kind":"waterfall","labels":["收入","房租"],"series":[{"name":"x","values":[100,-40]}]}]}]},
         {"type":"row","blocks":[{"type":"kv","items":[{"label":"账户","value":"招行"},{"label":"余额","value":12.5,"tone":"good"}]},
                                 {"type":"callout","tone":"warn","text":"有一笔重复"}]},
         {"type":"section","title":"明细","collapsed":true,"blocks":[
           {"type":"table","columns":["日期","分类",{"title":"金额","numeric":true}],"filter":"分类","totals":true,
            "rows":[{"cells":["10-05","餐饮",25],"link":"ledger://transactions?date=2026-10-05"},["10-06","交通","8.5"],
                    {"cells":["10-07","餐饮","1,200"],"children":[["","午饭","100"]]}]}]},
         {"type":"progress","items":[{"label":"餐饮","value":1200,"target":1000},{"label":"无预算","value":1,"target":0}]},
         {"type":"timeline","items":[{"date":"2026-10-05","title":"机票","value":1280,"tone":"bad"}]},
         {"type":"heatmap","days":[{"date":"2026-10-02","value":3},{"date":"2026-10-01","value":5},{"date":"2026-02-30","value":1}]},
         {"type":"compare","left":"9月","right":"10月","items":[{"label":"餐饮","left":1600,"right":1820.5}]},
         {"type":"actions","items":[{"label":"看明细","ask":"列出餐饮"},{"label":"打开","link":"ledger://search?q=餐饮"},{"label":"外链","link":"https://x"}]},
         {"type":"mystery"},
         {"type":"note","text":"不含转账"}]}
        """
        let segments = LedgerAgentReplyText.segments("看这里：\n```visual\n\(json)\n```\n完。").filter { $0 != .prose("") }
        XCTAssertEqual(segments.count, 3)
        guard case let .visual(visual) = segments[1] else { return XCTFail("\(segments)") }
        XCTAssertEqual(visual.title, "10 月支出")
        XCTAssertEqual(visual.unit, "元")
        // The unknown block is dropped; the other ten stay in order.
        XCTAssertEqual(visual.blocks.count, 10)

        guard case let .stats(stats) = visual.blocks[0] else { return XCTFail() }
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats[0].value, 5230.5)
        XCTAssertEqual(stats[0].better, .lower)
        XCTAssertEqual(stats[0].spark, [1, 2, 3])
        XCTAssertEqual(stats[0].link?.scheme, "ledger")
        XCTAssertEqual(stats[1].text, "正常")

        guard case let .tabs(tabs) = visual.blocks[1], case let .chart(bar) = tabs[0].blocks[0],
              case let .chart(waterfall) = tabs[1].blocks[0] else { return XCTFail() }
        XCTAssertEqual(tabs.map(\.label), ["3 个月", "6 个月"])
        XCTAssertEqual(bar.kind(of: "均值"), .line)
        XCTAssertEqual(bar.rules, [.init(value: 1.8, label: "预算")])
        XCTAssertNotNil(bar.link(for: "8月"))
        XCTAssertNil(bar.link(for: "9月"), "a link outside the ledger is dropped")
        XCTAssertEqual(waterfall.steps.map(\.end), [100, 60, 60])
        XCTAssertEqual(waterfall.steps.map(\.category), ["增加", "减少", "合计"])

        guard case let .row(row) = visual.blocks[2], case let .keyValues(values) = row[0], case let .callout(callout) = row[1]
        else { return XCTFail() }
        XCTAssertEqual(values.items.map(\.value), ["招行", "12.5"])
        XCTAssertEqual(values.items[1].tone, .good)
        XCTAssertEqual(callout.kind, .warn)

        guard case let .section(section) = visual.blocks[3], case let .table(table) = section.blocks[0] else { return XCTFail() }
        XCTAssertTrue(section.collapsed)
        XCTAssertEqual(table.columns.map(\.numeric), [false, false, true])
        XCTAssertEqual(table.filter, 1)
        XCTAssertEqual(table.filterValues, ["餐饮", "交通"])
        XCTAssertEqual(table.rows[0].cells, ["10-05", "餐饮", "25"])
        XCTAssertEqual(table.rows[2].children.count, 1)
        XCTAssertEqual(table.totals(of: table.rows), [nil, nil, 1233.5])
        XCTAssertEqual(table.sorted(by: 2, ascending: false).map { $0.cells[0] }, ["10-07", "10-05", "10-06"])

        guard case let .progress(progress) = visual.blocks[4] else { return XCTFail() }
        XCTAssertEqual(progress.items.count, 1, "a zero target is dropped")
        XCTAssertEqual(progress.better, .lower)

        guard case let .heatmap(heatmap) = visual.blocks[6] else { return XCTFail() }
        XCTAssertEqual(heatmap.days.map { LedgerAgentVisual.dayString($0.date) }, ["2026-10-01", "2026-10-02"])
        XCTAssertEqual(heatmap.link(for: heatmap.days[0])?.absoluteString, "ledger://transactions?date=2026-10-01")
        XCTAssertEqual(LedgerAgentVisual.weekdayIndex(heatmap.days[0].date), 3, "2026-10-01 is a Thursday")

        guard case let .actions(actions) = visual.blocks[8] else { return XCTFail() }
        XCTAssertEqual(actions.map(\.label), ["看明细", "打开"])
        XCTAssertEqual(actions[0].target, .ask("列出餐饮"))
    }

    func testVisualsWithoutUsableBlocksStayCodeAndContainersStopNesting() {
        for json in [#"{"blocks":[]}"#, #"{"blocks":[{"type":"mystery"}]}"#, #"{"title":"x"}"#, "not json"] {
            XCTAssertEqual(LedgerAgentReplyText.segments("```visual\n\(json)\n```").filter { $0 != .prose("") }, [.code(json)], json)
        }
        let note = #"{"type":"note","text":"深"}"#
        let deep = #"{"blocks":[{"type":"row","blocks":[{"type":"section","title":"a","blocks":[{"type":"row","blocks":["# + note + #",{"type":"row","blocks":["# + note + #"]}]}]}]}]}"#
        guard let visual = LedgerAgentVisual(json: deep), case let .row(outer) = visual.blocks[0],
              case let .section(section) = outer[0], case let .row(inner) = section.blocks[0] else { return XCTFail() }
        XCTAssertEqual(inner, [.note("深")], "a fourth container level is dropped")
    }

    func testVisualNumberFormatting() {
        XCTAssertEqual(LedgerAgentVisual.amount(1820.5, unit: "元"), "1,820.5 元")
        XCTAssertEqual(LedgerAgentVisual.amount(-12, unit: "¥"), "-¥12")
        XCTAssertEqual(LedgerAgentVisual.percent(-0.125), "-12.5%")
        XCTAssertEqual(LedgerAgentVisual.percent(0.3), "+30%")
        XCTAssertEqual(LedgerAgentVisual.number("¥1,234.5 元"), 1234.5)
        XCTAssertEqual(LedgerAgentVisual.tone(of: 5, better: .lower), .bad)
        XCTAssertEqual(LedgerAgentVisual.tone(of: 5, better: nil), .neutral)
    }

    func testTurnRequestEncodesOnlyFieldsTheNativeDecoderAccepts() throws {
        let request = LedgerAgentTurnRequest(turnId: "t", workspaceRoot: "/w", runtimeRoot: "/r", entrypoint: "main.bean",
            modelHandle: "h", sensitiveUnlocked: true, provider: "anthropic", model: "claude-sonnet-4-5", apiKey: "k",
            history: [.init(role: "user", content: "hi")], message: "m")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "turnId", "workspaceRoot", "runtimeRoot", "entrypoint", "modelHandle",
            "sensitiveUnlocked", "provider", "model", "apiKey", "history", "message"])
        XCTAssertEqual(object["version"] as? Int, 1)
    }

    func testCustomEndpointEncodesForTheNativeDecoder() throws {
        let choice = LedgerAgentModelChoice(provider: "custom", model: "qwen3", custom: .init(api: .anthropicMessages, baseURL: "https://gw.example.com/v1"))
        XCTAssertTrue(choice.isComplete)
        let request = LedgerAgentTurnRequest(turnId: "t", workspaceRoot: "/w", runtimeRoot: "/r", entrypoint: "main.bean",
            sensitiveUnlocked: true, provider: choice.provider, model: choice.model, apiKey: "k", custom: choice.custom,
            history: [], message: "m")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let custom = try XCTUnwrap(object["custom"] as? [String: String])
        XCTAssertEqual(custom, ["api": "anthropic-messages", "baseURL": "https://gw.example.com/v1"])
    }

    func testCustomChoiceNeedsAModelAndAPlainHTTPURL() {
        func choice(_ url: String, model: String = "m") -> LedgerAgentModelChoice {
            .init(provider: "custom", model: model, custom: .init(api: .openAICompletions, baseURL: url))
        }
        XCTAssertTrue(choice("http://192.168.1.8:11434/v1").isComplete)
        XCTAssertFalse(choice("https://api.example.com/v1", model: " ").isComplete)
        XCTAssertFalse(choice("").isComplete)
        XCTAssertFalse(choice("ftp://example.com").isComplete)
        XCTAssertFalse(choice("https://user:pass@example.com/v1").isComplete)
        XCTAssertFalse(choice("https://example.com/v1?key=1").isComplete)
        XCTAssertTrue(LedgerAgentModelChoice(provider: "anthropic", model: "claude-sonnet-4-5").isComplete)
    }

    func testTieredPolicyHoldsDeletionsAndLargeRemovals() {
        func review(_ files: [LedgerAgentFileDiff]) -> LedgerAgentReview { .init(id: UUID(), files: files) }
        func edit(_ before: String, _ after: String) -> LedgerAgentReview {
            review([.init(path: "2026/10.bean", before: Data(before.utf8), after: Data(after.utf8))])
        }
        func lines(_ count: Int) -> String { (0..<count).map { "l\($0)" }.joined(separator: "\n") + "\n" }

        // Appending and a small edit are the everyday change: written at once.
        let append = edit("a\n", "a\nb\n")
        XCTAssertNil(append.tieredHoldReason)
        XCTAssertTrue(LedgerAgentWritePolicy.tiered.writesWithoutAsking(append))
        XCTAssertNil(review([.init(path: "2026/11.bean", before: nil, after: Data("x\n".utf8))]).tieredHoldReason)
        XCTAssertNil(edit(lines(21), "l0\n").tieredHoldReason, "20 removed lines is still allowed")

        // Past the threshold it asks first, and says how much goes.
        let cut = edit(lines(22), "l0\n")
        XCTAssertEqual(cut.removed, 21)
        XCTAssertEqual(cut.tieredHoldReason, "这次改动删除了 21 行，需要你确认。")
        XCTAssertFalse(LedgerAgentWritePolicy.tiered.writesWithoutAsking(cut))

        // A deleted file asks whatever it weighed.
        let deleted = review([.init(path: "documents/old.pdf", before: Data([0, 1]), after: nil),
                              .init(path: "documents/older.pdf", before: Data([0, 1]), after: nil)])
        XCTAssertEqual(deleted.files.map(\.change), [.removed, .removed])
        XCTAssertEqual(deleted.tieredHoldReason, "这次改动删除了 2 个文件，需要你确认。")
        XCTAssertEqual(review([.init(path: "documents/old.pdf", before: Data([0, 1]), after: nil)]).tieredHoldReason,
                       "这次改动删除了 1 个文件，需要你确认。")

        // 全部自动写入 never asks; 每次确认 always waits, with nothing to explain.
        XCTAssertTrue(LedgerAgentWritePolicy.always.writesWithoutAsking(deleted))
        XCTAssertNil(LedgerAgentWritePolicy.always.holdReason(for: deleted))
        XCTAssertFalse(LedgerAgentWritePolicy.confirm.writesWithoutAsking(append))
        XCTAssertNil(LedgerAgentWritePolicy.confirm.holdReason(for: append))
    }

    @MainActor
    func testWritePolicyStartsTieredAndMigratesTheOldAutoWriteSwitch() throws {
        let suite = "LedgerAgentTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let keys: (String) -> ClassificationKeyStore = { .init(service: "LedgerAgentTests-" + suite, account: $0) }
        @MainActor func stored() -> LedgerAgentSettings { LedgerAgentSettings(defaults: defaults, catalog: .fallback, keyStore: keys) }

        // Nothing stored yet: a new install writes tiered.
        XCTAssertEqual(stored().writePolicy, .tiered)
        // An old switch that was on meant every change was written, one that
        // was explicitly off meant every change was confirmed.
        defaults.set(true, forKey: "ledger.agent.auto-write")
        XCTAssertEqual(stored().writePolicy, .always)
        defaults.set(false, forKey: "ledger.agent.auto-write")
        XCTAssertEqual(stored().writePolicy, .confirm)
        // Once the user picks, the new key wins and outlives the old one.
        let settings = stored()
        settings.setWritePolicy(.tiered)
        XCTAssertEqual(defaults.string(forKey: "ledger.agent.write-policy"), "tiered")
        defaults.removeObject(forKey: "ledger.agent.auto-write")
        XCTAssertEqual(stored().writePolicy, .tiered)
    }

    @MainActor
    func testSettingsRestoreTheCustomEndpointAfterSwitchingProviders() throws {
        let suite = "LedgerAgentTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = LedgerAgentSettings(defaults: defaults, catalog: .fallback,
            keyStore: { .init(service: "LedgerAgentTests-" + suite, account: $0) })
        settings.select(provider: "custom")
        XCTAssertTrue(settings.choice.isCustom)
        settings.setCustom(api: .openAIResponses, baseURL: " https://gw.example.com/v1 ")
        settings.select(model: "my-model")
        settings.select(provider: "anthropic")
        XCTAssertNil(settings.choice.custom)
        settings.select(provider: "custom")
        XCTAssertEqual(settings.choice, .init(provider: "custom", model: "my-model",
            custom: .init(api: .openAIResponses, baseURL: "https://gw.example.com/v1")))
    }

    @MainActor
    func testFavoritesSwitchProviderAndModelInOneTap() throws {
        let suite = "LedgerAgentTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let keys: (String) -> ClassificationKeyStore = { .init(service: "LedgerAgentTests-" + suite, account: $0) }
        let settings = LedgerAgentSettings(defaults: defaults, catalog: .fallback, keyStore: keys)
        settings.toggleFavoriteForCurrent()
        XCTAssertTrue(settings.currentIsFavorite)
        settings.select(provider: "custom")
        settings.setCustom(api: .openAICompletions, baseURL: "https://gw.example.com/v1")
        settings.select(model: "qwen3")
        settings.toggleFavoriteForCurrent()
        XCTAssertEqual(settings.favorites.map(\.choice.model), ["claude-sonnet-4-5", "qwen3"])
        // A model nothing describes is offered the assumed levels.
        XCTAssertEqual(settings.supportedThinking, LedgerAgentThinking.custom)
        XCTAssertTrue(settings.thinkingIsAssumed)

        let anthropic = try XCTUnwrap(settings.favorites.first)
        settings.select(favorite: anthropic)
        XCTAssertEqual(settings.choice, .init(provider: "anthropic", model: "claude-sonnet-4-5"))

        // Favorites survive a relaunch; unstarring removes one.
        let reopened = LedgerAgentSettings(defaults: defaults, catalog: .fallback, keyStore: keys)
        XCTAssertEqual(reopened.favorites, settings.favorites)
        reopened.toggleFavoriteForCurrent()
        XCTAssertEqual(reopened.favorites.map(\.choice.model), ["qwen3"])
    }

    @MainActor
    func testProviderListAddsModelsTheCatalogLacks() async throws {
        let suite = "LedgerAgentTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keys: (String) -> ClassificationKeyStore = { .init(service: "LedgerAgentTests-" + suite, account: $0) }
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let sent = SentRequest()
        let lister = LedgerAgentModelLister(run: { request in
            sent.data = request
            return Data(#"{"version":1,"ok":true,"models":[{"id":"claude-next","title":"Claude Next","thinkingLevels":["off","low","high"],"known":false}]}"#.utf8)
        })
        let settings = LedgerAgentSettings(defaults: defaults, catalog: .fallback, keyStore: keys, lister: lister)
        await settings.refreshModels()
        XCTAssertNotNil(settings.listError, "listed without a key")
        // CI runners cannot write the Keychain, so the key is passed in.
        await settings.refreshModels(apiKey: "sk-test")
        XCTAssertNil(settings.listError)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.data)) as? [String: Any])
        XCTAssertEqual(request["provider"] as? String, "anthropic")
        XCTAssertEqual(request["apiKey"] as? String, "sk-test")
        XCTAssertEqual(settings.listedModels?.map(\.id), ["claude-next"])

        settings.select(model: "claude-next")
        XCTAssertEqual(settings.modelTitle, "Claude Next")
        XCTAssertEqual(settings.supportedThinking, [.off, .low, .high])
        XCTAssertEqual(settings.effectiveThinking, .high)
        settings.toggleFavoriteForCurrent()
        XCTAssertEqual(settings.favorites.last?.thinkingLevels, ["off", "low", "high"])
    }

    @MainActor
    func testProviderListWindowsOutliveARelaunch() async throws {
        let suite = "LedgerAgentTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keys: (String) -> ClassificationKeyStore = { .init(service: "LedgerAgentTests-" + suite, account: $0) }
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let calls = SentRequest()
        let lister = LedgerAgentModelLister(run: { request in
            calls.data = request
            return Data(#"{"version":1,"ok":true,"models":[{"id":"claude-sonnet-4-5","title":"Claude Sonnet 4.5","known":true,"contextWindow":1000000},{"id":"claude-next","title":"Claude Next","known":false}]}"#.utf8)
        })
        let settings = LedgerAgentSettings(defaults: defaults, catalog: .fallback, keyStore: keys, lister: lister)
        let sonnet = LedgerAgentModelChoice(provider: "anthropic", model: "claude-sonnet-4-5")
        let next = LedgerAgentModelChoice(provider: "anthropic", model: "claude-next")
        XCTAssertNil(settings.contextWindow(for: sonnet))

        // Without a key nothing is fetched and nothing is shown.
        await settings.learnContextWindow()
        XCTAssertNil(calls.data)
        XCTAssertNil(settings.listError)

        await settings.refreshModels(apiKey: "sk-test")
        XCTAssertEqual(settings.contextWindow(for: sonnet), 1_000_000)
        XCTAssertNil(settings.contextWindow(for: next), "a list without a window leaves it to the native side")
        settings.toggleFavoriteForCurrent()
        XCTAssertEqual(settings.favorites.last?.contextWindow, 1_000_000)

        let reopened = LedgerAgentSettings(defaults: defaults, catalog: .fallback, keyStore: keys, lister: lister)
        XCTAssertNil(reopened.listedModels)
        XCTAssertEqual(reopened.contextWindow(for: sonnet), 1_000_000)
    }

    func testTurnRequestSendsTheListedContextWindow() throws {
        var request = LedgerAgentTurnRequest(turnId: "t", workspaceRoot: "/w", runtimeRoot: "/r", entrypoint: "main.bean",
            sensitiveUnlocked: true, provider: "anthropic", model: "claude-next", apiKey: "k", history: [], message: "m")
        request.contextWindow = 400_000
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(object["contextWindow"] as? Int, 400_000)
        let listed = try JSONDecoder().decode(LedgerAgentListedModel.self,
            from: Data(#"{"id":"a","title":"A","known":false,"contextWindow":262144}"#.utf8))
        XCTAssertEqual(listed.contextWindow, 262_144)
        let older = try JSONDecoder().decode(LedgerAgentListedModel.self, from: Data(#"{"id":"a","title":"A","known":false}"#.utf8))
        XCTAssertNil(older.contextWindow)
        XCTAssertNil(older.maxOutputTokens)
        XCTAssertNil(object["maxOutputTokens"], "no listed reply limit keeps the native one")
        request.maxOutputTokens = 65_536
        let limited = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(limited["maxOutputTokens"] as? Int, 65_536)
    }

    /// A gateway behind a custom endpoint names its models provider/model and
    /// lists each one's window and reply limit (issue #663). The choice finds
    /// them, also after a relaunch, and only for that endpoint.
    @MainActor
    func testCustomEndpointListGivesTheWindowOfASlashedModelID() async throws {
        let suite = "LedgerAgentTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keys: (String) -> ClassificationKeyStore = { .init(service: "LedgerAgentTests-" + suite, account: $0) }
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let calls = SentRequest()
        let lister = LedgerAgentModelLister(run: { request in
            calls.data = request
            return Data(#"{"version":1,"ok":true,"models":[{"id":"antigravity/gemini-3.8-flash-tiered","title":"antigravity/gemini-3.8-flash-tiered","thinkingLevels":["off","minimal","low","medium","high"],"known":false,"contextWindow":1048576,"maxOutputTokens":65536},{"id":"auto/deepseek-flash","title":"auto/deepseek-flash","thinkingLevels":["off","minimal","low","medium","high"],"known":false}]}"#.utf8)
        })
        let settings = LedgerAgentSettings(defaults: defaults, catalog: .fallback, keyStore: keys, lister: lister)
        settings.select(provider: "custom")
        settings.setCustom(api: .openAICompletions, baseURL: "https://gw.example.com/v1")
        settings.select(model: "antigravity/gemini-3.8-flash-tiered")
        let gemini = settings.choice
        XCTAssertTrue(gemini.isCustom)
        XCTAssertNil(settings.contextWindow(for: gemini))
        XCTAssertNil(settings.maxOutputTokens(for: gemini))
        // Without a key the read waits; saving one changes what starts it.
        XCTAssertEqual(settings.contextWindowTaskID, LedgerAgentSettings.identity(gemini))

        await settings.refreshModels(apiKey: "sk-test")
        XCTAssertNil(settings.listError)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(calls.data)) as? [String: Any])
        XCTAssertEqual(request["provider"] as? String, "custom")
        XCTAssertEqual((request["custom"] as? [String: Any])?["baseURL"] as? String, "https://gw.example.com/v1")
        XCTAssertEqual(settings.contextWindow(for: gemini), 1_048_576)
        XCTAssertEqual(settings.maxOutputTokens(for: gemini), 65_536)
        let auto = LedgerAgentModelChoice(provider: "custom", model: "auto/deepseek-flash", custom: gemini.custom)
        XCTAssertNil(settings.contextWindow(for: auto), "a model the list gives no window keeps the native 128k")
        XCTAssertNil(settings.maxOutputTokens(for: auto))
        let elsewhere = LedgerAgentModelChoice(provider: "custom", model: gemini.model,
            custom: .init(api: .openAICompletions, baseURL: "https://other.example.com/v1"))
        XCTAssertNil(settings.contextWindow(for: elsewhere), "another endpoint's list says nothing about this one")

        let reopened = LedgerAgentSettings(defaults: defaults, catalog: .fallback, keyStore: keys, lister: lister)
        XCTAssertNil(reopened.listedModels)
        XCTAssertEqual(reopened.contextWindow(for: gemini), 1_048_576)
        XCTAssertEqual(reopened.maxOutputTokens(for: gemini), 65_536)
        XCTAssertNil(reopened.contextWindow(for: auto))
    }

    func testCrashReportShowsOnce() throws {
        let runtime = try root()
        XCTAssertNil(LedgerAgentCrashReport.take(runtimeRoot: runtime))
        try Data("panic: boom\n\ngoroutine 7 [running]:\nai.parseSSE()\n\ngoroutine 18 [force gc (idle)]:\nruntime.gopark()\n".utf8)
            .write(to: runtime.appendingPathComponent(LedgerAgentCrashReport.fileName))
        XCTAssertEqual(LedgerAgentCrashReport.take(runtimeRoot: runtime), "panic: boom\n\ngoroutine 7 [running]:\nai.parseSSE()")
        XCTAssertNil(LedgerAgentCrashReport.take(runtimeRoot: runtime))
    }

    func testErrorsClassifyAuthFailures() {
        XCTAssertEqual(LedgerAgentError.classify("401 Unauthorized: invalid x-api-key"), .invalidKey("401 Unauthorized: invalid x-api-key"))
        XCTAssertEqual(LedgerAgentError.classify("context deadline exceeded"), .failed("context deadline exceeded"))
    }

    @MainActor
    func testConversationAppendsRepliesAndKeepsFailedQuestions() async throws {
        let conversation = LedgerAgentConversation()
        conversation.send("这个月花了多少") { _, history, _ in
            XCTAssertTrue(history.isEmpty)
            return .init(ok: true, reply: "共 2,486.40 元。", toolCalls: [.init(name: "get_ledger_summary", isError: false)])
        }
        XCTAssertTrue(conversation.isRunning)
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.messages.map(\.text), ["这个月花了多少", "共 2,486.40 元。"])
        XCTAssertEqual(conversation.messages.last?.toolCalls.count, 1)

        conversation.send("再看看上个月") { _, history, _ in
            XCTAssertEqual(history.count, 2)
            return .init(ok: false, error: "401 invalid x-api-key")
        }
        try await waitUntilIdle(conversation)
        guard case let .failed(error, question) = conversation.phase else { return XCTFail("turn did not fail") }
        XCTAssertEqual(question, "再看看上个月")
        if case .invalidKey = error {} else { XCTFail("auth failure not classified: \(error)") }

        // Retrying the same question replaces it instead of repeating it.
        conversation.send("再看看上个月") { _, _, _ in .init(ok: true, reply: "上月 2,031.70 元。") }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.messages.map(\.text), ["这个月花了多少", "共 2,486.40 元。", "再看看上个月", "上月 2,031.70 元。"])

        conversation.reset()
        XCTAssertTrue(conversation.messages.isEmpty)
    }

    func testErrorHeadlinesSayWhetherARetryHelps() {
        XCTAssertEqual(LedgerAgentError.failed("模型服务 150 秒没有任何响应，连接已断开").headline, "模型服务长时间没有响应")
        XCTAssertEqual(LedgerAgentError.failed("429 Too Many Requests").headline, "模型服务限流或额度不足")
        XCTAssertEqual(LedgerAgentError.failed("529 overloaded_error").headline, "模型服务暂时不可用")
        XCTAssertEqual(LedgerAgentError.failed("dial tcp: lookup api.example.com: no such host").headline, "网络连接出了问题")
        XCTAssertEqual(LedgerAgentError.failed("400 invalid_request_error: messages.1").headline, "模型服务拒绝了这次请求")
        XCTAssertEqual(LedgerAgentError.invalidKey("401").headline, "API Key 无效或已过期")
    }

    func testHistorySkipsEmptyReplies() {
        let messages: [LedgerAgentMessage] = [
            .init(role: .user, text: "一"), .init(role: .assistant, text: "  "),
            .init(role: .user, text: "二"), .init(role: .assistant, text: "答"),
        ]
        XCTAssertEqual(LedgerAgentHistory.entries(from: messages), [.init(role: "user", content: "二"), .init(role: "assistant", content: "答")])
    }

    /// An answer without text used to draw an empty reply, which read as the
    /// assistant not answering at all.
    @MainActor
    func testEmptyReplyIsAFailureWithRetry() async throws {
        let conversation = LedgerAgentConversation()
        conversation.send("这个月花了多少") { _, _, _ in .init(ok: true, reply: "  ") }
        try await waitUntilIdle(conversation)
        guard case let .failed(_, question) = conversation.phase else { return XCTFail("empty reply passed as an answer") }
        XCTAssertEqual(question, "这个月花了多少")
        XCTAssertEqual(conversation.messages.map(\.role), [.user])
    }

    @MainActor
    func testSendReportsWhetherTheTurnStarted() async throws {
        let conversation = LedgerAgentConversation()
        XCTAssertFalse(conversation.send("   ") { _, _, _ in .init(ok: true, reply: "x") })
        XCTAssertTrue(conversation.send("问") { _, _, _ in
            try? await Task.sleep(nanoseconds: 30_000_000)
            return .init(ok: true, reply: "答")
        })
        XCTAssertFalse(conversation.send("又问") { _, _, _ in .init(ok: true, reply: "x") })
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.messages.map(\.text), ["问", "答"])
    }

    func testNativeDeadlineStopsWaitingOnACallThatNeverReturns() async throws {
        let cancelled = expectation(description: "the stuck turn is cancelled")
        do {
            _ = try await LedgerAgentRunner.withDeadline(0.05, onTimeout: { cancelled.fulfill() }) {
                Thread.sleep(forTimeInterval: 0.5)
                return Data()
            }
            XCTFail("a stuck call was waited for")
        } catch let error as LedgerAgentError {
            XCTAssertEqual(error.headline, "模型服务长时间没有响应")
        }
        await fulfillment(of: [cancelled], timeout: 1)
        let quick = try await LedgerAgentRunner.withDeadline(5, onTimeout: {}) { Data("ok".utf8) }
        XCTAssertEqual(quick, Data("ok".utf8))
    }

    @MainActor
    func testStoppedTurnDropsALateReply() async throws {
        let conversation = LedgerAgentConversation()
        conversation.send("慢问题") { _, _, _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return .init(ok: true, reply: "迟到的回答")
        }
        conversation.stop()
        XCTAssertEqual(conversation.phase, .idle)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(conversation.messages.map(\.text), ["慢问题"])
    }

    func testRepositoryRunsTheTurnOnTheCommittedGenerationAndRetriesAStaleModel() async throws {
        let engine = HandleEngine()
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: engine, validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Agent fixture")
        let repository = catalog.repository(for: descriptor)
        let recorder = RequestRecorder()
        let runner = LedgerAgentRunner(run: { data in
            let count = await recorder.record(data)
            return Data((count == 1 ? #"{"version":1,"ok":false,"toolCalls":[],"error":"stale","modelUnavailable":true}"#
                : #"{"version":1,"ok":true,"reply":"ok","toolCalls":[{"name":"get_accounts","arguments":{"activeOnly":true},"isError":false}]}"#).utf8)
        }, cancel: { _ in })
        let response = try await repository.runAgentTurn(message: "我有哪些账户", history: [],
            choice: .init(provider: "anthropic", model: "claude-sonnet-4-5"), apiKey: "k", sensitiveUnlocked: true, runner: runner)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.toolCalls.first?.title, "账户")
        let recorded = await recorder.requests
        let requests = try recorded.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0["modelHandle"] as? String }, ["h1", "h2"])
        let workspace = try XCTUnwrap(requests.first?["workspaceRoot"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: workspace).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "generations")
        XCTAssertNotEqual(requests[0]["turnId"] as? String, requests[1]["turnId"] as? String)
        let replaced = await engine.replaced
        XCTAssertEqual(replaced, [nil, "h1"])
    }

    func testRepositorySendsTheTranscriptAndConversation() async throws {
        let engine = HandleEngine()
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: engine, validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Agent transcript fixture")
        let repository = catalog.repository(for: descriptor)
        let recorder = RequestRecorder()
        let runner = LedgerAgentRunner(run: { data in
            _ = await recorder.record(data)
            return Data(#"{"version":1,"ok":true,"reply":"ok","toolCalls":[],"transcript":"[2]"}"#.utf8)
        }, cancel: { _ in })
        let conversation = UUID()
        let response = try await repository.runAgentTurn(message: "接着说", history: [],
            choice: .init(provider: "anthropic", model: "claude-sonnet-4-5"), apiKey: "k", sensitiveUnlocked: true,
            transcript: "[1]", conversationID: conversation, runner: runner)
        XCTAssertEqual(response.transcript, "[2]")
        let recorded = await recorder.requests
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recorded.first)) as? [String: Any])
        XCTAssertEqual(request["transcript"] as? String, "[1]")
        XCTAssertEqual(request["conversationId"] as? String, conversation.uuidString)
    }

    /// Follow-ups build on the earlier turns' reads: an answered turn's
    /// transcript is kept for the next one, a failed turn leaves it alone.
    @MainActor
    func testConversationKeepsTheLastAnsweredTranscript() async throws {
        let conversation = LedgerAgentConversation()
        conversation.send("一") { _, _, _ in .init(ok: true, reply: "答一", transcript: "[1]") }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.transcript, "[1]")
        conversation.send("二") { _, _, _ in .init(ok: false, error: "503 overloaded") }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.transcript, "[1]")
        conversation.send("二") { _, _, _ in .init(ok: true, reply: "答二", transcript: "[1,2]") }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.transcript, "[1,2]")
        conversation.reset()
        XCTAssertNil(conversation.transcript)
    }

    func testFileDiffShowsChangedLinesWithContext() {
        let before = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let after = before.replacingOccurrences(of: "line 3\n", with: "line three\n")
            .replacingOccurrences(of: "line 18\n", with: "line 18\nline 18b\n")
        let diff = LedgerAgentFileDiff(path: "main.bean", before: Data(before.utf8), after: Data(after.utf8))
        XCTAssertEqual(diff.change, .modified)
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 1)
        XCTAssertEqual(diff.lines.map(\.kind), [.context, .context, .removed, .added, .context, .context, .gap,
                                               .context, .context, .added, .context, .context])
        XCTAssertEqual(diff.lines[2].text, "line 3")
        XCTAssertEqual(diff.lines[3].text, "line three")
        XCTAssertEqual(diff.lines[6].text, "11 行未改动")

        let created = LedgerAgentFileDiff(path: "2026/02.bean", before: nil, after: Data("a\nb\n".utf8))
        XCTAssertEqual(created.change, .added)
        XCTAssertEqual(created.lines.map(\.kind), [.added, .added])
    }

    func testDraftMirrorCopiesChangedFilesAndRemovesMissingOnes() throws {
        let draft = try root(), stage = try root()
        let fm = FileManager.default
        try fm.createDirectory(at: draft.appendingPathComponent("2026"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stage.appendingPathComponent("old"), withIntermediateDirectories: true)
        try Data("same".utf8).write(to: draft.appendingPathComponent("main.bean"))
        try Data("same".utf8).write(to: stage.appendingPathComponent("main.bean"))
        try Data("new".utf8).write(to: draft.appendingPathComponent("2026/02.bean"))
        try Data("gone".utf8).write(to: stage.appendingPathComponent("old/gone.bean"))
        try Data("moved".utf8).write(to: stage.appendingPathComponent("receipt.pdf"))
        try Data([0, 1, 2]).write(to: draft.appendingPathComponent("2026/receipt.pdf"))
        try Data("hidden".utf8).write(to: stage.appendingPathComponent(".keep"))
        let stamp = try fm.attributesOfItem(atPath: stage.appendingPathComponent("main.bean").path)[.modificationDate] as? Date

        try LedgerAgentDraftMirror.apply(from: draft, to: stage)

        XCTAssertEqual(try LedgerAgentDraftMirror.files(in: stage), ["main.bean", "2026/02.bean", "2026/receipt.pdf"])
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent("2026/02.bean")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent("2026/receipt.pdf")), Data([0, 1, 2]))
        // A file the draft no longer has was moved or deleted there; hidden
        // files are not the Agent's and stay.
        XCTAssertFalse(fm.fileExists(atPath: stage.appendingPathComponent("receipt.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: stage.appendingPathComponent(".keep").path))
        // An unchanged file is not rewritten, so it is not a change candidate.
        XCTAssertEqual(try fm.attributesOfItem(atPath: stage.appendingPathComponent("main.bean").path)[.modificationDate] as? Date, stamp)
    }

    @MainActor
    func testConversationReviewsAnEditedTurnAndWritesOnlyOnConfirm() async throws {
        let ledger = FakeDraftLedger()
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.send("午饭改成 26") { message, _, draft in
            XCTAssertEqual(message, "午饭改成 26")
            XCTAssertEqual(draft?.lastPathComponent, "draft-1")
            return .init(ok: true, reply: "改动已准备好。", edited: true)
        }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.pending?.status, .ready)
        XCTAssertEqual(conversation.pending?.review?.files.map(\.path), ["main.bean"])
        let writesBefore = await ledger.writes
        XCTAssertEqual(writesBefore, 0)

        conversation.write()
        for _ in 0..<200 where conversation.pending != nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(conversation.pending)
        XCTAssertEqual(conversation.written?.files.count, 1)
        let writes = await ledger.writes
        XCTAssertEqual(writes, 1)

        // The next question tells the model its change was written, and reuses the draft.
        conversation.send("好了吗") { message, _, draft in
            XCTAssertTrue(message.hasSuffix("好了吗"))
            XCTAssertTrue(message.contains("已写入账本"))
            XCTAssertEqual(draft?.lastPathComponent, "draft-1")
            return .init(ok: true, reply: "好了。")
        }
        try await waitUntilIdle(conversation)
        XCTAssertNil(conversation.pending)
        let opened = await ledger.opened
        XCTAssertEqual(opened, 1)
    }

    @MainActor
    func testConversationReportsAConflictingDraftAndStartsOverOnDiscard() async throws {
        let ledger = FakeDraftLedger()
        await ledger.failReview(with: .conflict(["main.bean"]))
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.send("批量改分类") { _, _, _ in .init(ok: true, reply: "改好了。", edited: true) }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.pending, .init(review: nil, status: .conflict(["main.bean"])))

        conversation.discard()
        XCTAssertNil(conversation.pending)
        conversation.send("重新来") { message, _, draft in
            XCTAssertTrue(message.contains("放弃"))
            XCTAssertEqual(draft?.lastPathComponent, "draft-2")
            return .init(ok: true, reply: "好。")
        }
        try await waitUntilIdle(conversation)
        conversation.reset()
        for _ in 0..<200 { if await ledger.closed == 1 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let closed = await ledger.closed
        XCTAssertEqual(closed, 1)
    }

    func testStepDecodesNativeEvents() {
        XCTAssertEqual(LedgerAgentStep.decode(#"{"version":1,"kind":"model"}"#)?.title, "正在思考")
        let read = LedgerAgentStep.decode(#"{"version":1,"kind":"tool","name":"read_file","arguments":{"path":"2026/10.bean"}}"#)
        XCTAssertEqual(read?.kind, .tool)
        XCTAssertEqual(read?.title, "读取文件 · 2026/10.bean")
        XCTAssertNil(LedgerAgentStep.decode(#"{"version":2,"kind":"model"}"#))
        XCTAssertNil(LedgerAgentStep.decode(#"{"version":1,"kind":"stream"}"#))
        XCTAssertNil(LedgerAgentStep.decode(#"{"version":1,"kind":"tool"}"#))
    }

    @MainActor
    func testConversationReportsStepsAndEndingsToItsLifecycle() async throws {
        let lifecycle = RecordingLifecycle()
        let conversation = LedgerAgentConversation()
        conversation.lifecycle = lifecycle
        conversation.send("这个月餐饮", reporting: { _, _, _, report in
            report(.init(kind: .model))
            report(.init(kind: .tool, call: .init(name: "run_bql", isError: false)))
            try? await Task.sleep(nanoseconds: 30_000_000)
            return .init(ok: true, reply: "共 812 元。")
        })
        XCTAssertEqual(lifecycle.events.first, "started 这个月餐饮")
        for _ in 0..<200 where conversation.step?.kind != .tool { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(conversation.step?.title, "BQL 查询")
        try await waitUntilIdle(conversation)
        XCTAssertNil(conversation.step)
        XCTAssertEqual(lifecycle.events, ["started 这个月餐饮", "step 1 正在思考", "step 2 BQL 查询",
                                          "ended answered(\"共 812 元。\")"])

        conversation.send("慢问题") { _, _, _ in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return .init(ok: true, reply: "迟到")
        }
        conversation.stop()
        XCTAssertEqual(lifecycle.events.last, "ended stopped")
    }

    @MainActor
    func testInterruptedTurnReturnsTheQuestionAndReviewsTheDraftNext() async throws {
        let ledger = FakeDraftLedger()
        let lifecycle = RecordingLifecycle()
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.lifecycle = lifecycle
        conversation.send("看看草稿") { _, _, _ in .init(ok: true, reply: "好。") }
        try await waitUntilIdle(conversation)
        XCTAssertNil(conversation.pending)

        conversation.send("批量改分类") { _, _, draft in
            XCTAssertEqual(draft?.lastPathComponent, "draft-1")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return .init(ok: true, reply: "迟到的回答", edited: true)
        }
        conversation.interrupt()
        XCTAssertEqual(conversation.phase, .failed(.interrupted, question: "批量改分类"))
        XCTAssertEqual(lifecycle.events.last, "ended interrupted")

        // The retry is told about the interruption and shows whatever the
        // interrupted turn left in the draft, even if it edits nothing itself.
        conversation.send("批量改分类") { message, _, draft in
            XCTAssertTrue(message.contains("中断"))
            XCTAssertEqual(draft?.lastPathComponent, "draft-1")
            return .init(ok: true, reply: "改好了。")
        }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.messages.map(\.text), ["看看草稿", "好。", "批量改分类", "改好了。"])
        XCTAssertEqual(conversation.pending?.status, .ready)
        XCTAssertEqual(lifecycle.events.last, "ended changeReady(\"改好了。\", files: 1)")
    }

    @MainActor
    func testFirstQuestionShowsItsPreparationWithoutCountingIt() async throws {
        let ledger = FakeDraftLedger()
        let lifecycle = RecordingLifecycle()
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.lifecycle = lifecycle
        conversation.send("第一个问题", reporting: { _, _, _, report in
            report(.loadingLedger)
            report(.init(kind: .model))
            try? await Task.sleep(nanoseconds: 30_000_000)
            return .init(ok: true, reply: "好。")
        })
        try await waitUntilIdle(conversation)
        XCTAssertEqual(Array(lifecycle.events.prefix(4)),
                       ["started 第一个问题", "step 0 正在准备账本草稿", "step 0 正在加载账本", "step 1 正在思考"])
        XCTAssertNil(LedgerAgentStep.decode(#"{"version":1,"kind":"preparing"}"#))

        // The draft is open now, so the next question has nothing to copy.
        conversation.send("第二个问题") { _, _, _ in .init(ok: true, reply: "好。") }
        try await waitUntilIdle(conversation)
        XCTAssertFalse(lifecycle.events.dropFirst(4).contains { $0.contains("正在准备账本草稿") })
    }

    @MainActor
    func testInterruptedTurnResumesOnceAndStopsLooping() async throws {
        let conversation = LedgerAgentConversation()
        let slow: LedgerAgentConversation.Send = { _, _, _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return .init(ok: true, reply: "迟到")
        }
        XCTAssertNil(conversation.takeResumableQuestion())
        for _ in 0..<LedgerAgentConversation.maximumResumes {
            conversation.send("长问题", using: slow)
            conversation.interrupt()
            XCTAssertEqual(conversation.takeResumableQuestion(), "长问题")
            XCTAssertNil(conversation.takeResumableQuestion())
        }
        // Cut short again right after its resumes: the user retries by hand.
        conversation.send("长问题", using: slow)
        conversation.interrupt()
        XCTAssertNil(conversation.takeResumableQuestion())

        // An answer earns it fresh resumes.
        conversation.send("长问题") { _, _, _ in .init(ok: true, reply: "好。") }
        try await waitUntilIdle(conversation)
        conversation.send("下一个", using: slow)
        conversation.interrupt()
        XCTAssertEqual(conversation.takeResumableQuestion(), "下一个")

        // A stop is the user's own choice and is never resumed.
        conversation.send("再一个", using: slow)
        conversation.stop()
        XCTAssertNil(conversation.takeResumableQuestion())
    }

    @MainActor
    func testFailureAfterAFreezeCountsAsAnInterruption() async throws {
        let lifecycle = FrozenLifecycle()
        let conversation = LedgerAgentConversation()
        conversation.lifecycle = lifecycle
        conversation.send("冻住了") { _, _, _ in throw URLError(.networkConnectionLost) }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.phase, .failed(.interrupted, question: "冻住了"))
        XCTAssertEqual(lifecycle.ended, [.interrupted])
        XCTAssertEqual(conversation.takeResumableQuestion(), "冻住了")

        // A refused key is still the key's fault.
        conversation.send("冻住了") { _, _, _ in .init(ok: false, error: "401 invalid api key") }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.phase, .failed(.invalidKey("401 invalid api key"), question: "冻住了"))

        // Without a freeze a network failure is reported as it is.
        lifecycle.frozen = false
        conversation.send("冻住了") { _, _, _ in throw URLError(.networkConnectionLost) }
        try await waitUntilIdle(conversation)
        guard case .failed(.failed, _) = conversation.phase else { return XCTFail("\(conversation.phase)") }
    }

    #if os(iOS)
    @MainActor
    func testInterruptionNotificationNamesTheCause() {
        let summary = LedgerAgentBackgroundRun.summary(.interrupted, concealed: true, cause: "后台保活被来电或其他 App 的声音打断")
        XCTAssertEqual(summary.phase, .interrupted)
        XCTAssertTrue(summary.body.hasPrefix("后台保活被来电"))
    }
    #endif

    func testThinkingClampsLikeTheNativeLoop() {
        XCTAssertEqual(LedgerAgentThinking.max.clamped(to: [.off, .minimal, .low, .medium, .high]), .high)
        XCTAssertEqual(LedgerAgentThinking.off.clamped(to: [.low, .medium, .high]), .low)
        XCTAssertEqual(LedgerAgentThinking.medium.clamped(to: [.off, .low, .high]), .high)
        XCTAssertEqual(LedgerAgentThinking.medium.clamped(to: [.off]), .off)

        let catalog = try? JSONDecoder().decode(LedgerAgentCatalog.self, from: Data(#"""
        {"providers":[{"id":"anthropic","title":"Anthropic","models":[
          {"id":"a","title":"A","thinkingLevels":["off","low","medium","high","ultra"]},{"id":"b","title":"B"}]}]}
        """#.utf8))
        XCTAssertEqual(catalog?.provider("anthropic")?.models.map(\.thinking), [[.off, .low, .medium, .high], [.off]])
    }

    func testTurnRequestSendsThinkingOnlyWhenSet() throws {
        func encoded(_ thinking: String?) throws -> [String: Any] {
            let request = LedgerAgentTurnRequest(turnId: "t", workspaceRoot: "/w", runtimeRoot: "/r", entrypoint: "main.bean",
                sensitiveUnlocked: true, provider: "anthropic", model: "m", apiKey: "k", thinking: thinking, history: [], message: "hi")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        }
        XCTAssertEqual(try encoded("high")["thinking"] as? String, "high")
        XCTAssertNil(try encoded(nil)["thinking"])
    }

    @MainActor
    func testSessionsSaveConversationsAndReopenThem() async throws {
        let store = MemoryConversationStore()
        let sessions = LedgerAgentSessions()
        sessions.bind(ledger: UUID(), storage: store.storage)
        sessions.current.send("十月吃饭花了多少") { _, _, _ in .init(ok: true, reply: "## 餐饮\n共 **812** 元。") }
        try await waitUntilIdle(sessions.current)
        let first = sessions.current.id
        XCTAssertEqual(sessions.saved.map(\.title), ["十月吃饭花了多少"])
        XCTAssertEqual(sessions.saved.first?.summary, "餐饮 共 812 元。")
        for _ in 0..<200 { if await store.count == 1 { break }; try await Task.sleep(nanoseconds: 2_000_000) }
        let stored = await store.count
        XCTAssertEqual(stored, 1)

        sessions.startNew()
        XCTAssertTrue(sessions.current.messages.isEmpty)
        XCTAssertNotEqual(sessions.current.id, first)
        sessions.open(first)
        XCTAssertEqual(sessions.current.id, first)
        XCTAssertEqual(sessions.current.messages.map(\.text), ["十月吃饭花了多少", "## 餐饮\n共 **812** 元。"])

        // A fresh session for the same ledger reads the saved history back.
        let reopened = LedgerAgentSessions()
        reopened.bind(ledger: UUID(), storage: store.storage)
        for _ in 0..<200 where reopened.saved.isEmpty { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(reopened.saved.map(\.id), [first])

        reopened.delete(first)
        XCTAssertTrue(reopened.saved.isEmpty)
        for _ in 0..<200 { if await store.count == 0 { break }; try await Task.sleep(nanoseconds: 2_000_000) }
        let left = await store.count
        XCTAssertEqual(left, 0)
    }

    @MainActor
    func testRunningConversationKeepsAnsweringAfterTheUserMovesOn() async throws {
        let sessions = LedgerAgentSessions()
        sessions.bind(ledger: UUID(), storage: MemoryConversationStore().storage)
        let slow = sessions.current
        slow.send("慢问题") { _, _, _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
            return .init(ok: true, reply: "答完了")
        }
        sessions.startNew()
        XCTAssertTrue(sessions.background === slow)
        XCTAssertTrue(slow.isRunning)
        XCTAssertTrue(sessions.busyElsewhere)
        try await waitUntilIdle(slow)
        XCTAssertFalse(sessions.busyElsewhere)
        XCTAssertEqual(sessions.saved.first?.summary, "答完了")
        sessions.showBackground()
        XCTAssertTrue(sessions.current === slow)
        XCTAssertNil(sessions.background)
    }

    @MainActor
    func testLeavingAnUnwrittenChangeDropsItAndSaysSoOnReopen() async throws {
        let ledger = FakeDraftLedger()
        let sessions = LedgerAgentSessions()
        sessions.bind(ledger: UUID(), storage: MemoryConversationStore().storage)
        let editing = sessions.current
        editing.editor = ledger.editor
        editing.send("午饭改成 26") { _, _, _ in .init(ok: true, reply: "改好了。", edited: true) }
        try await waitUntilIdle(editing)
        XCTAssertEqual(editing.pending?.status, .ready)
        XCTAssertEqual(sessions.saved.first?.unwrittenChange, true)

        sessions.startNew()
        for _ in 0..<200 { if await ledger.closed == 1 { break }; try await Task.sleep(nanoseconds: 2_000_000) }
        let closed = await ledger.closed
        XCTAssertEqual(closed, 1)

        sessions.open(editing.id)
        XCTAssertNotNil(sessions.current.restoredNotice)
        XCTAssertNil(sessions.current.pending)
        sessions.current.send("接着改") { message, history, _ in
            XCTAssertTrue(message.contains("旧对话"))
            XCTAssertEqual(history.count, 2)
            return .init(ok: true, reply: "好。")
        }
        try await waitUntilIdle(sessions.current)
        XCTAssertNil(sessions.current.restoredNotice)
    }

    @MainActor
    func testSessionsStartOverForAnotherLedger() async throws {
        let sessions = LedgerAgentSessions()
        let store = MemoryConversationStore()
        let first = UUID()
        sessions.bind(ledger: first, storage: store.storage)
        sessions.current.send("问题") { _, _, _ in .init(ok: true, reply: "回答") }
        try await waitUntilIdle(sessions.current)
        sessions.bind(ledger: first, storage: store.storage)
        XCTAssertEqual(sessions.current.messages.count, 2)
        sessions.bind(ledger: UUID(), storage: MemoryConversationStore().storage)
        XCTAssertTrue(sessions.current.messages.isEmpty)
        XCTAssertTrue(sessions.saved.isEmpty)
    }

    func testRepositoryWritesAnAgentDraftThroughThePreparedPath() async throws {
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: HandleEngine(), validator: { root, entry in
            let text = try String(contentsOf: root.appendingPathComponent(entry), encoding: .utf8)
            if text.contains("Expenses:Nope") { throw LocalLedgerError.invalidConfiguration("unknown account Expenses:Nope") }
        })
        let descriptor = try await catalog.create(name: "Agent draft")
        let repository = catalog.repository(for: descriptor)
        let draft = try await repository.openAgentDraft()
        let main = draft.root.appendingPathComponent("main.bean")
        let original = try String(contentsOf: main, encoding: .utf8)
        let noChange = try await repository.reviewAgentDraft(draft)
        XCTAssertNil(noChange)

        // The turn sends the draft as its scratch copy.
        let recorder = RequestRecorder()
        let runner = LedgerAgentRunner(run: { data in
            _ = await recorder.record(data)
            return Data(#"{"version":1,"ok":true,"reply":"ok","edited":true}"#.utf8)
        }, cancel: { _ in })
        let response = try await repository.runAgentTurn(message: "记一笔", history: [],
            choice: .init(provider: "anthropic", model: "claude-sonnet-4-5"), apiKey: "k", sensitiveUnlocked: true,
            draft: draft.root, runner: runner)
        XCTAssertTrue(response.edited)
        let requests = await recorder.requests
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.first)) as? [String: Any])
        XCTAssertEqual(sent["scratchRoot"] as? String, draft.root.path)

        try Data((original + "\n2026-10-31 open Expenses:Nope\n").utf8).write(to: main)
        do {
            _ = try await repository.reviewAgentDraft(draft)
            XCTFail("an invalid draft was prepared")
        } catch let error as LedgerAgentEditError {
            guard case .invalid = error else { return XCTFail("\(error)") }
        }
        // The template already opens Expenses:Food, so assert on the exact
        // line the draft adds rather than on the account name.
        let added = "2026-10-31 open Expenses:Food CNY"
        try Data((original + "\n" + added + "\n").utf8).write(to: main)
        try FileManager.default.createDirectory(at: draft.root.appendingPathComponent("2026"), withIntermediateDirectories: true)
        try Data("; 新文件\n".utf8).write(to: draft.root.appendingPathComponent("2026/02.bean"))
        let prepared = try await repository.reviewAgentDraft(draft)
        let review = try XCTUnwrap(prepared)
        XCTAssertEqual(review.files.map(\.path), ["2026/02.bean", "main.bean"])
        XCTAssertEqual(review.files.first?.change, .added)
        let before = try await repository.readFile(path: "main.bean").text
        XCTAssertFalse(before.contains(added))

        let rebased = try await repository.writeAgentDraft(review, draft: draft)
        XCTAssertNotEqual(rebased.baseRevisionID, draft.baseRevisionID)
        let after = try await repository.readFile(path: "main.bean").text
        XCTAssertTrue(after.contains(added))
        let created = try await repository.readFile(path: "2026/02.bean").text
        XCTAssertEqual(created, "; 新文件\n")
        let clean = try await repository.reviewAgentDraft(rebased)
        XCTAssertNil(clean)

        // A commit from elsewhere after the draft was copied is kept: the
        // draft is merged onto it instead of being refused.
        let other = try await repository.openAgentDraft()
        try Data("; 别处\n".utf8).write(to: other.root.appendingPathComponent("other.bean"))
        let otherReview = try await repository.reviewAgentDraft(other)
        _ = try await repository.writeAgentDraft(try XCTUnwrap(otherReview), draft: other)
        try Data("; 晚了\n".utf8).write(to: draft.root.appendingPathComponent("late.bean"))
        let mergedPrepared = try await repository.reviewAgentDraft(rebased)
        let merged = try XCTUnwrap(mergedPrepared)
        XCTAssertEqual(merged.files.map(\.path), ["late.bean"])

        // The ledger moves again after the card was drawn: writing merges again.
        let third = try await repository.openAgentDraft()
        try Data("; 第三处\n".utf8).write(to: third.root.appendingPathComponent("third.bean"))
        let thirdReview = try await repository.reviewAgentDraft(third)
        _ = try await repository.writeAgentDraft(try XCTUnwrap(thirdReview), draft: third)
        let afterMerge = try await repository.writeAgentDraft(merged, draft: rebased)
        for path in ["late.bean", "other.bean", "third.bean"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: afterMerge.root.appendingPathComponent(path).path), path)
            _ = try await repository.readFile(path: path)
        }
        let settled = try await repository.reviewAgentDraft(afterMerge)
        XCTAssertNil(settled)

        try Data("; 不要了\n".utf8).write(to: afterMerge.root.appendingPathComponent("dropped.bean"))
        let fresh = try await repository.discardAgentDraft(nil, draft: afterMerge)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.root.appendingPathComponent("dropped.bean").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.root.appendingPathComponent("other.bean").path))
        await repository.closeAgentDraft(fresh)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.root.path))
    }

    func testRepositoryMergesTheSameFileAndRefusesOnlyTheSameLines() async throws {
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: HandleEngine(), validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Agent merge")
        let repository = catalog.repository(for: descriptor)
        let seed = try await repository.openAgentDraft()
        let ledger = (1...12).map { "; 第 \($0) 行" }.joined(separator: "\n") + "\n"
        try Data(ledger.utf8).write(to: seed.root.appendingPathComponent("2026.bean"))
        let seedReview = try await repository.reviewAgentDraft(seed)
        _ = try await repository.writeAgentDraft(try XCTUnwrap(seedReview), draft: seed)

        func commitElsewhere(_ text: String) async throws {
            let other = try await repository.openAgentDraft()
            try Data(text.utf8).write(to: other.root.appendingPathComponent("2026.bean"))
            let otherReview = try await repository.reviewAgentDraft(other)
            _ = try await repository.writeAgentDraft(try XCTUnwrap(otherReview), draft: other)
        }

        // Different lines of one file, and both appending at the end.
        let draft = try await repository.openAgentDraft()
        let file = draft.root.appendingPathComponent("2026.bean")
        try Data(ledger.replacingOccurrences(of: "; 第 2 行", with: "; 助手改了第 2 行").appending("; 助手追加\n").utf8).write(to: file)
        try await commitElsewhere(ledger.replacingOccurrences(of: "; 第 10 行", with: "; 别处改了第 10 行").appending("; 别处追加\n"))
        let reviewPrepared = try await repository.reviewAgentDraft(draft)
        let review = try XCTUnwrap(reviewPrepared)
        let next = try await repository.writeAgentDraft(review, draft: draft)
        let written = try await repository.readFile(path: "2026.bean").text
        for line in ["; 助手改了第 2 行", "; 别处改了第 10 行", "; 别处追加", "; 助手追加"] {
            XCTAssertTrue(written.contains(line), line)
        }
        XCTAssertLessThan(try XCTUnwrap(written.range(of: "; 别处追加")).lowerBound,
                          try XCTUnwrap(written.range(of: "; 助手追加")).lowerBound)
        XCTAssertEqual(try String(contentsOf: next.root.appendingPathComponent("2026.bean"), encoding: .utf8), written)

        // The same line changed on both sides is a conflict.
        try Data(written.replacingOccurrences(of: "; 第 5 行", with: "; 助手改了第 5 行").utf8)
            .write(to: next.root.appendingPathComponent("2026.bean"))
        try Data("; 助手新文件\n".utf8).write(to: next.root.appendingPathComponent("notes.bean"))
        try await commitElsewhere(written.replacingOccurrences(of: "; 第 5 行", with: "; 别处改了第 5 行"))
        do {
            _ = try await repository.reviewAgentDraft(next)
            XCTFail("a conflicting draft was prepared")
        } catch let error as LedgerAgentEditError {
            XCTAssertEqual(error, .conflict(["2026.bean"]))
        }

        // The next turn's rebase keeps what merges and hands back the rest.
        let (rebased, dropped) = try await repository.rebaseAgentDraft(next)
        XCTAssertEqual(dropped, ["2026.bean"])
        XCTAssertNotEqual(rebased.baseRevisionID, next.baseRevisionID)
        let current = try await repository.readFile(path: "2026.bean").text
        XCTAssertEqual(try String(contentsOf: rebased.root.appendingPathComponent("2026.bean"), encoding: .utf8), current)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rebased.root.appendingPathComponent("notes.bean").path))
        let remainingPrepared = try await repository.reviewAgentDraft(rebased)
        let remaining = try XCTUnwrap(remainingPrepared)
        XCTAssertEqual(remaining.files.map(\.path), ["notes.bean"])
        let unchanged = try await repository.rebaseAgentDraft(rebased)
        XCTAssertEqual(unchanged.0, rebased)
        XCTAssertTrue(unchanged.dropped.isEmpty)
    }

    func testMergeTakesEachSidesChangeAndRefusesOverlaps() {
        let base = Data("a\nb\nc\nd\ne\n".utf8)
        func merge(_ ours: String?, _ theirs: String?, path: String = "x.bean", base: Data? = base) -> LedgerAgentMerge.FileResult {
            LedgerAgentMerge.merge(path: path, base: base, ours: ours.map { Data($0.utf8) }, theirs: theirs.map { Data($0.utf8) })
        }
        XCTAssertEqual(merge("A\nb\nc\nd\ne\n", "a\nb\nc\nd\nE\n"), .merged(Data("A\nb\nc\nd\nE\n".utf8)))
        XCTAssertEqual(merge("a\nB\nc\nd\ne\n", "a\nX\nc\nd\ne\n"), .conflict)
        XCTAssertEqual(merge("a\nb\nc\nd\ne\nours\n", "a\nb\nc\nd\ne\ntheirs\n"),
                       .merged(Data("a\nb\nc\nd\ne\ntheirs\nours\n".utf8)))
        // Outside .bean files, insertions at the same place are a conflict.
        XCTAssertEqual(merge("a\nb\nc\nd\ne\nours\n", "a\nb\nc\nd\ne\ntheirs\n", path: "notes.md"), .conflict)
        // The same change on both sides, and a change on one side only.
        XCTAssertEqual(merge("a\nB\nc\nd\ne\n", "a\nB\nc\nd\ne\n"), .merged(Data("a\nB\nc\nd\ne\n".utf8)))
        XCTAssertEqual(merge("a\nb\nc\nd\ne\n", "a\nb\nC\nd\ne\n"), .merged(Data("a\nb\nC\nd\ne\n".utf8)))
        // Deleted on one side and edited on the other.
        XCTAssertEqual(merge(nil, "a\nB\nc\nd\ne\n"), .conflict)
        XCTAssertEqual(merge(nil, "a\nb\nc\nd\ne\n"), .merged(nil))
        // Both created the file.
        XCTAssertEqual(merge("x\n", "y\n", path: "new.bean", base: nil), .merged(Data("y\nx\n".utf8)))
        // A binary file changed on both sides.
        XCTAssertEqual(LedgerAgentMerge.merge(path: "s.pdf", base: Data([0, 1]), ours: Data([0, 2]), theirs: Data([0, 3])), .conflict)
        // The final newline one side added is kept.
        XCTAssertEqual(merge("a\nb\nc\nd\ne\nf", "A\nb\nc\nd\ne\n", base: Data("a\nb\nc\nd\ne".utf8)),
                       .merged(Data("A\nb\nc\nd\ne\nf\n".utf8)))
    }

    @MainActor
    func testAlwaysPolicyWritesAndStillStopsOnAConflict() async throws {
        let ledger = FakeDraftLedger()
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.writePolicy = .always
        conversation.send("记一笔") { _, _, _ in .init(ok: true, reply: "好了。", edited: true) }
        try await waitUntilIdle(conversation)
        for _ in 0..<200 where conversation.pending != nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(conversation.pending)
        XCTAssertEqual(conversation.written?.files.count, 1)
        let writes = await ledger.writes
        XCTAssertEqual(writes, 1)

        // A conflict still stops for the user.
        await ledger.failReview(with: .conflict(["main.bean"]))
        conversation.send("再改") { _, _, _ in .init(ok: true, reply: "改了。", edited: true) }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.pending?.status, .conflict(["main.bean"]))
        let after = await ledger.writes
        XCTAssertEqual(after, 1)
    }

    @MainActor
    func testTieredPolicyWritesASmallChangeAtOnce() async throws {
        let ledger = FakeDraftLedger()
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        // The default: an edit of a bean file is the everyday kind of change.
        XCTAssertEqual(conversation.writePolicy, .tiered)
        conversation.send("记一笔") { _, _, _ in .init(ok: true, reply: "好了。", edited: true) }
        try await waitUntilIdle(conversation)
        for _ in 0..<200 where conversation.pending != nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(conversation.pending)
        XCTAssertEqual(conversation.written?.files.map(\.path), ["main.bean"])
        let writes = await ledger.writes
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testTieredPolicyHoldsAFileDeletion() async throws {
        let ledger = FakeDraftLedger()
        await ledger.serve(files: [.init(path: "documents/old.pdf", before: Data([0, 1]), after: nil)])
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.send("删掉那份旧账单") { _, _, _ in .init(ok: true, reply: "好了。", edited: true) }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.pending?.status, .ready)
        XCTAssertEqual(conversation.pending?.holdReason, "这次改动删除了 1 个文件，需要你确认。")
        let writes = await ledger.writes
        XCTAssertEqual(writes, 0)

        // The card's button writes it, as before.
        conversation.write()
        for _ in 0..<200 where conversation.pending != nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(conversation.pending)
        let after = await ledger.writes
        XCTAssertEqual(after, 1)
    }

    @MainActor
    func testConfirmPolicyWaitsForTheCard() async throws {
        let ledger = FakeDraftLedger()
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.writePolicy = .confirm
        conversation.send("记一笔") { _, _, _ in .init(ok: true, reply: "好了。", edited: true) }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.pending?.status, .ready)
        // 每次确认 is the user's own choice, so the card has nothing to explain.
        XCTAssertNil(conversation.pending?.holdReason)
        let writes = await ledger.writes
        XCTAssertEqual(writes, 0)

        conversation.write()
        for _ in 0..<200 where conversation.pending != nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(conversation.pending)
        let after = await ledger.writes
        XCTAssertEqual(after, 1)
    }

    @MainActor
    func testTurnRebasesTheDraftAndTellsTheModelWhatItDropped() async throws {
        let ledger = FakeDraftLedger()
        await ledger.dropOnRebase(["2026/10.bean"])
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.send("记一笔") { message, _, _ in
            XCTAssertFalse(message.contains("冲突"))
            return .init(ok: true, reply: "好了。", edited: true)
        }
        try await waitUntilIdle(conversation)
        conversation.send("接着改") { message, _, _ in
            XCTAssertTrue(message.contains("2026/10.bean"))
            XCTAssertTrue(message.hasSuffix("接着改"))
            return .init(ok: true, reply: "重新改好了。")
        }
        try await waitUntilIdle(conversation)
        // The rebased draft is reviewed again even though the turn edited nothing.
        let reviews = await ledger.reviews
        XCTAssertEqual(reviews, 2)
        XCTAssertNotNil(conversation.pending?.review)
    }

    // MARK: Ask, undo and links

    func testTurnResponseDecodesAnAskCard() throws {
        let json = #"{"ok":true,"reply":"归到哪？","ask":{"question":"归到哪？","options":["餐饮","交通"],"multiple":true}}"#
        let response = try JSONDecoder().decode(LedgerAgentTurnResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.ask, .init(question: "归到哪？", options: ["餐饮", "交通"], multiple: true))
        XCTAssertEqual(response.ask?.answer(["交通", "餐饮"]), "餐饮、交通")
        let broken = #"{"ok":true,"reply":"归到哪？","ask":{"question":1}}"#
        XCTAssertNil(try JSONDecoder().decode(LedgerAgentTurnResponse.self, from: Data(broken.utf8)).ask)
    }

    @MainActor
    func testAskCardStaysWithTheReplyAndSurvivesASave() async throws {
        let conversation = LedgerAgentConversation()
        let ask = LedgerAgentAsk(question: "10-05 的 25 元归到哪？", options: ["餐饮", "交通"])
        conversation.send("帮我分类") { _, _, _ in .init(ok: true, reply: ask.question, ask: ask) }
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.messages.last?.ask, ask)
        let saved = try XCTUnwrap(conversation.saved())
        let decoded = try JSONDecoder().decode(LedgerAgentSavedConversation.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(LedgerAgentConversation(restoring: decoded).messages.last?.ask, ask)
    }

    @MainActor
    func testWrittenChangeIsRecordedAndCanBeUndone() async throws {
        let ledger = FakeDraftLedger()
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.send("午饭改成 26") { _, _, _ in .init(ok: true, reply: "改动已准备好。", edited: true) }
        try await waitUntilIdle(conversation)
        conversation.write()
        for _ in 0..<200 where conversation.messages.last?.write == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        let reply = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(reply.write?.files, ["main.bean"])
        XCTAssertTrue(conversation.canUndo(reply))

        conversation.undo(reply)
        for _ in 0..<200 where conversation.messages.last?.write?.undoneAt == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        let undone = try XCTUnwrap(conversation.messages.last)
        XCTAssertNotNil(undone.write?.undoneAt)
        XCTAssertFalse(conversation.canUndo(undone))
        let undos = await ledger.undos
        XCTAssertEqual(undos, 1)
        let saved = try XCTUnwrap(conversation.saved())
        XCTAssertNotNil(saved.messages.last?.write?.undoneAt)

        // The model hears about the undo with the next question.
        conversation.send("现在呢") { message, _, _ in
            XCTAssertTrue(message.contains("撤销"))
            XCTAssertTrue(message.hasSuffix("现在呢"))
            return .init(ok: true, reply: "已恢复。")
        }
        try await waitUntilIdle(conversation)
    }

    @MainActor
    func testUndoThatConflictsSaysWhichFiles() async throws {
        let ledger = FakeDraftLedger()
        await ledger.failUndo(with: .conflict(["2026/10.bean"]))
        let conversation = LedgerAgentConversation()
        conversation.editor = ledger.editor
        conversation.send("改") { _, _, _ in .init(ok: true, reply: "好了。", edited: true) }
        try await waitUntilIdle(conversation)
        conversation.write()
        for _ in 0..<200 where conversation.messages.last?.write == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        conversation.undo(try XCTUnwrap(conversation.messages.last))
        for _ in 0..<200 where conversation.undoFailure == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(conversation.undoFailure?.text.contains("2026/10.bean") == true)
        XCTAssertNil(conversation.messages.last?.write?.undoneAt)
    }

    func testRepositoryUndoesAWrittenDraftAndKeepsLaterCommits() async throws {
        let catalog = LocalLedgerCatalog(rootDirectory: try root(), engine: HandleEngine(), validator: { _, _ in })
        let descriptor = try await catalog.create(name: "Agent undo")
        let repository = catalog.repository(for: descriptor)
        let draft = try await repository.openAgentDraft()
        let main = draft.root.appendingPathComponent("main.bean")
        let original = try String(contentsOf: main, encoding: .utf8)
        let added = "; 助手加的一行"
        try Data((original + "\n" + added + "\n").utf8).write(to: main)
        try Data("; 新文件\n".utf8).write(to: draft.root.appendingPathComponent("agent.bean"))
        let prepared = try await repository.reviewAgentDraft(draft)
        let review = try XCTUnwrap(prepared)
        _ = try await repository.writeAgentDraft(review, draft: draft)
        let written = await repository.agentWrite(for: review)
        let revisions = try XCTUnwrap(written)
        XCTAssertNotEqual(revisions.parent, revisions.revision)
        let taken = await repository.agentWrite(for: review)
        XCTAssertNil(taken)

        // A later commit elsewhere survives the undo.
        let other = try await repository.openAgentDraft()
        try Data("; 别处\n".utf8).write(to: other.root.appendingPathComponent("other.bean"))
        let otherReview = try await repository.reviewAgentDraft(other)
        _ = try await repository.writeAgentDraft(try XCTUnwrap(otherReview), draft: other)

        let record = LedgerAgentWriteRecord(parent: revisions.parent, revision: revisions.revision,
                                            files: review.files.map(\.path), writtenAt: Date())
        try await repository.undoAgentWrite(record)
        let restored = try await repository.readFile(path: "main.bean").text
        XCTAssertFalse(restored.contains(added))
        let files = try await repository.files()
        XCTAssertFalse(files.contains("agent.bean"))
        XCTAssertTrue(files.contains("other.bean"))
        // Undoing again finds nothing left to reverse.
        try await repository.undoAgentWrite(record)
    }

    func testLedgerLinksAreEncodedForMarkdown() {
        let text = "看 [这些](ledger://search?q=payee:美团 AND (narration:午饭)) 和 [账户](ledger://accounts?account=Expenses:Food)。"
        let encoded = LedgerAgentReplyText.encodingLedgerLinks(text)
        XCTAssertTrue(encoded.contains("](ledger://search?q=payee:%E7%BE%8E%E5%9B%A2%20AND%20%28narration:%E5%8D%88%E9%A5%AD%29)"), encoded)
        XCTAssertTrue(encoded.contains("](ledger://accounts?account=Expenses:Food)"), encoded)
        XCTAssertTrue(encoded.hasSuffix("。"))
        let url = URL(string: "ledger://search?q=payee:%E7%BE%8E%E5%9B%A2%20AND%20%28narration:%E5%8D%88%E9%A5%AD%29")!
        XCTAssertEqual(LedgerExternalRoute.parse(url), .search("payee:美团 AND (narration:午饭)"))
        // Already encoded targets are left as they are.
        XCTAssertEqual(LedgerAgentReplyText.encodingLedgerLinks(encoded), encoded)
        XCTAssertEqual(LedgerAgentReplyText.encodingLedgerLinks("没有链接"), "没有链接")
    }

    // MARK: Fixtures

    private actor MemoryConversationStore {
        private var files: [UUID: Data] = [:]
        var count: Int { files.count }
        func save(_ id: UUID, _ data: Data) { files[id] = data }
        func load() -> [Data] { Array(files.values) }
        func remove(_ id: UUID) { files[id] = nil }
        func removeAll() { files = [:] }

        nonisolated var storage: LedgerAgentSessions.Storage {
            .init(save: { await self.save($0, $1) }, load: { await self.load() },
                  remove: { await self.remove($0) }, removeAll: { await self.removeAll() })
        }
    }

    @MainActor
    private final class RecordingLifecycle: LedgerAgentLifecycle {
        var events: [String] = []
        func turnStarted(question: String, conversation: LedgerAgentConversation) { events.append("started " + question) }
        func turnStepped(_ step: LedgerAgentStep, count: Int) { events.append("step \(count) \(step.title)") }
        func turnEnded(_ ending: LedgerAgentTurnEnding) { events.append("ended \(ending)") }
    }

    @MainActor
    private final class FrozenLifecycle: LedgerAgentLifecycle {
        var frozen = true
        var ended: [LedgerAgentTurnEnding] = []
        var turnWasSuspended: Bool { frozen }
        func turnStarted(question: String, conversation: LedgerAgentConversation) {}
        func turnStepped(_ step: LedgerAgentStep, count: Int) {}
        func turnEnded(_ ending: LedgerAgentTurnEnding) { ended.append(ending) }
    }

    private actor FakeDraftLedger {
        var opened = 0, writes = 0, closed = 0, reviews = 0, undos = 0
        private var reviewError: LedgerAgentEditError?
        private var undoError: LedgerAgentEditError?
        /// The files the next review reports; nil means one small bean edit.
        private var served: [LedgerAgentFileDiff]?
        func serve(files: [LedgerAgentFileDiff]) { served = files }
        func failUndo(with error: LedgerAgentEditError) { undoError = error }
        private var dropped: [String] = []
        func failReview(with error: LedgerAgentEditError) { reviewError = error }
        func dropOnRebase(_ paths: [String]) { dropped = paths }

        nonisolated var editor: LedgerAgentEditor {
            LedgerAgentEditor(
                open: { await self.open() },
                review: { try await self.review($0) },
                write: { _, draft in await self.write(draft) },
                discard: { _, _ in await self.open() },
                close: { _ in await self.close() },
                rebase: { await self.rebase($0) },
                written: { _ in (UUID(), UUID()) },
                undo: { _ in try await self.undo() })
        }

        private func undo() throws {
            if let undoError { throw undoError }
            undos += 1
        }

        /// The first rebase finds the ledger unmoved; later ones move it on.
        private var rebases = 0
        private func rebase(_ draft: LedgerAgentDraft) -> (LedgerAgentDraft, dropped: [String]) {
            rebases += 1
            guard rebases > 1, !dropped.isEmpty else { return (draft, []) }
            return (.init(id: draft.id, root: draft.root, baseRevisionID: UUID()), dropped)
        }

        private func open() -> LedgerAgentDraft {
            opened += 1
            return .init(id: UUID(), root: URL(fileURLWithPath: "/tmp/draft-\(opened)"), baseRevisionID: UUID())
        }
        private func review(_ draft: LedgerAgentDraft) throws -> LedgerAgentReview? {
            reviews += 1
            if let reviewError { throw reviewError }
            return .init(id: UUID(), files: served ?? [.init(path: "main.bean", before: Data("a\n".utf8), after: Data("b\n".utf8))])
        }
        private func write(_ draft: LedgerAgentDraft) -> LedgerAgentDraft {
            writes += 1
            return .init(id: draft.id, root: draft.root, baseRevisionID: UUID())
        }
        private func close() { closed += 1 }
    }

    // MARK: Fixtures

    private actor HandleEngine: LocalLedgerEngine {
        var replaced: [String?] = []
        func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data { Data("{}".utf8) }
        func committedModelHandle(for request: LocalLedgerEngineRequest, replacing stale: String?) async throws -> String? {
            replaced.append(stale)
            return "h\(replaced.count)"
        }
    }

    private actor RequestRecorder {
        var requests: [Data] = []
        func record(_ data: Data) -> Int {
            requests.append(data)
            return requests.count
        }
    }

    @MainActor
    private func waitUntilIdle(_ conversation: LedgerAgentConversation) async throws {
        for _ in 0..<200 where conversation.isRunning {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(conversation.isRunning)
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LedgerAgentTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// The last request a substitute lister saw.
private final class SentRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var data: Data? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
