import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Text Formatter

struct TransactionShareTextFormatter {
    static func format(
        transactions: [LedgerTransaction],
        currency: String,
        accountLabels: [String: String] = [:]
    ) -> String {
        if transactions.count == 1, let tx = transactions.first {
            let p = TransactionPresentation(transaction: tx)
            let kindStr = p.kind == .expense ? "支出" : (p.kind == .income ? "收入" : "转账")
            var lines = [
                "【Ledger 记账凭证】",
                "类型：\(kindStr)",
                "金额：\(MoneyText.format(minorUnits: p.minorUnits, currency: p.currency))",
                "时间：\(tx.date)"
            ]
            let desc = tx.payee.isEmpty ? (tx.narration.isEmpty ? p.title : tx.narration) : (tx.narration.isEmpty ? tx.payee : "\(tx.payee) - \(tx.narration)")
            lines.append("描述：\(desc)")

            if !tx.postings.isEmpty {
                lines.append("分录：")
                for posting in tx.postings {
                    let label = accountLabels[posting.account] ?? posting.account
                    let amt = MoneyText.format(minorUnits: abs(posting.amount), currency: posting.currency ?? p.currency)
                    let sign = posting.amount >= 0 ? "+" : "-"
                    lines.append("  · \(label): \(sign)\(amt)")
                }
            }
            if let tags = tx.tags, !tags.isEmpty {
                lines.append("标签：\(tags.map { "#\($0)" }.joined(separator: " "))")
            }
            lines.append("----------------------------")
            lines.append("由 Beancount Ledger 生成")
            return lines.joined(separator: "\n")
        }

        // Multiple transactions
        let sorted = transactions.sorted { $0.date > $1.date }
        var totalExpense = 0
        var totalIncome = 0
        for tx in sorted {
            let p = TransactionPresentation(transaction: tx)
            if p.kind == .expense { totalExpense += p.minorUnits }
            else if p.kind == .income { totalIncome += p.minorUnits }
        }

        var lines = [
            "【Ledger 消费对账清单】",
            "交易笔数：共 \(sorted.count) 笔",
            "支出合计：\(MoneyText.format(minorUnits: totalExpense, currency: currency))",
            "收入合计：\(MoneyText.format(minorUnits: totalIncome, currency: currency))",
            "----------------------------"
        ]

        for (idx, tx) in sorted.enumerated() {
            let p = TransactionPresentation(transaction: tx)
            let sign = p.kind == .expense ? "-" : (p.kind == .income ? "+" : "")
            let amt = MoneyText.format(minorUnits: p.minorUnits, currency: p.currency)
            let name = tx.payee.isEmpty ? (tx.narration.isEmpty ? p.title : tx.narration) : tx.payee
            lines.append("\(idx + 1). [\(tx.date)] \(name) \(sign)\(amt)")
        }

        lines.append("----------------------------")
        lines.append("由 Beancount Ledger 生成")
        return lines.joined(separator: "\n")
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

                AmountLabel(
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

    private var totalExpense: Int {
        sortedTransactions.reduce(0) { sum, tx in
            let p = TransactionPresentation(transaction: tx)
            return p.kind == .expense ? sum + p.minorUnits : sum
        }
    }

    private var totalIncome: Int {
        sortedTransactions.reduce(0) { sum, tx in
            let p = TransactionPresentation(transaction: tx)
            return p.kind == .income ? sum + p.minorUnits : sum
        }
    }

    private var netAmount: Int {
        totalIncome - totalExpense
    }

    private var dateSpanDescription: String {
        let dates = sortedTransactions.map(\.date)
        guard let first = dates.last, let last = dates.first else { return "交易清单" }
        return first == last ? first : "\(first) ~ \(last)"
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle.portrait.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(LedgerPalette.cobalt)
                    Text("LEDGER")
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(LedgerPalette.ink)
                    Text("· 消费对账清单")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Spacer()
                    Text("共 \(sortedTransactions.count) 笔")
                        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(LedgerPalette.cobalt)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(LedgerPalette.cobalt.opacity(0.1), in: Capsule())
                }

                HStack {
                    Text(dateSpanDescription)
                        .font(.system(size: 11.5))
                        .foregroundStyle(LedgerPalette.secondary)
                    Spacer()
                }
            }

            // 3-Column Summary Stats Box
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("支出合计")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                    AmountLabel(
                        minorUnits: totalExpense,
                        currency: currency,
                        font: .system(size: 15, weight: .bold, design: .rounded),
                        color: LedgerPalette.expense
                    )
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(LedgerPalette.line.opacity(0.5))
                    .frame(width: 1, height: 24)
                    .padding(.horizontal, 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text("收入合计")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                    AmountLabel(
                        minorUnits: totalIncome,
                        currency: currency,
                        font: .system(size: 15, weight: .bold, design: .rounded),
                        color: LedgerPalette.income
                    )
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(LedgerPalette.line.opacity(0.5))
                    .frame(width: 1, height: 24)
                    .padding(.horizontal, 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text("收支差额")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                    AmountLabel(
                        minorUnits: netAmount,
                        currency: currency,
                        prefix: netAmount > 0 ? "+" : "",
                        font: .system(size: 15, weight: .bold, design: .rounded),
                        color: netAmount >= 0 ? LedgerPalette.ink : LedgerPalette.expense
                    )
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            ReceiptDashedLine()
                .frame(height: 1)

            // Item List (display up to 35 items)
            VStack(spacing: 8) {
                let displayed = Array(sortedTransactions.prefix(35))
                ForEach(displayed) { tx in
                    let p = TransactionPresentation(transaction: tx)
                    let visual = TransactionVisualCategory.resolve(
                        transaction: tx,
                        presentation: p,
                        accountLabels: accountLabels
                    )
                    let sign = p.kind == .expense ? "-" : (p.kind == .income ? "+" : "")
                    let color = p.kind == .expense ? LedgerPalette.ink : (p.kind == .income ? LedgerPalette.income : LedgerPalette.secondary)

                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(visual.color.opacity(0.14))
                                .frame(width: 28, height: 28)
                            Image(systemName: visual.iconName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(visual.color)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(LedgerPalette.ink)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(tx.date)
                                Text("·")
                                Text(visual.categoryLabel)
                            }
                            .font(.system(size: 10.5))
                            .foregroundStyle(LedgerPalette.secondary)
                        }

                        Spacer()

                        AmountLabel(
                            minorUnits: p.minorUnits,
                            currency: p.currency,
                            prefix: sign,
                            font: .system(size: 13, weight: .semibold, design: .rounded),
                            color: color
                        )
                        .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }

                if sortedTransactions.count > 35 {
                    Text("... 以及另外 \(sortedTransactions.count - 35) 笔交易")
                        .font(.system(size: 11))
                        .foregroundStyle(LedgerPalette.secondary)
                        .padding(.top, 4)
                }
            }

            ReceiptDashedLine()
                .frame(height: 1)

            // Footer
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10.5))
                    Text("Beancount 复式对账已校验")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(LedgerPalette.success)

                Spacer()

                Text("生成自 Beancount Ledger")
                    .font(.system(size: 10))
                    .foregroundStyle(LedgerPalette.secondary.opacity(0.8))
            }
        }
        .padding(20)
        .frame(width: 350)
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
            .task(id: selectedTab) {
                if selectedTab == .card && renderedUIImage == nil {
                    renderCard()
                }
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
                                image: Image(uiImage: renderedUIImage ?? UIImage())
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
                    } else if let uiImage = renderedUIImage {
                        ShareLink(
                            item: Image(uiImage: uiImage),
                            preview: SharePreview(
                                isSingle ? "记账凭证" : "消费对账清单",
                                image: Image(uiImage: uiImage)
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
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(LedgerPalette.cobalt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
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
        let renderer: ImageRenderer<AnyView>
        if isSingle, let tx = transactions.first {
            renderer = ImageRenderer(content: AnyView(
                SingleTransactionReceiptCard(
                    transaction: tx,
                    accountLabels: accountLabels
                )
            ))
        } else {
            renderer = ImageRenderer(content: AnyView(
                CombinedTransactionStatementCard(
                    transactions: transactions,
                    currency: currency,
                    accountLabels: accountLabels
                )
            ))
        }
        renderer.scale = displayScale > 1.0 ? displayScale : 3.0
        if let uiImage = renderer.uiImage {
            self.renderedUIImage = uiImage
            if let data = uiImage.pngData() {
                let tempDir = FileManager.default.temporaryDirectory
                let fileName = isSingle ? "Ledger-Receipt-\(transactions.first?.date ?? "tx").png" : "Ledger-Statement-\(transactions.count)tx.png"
                let fileURL = tempDir.appendingPathComponent(fileName)
                try? data.write(to: fileURL)
                self.tempImageURL = fileURL
            }
        }
    }

    private func copyImage() {
        #if canImport(UIKit)
        if let image = renderedUIImage {
            UIPasteboard.general.image = image
            showNotice("已拷贝长图到剪贴板")
            LedgerFeedback.success()
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
