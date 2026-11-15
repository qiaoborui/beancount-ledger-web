#if os(iOS)
import SwiftUI
import WebKit
#if canImport(LedgerLinux)
import LedgerLinux
#endif

/// The built-in Linux's terminal: a login shell on a pseudo-terminal of the
/// engine's, drawn by xterm.js (bundled, no network) in a web view.
///
/// One session lives while the App runs, so leaving the page and coming back
/// finds the shell where it was; its recent output is replayed into the new
/// page. 重新开始 ends it and starts another.
final class LedgerLinuxTerminalSession: @unchecked Sendable {
    static let shared = LedgerLinuxTerminalSession()

    private let lock = NSLock()
    private var id: Int32 = 0
    private var exited = false
    private var starting = false
    /// What the shell printed, kept for a page that opens later.
    private var scrollback = Data()
    private static let scrollbackLimit = 512 * 1024
    private var pending = Data()
    private var flushScheduled = false
    /// Receives output on the main thread. Set by the page on screen.
    private var listener: (@MainActor (Data) -> Void)?
    private var exitListener: (@MainActor (Int32) -> Void)?
    private var unsent = Data()
    private let inputQueue = DispatchQueue(label: "ledger.linux.terminal.input")
    private var size = (cols: Int32(80), rows: Int32(24))

    private init() {}

    var isRunning: Bool { lock.withLock { id != 0 && !exited } }

    /// Attaches a page: it gets the output so far, then everything new.
    @MainActor
    func attach(output: @escaping @MainActor (Data) -> Void, exit: @escaping @MainActor (Int32) -> Void) -> Data {
        lock.withLock {
            listener = output
            exitListener = exit
            return scrollback
        }
    }

    @MainActor
    func detach() {
        lock.withLock {
            listener = nil
            exitListener = nil
        }
    }

    /// Boots the machine if needed and opens the shell. Runs off the main thread.
    func start(cols: Int, rows: Int) async throws {
        let shouldStart = lock.withLock { () -> Bool in
            size = (Int32(clamping: cols), Int32(clamping: rows))
            if (id != 0 && !exited) || starting { return false }
            starting = true
            return true
        }
        guard shouldStart else { return }
        defer { lock.withLock { starting = false } }
        try await Task.detached(priority: .userInitiated) {
            try LedgerLinuxMachine.shared.boot()
            try self.open()
        }.value
    }

    private func open() throws {
        #if canImport(LedgerLinux)
        let previous = lock.withLock { id }
        if previous != 0 { ledger_linux_terminal_close(previous) }
        let (cols, rows) = lock.withLock { size }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let opened = ledger_linux_terminal_open(cols, rows, { context, data, length in
            guard let context, let data, length > 0 else { return }
            let session = Unmanaged<LedgerLinuxTerminalSession>.fromOpaque(context).takeUnretainedValue()
            session.receive(Data(bytes: data, count: Int(length)))
        }, { context, code in
            guard let context else { return }
            let session = Unmanaged<LedgerLinuxTerminalSession>.fromOpaque(context).takeUnretainedValue()
            session.finished(code)
        }, context)
        guard opened > 0 else {
            throw TerminalError(message: String(localized: "终端打不开（\(opened)）。"))
        }
        lock.withLock {
            id = opened
            exited = false
        }
        #else
        throw TerminalError(message: String(localized: "这台设备上没有内置 Linux。"))
        #endif
    }

    struct TerminalError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Ends the shell and starts a new one with a clear screen.
    func restart() async throws {
        lock.withLock {
            scrollback.removeAll()
            pending.removeAll()
            unsent.removeAll()
            exited = true
        }
        let (cols, rows) = lock.withLock { size }
        try await start(cols: Int(cols), rows: Int(rows))
    }

    // MARK: Output

