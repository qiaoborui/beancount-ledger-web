import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerSetupScriptTests: XCTestCase {
    func testFreeTextOnTheWelcomeScreenPicksTheWay() {
        XCTAssertEqual(LedgerSetupScript.path(for: "账本在 GitHub 上"), .git)
        XCTAssertEqual(LedgerSetupScript.path(for: "https://gitea.example.com/me/ledger"), .git)
        XCTAssertEqual(LedgerSetupScript.path(for: "我有一个仓库"), .git)
        XCTAssertEqual(LedgerSetupScript.path(for: "从 iCloud 云盘里的账本继续"), .other)
        XCTAssertEqual(LedgerSetupScript.path(for: "想从备份恢复"), .other)
        XCTAssertEqual(LedgerSetupScript.path(for: "工资卡是招行，平时用支付宝"), .scratch)
        XCTAssertEqual(LedgerSetupScript.path(for: "你好"), .scratch)
    }

    func testRepositoryAddressesAreRecognisedAsHTTPS() {
        XCTAssertEqual(LedgerSetupScript.gitRepository(in: "https://github.com/borui/ledger"), "https://github.com/borui/ledger")
        XCTAssertEqual(LedgerSetupScript.gitRepository(in: "在 github.com/borui/ledger.git 上"), "https://github.com/borui/ledger.git")
        // A browser link into the repository names the repository itself.
        XCTAssertEqual(LedgerSetupScript.gitRepository(in: "https://github.com/borui/ledger/tree/main/2026"),
                       "https://github.com/borui/ledger")
        XCTAssertEqual(LedgerSetupScript.gitRepository(in: "地址是 https://git.example.com/a/b.git。"), "https://git.example.com/a/b.git")
        XCTAssertNil(LedgerSetupScript.gitRepository(in: "git@github.com:borui/ledger.git"))
        XCTAssertNil(LedgerSetupScript.gitRepository(in: "http://github.com/borui/ledger"))
        XCTAssertNil(LedgerSetupScript.gitRepository(in: "https://github.com/borui"))
        XCTAssertNil(LedgerSetupScript.gitRepository(in: "账本在 GitHub 上"))
    }

    func testAConnectedLedgerIsNamedAfterItsRepository() {
        XCTAssertEqual(LedgerSetupScript.ledgerName(forRepository: "https://github.com/borui/ledger.git"), "ledger")
        XCTAssertEqual(LedgerSetupScript.ledgerName(forRepository: "https://github.com/borui/money"), "money")
        XCTAssertEqual(LedgerSetupScript.ledgerName(forRepository: "https://example.com/"), "我的账本")
    }

    func testTheConnectedGreetingOffersStepsForALedgerWithHistory() {
        let opening = LedgerAgentOpening.connected(name: "生活账本")
        XCTAssertTrue(opening.text.contains("「生活账本」"))
        XCTAssertFalse(opening.steps.isEmpty)
        XCTAssertEqual(opening.ask.options, opening.steps)
    }

    private actor Recorder {
        private(set) var sent: [Data] = []
        func next(_ data: Data) -> Data {
            sent.append(data)
            return Data(#"{"ok":true,"reply":"好，先说说招行卡。","toolCalls":[]}"#.utf8)
        }
    }

    @MainActor
    func testWhatTheUserSaidBeforeTheModelOpensTheConversation() async throws {
        let recorder = Recorder()
        let conversation = LedgerOnboardingConversation(
            runner: LedgerAgentRunner(run: { await recorder.next($0) }, cancel: { _ in }),
            credentials: { .init(choice: .init(provider: "anthropic", model: "claude-sonnet-4-5"), apiKey: "k", thinking: nil) })
        conversation.start(saying: "  工资卡是招行  ")
        for _ in 0..<2000 where conversation.isRunning { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(conversation.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(conversation.messages.first?.text, "工资卡是招行")
        let sent = await recorder.sent
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[0]) as? [String: Any])
        XCTAssertEqual(request["message"] as? String, LedgerOnboardingConversation.opening + "\n工资卡是招行")
    }
}
