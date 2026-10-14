import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Text Formatter

// MARK: - Safe Share Amount Label (No EnvironmentObject dependency)

struct ShareAmountText: View {
    let minorUnits: Int
    let currency: String
    var prefix: String = ""
    var font: Font = .system(size: 14, weight: .semibold, design: .monospaced)
    var color: Color = LedgerPalette.ink

    var body: some View {
        Text(prefix + MoneyText.format(minorUnits: abs(minorUnits), currency: currency))
            .font(font.monospacedDigit())
            .foregroundStyle(color)
    }
}

// MARK: - Single Transaction Receipt Card (For Image Sharing)

struct SingleTransactionReceiptCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let transaction: LedgerTransaction
    let accountLabels: [String: String]

    private var presentation: TransactionPresentation {
        TransactionPresentation(transaction: transaction)
    }

    private var categoryVisual: TransactionVisualCategory {
        TransactionVisualCategory.resolve(
            transaction: transaction,
            presentation: presentation,
            accountLabels: accountLabels
        )
    }

    private var kindBadgeText: String {
        if presentation.isRefund {
            return "退款"
        }
        switch presentation.kind {
        case .expense: return "支出"
        case .income: return "收入"
        case .transfer: return "转账"
        }
    }

    private var amountColor: Color {
        switch presentation.kind {
        case .expense: return LedgerPalette.expense
        case .income: return LedgerPalette.income
        case .transfer: return LedgerPalette.ink
        }
    }

    private var amountPrefix: String {
        switch presentation.kind {
        case .expense: return "−"
        case .income: return "+"
        case .transfer: return ""
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header: Logo & Receipt Title
            HStack(spacing: 8) {
                Text("LEDGER")
                    .balancedFont(size: 13, weight: .semibold)
                    .tracking(1.5)
                    .foregroundStyle(BalancedPalette.ink)
                Text("· 记账凭证")
                    .balancedFont(size: 12)
                    .foregroundStyle(BalancedPalette.meta)
                Spacer()
                BalancedTag(text: kindBadgeText, kind: {
                    switch presentation.kind {
                    case .expense: .pending
                    case .income: .ok
                    case .transfer: .neutral
                    }
                }())
            }

            // Hero Amount & Payee
            VStack(spacing: 6) {
                ShareAmountText(
                    minorUnits: presentation.minorUnits,
                    currency: presentation.currency,
                    prefix: amountPrefix,
                    font: .custom(BalancedWeight.medium.sansPostscriptName, size: 32),
                    color: amountColor
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                Text(presentation.title)
                    .balancedFont(size: 17, weight: .medium)
                    .foregroundStyle(BalancedPalette.ink)
                    .multilineTextAlignment(.center)

                if !presentation.subtitle.isEmpty {
                    Text(presentation.subtitle)
                        .balancedFont(size: 13)
                        .foregroundStyle(BalancedPalette.meta)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, 2)

            BalancedPalette.rule.frame(height: 1)

            // Money Flow
            let moneyFlow = TransactionMoneyFlow.build(
                transaction: transaction,
                accountLabels: accountLabels,
                defaultCurrency: presentation.currency
            )
            TransactionMoneyFlowView(flow: moneyFlow, compact: true, isShareReceipt: true)

            BalancedPalette.rule.frame(height: 1)

            // Info rows
            VStack(spacing: 9) {
                receiptRow(title: "交易时间", value: TransactionDateHeaderFormatter.format(transaction.date))
                receiptRow(title: "消费分类", value: categoryVisual.categoryLabel)

                if !transaction.postings.isEmpty {
                    ForEach(Array(transaction.postings.prefix(4).enumerated()), id: \.offset) { _, posting in
                        let label = accountLabels[posting.account] ?? posting.account
                        let amt = MoneyText.format(minorUnits: abs(posting.amount), currency: posting.currency ?? presentation.currency)
                        let sign = posting.amount >= 0 ? "+" : "−"
                        receiptRow(title: label, value: "\(sign)\(amt)")
                    }
                }

                if let tags = transaction.tags, !tags.isEmpty {
                    HStack {
                        Text("交易标签")
                            .balancedFont(size: 12.5)
                            .foregroundStyle(BalancedPalette.meta)
                        Spacer()
                        HStack(spacing: 8) {
                            ForEach(tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .balancedFont(size: 11.5)
                                    .foregroundStyle(BalancedPalette.ink)
                            }
                        }
                    }
                }
            }

            BalancedPalette.rule.frame(height: 1)

            // Footer
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Text("复式平衡 · 双向校验")
                        .balancedFont(size: 11)
                }
                .foregroundStyle(BalancedPalette.income)

                Spacer()

                Text("由 Beancount 生成")
                    .balancedFont(size: 10.5)
                    .foregroundStyle(BalancedPalette.meta)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(BalancedPalette.page)
    }

    private func receiptRow(title: String, value: String) -> some View {
        HStack {
            Text(title).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
            Spacer()
            Text(value).balancedFont(size: 12.5, weight: .medium).foregroundStyle(BalancedPalette.ink)
        }
    }
}

// MARK: - Combined Statement Card (For Batch Sharing)

struct CombinedTransactionStatementCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let transactions: [LedgerTransaction]
    let currency: String
    let accountLabels: [String: String]

    private var sortedTransactions: [LedgerTransaction] {
        transactions.sorted { $0.date > $1.date }
    }

    private var dateSpanDescription: String {
        let dates = sortedTransactions.map(\.date)
        guard let first = dates.last, let last = dates.first else { return "流水清单" }
        if first == last {
            return TransactionDateHeaderFormatter.format(first)
        } else {
            let start = first.replacingOccurrences(of: "-", with: ".")
            let end = last.replacingOccurrences(of: "-", with: ".")
            return "\(start) — \(end)"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            statementHeader

            BalancedPalette.rule.frame(height: 1)

            // Body grouped by date
            statementBody

            BalancedPalette.rule.frame(height: 1)

            // Footer
            statementFooter
        }
        .padding(20)
        .frame(width: 360)
        .background(BalancedPalette.page)
    }

    // MARK: - Header

    private var statementHeader: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Text("LEDGER")
                        .balancedFont(size: 13, weight: .semibold)
                        .tracking(1.8)
                        .foregroundStyle(BalancedPalette.ink)
                    Text("·")
                        .balancedFont(size: 12)
                        .foregroundStyle(BalancedPalette.meta)
                    Text("流水对账明细")
                        .balancedFont(size: 12.5, weight: .medium)
                        .foregroundStyle(BalancedPalette.ink)
                }

                Spacer()

                Text("共 \(sortedTransactions.count) 笔")
                    .balancedFont(size: 11)
                    .monospacedDigit()
                    .foregroundStyle(BalancedPalette.meta)
            }

            HStack(spacing: 5) {
                Text(dateSpanDescription)
                    .balancedFont(size: 12)
                    .foregroundStyle(BalancedPalette.meta)
                Spacer()
            }
        }
    }

    // MARK: - Body (Grouped by Date)

    private var statementBody: some View {
        VStack(spacing: 14) {
            let totalDisplayed = Array(sortedTransactions.prefix(45))
            let truncated = sortedTransactions.count > 45
            let displayedGrouped = Dictionary(grouping: totalDisplayed, by: \.date)
            let sortedKeys = displayedGrouped.keys.sorted(by: >)

            ForEach(sortedKeys, id: \.self) { date in
                let txs = displayedGrouped[date] ?? []
                VStack(alignment: .leading, spacing: 8) {
                    // Date section header
                    HStack(spacing: 6) {
                        Text(TransactionDateHeaderFormatter.format(date))
                            .balancedFont(size: 12, weight: .medium)
                            .foregroundStyle(BalancedPalette.ink)
                        Spacer()
                        Text("\(txs.count) 笔")
                            .balancedFont(size: 10.5)
                            .monospacedDigit()
                            .foregroundStyle(BalancedPalette.meta)
                    }
                    .padding(.horizontal, 2)

                    VStack(spacing: 0) {
                        ForEach(Array(txs.enumerated()), id: \.element.id) { index, tx in
                            transactionRow(tx)
                                .padding(.vertical, 8)

                            if index < txs.count - 1 {
                                BalancedPalette.rule.frame(height: 1)
                            }
                        }
                    }
                }
            }

            if truncated {
                Text("... 仅展示前 45 笔，共 \(sortedTransactions.count) 笔流水")
                    .balancedFont(size: 11)
                    .foregroundStyle(BalancedPalette.meta)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Row

    private func transactionRow(_ tx: LedgerTransaction) -> some View {
        let p = TransactionPresentation(transaction: tx)
        let visual = TransactionVisualCategory.resolve(
            transaction: tx,
            presentation: p,
            accountLabels: accountLabels
        )
        let sign = p.kind == .expense ? "−" : (p.kind == .income ? "+" : "")
        let color = p.kind == .expense ? BalancedPalette.expense : (p.kind == .income ? BalancedPalette.income : BalancedPalette.ink)

        let title: String = {
            if !tx.payee.isEmpty {
                return tx.payee
            }
            if !tx.narration.isEmpty {
                return tx.narration
            }
            return visual.categoryLabel
        }()

        let subtitleDetail: String = {
            if !tx.payee.isEmpty && !tx.narration.isEmpty {
                return "\(visual.categoryLabel) · \(tx.narration)"
            }
            return visual.categoryLabel
        }()

        let account = fundingAccount(for: tx)

        return HStack(spacing: 12) {
            // Title & Subtitle
            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .balancedFont(size: 14, weight: .medium)
                    .foregroundStyle(BalancedPalette.ink)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(subtitleDetail)
                        .lineLimit(1)

                    if let tag = tx.tags?.first, !tag.isEmpty {
                        Text("#\(tag)")
                            .balancedFont(size: 9.5)
                            .foregroundStyle(BalancedPalette.ink)
                    }
                }
                .balancedFont(size: 11.5)
                .foregroundStyle(BalancedPalette.meta)
            }

            Spacer(minLength: 8)

            // Amount & Funding Account
            VStack(alignment: .trailing, spacing: 2) {
                ShareAmountText(
                    minorUnits: p.minorUnits,
                    currency: p.currency,
                    prefix: sign,
                    font: .custom(BalancedWeight.medium.sansPostscriptName, size: 15),
                    color: color
                )
                .lineLimit(1)

                if let account, !account.isEmpty {
                    Text(account)
                        .balancedFont(size: 10.5)
                        .foregroundStyle(BalancedPalette.meta)
                        .lineLimit(1)
                }
            }
        }
    }

    private func fundingAccount(for tx: LedgerTransaction) -> String? {
        if let posting = tx.postings.first(where: {
            $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:")
        }) {
            if let custom = accountLabels[posting.account], !custom.isEmpty {
                return custom
            }
            let segs = posting.account.components(separatedBy: ":")
            return segs.last ?? posting.account
        }
        return nil
    }

    // MARK: - Footer

    private var statementFooter: some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                Text("复式平衡凭证 · 真实流水记录").balancedFont(size: 10.5)
            }
            .foregroundStyle(BalancedPalette.income)

            Spacer()

            Text("Beancount Ledger")
                .balancedMono(size: 10.5)
                .foregroundStyle(BalancedPalette.meta)
        }
    }
}

