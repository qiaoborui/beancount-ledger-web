#if os(iOS)
import SwiftUI

/// The ledger's memory folder, as the user reads and edits it: MEMORY.md,
/// which every conversation carries, and the topic files the assistant
/// reads when they matter. The assistant keeps them up to date on its own;
/// this page is where the user corrects, reorganises or clears them.
struct LedgerAgentMemoryView: View {
    @EnvironmentObject private var session: LedgerSession
    @ObservedObject private var settings = LedgerAgentSettings.shared
    @ObservedObject private var memorySync = LedgerAgentMemorySync.shared
    @ObservedObject private var sessions = LedgerAgentSessions.shared
    @Environment(\.dismiss) private var dismiss
    @State private var files: [String: String] = [:]
    @State private var updated: [String: Date] = [:]
    @State private var request = ""
    @FocusState private var requesting: Bool
    @State private var loaded = false
    @State private var error: String?
    @State private var confirmingClear = false
    @State private var creating = false

    private var topics: [String] {
        files.keys.filter { $0 != LedgerAgentMemoryLayout.indexName }.sorted()
    }

    var body: some View {
        List {
            if let error { Section { StatusBanner(message: error) { self.error = nil } } }
            Section {
                Toggle("使用记忆", isOn: Binding(get: { settings.usesMemory }, set: { settings.setUsesMemory($0) }))
                    .accessibilityIdentifier("ledger-agent-uses-memory")
            } footer: {
                Text("关掉后助手不读也不更新记忆，下面的内容仍然保留。")
            }
            Section {
                NavigationLink {
                    LedgerAgentMemoryFileView(path: LedgerAgentMemoryLayout.indexName, onChange: reload)
                } label: {
                    row(path: LedgerAgentMemoryLayout.indexName,
                        detail: files[LedgerAgentMemoryLayout.indexName].map { _ in String(localized: "总览，每次对话都会带上") }
                            ?? String(localized: "还没有记忆。和助手说「记住……」，或者点进来直接写。"))
                }
                .accessibilityIdentifier("ledger-agent-memory-index")
            } header: { Text("自动记忆") } footer: {
                Text("助手在对话里自己记下的偏好和习惯。MEMORY.md 只放每次都用得上的规则，超过约 3 KB 时助手会把成块的细节挪进下面的记忆文件。")
            }
            Section {
                ForEach(topics, id: \.self) { path in
                    NavigationLink {
                        LedgerAgentMemoryFileView(path: path, onChange: reload)
                    } label: {
                        row(path: path, detail: LedgerAgentMemoryLayout.description(of: files[path] ?? ""))
                    }
                }
                Button { creating = true } label: {
                    Label("新建记忆文件", systemImage: "doc.badge.plus")
                }
                .accessibilityIdentifier("ledger-agent-memory-new")
            } header: { Text("记忆文件") } footer: {
                Text("助手先看每个文件开头的说明，和问题有关才读全文，所以记忆多了也不会每次都占上下文。")
            }
            if memorySync.available {
                Section {
                    HStack {
                        Text("上次同步")
                        Spacer()
                        if memorySync.running {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(memorySync.lastSynced.map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "还没有"))
                                .foregroundStyle(BalancedPalette.meta)
                        }
                    }
                    Button("立即同步") { Task { await memorySync.syncNow() } }
                        .disabled(memorySync.running)
                        .accessibilityIdentifier("ledger-agent-memory-sync")
                    if let syncError = memorySync.error {
                        Text(syncError).font(.footnote).foregroundStyle(BalancedPalette.expense)
                    }
                } header: { Text("云端") } footer: {
                    Text("记忆同步到账本仓库的 agent-memory 分支，家里机器上的定时任务读同一份，也会把学到的写回来。两边同时改了同一个文件时按行合并。")
                }
            }
            if !files.isEmpty {
                Section {
                    Button("清空记忆", role: .destructive) { confirmingClear = true }
                        .accessibilityIdentifier("ledger-agent-memory-clear")
                }
            }
        }
        .font(.subheadline)
        .terminalNativeChrome()
        .ledgerSubpageChrome(String(localized: "记忆"))
        .privacySensitive()
        .confirmationDialog("清空记忆？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { clear() }
        } message: {
            Text("助手会忘掉记下的所有偏好和习惯，之后再从对话里重新学。同步后其他设备和云端也会清空。")
        }
        .sheet(isPresented: $creating) {
            NavigationStack { LedgerAgentMemoryNewFileView(existing: Set(files.keys), onCreate: reload) }
                .environmentObject(session)
        }
        .safeAreaInset(edge: .bottom) { requestBar }
        .task { await load() }
        .task { await memorySync.syncNow() }
        .onChange(of: memorySync.revision) { _, _ in Task { await load() } }
    }

    /// 告诉助手要改什么: the request goes to a new conversation, where the
    /// assistant changes the files with its memory tools.
    private var requestBar: some View {
        HStack(spacing: 8) {
            TextField("告诉助手要更改或删除什么", text: $request, axis: .vertical)
                .lineLimit(1...4)
                .focused($requesting)
                .submitLabel(.send)
                .onSubmit(sendRequest)
                .accessibilityIdentifier("ledger-agent-memory-request")
            Button(action: sendRequest) {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                              ? BalancedPalette.edge : BalancedPalette.ink))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("发送")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(BalancedPalette.edge, lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func sendRequest() {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        request = ""
        requesting = false
        if !sessions.current.isRunning, !sessions.busyElsewhere { sessions.startNew() }
        sessions.queuedQuestion = String(localized: "改一下你的记忆：\(text)\n（先看 MEMORY.md 和相关的记忆文件，用 edit_memory / write_memory 改，改完告诉我改了哪些文件。）")
        dismiss()
    }

    private func row(path: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: path).balancedMono(size: 13)
                Spacer()
                if let date = updated[path] {
                    Text("更新于 \(date.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(BalancedPalette.meta)
                }
            }
            if !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(BalancedPalette.meta).lineLimit(2)
            }
        }
    }

    private func reload() { Task { await load() } }

    private func load() async {
        guard let repository = session.localRepository else { return }
        files = await repository.workspace.agentMemoryFiles()
        let folder = repository.workspace.agentMemoryLocation
        var dates: [String: Date] = [:]
        for path in files.keys {
            if let date = try? folder.appendingPathComponent(path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                dates[path] = date
            }
        }
        updated = dates
        loaded = true
    }

    private func clear() {
        guard let repository = session.localRepository else { return }
        Task {
            await repository.workspace.clearAgentMemory()
            LedgerAgentCloudSync.shared.localChanged()
            await load()
        }
    }
}

