#if os(iOS)
import SwiftUI
import UIKit

/// What 继续修改 does with an artifact: the chat page puts a request naming it
/// in the composer. Absent where there is no composer to fill.
struct LedgerAgentReviseArtifact: Sendable {
    let revise: @MainActor @Sendable (LedgerAgentArtifactSpec) -> Void
}

private struct LedgerAgentReviseArtifactKey: EnvironmentKey {
    static let defaultValue: LedgerAgentReviseArtifact? = nil
}

extension EnvironmentValues {
    var ledgerAgentReviseArtifact: LedgerAgentReviseArtifact? {
        get { self[LedgerAgentReviseArtifactKey.self] }
        set { self[LedgerAgentReviseArtifactKey.self] = newValue }
    }
}

extension LedgerAgentArtifactSpec {
    /// The request 继续修改 leaves in the composer, for the user to finish.
    var revisionPrompt: String {
        String(localized: "修改产物「\(title)」（id: \(id)）：")
    }
}

/// An artifact in a reply: a card with its title and summary that opens the
/// page full screen, at the version this reply wrote.
struct LedgerAgentArtifactCard: View {
    let artifact: LedgerAgentArtifactSpec
    var onAsk: (String) -> Void = { _ in }
    @Environment(\.ledgerAgentReviseArtifact) private var revise
    @Environment(\.openURL) private var openURL
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            LedgerAgentArtifactRowLabel(title: artifact.title, detail: artifact.summary ?? String(localized: "产物 · 点开查看"))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LedgerAgentPalette.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(LedgerAgentPalette.rule, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("全屏打开这个产物")
        .accessibilityIdentifier("ledger-agent-artifact-card")
        .fullScreenCover(isPresented: $presented) {
            LedgerAgentArtifactScreen(artifact: artifact, onClose: { presented = false },
                                      onAsk: { question in
                                          presented = false
                                          onAsk(question)
                                      },
                                      onRevise: revise.map { revise in
                                          { (spec: LedgerAgentArtifactSpec) in
                                              presented = false
                                              revise.revise(spec)
                                          }
                                      })
                // A ledger:// link closes the page first, so the page it
                // opens is not hidden behind it.
                .environment(\.openURL, OpenURLAction { url in
                    presented = false
                    openURL(url)
                    return .handled
                })
                .ledgerPrivacyProtectedSheet()
        }
    }
}

/// An artifact the reply is still writing.
struct LedgerAgentArtifactBuildingCard: View {
    let title: String?
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LedgerAgentArtifactRowLabel(title: title ?? String(localized: "产物"), detail: String(localized: "正在生成…"),
                                    showsChevron: false)
            .opacity(dimmed ? 0.55 : 1)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LedgerAgentPalette.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(LedgerAgentPalette.rule, lineWidth: 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dimmed = true }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ledger-agent-artifact-building")
    }
}

private struct LedgerAgentArtifactRowLabel: View {
    let title: String
    let detail: String
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(LedgerAgentPalette.secondary)
                .frame(width: 38, height: 38)
                .background(LedgerAgentPalette.page, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(LedgerAgentPalette.rule, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).balancedFont(size: 15, weight: .semibold).foregroundStyle(LedgerAgentPalette.ink)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text(verbatim: detail).balancedFont(size: 12.5).foregroundStyle(LedgerAgentPalette.meta)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LedgerAgentPalette.meta)
            }
        }
    }
}

/// One artifact full screen: the page, its versions, and 继续修改.
struct LedgerAgentArtifactScreen: View {
    /// What to show first: the version a reply wrote, or the latest.
    let artifact: LedgerAgentArtifactSpec
    var onClose: () -> Void
    var onAsk: (String) -> Void = { _ in }
    var onRevise: ((LedgerAgentArtifactSpec) -> Void)?
    /// Set from the 产物 list, which can delete.
    var onDelete: (() -> Void)?

