#if os(iOS)
import os
import SwiftUI
import WebKit

/// An HTML artifact's page in a web view cut off from the network. Every
/// load but the page itself is blocked twice over (the document's
/// Content-Security-Policy and a content rule list), every navigation is
/// refused, nothing persists between loads, and the page reaches the ledger
/// only through `window.ledger`: read-only queries the app runs, `ledger://`
/// links, and a follow-up question after the user taps.
struct LedgerAgentArtifactHTMLView: UIViewRepresentable {
    let html: String
    let context: LedgerAgentArtifactHTML.Context
    /// Bumped to load the page again, so its queries read the ledger afresh.
    let reload: Int
    let runQuery: @MainActor (String) async throws -> BQLResult
    let onOpen: @MainActor (URL) -> Void
    let onAsk: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = false
        configuration.dataDetectorTypes = []
        configuration.userContentController.addScriptMessageHandler(WeakHandler(context.coordinator),
                                                                     contentWorld: .page, name: "ledger")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.runQuery = runQuery
        coordinator.onOpen = onOpen
        coordinator.onAsk = onAsk
        let document = LedgerAgentArtifactHTML.document(body: html, context: self.context)
        guard coordinator.loaded != document || coordinator.reload != reload else { return }
        coordinator.loaded = document
        coordinator.reload = reload
        coordinator.load(document)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        var loaded: String?
        var reload = 0
        var runQuery: (@MainActor (String) async throws -> BQLResult)?
        var onOpen: (@MainActor (URL) -> Void)?
        var onAsk: ((String) -> Void)?
        private var queries = 0
        private var lastAsk: Date?
        private var rulesInstalled = false

        private static var rules: WKContentRuleList?

        func load(_ document: String) {
            queries = 0
            Task { @MainActor in
                // The rules go in before the page, so it is never free to
                // fetch. If they cannot be compiled the page still loads:
                // its Content-Security-Policy and the refused navigations
                // keep it offline, and a blank page would help no one.
                await installRules()
                webView?.loadHTMLString(document, baseURL: nil)
            }
        }

        private func installRules() async {
            guard !rulesInstalled, let webView else { return }
            if Self.rules == nil {
                do {
                    Self.rules = try await WKContentRuleListStore.default()
                        .compileContentRuleList(forIdentifier: "ledger-artifact-offline-v2",
                                                encodedContentRuleList: LedgerAgentArtifactHTML.contentRules)
                } catch {
                    Self.logger.error("artifact rule list did not compile: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard let rules = Self.rules else { return }
            webView.configuration.userContentController.add(rules)
            rulesInstalled = true
        }

        private static let logger = Logger(subsystem: "app.beancount.ledger", category: "agent-artifact-html")

        func handle(_ body: Any) async -> (Any?, String?) {
            guard let message = body as? [String: Any], let op = message["op"] as? String else { return (nil, "无效的请求") }
            switch op {
            case "query":
                guard let query = message["bql"] as? String, LedgerAgentArtifactHTML.allows(query: query) else {
                    return (nil, "只能运行一条 SELECT、BALANCES 或 JOURNAL 查询")
                }
                guard queries < LedgerAgentArtifactHTML.maximumQueries else { return (nil, "这个页面的查询次数已用完") }
                queries += 1
                guard let runQuery else { return (nil, "账本不可用") }
                do {
                    return (LedgerAgentArtifactHTML.reply(try await runQuery(query)), nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            case "open":
                guard let raw = message["url"] as? String, let url = LedgerAgentVisual.ledgerLink(raw) else {
                    return (nil, "只能打开 ledger:// 链接")
                }
                guard message["active"] as? Bool == true else { return (nil, "需要用户点按后才能打开") }
                onOpen?(url)
                return (true, nil)
            case "ask":
                guard let text = (message["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                      text.count <= LedgerAgentVisual.Action.maximumQuestion else { return (nil, "问题为空或太长") }
                guard message["active"] as? Bool == true else { return (nil, "需要用户点按后才能追问") }
                if let lastAsk, Date().timeIntervalSince(lastAsk) < LedgerAgentArtifactHTML.askInterval { return (nil, "太频繁了") }
                lastAsk = Date()
                onAsk?(text)
                return (true, nil)
            default:
                return (nil, "不支持的操作")
            }
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = action.request.url
            if url?.scheme?.lowercased() == "ledger" {
                if action.navigationType == .linkActivated, let url = LedgerAgentVisual.ledgerLink(url?.absoluteString) { onOpen?(url) }
                return .cancel
            }
            // Only the document the app loaded, at about:blank.
            let isPage = action.targetFrame?.isMainFrame == true && action.navigationType == .other
                && (url == nil || url?.absoluteString == "about:blank")
            return isPage ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo) async {}
    }

    /// Holds the coordinator weakly, so the content controller does not keep
    /// the page's coordinator alive.
    @MainActor
    private final class WeakHandler: NSObject, WKScriptMessageHandlerWithReply {
        weak var coordinator: Coordinator?
        init(_ coordinator: Coordinator) { self.coordinator = coordinator }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) async -> (Any?, String?) {
            guard let coordinator else { return (nil, "页面已关闭") }
            return await coordinator.handle(message.body)
        }
    }
}
#endif
