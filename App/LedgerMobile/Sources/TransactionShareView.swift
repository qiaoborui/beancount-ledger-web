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
    var font: Font = .system(size: 14, weight: .semibold, design: .rounded)
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
        case .expense: return "-"
        case .income: return "+"
        case .transfer: return ""
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header: Logo & Receipt Title
            HStack(spacing: 8) {
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(LedgerPalette.cobalt)
                Text("LEDGER")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(LedgerPalette.ink)
                Text("· 记账凭证")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
                Spacer()
                Text(kindBadgeText)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(amountColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(amountColor.opacity(0.12), in: Capsule())
            }

            // Hero Amount & Payee
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(categoryVisual.color.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: categoryVisual.iconName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(categoryVisual.color)
                }
                .padding(.top, 4)

                ShareAmountText(
                    minorUnits: presentation.minorUnits,
                    currency: presentation.currency,
                    prefix: amountPrefix,
                    font: .system(size: 34, weight: .bold, design: .rounded),
                    color: amountColor
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                Text(presentation.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                    .multilineTextAlignment(.center)

                if !presentation.subtitle.isEmpty {
                    Text(presentation.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(LedgerPalette.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, 2)

            ReceiptDashedLine()
                .frame(height: 1)

            // Money Flow
            let moneyFlow = TransactionMoneyFlow.build(
                transaction: transaction,
                accountLabels: accountLabels,
                defaultCurrency: presentation.currency
            )
            TransactionMoneyFlowView(flow: moneyFlow, compact: true)

            ReceiptDashedLine()
                .frame(height: 1)

            // Info rows
            VStack(spacing: 9) {
                receiptRow(title: "交易时间", value: TransactionDateHeaderFormatter.format(transaction.date))
                receiptRow(title: "消费分类", value: categoryVisual.categoryLabel)

                if !transaction.postings.isEmpty {
                    ForEach(Array(transaction.postings.prefix(4).enumerated()), id: \.offset) { _, posting in
                        let label = accountLabels[posting.account] ?? posting.account
                        let amt = MoneyText.format(minorUnits: abs(posting.amount), currency: posting.currency ?? presentation.currency)
                        let sign = posting.amount >= 0 ? "+" : "-"
                        receiptRow(title: label, value: "\(sign)\(amt)")
                    }
                }

                if let tags = transaction.tags, !tags.isEmpty {
                    HStack {
                        Text("交易标签")
                            .font(.system(size: 12.5))
                            .foregroundStyle(LedgerPalette.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(LedgerPalette.cobalt)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(LedgerPalette.cobalt.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                }
            }

            ReceiptDashedLine()
                .frame(height: 1)

            // Footer
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                    Text("复式平衡 · 双向校验")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(LedgerPalette.success)

                Spacer()

                Text("由 Beancount 生成")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(LedgerPalette.secondary.opacity(0.8))
            }
        }
        .padding(20)
        .frame(width: 340)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color(uiColor: .secondarySystemBackground) : Color.white)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.08),
                    radius: 12,
                    x: 0,
                    y: 4
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(LedgerPalette.line.opacity(0.4), lineWidth: 0.5)
        }
    }

    private func receiptRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(LedgerPalette.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(LedgerPalette.ink)
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

            ReceiptDashedLine()
                .frame(height: 1)

            // Body grouped by date
            statementBody

            ReceiptDashedLine()
                .frame(height: 1)

            // Footer
            statementFooter
        }
        .padding(20)
        .frame(width: 360)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(colorScheme == .dark ? Color(uiColor: .secondarySystemBackground) : Color.white)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08),
                    radius: 16,
                    x: 0,
                    y: 6
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(LedgerPalette.line.opacity(0.4), lineWidth: 0.75)
        }
    }

    // MARK: - Header

    private var statementHeader: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle.portrait.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(LedgerPalette.cobalt)
                    Text("LEDGER")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(LedgerPalette.ink)
                    Text("·")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(LedgerPalette.secondary.opacity(0.5))
                    Text("流水对账明细")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                }

                Spacer()

                Text("共 \(sortedTransactions.count) 笔")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(LedgerPalette.cobalt)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(LedgerPalette.cobalt.opacity(0.1), in: Capsule())
            }

            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
                Text(dateSpanDescription)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
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
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(LedgerPalette.ink)
                        Spacer()
                        Text("\(txs.count) 笔")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    .padding(.horizontal, 2)

                    // Group card container
                    VStack(spacing: 0) {
                        ForEach(Array(txs.enumerated()), id: \.element.id) { index, tx in
                            transactionRow(tx)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)

                            if index < txs.count - 1 {
                                Divider()
                                    .overlay(LedgerPalette.line.opacity(0.3))
                                    .padding(.leading, 54)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color(uiColor: .systemGray6).opacity(0.55))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(LedgerPalette.line.opacity(0.3), lineWidth: 0.5)
                    }
                }
            }

            if truncated {
                Text("... 仅展示前 45 笔，共 \(sortedTransactions.count) 笔流水")
                    .font(.system(size: 11))
                    .foregroundStyle(LedgerPalette.secondary)
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
        let sign = p.kind == .expense ? "-" : (p.kind == .income ? "+" : "")
        let color = p.kind == .expense ? LedgerPalette.ink : (p.kind == .income ? LedgerPalette.income : LedgerPalette.secondary)

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
            // Category Icon
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(visual.color.opacity(0.13))
                    .frame(width: 36, height: 36)
                Image(systemName: visual.iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(visual.color)
            }

            // Title & Subtitle
            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(subtitleDetail)
                        .lineLimit(1)

                    if let tag = tx.tags?.first, !tag.isEmpty {
                        Text("#\(tag)")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(LedgerPalette.cobalt)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(LedgerPalette.cobalt.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(LedgerPalette.secondary)
            }

            Spacer(minLength: 8)

            // Amount & Funding Account
            VStack(alignment: .trailing, spacing: 2) {
                ShareAmountText(
                    minorUnits: p.minorUnits,
                    currency: p.currency,
                    prefix: sign,
                    font: .system(size: 15.5, weight: .bold, design: .rounded),
                    color: color
                )
                .lineLimit(1)

                if let account, !account.isEmpty {
                    Text(account)
                        .font(.system(size: 10.5))
                        .foregroundStyle(LedgerPalette.secondary)
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
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(LedgerPalette.success)
                Text("复式平衡凭证 · 真实流水记录")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
            }

            Spacer()

            Text("Beancount Ledger")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(LedgerPalette.secondary.opacity(0.8))
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
                // Segmented Picker
                Picker("分享形式", selection: $selectedTab) {
                    ForEach(ShareTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                // Notice Toast
                if let actionNotice {
                    Text(actionNotice)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(LedgerPalette.cobalt, in: Capsule())
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
            .background(LedgerPalette.canvas)
            .navigationTitle(sheetTitle)
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
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    // Copy Image Button
                    Button {
                        copyImage()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                            Text("拷贝图片")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LedgerPalette.ink)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressScaleButtonStyle())

                    // Share Link (System Share Sheet)
                    if let imageURL = tempImageURL {
                        ShareLink(
                            item: imageURL,
                            preview: SharePreview(
                                isSingle ? "记账凭证" : "消费对账清单",
                                icon: Image(systemName: "doc.text.image")
                            )
                        ) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                Text("系统分享")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(LedgerPalette.cobalt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressScaleButtonStyle())
                    } else {
                        Button {
                            renderCard()
                        } label: {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .tint(.white)
                                Text("生成图片中...")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(LedgerPalette.cobalt.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(true)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(LedgerPalette.panel)
        }
    }

    // MARK: - Text Preview Section

    private var textPreviewSection: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(shareText)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(LedgerPalette.ink)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LedgerPalette.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(LedgerPalette.line.opacity(0.4), lineWidth: 0.5)
                        }
                }
                .padding(20)
            }

            // Bottom Action Bar
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    // Copy Text Button
                    Button {
                        copyText()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                            Text("拷贝文字")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LedgerPalette.ink)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressScaleButtonStyle())

                    // Share Text Button
                    ShareLink(item: shareText) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                            Text("分享文字")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(LedgerPalette.cobalt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressScaleButtonStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(LedgerPalette.panel)
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
            Form {
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        // The presenting sheet owns cleanup via onDismiss. A system share
        // controller may hide this view without ending the export presentation.
    }
}