    @EnvironmentObject private var session: LedgerSession
    @ObservedObject private var shelf = LedgerAgentArtifactShelf.shared
    @State private var record: LedgerAgentArtifactRecord?
    @State private var shown: LedgerAgentArtifactSpec?
    @State private var shownVersion: Int?
    @State private var confirmingDelete = false
    /// Bumped by 重新载入数据 so an HTML page runs its queries again.
    @State private var reload = 0
    @Environment(\.openURL) private var openURL

    private var current: LedgerAgentArtifactSpec { shown ?? artifact }

    /// Today on the device's calendar, as yyyy-MM-dd.
    private static var today: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: current.title).balancedFont(size: 22, weight: .semibold)
                .foregroundStyle(LedgerAgentPalette.ink)
                .accessibilityAddTraits(.isHeader)
            if let summary = current.summary {
                Text(verbatim: summary).balancedFont(size: 13.5).foregroundStyle(LedgerAgentPalette.secondary)
            }
            if let caption = versionCaption {
                Text(verbatim: caption).balancedFont(size: 12).foregroundStyle(LedgerAgentPalette.meta)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let html = current.html {
                    // The page scrolls itself, under the heading.
                    VStack(alignment: .leading, spacing: 10) {
                        heading
                        LedgerAgentArtifactHTMLView(
                            html: html,
                            context: .init(title: current.title, today: Self.today,
                                           currency: session.ledger?.valuationCurrency ?? "CNY"),
                            reload: reload,
                            runQuery: { query in try await session.runBQL(query: query) },
                            onOpen: { url in openURL(url) },
                            onAsk: onAsk)
                            .id(current.json)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            heading
                            LedgerAgentVisualView(visual: current.visual, onAsk: onAsk)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .background(LedgerAgentPalette.page)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", action: onClose).accessibilityIdentifier("ledger-agent-artifact-close")
                }
                ToolbarItem(placement: .primaryAction) { menu }
            }
            .privacySensitive()
        }
        .task(id: shelf.revision) { await load() }
        .confirmationDialog("删除这个产物？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { onDelete?() }
        } message: {
            Text("它的所有版本都会删掉，对话里的卡片仍然可以打开当时的版本。")
        }
    }

    private var versionCaption: String? {
        guard let record, let number = shownVersion ?? record.version(matching: current)?.number else { return nil }
        let date = (record.version(number)?.savedAt ?? record.updatedAt).formatted(date: .abbreviated, time: .shortened)
        if record.versions.count > 1 {
            return String(localized: "第 \(number) 版，共 \(record.versions.count) 版 · \(date)")
        }
        return date
    }

    private var menu: some View {
        Menu {
            if let onRevise {
                Button("继续修改", systemImage: "pencil") { onRevise(current) }
                    .accessibilityIdentifier("ledger-agent-artifact-revise")
                if !current.isHTML {
                    Button("用最新数据刷新", systemImage: "arrow.clockwise") {
                        onAsk(String(localized: "用最新的账本数据刷新产物「\(current.title)」（id: \(current.id)），结构不变。"))
                    }
                }
            }
            if current.isHTML {
                // The page queries the ledger as it loads, so loading it
                // again is the refresh; no model call.
                Button("重新载入数据", systemImage: "arrow.clockwise") { reload += 1 }
            }
            if let record, record.versions.count > 1 {
                Menu("历史版本") {
                    ForEach(Array(record.versions.reversed()), id: \.number) { version in
                        Button {
                            if let spec = LedgerAgentArtifactSpec(json: version.spec) {
                                shown = spec
                                shownVersion = version.number
                            }
                        } label: {
                            Text("第 \(version.number) 版 · \(version.savedAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                }
            }
            Button(current.isHTML ? "复制源码" : "复制 JSON", systemImage: "doc.on.doc") { UIPasteboard.general.string = current.json }
            if onDelete != nil {
                Button("删除", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("更多")
        .accessibilityIdentifier("ledger-agent-artifact-more")
    }

    private func load() async {
        guard let repository = session.localRepository,
              let data = await repository.workspace.agentArtifact(id: artifact.id) else { return }
        record = LedgerAgentArtifactRecord.decode(data)
    }
}

extension LedgerAgentArtifactRecord {
    /// The saved version whose block is this one.
    func version(matching spec: LedgerAgentArtifactSpec) -> Version? {
        versions.last { $0.spec == spec.json }
    }
}

/// Every artifact of this ledger, newest first, from the history drawer.
struct LedgerAgentArtifactsView: View {
    /// Leaves a request in the chat's composer and returns to it.
    var onRevise: (LedgerAgentArtifactSpec) -> Void
    var onAsk: (String) -> Void
    /// The composer at the bottom: a request for a new artifact, sent in a
    /// conversation of its own.
    var onCreate: ((String) -> Void)? = nil
    /// The round button at the top left: back to the conversations drawer.
    /// Without it the page has a back chevron there instead.
    var onMenu: (() -> Void)? = nil

    @EnvironmentObject private var session: LedgerSession
    @ObservedObject private var shelf = LedgerAgentArtifactShelf.shared
    @Environment(\.ledgerIconTabBar) private var tabBar
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Item] = []
    @State private var loaded = false
    @State private var opened: Opened?
    @State private var searching = false
    @State private var query = ""
    @State private var byName = false
    @State private var draft = ""
    @FocusState private var focus: Field?

    private enum Field { case search, composer }

    private struct Opened: Identifiable {
        let spec: LedgerAgentArtifactSpec
        var id: String { spec.id }
    }

    /// A record with its latest page read once, for the card's preview.
    fileprivate struct Item: Identifiable {
        let record: LedgerAgentArtifactRecord
        let spec: LedgerAgentArtifactSpec?
        var id: String { record.id }
    }

    private var shown: [Item] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = words.isEmpty ? items : items.filter {
            $0.record.title.localizedCaseInsensitiveContains(words)
                || ($0.record.summary?.localizedCaseInsensitiveContains(words) ?? false)
        }
        return byName ? matching.sorted { $0.record.title.localizedStandardCompare($1.record.title) == .orderedAscending } : matching
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("产物")
                    .balancedFont(size: 32, weight: .semibold)
                    .foregroundStyle(LedgerAgentPalette.ink)
                    .padding(.top, 4)
                    .padding(.bottom, searching ? 0 : 4)
                    .accessibilityAddTraits(.isHeader)
                if searching { searchField }
                if loaded && items.isEmpty {
                    empty
                } else if loaded && shown.isEmpty {
                    Text("没有找到相关的产物").balancedFont(size: 14).foregroundStyle(LedgerAgentPalette.meta)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(shown) { item in
                    LedgerAgentArtifactTile(item: item, open: { open(item) },
                                            revise: item.spec.map { spec in { onRevise(spec) } },
                                            delete: { delete(item.id) })
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(LedgerAgentPalette.page)
        .toolbar(.hidden, for: .navigationBar)
        .ledgerSoftTopEdge()
        .ledgerGlassTopBar { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottom }
        .background { TerminalBackGestureBridge().frame(width: 0, height: 0) }
        .privacySensitive()
        .task(id: shelf.revision) { await load() }
        .fullScreenCover(item: $opened) { item in
            LedgerAgentArtifactScreen(artifact: item.spec, onClose: { opened = nil },
                                      onAsk: { question in
                                          opened = nil
                                          onAsk(question)
                                      },
                                      onRevise: { spec in
                                          opened = nil
                                          onRevise(spec)
                                      },
                                      onDelete: {
                                          opened = nil
                                          delete(item.spec.id)
                                      })
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme?.lowercased() == "ledger" else { return .systemAction }
                    opened = nil
                    session.openWidgetURL(url)
                    return .handled
                })
                .ledgerPrivacyProtectedSheet()
        }
    }

    // MARK: Bars

    /// Claude's 产物 bar: a round button at the leading edge, a capsule with
    /// search and more at the trailing one, no title (the page sets it large).
    private var topBar: some View {
        HStack(spacing: 8) {
            if let onMenu {
                roundButton("sidebar.left", label: "历史对话", identifier: "ledger-agent-artifacts-menu", action: onMenu)
            } else {
                roundButton("chevron.left", label: "返回上一页", identifier: "ledger-agent-artifacts-back") { dismiss() }
            }
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                barIcon("magnifyingglass", label: searching ? "收起搜索" : "搜索产物", identifier: "ledger-agent-artifacts-search") {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        searching.toggle()
                        if !searching { query = "" }
                    }
                    focus = searching ? .search : nil
                }
                moreMenu
            }
            .padding(.horizontal, 2)
            .background {
                if !LedgerGlass.isAvailable { Capsule().fill(LedgerAgentPalette.sunken) }
            }
            .ledgerGlassControl()
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func roundButton(_ symbol: String, label: LocalizedStringKey, identifier: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .foregroundStyle(LedgerAgentPalette.ink)
                .frame(width: 44, height: 44)
                .background {
                    if !LedgerGlass.isAvailable { Circle().fill(LedgerAgentPalette.sunken) }
                }
                .ledgerGlassControl()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func barIcon(_ symbol: String, label: LocalizedStringKey, identifier: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .foregroundStyle(LedgerAgentPalette.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var moreMenu: some View {
        Menu {
            Picker("排序", selection: $byName) {
                Label("最近更新", systemImage: "clock").tag(false)
                Label("按名称", systemImage: "textformat").tag(true)
            }
            if onCreate != nil {
                Button { focus = .composer } label: { Label("新建产物", systemImage: "plus") }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .medium))
                .foregroundStyle(LedgerAgentPalette.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("更多")
        .accessibilityIdentifier("ledger-agent-artifacts-more")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(LedgerAgentPalette.meta)
            TextField("搜索产物", text: $query)
                .balancedFont(size: 16)
                .focused($focus, equals: .search)
                .submitLabel(.search)
                .accessibilityIdentifier("ledger-agent-artifacts-query")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(LedgerAgentPalette.meta)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .ledgerGlassField()
        .clipShape(Capsule())
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LedgerAgentPalette.meta)
            Text("还没有产物").balancedFont(size: 16, weight: .medium).foregroundStyle(LedgerAgentPalette.ink)
            Text("让助手「做一个 2026 年餐饮支出面板」「生成一份本月账单报告」，做好的页面会存在这里，随时打开、继续修改或用最新数据刷新。")
                .balancedFont(size: 13).foregroundStyle(LedgerAgentPalette.meta)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 80)
    }

    /// The composer, and the tab bar under it while the keyboard is down.
    private var bottom: some View {
        VStack(spacing: 0) {
            if onCreate != nil { composer }
            if let tabBar, focus == nil {
                LedgerIconTabBar(model: tabBar)
                    .transition(.opacity)
            }
        }
        .padding(.top, 10)
        .animation(LedgerAgentKeyboardInset.motion, value: focus == nil)
        .ledgerIconTabBarGround()
    }

    private var composer: some View {
        let ready = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("做一个文档、报表或应用", text: $draft, axis: .vertical)
                .balancedFont(size: 16)
                .lineLimit(1...5)
                .focused($focus, equals: .composer)
                .padding(.vertical, 11)
                .padding(.leading, 18)
                .accessibilityIdentifier("ledger-agent-artifacts-composer")
            Button(action: create) {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LedgerAgentPalette.page)
                    .frame(width: 32, height: 32)
                    .background(LedgerAgentPalette.ink.opacity(ready ? 1 : 0.25), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .padding(.trailing, 6)
            .padding(.bottom, 6)
            .accessibilityLabel("发送")
            .accessibilityIdentifier("ledger-agent-artifacts-send")
        }
        .frame(minHeight: 44)
        .background {
            if !LedgerGlass.isAvailable {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(LedgerAgentPalette.sunken)
            }
        }
        .modifier(LedgerAgentArtifactComposerGlass())
        .padding(.horizontal, 12)
        .padding(.bottom, focus == nil ? 4 : 8)
    }

    // MARK: Actions

    private func create() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let onCreate else { return }
        draft = ""
        focus = nil
        onCreate(String(localized: "做一个产物：\(text)"))
    }

    private func open(_ item: Item) {
        if let spec = item.spec { opened = Opened(spec: spec) }
    }

    private func load() async {
        guard let repository = session.localRepository else { return }
        let data = await repository.workspace.agentArtifacts()
        items = data.compactMap(LedgerAgentArtifactRecord.decode)
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { record in Item(record: record, spec: record.latest.flatMap { LedgerAgentArtifactSpec(json: $0.spec) }) }
        loaded = true
    }

    private func delete(_ id: String) {
        guard let repository = session.localRepository else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { items.removeAll { $0.id == id } }
        Task {
            await repository.workspace.removeAgentArtifact(id: id)
            LedgerAgentCloudSync.shared.localChanged()
            LedgerAgentArtifactShelf.shared.changed()
        }
    }
}

/// The composer's ground: glass on iOS 26, rounded to a capsule at one line.
private struct LedgerAgentArtifactComposerGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            content
        }
    }
}

/// An artifact on the 产物 page: a large rounded card with the page itself,
/// small, on top, and its title and age under it.
private struct LedgerAgentArtifactTile: View {
    let item: LedgerAgentArtifactsView.Item
    let open: () -> Void
    let revise: (() -> Void)?
    let delete: () -> Void

    private static let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                LedgerAgentArtifactPreview(spec: item.spec)
                    .frame(height: 190)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding([.horizontal, .top], 8)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.record.title)
                        .balancedFont(size: 16, weight: .semibold)
                        .foregroundStyle(LedgerAgentPalette.ink)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text(verbatim: LedgerAgentArtifactAge.text(item.record.updatedAt))
                        .balancedFont(size: 13)
                        .foregroundStyle(LedgerAgentPalette.meta)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(LedgerAgentPalette.sunken, in: Self.shape)
            .contentShape(Self.shape)
        }
        .buttonStyle(LedgerAgentArtifactTilePress())
        .contextMenu {
            Button { open() } label: { Label("打开", systemImage: "arrow.up.left.and.arrow.down.right") }
            if let revise {
                Button { revise() } label: { Label("继续修改", systemImage: "pencil") }
            }
            Button(role: .destructive) { delete() } label: { Label("删除", systemImage: "trash") }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(item.record.title)，\(LedgerAgentArtifactAge.text(item.record.updatedAt))"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityIdentifier("ledger-agent-artifact-row")
    }
}