    private func receive(_ data: Data) {
        let schedule = lock.withLock { () -> Bool in
            scrollback.append(data)
            if scrollback.count > Self.scrollbackLimit {
                scrollback.removeFirst(scrollback.count - Self.scrollbackLimit)
            }
            pending.append(data)
            if flushScheduled { return false }
            flushScheduled = true
            return true
        }
        guard schedule else { return }
        // Batched: a command that prints a lot reaches the page a frame at a time.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [self] in
            MainActor.assumeIsolated { flush() }
        }
    }

    @MainActor
    private func flush() {
        let (data, listener) = lock.withLock { () -> (Data, (@MainActor (Data) -> Void)?) in
            let data = pending
            pending.removeAll()
            flushScheduled = false
            return (data, self.listener)
        }
        if !data.isEmpty { listener?(data) }
    }

    private func finished(_ code: Int32) {
        lock.withLock { exited = true }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                flush()
                let exitListener = lock.withLock { self.exitListener }
                exitListener?(code)
            }
        }
    }

    // MARK: Input

    /// Types into the shell. What its full input buffer does not take yet is
    /// sent a moment later, in order.
    func send(_ data: Data) {
        lock.withLock { unsent.append(data) }
        inputQueue.async { [self] in drain() }
    }

    /// Only ever on `inputQueue`, so `unsent` loses its front only here. The
    /// write happens outside the lock: the terminal echoes what it is given
    /// straight back through `receive`, which takes the lock.
    private func drain() {
        #if canImport(LedgerLinux)
        let (terminal, chunk) = lock.withLock { () -> (Int32, Data) in
            guard id != 0, !exited else {
                unsent.removeAll()
                return (0, Data())
            }
            return (id, unsent.prefix(4096))
        }
        guard terminal != 0, !chunk.isEmpty else { return }
        let taken = chunk.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return 0 }
            return ledger_linux_terminal_write(terminal, base, Int32(clamping: buffer.count))
        }
        let more = lock.withLock { () -> Bool in
            if taken < 0 {
                unsent.removeAll()
                return false
            }
            unsent.removeFirst(min(Int(taken), unsent.count))
            return !unsent.isEmpty
        }
        if more {
            inputQueue.asyncAfter(deadline: .now() + .milliseconds(taken == 0 ? 20 : 0)) { [self] in drain() }
        }
        #endif
    }

    func resize(cols: Int, rows: Int) {
        let current = lock.withLock { () -> Int32 in
            size = (Int32(clamping: cols), Int32(clamping: rows))
            return exited ? 0 : id
        }
        #if canImport(LedgerLinux)
        if current != 0 { ledger_linux_terminal_resize(current, Int32(clamping: cols), Int32(clamping: rows)) }
        #endif
    }
}

/// 终端 — a full-screen terminal on the built-in Linux.
struct LedgerLinuxTerminalScreen: View {
    @State private var error: String?
    @State private var exitCode: Int32?
    @State private var restartToken = 0

    var body: some View {
        LedgerLinuxTerminalWebView(error: $error, exitCode: $exitCode, restartToken: restartToken)
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Color(red: 0.067, green: 0.071, blue: 0.078))
            .overlay(alignment: .top) {
                if let error {
                    StatusBanner(message: error) { self.error = nil }.padding()
                } else if let exitCode {
                    HStack {
                        Text("Shell 已退出（\(exitCode)）")
                        Spacer()
                        Button("重新开始") { restart() }
                    }
                    .font(.subheadline)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                }
            }
            .navigationTitle("终端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("重新开始", systemImage: "arrow.counterclockwise") { restart() }
                        .accessibilityIdentifier("ledger-linux-terminal-restart")
                }
            }
    }

    private func restart() {
        exitCode = nil
        error = nil
        restartToken += 1
    }
}

private struct LedgerLinuxTerminalWebView: UIViewRepresentable {
    @Binding var error: String?
    @Binding var exitCode: Int32?
    var restartToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "terminal")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = UIColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1)
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = view
        if let page = Bundle.main.url(forResource: "terminal", withExtension: "html") {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            error = String(localized: "这个版本的 App 没有带终端页面。")
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.restartToken != restartToken {
            context.coordinator.restartToken = restartToken
            context.coordinator.restart()
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
        LedgerLinuxTerminalSession.shared.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: LedgerLinuxTerminalWebView
        weak var webView: WKWebView?
        var restartToken: Int
        private var size = (cols: 80, rows: 24)
        private let session = LedgerLinuxTerminalSession.shared

        init(parent: LedgerLinuxTerminalWebView) {
            self.parent = parent
            restartToken = parent.restartToken
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                size = (body["cols"] as? Int ?? 80, body["rows"] as? Int ?? 24)
                attach()
            case "resize":
                size = (body["cols"] as? Int ?? size.cols, body["rows"] as? Int ?? size.rows)
                session.resize(cols: size.cols, rows: size.rows)
            case "input":
                if let text = body["data"] as? String { session.send(Data(text.utf8)) }
            case "binary":
                if let text = body["data"] as? String {
                    session.send(Data(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }))
                }
            default:
                break
            }
        }

        private func attach() {
            let earlier = session.attach(output: { [weak self] data in self?.write(data) },
                                         exit: { [weak self] code in self?.parent.exitCode = code })
            if !earlier.isEmpty { write(earlier) }
            if session.isRunning {
                session.resize(cols: size.cols, rows: size.rows)
                return
            }
            if earlier.isEmpty { write(Data(String(localized: "正在启动内置 Linux…\r\n").utf8)) }
            Task { await start() }
        }

        private func start() async {
            do {
                try await session.start(cols: size.cols, rows: size.rows)
                parent.exitCode = nil
            } catch {
                parent.error = error.localizedDescription
            }
        }

        func restart() {
            webView?.evaluateJavaScript("ledgerTerminal.reset()")
            Task {
                do {
                    try await session.restart()
                    parent.exitCode = nil
                } catch {
                    parent.error = error.localizedDescription
                }
            }
        }

        private func write(_ data: Data) {
            webView?.evaluateJavaScript("ledgerTerminal.write('\(data.base64EncodedString())')")
        }
    }
}
#endif
