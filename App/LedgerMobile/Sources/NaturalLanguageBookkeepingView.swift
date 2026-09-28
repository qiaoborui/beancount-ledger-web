import SwiftUI

struct NaturalLanguageBookkeepingView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = BookkeepingSettings.shared
    @ObservedObject private var classificationSettings = ImportClassificationSettings.shared
    var onSaved: (() -> Void)? = nil

    @State private var input = ""
    @State private var draft: BookkeepingDraft?
    @State private var records: [Record] = []
    @State private var busy = false
    @State private var error: String?
    @State private var preview: PreparedBookkeepingChange?
    @State private var operation: Task<Void, Never>?
    @State private var runID = UUID()
    @FocusState private var inputFocused: Bool

    // Account picker & modal states
    @State private var accountPickerTarget: (recordIndex: Int, postingIndex: Int, title: String, accounts: [LedgerAccountChoice])?
    @State private var showDatePicker = false
    @State private var editingDateIndex = 0
    @State private var showEditDetailsSheet = false
    @State private var editingRecordIndex = 0

    struct Record: Identifiable, Equatable {
        let id = UUID()
        var date: String
        var payee: String
        var narration: String
        var postings: [EditableTransactionPosting]

        init(_ entry: LedgerTransactionEntry) {
            date = entry.date
            payee = entry.payee
            narration = entry.narration
            postings = entry.postings.map { .init(account: $0.account, amount: $0.amount, currency: $0.currency) }
        }

        var entry: LedgerTransactionEntry {
            .init(date: date, flag: "*", payee: payee, narration: narration, postings: postings.map {
                .init(account: $0.account, amount: $0.amount, currency: $0.currency)
            })
        }
    }

    private struct ExamplePrompt: Identifiable {
        let id = UUID()
        let emoji: String
        let title: String
        let text: String
        let tint: Color
    }

    private let examplePrompts: [ExamplePrompt] = [
        .init(emoji: "🍱", title: "美团外卖", text: "中午在美团外卖点餐 35 元，微信零钱支付。", tint: Color(red: 0.96, green: 0.55, blue: 0.18)),
        .init(emoji: "🚇", title: "地铁出行", text: "今早乘坐地铁 7 元，支付宝花呗扣款。", tint: Color(red: 0.16, green: 0.54, blue: 0.95)),
        .init(emoji: "☕️", title: "咖啡饮品", text: "下午买了一杯星巴克 32 元，招行信用卡付款。", tint: Color(red: 0.72, green: 0.48, blue: 0.28)),
        .init(emoji: "📚", title: "买书分账", text: "昨天用招行信用卡买书 128 元，其中 48 元替同事垫付。", tint: Color(red: 0.35, green: 0.45, blue: 0.88)),
        .init(emoji: "💳", title: "信用卡还款", text: "从工行储蓄卡转账 3000 元还招商银行信用卡。", tint: Color(red: 0.12, green: 0.68, blue: 0.36))
    ]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: LedgerSpacing.lg) {
                        if !settings.canParse {
                            unconfiguredHeroBanner
                        }

                        aiInputCard

                        if let error {
                            StatusBanner(message: error) { self.error = nil }
                        }

                        if let draft, !draft.questions.isEmpty {
                            aiNoticePill(draft.questions)
                        }

                        if !records.isEmpty {
                            resultSection
                            // Bottom padding for floating confirm bar
                            Color.clear.frame(height: 80)
                        } else {
                            inspirationSection
                        }
                    }
                    .padding(.horizontal, LedgerSpacing.lg)
                    .padding(.top, LedgerSpacing.sm)
                    .padding(.bottom, LedgerSpacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)

                // Pinned bottom confirmation bar when result is ready
                if !records.isEmpty {
                    floatingActionBar
                }
            }
            .background(LedgerPalette.canvas.ignoresSafeArea())
            .navigationTitle("用一句话记账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        cancel()
                        dismiss()
                    }
                    .disabled(busy)
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        BookkeepingSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                }
            }
            .sheet(item: $preview) { prepared in
                BookkeepingPreviewView(preview: prepared) { _ in
                    dismiss()
                    onSaved?()
                }
            }
            .sheet(isPresented: Binding(
                get: { accountPickerTarget != nil },
                set: { if !$0 { accountPickerTarget = nil } }
            )) {
                if let target = accountPickerTarget {
                    NavigationStack {
                        LedgerAccountPicker(
                            title: target.title,
                            accounts: target.accounts,
                            selection: Binding(
                                get: {
                                    guard records.indices.contains(target.recordIndex),
                                          records[target.recordIndex].postings.indices.contains(target.postingIndex) else { return "" }
                                    return records[target.recordIndex].postings[target.postingIndex].account
                                },
                                set: { newAccount in
                                    guard records.indices.contains(target.recordIndex),
                                          records[target.recordIndex].postings.indices.contains(target.postingIndex) else { return }
                                    records[target.recordIndex].postings[target.postingIndex].account = newAccount
                                }
                            )
                        )
                    }
                }
            }
            .sheet(isPresented: $showDatePicker) {
                datePickerSheet
            }
            .sheet(isPresented: $showEditDetailsSheet) {
                editDetailsSheet
            }
        }
        .onChange(of: input) { _, _ in
            cancel()
            draft = nil
            records = []
        }
        .onChange(of: records.map(\.entry)) { before, after in
            draft?.proposals = BookkeepingPipeline.validProposals(draft?.proposals ?? [], before: before, after: after)
        }
        .onChange(of: session.phase) { _, phase in if phase != .ready { cancel() } }
        .onChange(of: settings.revision) { _, _ in cancel() }
        .onChange(of: classificationSettings.revision) { _, _ in cancel() }
        .onChange(of: session.privacyShielded) { _, shielded in if shielded { cancel() } }
        .onChange(of: session.currentLocalLedgerDescriptor?.id) { _, _ in cancel(); draft = nil; records = [] }
        .onDisappear { cancel() }
        .ledgerPrivacyProtectedSheet()
    }

    // MARK: - Unconfigured Notice Banner

    private var unconfiguredHeroBanner: some View {
        NavigationLink {
            BookkeepingSettingsView()
        } label: {
            HStack(spacing: LedgerSpacing.md) {
                ZStack {
                    Circle()
                        .fill(LedgerPalette.cobalt.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(LedgerPalette.cobalt)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("连接 AI 语义解析模型")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(LedgerPalette.ink)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    Text("支持一键接入 DeepSeek、OpenAI、Moonshot 或硅基流动")
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerPalette.secondary)
                }

                Spacer()
            }
            .padding(LedgerSpacing.md)
            .background(LedgerPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LedgerPalette.cobalt.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Modern AI Prompt Input Card

    private var aiInputCard: some View {
        VStack(spacing: 0) {
            // Text input area
            ZStack(alignment: .topLeading) {
                if input.isEmpty {
                    Text("输入日常口语，如：中午在美团外卖点餐 35 元，微信零钱支付。")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color(uiColor: .placeholderText))
                        .padding(.top, 10)
                        .padding(.leading, 6)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $input)
                    .frame(minHeight: records.isEmpty ? 88 : 64)
                    .font(.system(size: 15, weight: .regular))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .focused($inputFocused)
                    .accessibilityIdentifier("bookkeeping-natural-input")
            }
            .padding(.horizontal, LedgerSpacing.md)
            .padding(.top, LedgerSpacing.sm)

            Divider()
                .overlay(LedgerPalette.line.opacity(0.5))
                .padding(.horizontal, LedgerSpacing.md)
                .padding(.vertical, 4)

            // Bottom toolbar inside card
            HStack(spacing: LedgerSpacing.sm) {
                NavigationLink {
                    BookkeepingSettingsView()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LedgerPalette.cobalt)
                        Text(settings.configuration.model.isEmpty ? "语义解析设置" : settings.configuration.model)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if !input.isEmpty {
                    Button {
                        LedgerFeedback.light()
                        input = ""
                        draft = nil
                        records = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(LedgerPalette.secondary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                }

                // Parse / Send Button
                Button {
                    LedgerFeedback.light()
                    parse()
                } label: {
                    HStack(spacing: 5) {
                        if busy {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text("解析中…")
                                .font(.system(size: 13, weight: .semibold))
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                            Text(records.isEmpty ? "一键解析" : "重新解析")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        (busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !settings.canParse)
                        ? LedgerPalette.secondary.opacity(0.35)
                        : LedgerPalette.cobalt
                    )
                    .clipShape(Capsule())
                    .shadow(
                        color: (input.isEmpty || !settings.canParse) ? .clear : LedgerPalette.cobalt.opacity(0.28),
                        radius: 4, x: 0, y: 2
                    )
                }
                .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !settings.canParse)
                .accessibilityIdentifier("bookkeeping-parse")
            }
            .padding(.horizontal, LedgerSpacing.md)
            .padding(.bottom, LedgerSpacing.sm)
        }
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(inputFocused ? LedgerPalette.cobalt.opacity(0.5) : LedgerPalette.cardBorder, lineWidth: inputFocused ? 1.5 : 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
    }

    // MARK: - Inspiration Prompts Carousel

    private var inspirationSection: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            Text("快捷灵感示例")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
                .padding(.leading, 4)

            VStack(spacing: 8) {
                ForEach(examplePrompts) { prompt in
                    Button {
                        LedgerFeedback.light()
                        input = prompt.text
                        inputFocused = false
                    } label: {
                        HStack(spacing: LedgerSpacing.md) {
                            Text(prompt.emoji)
                                .font(.system(size: 22))
                                .frame(width: 36, height: 36)
                                .background(prompt.tint.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(prompt.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.ink)
                                Text(prompt.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(LedgerPalette.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.forward.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(prompt.tint.opacity(0.7))
                        }
                        .padding(12)
                        .background(LedgerPalette.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(LedgerPalette.cardBorder, lineWidth: 1)
                        )
                    }
                    .buttonStyle(PressScaleButtonStyle())
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Non-blocking AI Advice Pill

    private func aiNoticePill(_ questions: [String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.max.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LedgerPalette.gold)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("AI 提示")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LedgerPalette.gold)

                ForEach(Array(questions.prefix(2).enumerated()), id: \.offset) { _, q in
                    Text(q)
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerPalette.ink.opacity(0.85))
                }
            }
            Spacer()
        }
        .padding(10)
        .background(LedgerPalette.gold.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LedgerPalette.gold.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Result Section (Apple Wallet / Receipt Style Card)

    private var resultSection: some View {
        VStack(spacing: LedgerSpacing.md) {
            ForEach(Array(records.enumerated()), id: \.element.id) { recordIndex, record in
                transactionReceiptCard(record: binding(for: recordIndex), recordIndex: recordIndex)
            }
        }
    }

    private func transactionReceiptCard(record: Binding<Record>, recordIndex: Int) -> some View {
        let currentRecord = record.wrappedValue
        let mainAmount = heroAmount(for: currentRecord)
        let primaryCategory = currentRecord.postings.first(where: { !$0.account.hasPrefix("Assets:") && !$0.account.hasPrefix("Liabilities:") })?.account ?? ""
        let visual = TransactionVisualCategory.resolve(account: primaryCategory)

        return VStack(spacing: 0) {
            // Receipt Header: Category Icon + Merchant + Hero Amount
            HStack(alignment: .center, spacing: LedgerSpacing.md) {
                // Circular gradient category icon
                ZStack {
                    Circle()
                        .fill(visual.color.opacity(0.16))
                        .frame(width: 46, height: 46)
                    Image(systemName: visual.iconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(visual.color)
                }

                // Payee & Narration
                VStack(alignment: .leading, spacing: 3) {
                    let hasPayee = !currentRecord.payee.isEmpty
                    let titleText: String = {
                        if hasPayee { return currentRecord.payee }
                        if !currentRecord.narration.isEmpty { return currentRecord.narration }
                        return visual.categoryLabel.isEmpty ? "日常支出" : visual.categoryLabel
                    }()
                    let subtitleText: String = {
                        if hasPayee {
                            return currentRecord.narration.isEmpty ? (visual.categoryLabel.isEmpty ? "日常交易" : visual.categoryLabel) : currentRecord.narration
                        }
                        return visual.categoryLabel.isEmpty ? "未分类" : visual.categoryLabel
                    }()

                    Text(titleText)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(LedgerPalette.ink)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(subtitleText)
                            .font(.system(size: 13))
                            .foregroundStyle(LedgerPalette.secondary)
                            .lineLimit(1)

                        Button {
                            LedgerFeedback.light()
                            editingRecordIndex = recordIndex
                            showEditDetailsSheet = true
                        } label: {
                            Image(systemName: "pencil.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(LedgerPalette.cobalt)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("修改商户或备注")
                    }
                }

                Spacer()

                // Hero Amount Display
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(mainAmount.isNegative ? "-" : "+")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(mainAmount.isNegative ? LedgerPalette.expense : LedgerPalette.income)
                        Text(mainAmount.currencySymbol)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(mainAmount.isNegative ? LedgerPalette.expense : LedgerPalette.income)
                        Text(mainAmount.text)
                            .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(mainAmount.isNegative ? LedgerPalette.expense : LedgerPalette.income)
                    }

                    // Date Pill Button
                    Button {
                        LedgerFeedback.light()
                        editingDateIndex = recordIndex
                        showDatePicker = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "calendar")
                                .font(.system(size: 9))
                            Text(currentRecord.date)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(LedgerPalette.raised)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(LedgerSpacing.md)

            Divider()
                .overlay(LedgerPalette.line.opacity(0.6))

            // Postings Mapping Area
            if currentRecord.postings.count == 2 {
                twoPostingWorkflowView(record: record, recordIndex: recordIndex)
                    .padding(LedgerSpacing.md)
            } else {
                splitPostingsWorkflowView(record: record, recordIndex: recordIndex)
                    .padding(LedgerSpacing.md)
            }
        }
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(LedgerPalette.cardBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
    }

    // MARK: - 2-Posting Layout (Category ← Funding)

    private func twoPostingWorkflowView(record: Binding<Record>, recordIndex: Int) -> some View {
        VStack(spacing: LedgerSpacing.md) {
            // Category Posting
            accountSelectionBlock(
                title: "支出/收入分类",
                systemIcon: "tag.fill",
                iconColor: LedgerPalette.cobalt,
                record: record,
                recordIndex: recordIndex,
                postingIndex: 0,
                isFunding: false
            )

            // Subtle flow connector arrow
            HStack {
                Rectangle()
                    .fill(LedgerPalette.line.opacity(0.6))
                    .frame(height: 1)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .bold))
                    Text("资金流向")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(LedgerPalette.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(LedgerPalette.raised)
                .clipShape(Capsule())
                Rectangle()
                    .fill(LedgerPalette.line.opacity(0.6))
                    .frame(height: 1)
            }

            // Funding Posting
            accountSelectionBlock(
                title: "扣款/收款账户",
                systemIcon: "creditcard.fill",
                iconColor: LedgerPalette.olive,
                record: record,
                recordIndex: recordIndex,
                postingIndex: 1,
                isFunding: true
            )
        }
    }

    private func accountSelectionBlock(
        title: String,
        systemIcon: String,
        iconColor: Color,
        record: Binding<Record>,
        recordIndex: Int,
        postingIndex: Int,
        isFunding: Bool
    ) -> some View {
        let postingBinding = record.postings[postingIndex]
        let currentAccount = postingBinding.wrappedValue.account
        let allAccounts = session.ledger?.accounts ?? []
        let displayLabel = accountLabel(for: currentAccount, in: allAccounts)
        let visual = TransactionVisualCategory.resolve(account: currentAccount)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: systemIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(iconColor)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                }

                Spacer()

                // Current selected account badge & replacement picker
                Button {
                    LedgerFeedback.light()
                    openAccountPicker(
                        recordIndex: recordIndex,
                        postingIndex: postingIndex,
                        title: "选择\(title)",
                        isFunding: isFunding
                    )
                } label: {
                    HStack(spacing: 4) {
                        Text(currentAccount.isEmpty ? "未选择" : displayLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(currentAccount.isEmpty ? LedgerPalette.risk : LedgerPalette.ink)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(LedgerPalette.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            // Interactive Candidate Chips
            let candidates = candidateAccounts(for: recordIndex, postingIndex: postingIndex, isFunding: isFunding)
            if !candidates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(candidates, id: \.account) { candidate in
                            let isSelected = candidate.account == currentAccount
                            let candVisual = TransactionVisualCategory.resolve(account: candidate.account)

                            Button {
                                LedgerFeedback.selection()
                                postingBinding.wrappedValue.account = candidate.account
                            } label: {
                                HStack(spacing: 4) {
                                    if isFunding {
                                        Image(systemName: "creditcard")
                                            .font(.system(size: 10))
                                    } else {
                                        Image(systemName: candVisual.iconName)
                                            .font(.system(size: 10))
                                    }
                                    Text(candidate.displayLabel)
                                        .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 8, weight: .bold))
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(isSelected ? LedgerPalette.cobalt : LedgerPalette.raised)
                                .foregroundStyle(isSelected ? .white : LedgerPalette.ink)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(isSelected ? LedgerPalette.cobalt : LedgerPalette.cardBorder, lineWidth: 1)
                                )
                            }
                            .buttonStyle(PressScaleButtonStyle())
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    // MARK: - Split Postings Workflow View (3+ legs)

    private func splitPostingsWorkflowView(record: Binding<Record>, recordIndex: Int) -> some View {
        VStack(spacing: LedgerSpacing.sm) {
            ForEach(Array(record.wrappedValue.postings.enumerated()), id: \.element.id) { postingIndex, posting in
                let postingBinding = record.postings[postingIndex]
                let allAccounts = session.ledger?.accounts ?? []
                let isNegative = posting.amount.hasPrefix("-")
                let visual = TransactionVisualCategory.resolve(account: posting.account)
                let displayLabel = accountLabel(for: posting.account, in: allAccounts)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: LedgerSpacing.sm) {
                        Text(isNegative ? "出" : "入")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isNegative ? LedgerPalette.expense : LedgerPalette.income)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background((isNegative ? LedgerPalette.expense : LedgerPalette.income).opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Image(systemName: visual.iconName)
                            .font(.system(size: 12))
                            .foregroundStyle(visual.color)

                        Button {
                            LedgerFeedback.light()
                            openAccountPicker(
                                recordIndex: recordIndex,
                                postingIndex: postingIndex,
                                title: "选择分录账户",
                                isFunding: isNegative
                            )
                        } label: {
                            HStack(spacing: 2) {
                                Text(posting.account.isEmpty ? "选择账户" : displayLabel)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(posting.account.isEmpty ? LedgerPalette.risk : LedgerPalette.ink)
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        TextField("金额", text: postingBinding.amount)
                            .keyboardType(.numbersAndPunctuation)
                            .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)

                        Text(posting.currency)
                            .font(.system(size: 11, weight: .medium).monospaced())
                            .foregroundStyle(LedgerPalette.secondary)

                        if record.wrappedValue.postings.count > 2 {
                            Button(role: .destructive) {
                                LedgerFeedback.light()
                                record.wrappedValue.postings.remove(at: postingIndex)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(LedgerPalette.risk.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Candidate chips for split leg
                    let candidates = candidateAccounts(for: recordIndex, postingIndex: postingIndex, isFunding: isNegative)
                    if !candidates.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(candidates, id: \.account) { candidate in
                                    let isSelected = candidate.account == posting.account
                                    Button {
                                        LedgerFeedback.selection()
                                        postingBinding.wrappedValue.account = candidate.account
                                    } label: {
                                        Text(candidate.displayLabel)
                                            .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(isSelected ? LedgerPalette.cobalt : LedgerPalette.raised)
                                            .foregroundStyle(isSelected ? .white : LedgerPalette.ink)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(PressScaleButtonStyle())
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .background(LedgerPalette.raised.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Button {
                LedgerFeedback.light()
                record.wrappedValue.postings.append(.init(
                    account: "",
                    amount: "",
                    currency: session.ledger?.valuationCurrency ?? "CNY"
                ))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                    Text("添加分录")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
            }
        }
    }

    // MARK: - Floating Pinned Action Bar

    private var floatingActionBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(LedgerPalette.success)
                Text("Beancount 复式借贷平衡已通过校验")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
            }

            Button {
                LedgerFeedback.light()
                prepare()
            } label: {
                HStack(spacing: 8) {
                    if busy {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("正在校验与写入…")
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("确认并生成预览")
                    }
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(canPrepare ? LedgerPalette.cobalt : LedgerPalette.secondary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: canPrepare ? LedgerPalette.cobalt.opacity(0.3) : .clear, radius: 6, x: 0, y: 3)
            }
            .disabled(busy || !canPrepare)
            .accessibilityIdentifier("bookkeeping-prepare")
        }
        .padding(.horizontal, LedgerSpacing.lg)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
            LedgerPalette.canvas
                .opacity(0.96)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
        )
        .overlay(alignment: .top) {
            Divider().overlay(LedgerPalette.line.opacity(0.6))
        }
    }

    private var canPrepare: Bool {
        !records.isEmpty && records.allSatisfy { record in
            record.postings.count >= 2 &&
            record.postings.allSatisfy { !$0.account.isEmpty && !$0.amount.isEmpty }
        }
    }

    // MARK: - Date Picker Sheet

    private var datePickerSheet: some View {
        NavigationStack {
            VStack {
                DatePicker(
                    "交易日期",
                    selection: Binding(
                        get: {
                            guard records.indices.contains(editingDateIndex) else { return Date() }
                            return Self.parseDate(records[editingDateIndex].date) ?? Date()
                        },
                        set: { newDate in
                            guard records.indices.contains(editingDateIndex) else { return }
                            records[editingDateIndex].date = Self.formatDate(newDate)
                        }
                    ),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding()
            }
            .navigationTitle("调整日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showDatePicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Edit Details Sheet (Payee & Narration)

    private var editDetailsSheet: some View {
        NavigationStack {
            Form {
                if records.indices.contains(editingRecordIndex) {
                    Section("商户与用途") {
                        TextField("商户 / 交易对方（选填）", text: $records[editingRecordIndex].payee)
                        TextField("说明 / 备注", text: $records[editingRecordIndex].narration)
                    }
                }
            }
            .navigationTitle("修改交易信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showEditDetailsSheet = false }
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    // MARK: - Account Helpers & Matching

    private func binding(for recordIndex: Int) -> Binding<Record> {
        Binding(
            get: { records[recordIndex] },
            set: { records[recordIndex] = $0 }
        )
    }

    private func heroAmount(for record: Record) -> (currencySymbol: String, text: String, isNegative: Bool) {
        let currency = record.postings.first?.currency ?? "CNY"
        let symbol = CookieFastTransactionEditorBody.currencySymbol(for: currency)
        if let expensePosting = record.postings.first(where: { !$0.amount.hasPrefix("-") && !$0.amount.isEmpty }) {
            return (symbol, expensePosting.amount, true)
        }
        if let firstPosting = record.postings.first(where: { !$0.amount.isEmpty }) {
            let clean = firstPosting.amount.replacingOccurrences(of: "-", with: "")
            return (symbol, clean, true)
        }
        return (symbol, "0.00", false)
    }

    private func accountLabel(for account: String, in accounts: [LedgerAccount]) -> String {
        accounts.first(where: { $0.account == account })?.displayLabel
            ?? account.components(separatedBy: ":").last
            ?? account
    }

    private func candidateAccounts(for recordIndex: Int, postingIndex: Int, isFunding: Bool) -> [LedgerAccount] {
        let allAccounts = session.ledger?.accounts ?? []
        var candidates: [LedgerAccount] = []

        // 1. Proposals from Jev / classifier
        if let proposal = draft?.proposals.first(where: { $0.recordIndex == recordIndex && $0.postingIndex == postingIndex }) {
            for c in proposal.decision.candidates {
                if let match = allAccounts.first(where: { $0.account == c.value }) {
                    candidates.append(match)
                }
            }
        }

        // 2. Siblings / context candidates
        let currentAccount = (records.indices.contains(recordIndex) && records[recordIndex].postings.indices.contains(postingIndex))
            ? records[recordIndex].postings[postingIndex].account : ""

        let derived = isFunding
            ? BookkeepingAccountMatcher.fundingCandidates(selected: currentAccount, accounts: allAccounts)
            : BookkeepingAccountMatcher.categoryCandidates(selected: currentAccount, accounts: allAccounts)

        for item in derived where !candidates.contains(where: { $0.account == item.account }) {
            candidates.append(item)
            if candidates.count >= 5 { break }
        }

        return Array(candidates.prefix(5))
    }

    private func openAccountPicker(recordIndex: Int, postingIndex: Int, title: String, isFunding: Bool) {
        let all = session.ledger?.accounts.filter(\.active) ?? []
        let filtered = all.filter { acc in
            if isFunding {
                return acc.account.hasPrefix("Assets:") || acc.account.hasPrefix("Liabilities:")
            } else {
                return acc.account.hasPrefix("Expenses:") || acc.account.hasPrefix("Income:")
            }
        }
        let list = filtered.isEmpty ? all : filtered
        accountPickerTarget = (
            recordIndex: recordIndex,
            postingIndex: postingIndex,
            title: title,
            accounts: list.map { LedgerAccountChoice(account: $0.account, label: $0.displayLabel, group: $0.group, active: $0.active) }
        )
    }

    // MARK: - Core Execution Pipeline

    private func cancel() {
        operation?.cancel()
        operation = nil
        runID = UUID()
        busy = false
    }

    private func parse() {
        inputFocused = false
        cancel()
        guard session.phase == .ready, !session.privacyShielded,
              let ledgerID = session.currentLocalLedgerDescriptor?.id else { return }
        let id = UUID()
        runID = id
        busy = true
        error = nil
        let text = input, settingsRevision = settings.revision
        let classificationRevision = classificationSettings.revision
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let request = BookkeepingParseInput(
            text: text,
            referenceDate: formatter.string(from: Date()),
            timeZone: TimeZone.current.identifier,
            accounts: session.ledger?.accounts ?? [],
            currency: session.ledger?.valuationCurrency ?? "CNY"
        )
        operation = Task { @MainActor in
            defer { if runID == id { busy = false } }
            do {
                let parser = try settings.parser()
                var result = try await parser.parse(request)
                try Task.checkCancellation()
                guard runID == id, input == text, settings.revision == settingsRevision,
                      session.currentLocalLedgerDescriptor?.id == ledgerID,
                      session.phase == .ready, !session.privacyShielded else { return }

                // Automatically run Jev account classification if enabled
                if classificationSettings.isEnabled(for: ledgerID) {
                    if let classifier = try? classificationSettings.classifier() {
                        do {
                            result = try await BookkeepingPipeline.enrich(
                                result,
                                accounts: session.ledger?.accounts ?? [],
                                relatedHistory: { record in
                                    let rows = try await session.bookkeepingHistory(for: record)
                                    guard await MainActor.run(body: {
                                        runID == id && input == text && settings.revision == settingsRevision
                                            && classificationSettings.revision == classificationRevision
                                            && classificationSettings.isEnabled(for: ledgerID)
                                            && session.currentLocalLedgerDescriptor?.id == ledgerID
                                            && session.phase == .ready && !session.privacyShielded
                                    }) else { throw CancellationError() }
                                    return rows
                                },
                                provider: classifier
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // Optional enrichment failure leaves the parsed draft for manual review.
                        }
                    }
                }

                try Task.checkCancellation()
                guard runID == id, input == text, settings.revision == settingsRevision,
                      classificationSettings.revision == classificationRevision,
                      session.currentLocalLedgerDescriptor?.id == ledgerID,
                      session.phase == .ready, !session.privacyShielded else { return }

                // Auto-fill proposals directly into records
                var finalRecords = result.records.map(Record.init)
                for proposal in result.proposals {
                    let r = proposal.recordIndex, p = proposal.postingIndex
                    if finalRecords.indices.contains(r), finalRecords[r].postings.indices.contains(p) {
                        if finalRecords[r].postings[p].account.isEmpty && proposal.decision.value != "review" {
                            finalRecords[r].postings[p].account = proposal.decision.value
                        }
                    }
                }

                // If any accounts are still empty, use heuristic keyword matching
                let ledgerAccounts = session.ledger?.accounts ?? []
                for r in finalRecords.indices {
                    for p in finalRecords[r].postings.indices {
                        if finalRecords[r].postings[p].account.isEmpty {
                            let role = (result.accountRoles.indices.contains(r) && result.accountRoles[r].indices.contains(p))
                                ? result.accountRoles[r][p] : (finalRecords[r].postings[p].amount.hasPrefix("-") ? "funding" : "expense")
                            let matched = BookkeepingAccountMatcher.match(
                                role: role,
                                text: "\(text) \(finalRecords[r].payee) \(finalRecords[r].narration)",
                                accounts: ledgerAccounts
                            )
                            if let matched {
                                finalRecords[r].postings[p].account = matched
                            }
                        }
                    }
                }

                // If all accounts are populated, clear any generic questions
                let allFilled = finalRecords.allSatisfy { $0.postings.allSatisfy { !$0.account.isEmpty } }
                if allFilled {
                    result.questions = result.questions.filter { !$0.contains("选择账户") }
                }

                draft = result
                records = finalRecords

                if result.records.isEmpty {
                    error = "请补充交易日期、金额、币种和用途，再重新解析。"
                }
            } catch is CancellationError {
            } catch {
                if runID == id { self.error = error.localizedDescription }
            }
        }
    }

    private func prepare() {
        guard var next = draft, let repository = session.localRepository,
              session.phase == .ready, !session.privacyShielded else { return }
        next.records = records.map(\.entry)
        next.revision = UUID()
        next.questions = []
        guard next.records.allSatisfy({ $0.postings.allSatisfy { !$0.amount.isEmpty && !$0.account.isEmpty } }) else {
            error = "请补充每条分录的账户和金额。"
            return
        }
        busy = true
        error = nil
        let id = UUID()
        runID = id
        let preparedDraft = next
        operation = Task { @MainActor in
            defer { if runID == id { busy = false } }
            do {
                let result = try await repository.prepareBookkeeping(preparedDraft)
                try Task.checkCancellation()
                guard runID == id, session.currentLocalLedgerDescriptor?.id == repository.descriptor.id,
                      session.phase == .ready, !session.privacyShielded else {
                    await repository.discardPrepared(result)
                    return
                }
                preview = result
            } catch is CancellationError {
            } catch {
                if runID == id { self.error = error.localizedDescription }
            }
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