/// Presses the card in a little, the way Claude's cards answer a touch.
private struct LedgerAgentArtifactTilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// The artifact's page drawn at half size and clipped to the card's window;
/// an HTML page, which would need a web view per card, shows its mark.
private struct LedgerAgentArtifactPreview: View {
    let spec: LedgerAgentArtifactSpec?
    private static let scale: CGFloat = 0.5

    var body: some View {
        ZStack(alignment: .topLeading) {
            LedgerAgentPalette.page
            if let spec, !spec.isHTML {
                GeometryReader { proxy in
                    LedgerAgentVisualView(visual: spec.visual)
                        .padding(.horizontal, 20)
                        .frame(width: proxy.size.width / Self.scale, alignment: .topLeading)
                        .scaleEffect(Self.scale, anchor: .topLeading)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: spec?.isHTML == true ? "doc.richtext" : "rectangle.stack")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(LedgerAgentPalette.meta)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            }
        }
    }
}

/// How long ago an artifact changed, short as Claude writes it (2d, 3h).
enum LedgerAgentArtifactAge {
    static func text(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return String(localized: "刚刚")
        case ..<3600: return String(localized: "\(Int(seconds / 60)) 分钟前")
        case ..<86400: return String(localized: "\(Int(seconds / 3600)) 小时前")
        case ..<(86400 * 30): return String(localized: "\(Int(seconds / 86400)) 天前")
        default: return date.formatted(.dateTime.year().month().day())
        }
    }
}
#endif