// MARK: - Transaction Share Sheet

struct TransactionShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    let transactions: [LedgerTransaction]
    let currency: String
    let accountLabels: [String: String]

    enum ShareTab: String, CaseIterable, Identifiable {
        case card = "票据长图"
        case text = "文字清单"
        var id: String { rawValue }
    }

    @State private var selectedTab: ShareTab = .card
    @State private var renderedUIImage: UIImage?
    @State private var tempImageURL: URL?
    @State private var actionNotice: String?

    private var isSingle: Bool {
        transactions.count == 1
    }

    private var shareText: String {
        TransactionShareTextFormatter.format(
            transactions: transactions,
            currency: currency,
            accountLabels: accountLabels
        )
    }

    private var sheetTitle: String {
        if isSingle {
            return "分享记账凭证"
        } else {
            return "合并分享 · \(transactions.count) 笔流水"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // `.seg` — full-width mark, not a filled segmented control.
                HStack(spacing: 0) {
                    ForEach(ShareTab.allCases) { tab in
                        Button { selectedTab = tab } label: {
                            BalancedMark(title: tab.rawValue, selected: selectedTab == tab)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                .padding(.horizontal, 20)

                // Notice Toast
                if let actionNotice {
                    Text(actionNotice)
                        .balancedFont(size: 13, weight: .medium)
                        .foregroundStyle(BalancedPalette.page)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(BalancedPalette.ink, in: RoundedRectangle(cornerRadius: 3))
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.bottom, 6)
                }

                // Main Content
                switch selectedTab {
                case .card:
                    cardPreviewSection
                case .text:
                    textPreviewSection
                }
            }
            .background(BalancedPalette.page)
            .navigationTitle(sheetTitle)
            .terminalNativeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                await Task.yield()
                renderCard()
            }
        }
    }

    // MARK: - Card Preview Section

    private var cardPreviewSection: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack {
                    if isSingle, let tx = transactions.first {
                        SingleTransactionReceiptCard(
                            transaction: tx,
                            accountLabels: accountLabels
                        )
                        .padding(.vertical, 16)
                    } else {
                        CombinedTransactionStatementCard(
                            transactions: transactions,
                            currency: currency,
                            accountLabels: accountLabels
                        )
                        .padding(.vertical, 16)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Bottom Action Bar
            HStack(spacing: 10) {
                Button("拷贝图片") { copyImage() }
                    .buttonStyle(.balanced(.outline))

                if let imageURL = tempImageURL {
                    ShareLink(
                        item: imageURL,
                        preview: SharePreview(
                            isSingle ? "记账凭证" : "消费对账清单",
                            icon: Image(systemName: "doc.text.image")
                        )
                    ) {
                        Text("系统分享")
                            .balancedFont(size: 15, weight: .medium)
                            .foregroundStyle(BalancedPalette.page)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(BalancedPalette.ink, in: RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(PressScaleButtonStyle())
                } else {
                    Button {
                        renderCard()
                    } label: {
                        HStack(spacing: 6) {
                            ProgressView().tint(BalancedPalette.page)
                            Text("生成图片中...")
                        }
                        .balancedFont(size: 15, weight: .medium)
                        .foregroundStyle(BalancedPalette.page)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(BalancedPalette.ink.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    }
                    .disabled(true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
        }
    }

    // MARK: - Text Preview Section

    private var textPreviewSection: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(shareText)
                    .balancedMono(size: 13)
                    .foregroundStyle(BalancedPalette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .balancedBand()
                    .padding(20)
            }

            // Bottom Action Bar
            HStack(spacing: 10) {
                Button("拷贝文字") { copyText() }
                    .buttonStyle(.balanced(.outline))

                ShareLink(item: shareText) {
                    Text("分享文字")
                        .balancedFont(size: 15, weight: .medium)
                        .foregroundStyle(BalancedPalette.page)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(BalancedPalette.ink, in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(PressScaleButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
        }
    }

    // MARK: - Helper Actions

    @MainActor
    private func renderCard() {
        let card: AnyView
        if isSingle, let tx = transactions.first {
            card = AnyView(
                SingleTransactionReceiptCard(
                    transaction: tx,
                    accountLabels: accountLabels
                )
            )
        } else {
            card = AnyView(
                CombinedTransactionStatementCard(
                    transactions: transactions,
                    currency: currency,
                    accountLabels: accountLabels
                )
            )
        }
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3.0
        if let uiImage = renderer.uiImage {
            self.renderedUIImage = uiImage
            if let data = uiImage.pngData() {
                let tempDir = FileManager.default.temporaryDirectory
                let safeDate = transactions.first?.date.replacingOccurrences(of: "-", with: "") ?? "tx"
                let fileName = isSingle ? "Ledger-Receipt-\(safeDate).png" : "Ledger-Statement-\(transactions.count)tx.png"
                let fileURL = tempDir.appendingPathComponent(fileName)
                do {
                    try data.write(to: fileURL)
                    self.tempImageURL = fileURL
                } catch {
                    #if DEBUG
                    print("[Share] Failed to write temp image: \(error)")
                    #endif
                }
            }
        }
    }

    private func copyImage() {
        #if canImport(UIKit)
        if let image = renderedUIImage {
            UIPasteboard.general.image = image
            showNotice("已拷贝长图到剪贴板")
            LedgerFeedback.success()
        } else if let url = tempImageURL, let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            UIPasteboard.general.image = img
            showNotice("已拷贝长图到剪贴板")
            LedgerFeedback.success()
        } else {
            renderCard()
            showNotice("正在生成图片，请稍候")
        }
        #endif
    }

    private func copyText() {
        #if canImport(UIKit)
        UIPasteboard.general.string = shareText
        showNotice("已复制文字清单到剪贴板")
        LedgerFeedback.success()
        #endif
    }

    private func showNotice(_ msg: String) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            actionNotice = msg
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                actionNotice = nil
            }
        }
    }
}

/// Explicit file export leaves existing image/text/clipboard sharing unchanged.
/// Only the complete prepared file is shared; never read it back into one String.
struct TransactionTextExportSheet: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    let export: LocalTransactionShareExport

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("完整文字文件已准备", systemImage: "doc.text")
                    Text("共 \(export.count) 笔，包含当前筛选范围内的全部已选交易，不限于本页。")
                        .foregroundStyle(.secondary)
                }
                Section {
                    ShareLink(item: export.url) {
                        Label("分享文字文件", systemImage: "square.and.arrow.up")
                    }
                    .disabled(session.phase != .ready || session.privacyShielded)
                    .accessibilityIdentifier("transaction-text-export-share")
                } footer: {
                    Text("这是完整的 UTF-8 文字文件。关闭此窗口或锁定账本后，会清除本机临时文件；已交给其他应用的副本不受此清理影响。")
                }
            }
            .navigationTitle("导出流水文字")
            .terminalNativeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        // The presenting sheet owns cleanup via onDismiss. A system share
        // controller may hide this view without ending the export presentation.
    }
}