/// One memory file, edited as plain Markdown.
struct LedgerAgentMemoryFileView: View {
    let path: String
    let onChange: () -> Void
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saved = ""
    @State private var loaded = false
    @State private var error: String?
    @State private var confirmingDelete = false
    @FocusState private var editing: Bool

    private var isIndex: Bool { path == LedgerAgentMemoryLayout.indexName }
    private var limit: Int { isIndex ? LedgerAgentMemoryLayout.maxIndexBytes : LedgerAgentMemoryLayout.maxFileBytes }

    var body: some View {
        List {
            if let error { Section { StatusBanner(message: error) { self.error = nil } } }
            Section {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty && loaded {
                        Text(isIndex ? "## 偏好\n- 说「这个月」指自然月\n- 美团外卖记 Expenses:Food:Delivery" : "- 一条一行")
                            .balancedMono(size: 13)
                            .foregroundStyle(BalancedPalette.edge)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .balancedMono(size: 13)
                        .focused($editing)
                        .frame(minHeight: 360)
                        .scrollContentBackground(.hidden)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("ledger-agent-memory-editor")
                }
            } header: { Text(verbatim: path) } footer: {
                Text(isIndex
                     ? "一条一行，写成助手下次可以直接照做的话。不要写密码、验证码或卡号。最多约 \(limit) 字节。"
                     : "开头 --- 之间的 description 是助手决定要不要读这个文件的依据。最多约 \(limit) 字节。")
            }
            if !saved.isEmpty {
                Section {
                    Button(isIndex ? "清空总览" : "删除这个文件", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .font(.subheadline)
        .terminalNativeChrome()
        .ledgerSubpageChrome(isIndex ? String(localized: "总览") : path, actions: AnyView(
            Button { save(text) } label: {
                Text("保存").font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(!loaded || text == saved ? BalancedPalette.meta : BalancedPalette.ink)
            .disabled(!loaded || text == saved)
            .accessibilityIdentifier("ledger-agent-memory-save")
        ))
        .privacySensitive()
        .confirmationDialog(isIndex ? "清空总览？" : "删除这个记忆文件？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(isIndex ? "清空" : "删除", role: .destructive) { save("", leave: !isIndex) }
        }
        .task { await load() }
    }

    private func load() async {
        guard let repository = session.localRepository else { return }
        text = (await repository.workspace.agentMemoryFiles()[path] ?? "").trimmingCharacters(in: .newlines)
        saved = text
        loaded = true
    }

    private func save(_ content: String, leave: Bool = false) {
        guard let repository = session.localRepository else { return }
        if content.utf8.count > limit {
            error = String(localized: "这个文件太长了，请删掉、合并一些条目，或挪到别的主题文件（最多约 \(limit) 字节）。")
            return
        }
        Task {
            do {
                try await repository.workspace.saveAgentMemoryFile(path, text: content)
                LedgerAgentCloudSync.shared.localChanged()
                text = content.trimmingCharacters(in: .whitespacesAndNewlines)
                saved = text
                editing = false
                error = nil
                onChange()
                if leave { dismiss() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Starts a topic file: a path and the one line that says when to read it.
struct LedgerAgentMemoryNewFileView: View {
    let existing: Set<String>
    let onCreate: () -> Void
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var description = ""
    @State private var error: String?

    var body: some View {
        Form {
            if let error { Section { StatusBanner(message: error) { self.error = nil } } }
            Section {
                TextField("merchants 或 accounts/credit-cards", text: $path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .balancedMono(size: 13)
            } header: { Text("文件名") } footer: {
                Text("小写英文、数字和 -，最多两层目录，.md 可以不写。")
            }
            Section {
                TextField("例如：信用卡账单日、还款日和还款账户", text: $description)
            } header: { Text("什么时候该读它") }
        }
        .navigationTitle("新建主题文件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("创建") { create() }
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty || description.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func create() {
        guard let clean = LedgerAgentMemoryLayout.clean(path), clean != LedgerAgentMemoryLayout.indexName else {
            error = String(localized: "文件名只能用小写英文、数字和 -，最多两层目录。")
            return
        }
        guard !existing.contains(clean) else {
            error = String(localized: "已经有 \(clean) 了。")
            return
        }
        guard let repository = session.localRepository else { return }
        Task {
            do {
                try await repository.workspace.saveAgentMemoryFile(clean, text: LedgerAgentMemoryLayout.withDescription("", description))
                LedgerAgentCloudSync.shared.localChanged()
                onCreate()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The recap at the bottom of a conversation: what was asked, found and
/// changed, so a user coming back knows where things stand.
struct LedgerAgentRecapCard: View {
    let recap: LedgerAgentRecap?
    let isCurrent: Bool
    let isWorking: Bool
    let error: String?
    let onSummarize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                BalancedSectionLabel(text: String(localized: "回顾"))
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.mini)
                } else if recap != nil {
                    Button(action: onSummarize) {
                        Text(isCurrent ? "重新总结" : "更新").balancedFont(size: 12.5)
                            .foregroundStyle(BalancedPalette.meta)
                            .frame(minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ledger-agent-recap-refresh")
                }
            }
            if let recap {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(recap.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "·").balancedFont(size: 14, weight: .semibold).foregroundStyle(BalancedPalette.meta)
                            Text(point).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                        }
                    }
                }
                .opacity(isCurrent ? 1 : 0.6)
                if !isCurrent {
                    Text("之后又聊了几句，点「更新」重新总结。").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                }
            } else if !isWorking {
                Button(action: onSummarize) {
                    Label("总结这次对话", systemImage: "text.append")
                        .balancedFont(size: 13.5).foregroundStyle(BalancedPalette.ink)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ledger-agent-recap")
            } else {
                Text("正在总结…").balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
            }
            if let error, !isWorking {
                Text(error).balancedFont(size: 12).foregroundStyle(BalancedPalette.expense).lineLimit(3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { BalancedPalette.ruleStrong.frame(width: 2) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ledger-agent-recap-card")
    }
}
#endif
