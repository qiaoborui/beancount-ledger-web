import SwiftUI

/// Fills bank post dates on existing HSBC HK card entries from the archived
/// statements. The scan is read-only; the selected fills are written only after
/// confirmation (local ledgers through the change preview). Possible double
/// bookings are listed for the person to resolve; nothing is deleted here.
struct PostDateBackfillView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    var onWritten: () -> Void = {}

    @State private var result: LedgerPostDateBackfill?
    @State private var selectedIDs: Set<String> = []
    @State private var isScanning = false
    @State private var isWriting = false
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var prepared: PreparedBookkeepingChange?

    private var busy: Bool { isScanning || isWriting }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section { StatusBanner(message: errorMessage) { self.errorMessage = nil } }
                }
                if let notice {
                    Section {
                        Text(notice).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.ink)
                            .accessibilityIdentifier("post-date-backfill-notice")
                    }
                }
                if let result {
                    summarySection(result)
                    fillSection(result)
                    reviewSection(result)
                    duplicateSection(result)
                } else if isScanning {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("正在扫描已归档的汇丰账单…").balancedFont(size: 13.5).foregroundStyle(BalancedPalette.meta)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .ledgerReadingList()
            .tint(BalancedPalette.ink)
            .privacySensitive()
            .refreshable { await scan() }
            .navigationTitle("补写汇丰记账日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.disabled(isWriting)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let result, !result.fills.isEmpty {
                    Button {
                        Task { await write() }
                    } label: {
                        Text(isWriting ? "正在补写…" : "补写 \(selectedIDs.count) 笔记账日")
                    }
                    .buttonStyle(.balanced(.primary, disabled: busy || selectedIDs.isEmpty))
                    .disabled(busy || selectedIDs.isEmpty)
                    .accessibilityIdentifier("post-date-backfill-write")
                    .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                    .ledgerGlassDock()
                }
            }
            .accessibilityIdentifier("post-date-backfill")
        }
        .task { if result == nil { await scan() } }
        .sheet(item: $prepared) { change in
            BookkeepingPreviewView(preview: change, islandNotice: .written(count: selectedIDs.count)) { _ in
                finishWrite(count: selectedIDs.count)
            }
        }
        .interactiveDismissDisabled(isWriting)
        .ledgerPrivacyProtectedSheet()
    }

    private func summarySection(_ result: LedgerPostDateBackfill) -> some View {
        Section {
            Text("扫描 \(result.documents) 份账单、\(result.bankRows) 条银行记录；账本里还有 \(result.missingPostDate) 笔卡片分录缺少记账日。")
                .balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(result.warnings, id: \.self) { warning in
                Text(warning).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if result.fills.isEmpty && result.reviews.isEmpty && result.possibleDuplicates.isEmpty {
                Text("没有可补写的记账日，也没有发现疑似重复。")
                    .balancedFont(size: 13.5).foregroundStyle(BalancedPalette.meta)
            }
        }
        .listRowBackground(BalancedPalette.page)
    }

    @ViewBuilder
    private func fillSection(_ result: LedgerPostDateBackfill) -> some View {
        if !result.fills.isEmpty {
            Section {
                ForEach(result.fills) { fill in
                    ImportPostDateFillRow(fill: fill, included: selectedIDs.contains(fill.id)) {
                        if selectedIDs.contains(fill.id) { selectedIDs.remove(fill.id) } else { selectedIDs.insert(fill.id) }
                    }
                    .disabled(busy)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                }
            } header: {
                TerminalSectionLabel(text: String(localized: "补写记账日 \(selectedIDs.count) / \(result.fills.count)"))
                    .listRowBackground(BalancedPalette.page)
            } footer: {
                Text("这些已有分录与汇丰账单里的同一笔金额一致、日期相近，补写后可以按结单账期对账。")
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func reviewSection(_ result: LedgerPostDateBackfill) -> some View {
        if !result.reviews.isEmpty {
            Section {
                ForEach(Array(result.reviews.enumerated()), id: \.offset) { _, review in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(review.bankDate) · \(review.bankPayee)")
                                .balancedFont(size: 14, weight: .medium).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Self.unsigned(review.amount, review.currency))
                                .balancedFont(size: 14).monospacedDigit().foregroundStyle(BalancedPalette.ink)
                        }
                        Text(review.hint.summary).balancedFont(size: 12).foregroundStyle(BalancedPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("记账日 \(review.postDate)").balancedMono(size: 12).foregroundStyle(BalancedPalette.meta)
                    }
                    .padding(.vertical, 6)
                }
            } header: {
                TerminalSectionLabel(text: String(localized: "需要人工确认 \(result.reviews.count)"))
                    .listRowBackground(BalancedPalette.page)
            } footer: {
                Text("金额略有差异或有多条同金额候选，没有自动补写。确认是同一笔后，请在交易详情里修改金额并补上记账日。")
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func duplicateSection(_ result: LedgerPostDateBackfill) -> some View {
        if !result.possibleDuplicates.isEmpty {
            Section {
                ForEach(Array(result.possibleDuplicates.enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: 6) {
                        duplicateLine(pair.bank)
                        duplicateLine(pair.existing)
                    }
                    .padding(.vertical, 6)
                }
            } header: {
                TerminalSectionLabel(text: String(localized: "疑似重复记账 \(result.possibleDuplicates.count)"))
                    .listRowBackground(BalancedPalette.page)
            } footer: {
                Text("同一张卡上，银行导入的分录与支付宝/微信/手记分录金额接近、日期相近，可能记了两次。请核对后手动删除多余的一条，这里不会自动删除。")
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func duplicateLine(_ entry: LedgerPostDateBackfill.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(entry.date) · \(entry.payee.isEmpty ? entry.narration : entry.payee)")
                    .balancedFont(size: 14, weight: .medium).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.unsigned(entry.amount, entry.currency))
                    .balancedFont(size: 14).monospacedDigit().foregroundStyle(BalancedPalette.ink)
            }
            Text("\(entry.source ?? "-") · \(entry.file):\(entry.line)")
                .balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta).lineLimit(1).truncationMode(.middle)
        }
    }

    private static func unsigned(_ amount: String, _ currency: String) -> String {
        "\(amount.hasPrefix("-") ? String(amount.dropFirst()) : amount) \(currency)"
    }

    private func scan() async {
        guard !isWriting else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            let scanned = try await session.postDateBackfill()
            result = scanned
            selectedIDs = Set(scanned.fills.map(\.id))
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func write() async {
        let ids = selectedIDs
        guard !ids.isEmpty, !busy else { return }
        isWriting = true
        defer { isWriting = false }
        do {
            if session.isLocal, let repository = session.localRepository {
                prepared = try await repository.preparePostDateBackfill(fillIDs: Array(ids))
            } else {
                let applied = try await session.applyPostDateBackfill(fillIDs: Array(ids))
                finishWrite(count: applied.count)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finishWrite(count: Int) {
        notice = String(localized: "已为 \(count) 笔分录补写记账日。")
        onWritten()
        Task { await scan() }
    }
}
