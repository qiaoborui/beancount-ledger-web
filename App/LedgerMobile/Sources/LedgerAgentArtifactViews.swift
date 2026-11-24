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

    @EnvironmentObject private var session: LedgerSession
    @ObservedObject private var shelf = LedgerAgentArtifactShelf.shared
    @State private var records: [LedgerAgentArtifactRecord] = []
    @State private var loaded = false
    @State private var opened: Opened?

    private struct Opened: Identifiable {
        let spec: LedgerAgentArtifactSpec
        var id: String { spec.id }
    }

    var body: some View {
        List {
            if loaded && records.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有产物").balancedFont(size: 15, weight: .medium).foregroundStyle(LedgerAgentPalette.ink)
                        Text("让助手「做一个 2026 年餐饮支出面板」「生成一份本月账单报告」，做好的页面会存在这里，随时打开、继续修改或用最新数据刷新。")
                            .balancedFont(size: 13).foregroundStyle(LedgerAgentPalette.meta)
                    }
                    .padding(.vertical, 6)
                }
            }
            ForEach(records) { record in
                Button {
                    if let latest = record.latest, let spec = LedgerAgentArtifactSpec(json: latest.spec) { opened = Opened(spec: spec) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: record.title).balancedFont(size: 15, weight: .medium).foregroundStyle(LedgerAgentPalette.ink)
                        if let summary = record.summary {
                            Text(verbatim: summary).balancedFont(size: 13).foregroundStyle(LedgerAgentPalette.secondary).lineLimit(2)
                        }
                        Text(caption(record)).balancedFont(size: 12).foregroundStyle(LedgerAgentPalette.meta)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("删除", role: .destructive) { delete(record.id) }
                }
                .accessibilityIdentifier("ledger-agent-artifact-row")
            }
        }
        .terminalNativeChrome()
        .ledgerSubpageChrome(String(localized: "产物"))
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

    private func caption(_ record: LedgerAgentArtifactRecord) -> String {
        let date = record.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return record.versions.count > 1 ? String(localized: "\(date) · \(record.versions.count) 个版本") : date
    }

    private func load() async {
        guard let repository = session.localRepository else { return }
        let data = await repository.workspace.agentArtifacts()
        records = data.compactMap(LedgerAgentArtifactRecord.decode).sorted { $0.updatedAt > $1.updatedAt }
        loaded = true
    }

    private func delete(_ id: String) {
        guard let repository = session.localRepository else { return }
        records.removeAll { $0.id == id }
        Task {
            await repository.workspace.removeAgentArtifact(id: id)
            LedgerAgentCloudSync.shared.localChanged()
            LedgerAgentArtifactShelf.shared.changed()
        }
    }
}
#endif
