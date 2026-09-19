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

    // Account picker sheet state
    @State private var accountPickerTarget: (recordIndex: Int, postingIndex: Int, title: String, accounts: [LedgerAccountChoice])?
    @State private var showDatePicker = false
    @State private var editingDateIndex = 0

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
        let label: String
        let icon: String
        let text: String
    }

    private let examplePrompts: [ExamplePrompt] = [
        .init(label: "餐饮外卖", icon: "fork.knife", text: "中午在美团外卖点餐 35 元，微信零钱支付。"),
        .init(label: "地铁出行", icon: "tram", text: "今早乘坐地铁 7 元，支付宝花呗扣款。"),
        .init(label: "买书垫付", icon: "book.closed", text: "昨天用招行信用卡买书 128 元，其中 48 元替同事垫付。"),
        .init(label: "聚餐分摊", icon: "person.2", text: "昨晚和朋友吃火锅微信支付 240 元，收到转账 120 元。"),
        .init(label: "信用卡还款", icon: "creditcard", text: "从工行储蓄卡转账 3000 元还招商银行信用卡。")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: LedgerSpacing.md) {
                    if !settings.canParse {
                        unconfiguredNoticeSection
                    }

                    inputSection

                    if let error {
                        StatusBanner(message: error) { self.error = nil }
                    }

                    if let draft, !draft.questions.isEmpty {
                        aiQuestionsBanner(draft.questions)
                    }

                    if !records.isEmpty {
                        resultSection
                        actionsSection
                    }
                }
                .padding(.horizontal, LedgerSpacing.md)
                .padding(.vertical, LedgerSpacing.sm)
            }
            .background(LedgerPalette.canvas.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
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

    // MARK: - Input Section

    private var unconfiguredNoticeSection: some View {
        HStack(spacing: LedgerSpacing.sm) {
            Image(systemName: "sparkles")
                .foregroundStyle(LedgerPalette.gold)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("尚未配置语义解析模型")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LedgerPalette.ink)
                Text("支持连接 DeepSeek、OpenAI、Moonshot 等兼容大模型进行本地自然语言记账。")
                    .font(.caption)
                    .foregroundStyle(LedgerPalette.secondary)
            }
            Spacer()
            NavigationLink("前往配置") {
                BookkeepingSettingsView()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(LedgerPalette.cobalt)
        }
        .padding(LedgerSpacing.md)
        .background(LedgerPalette.raised)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LedgerPalette.gold.opacity(0.3), lineWidth: 1)
        )
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            ZStack(alignment: .topLeading) {
                if input.isEmpty {
                    Text("例如：中午在美团外卖点餐 35 元，微信零钱支付。")
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: .placeholderText))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $input)
                    .frame(minHeight: 72)
                    .focused($inputFocused)
                    .accessibilityIdentifier("bookkeeping-natural-input")
            }
            .padding(6)
            .background(LedgerPalette.raised)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(LedgerPalette.line, lineWidth: 1)
            )

            // Example prompt chips
            if records.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LedgerSpacing.xs) {
                        ForEach(examplePrompts) { prompt in
                            Button {
                                LedgerFeedback.light()
                                input = prompt.text
                                inputFocused = false
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: prompt.icon)
                                        .font(.caption2)
                                    Text(prompt.label)
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, LedgerSpacing.sm)
                                .padding(.vertical, 5)
                                .background(LedgerPalette.raised)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(LedgerPalette.cardBorder, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            HStack {
                NavigationLink {
                    BookkeepingSettingsView()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                            .font(.caption)
                        Text("语义解析设置")
                            .font(.caption)
                    }
                    .foregroundStyle(LedgerPalette.secondary)
                }

                Spacer()

                if !input.isEmpty {
                    Button {
                        LedgerFeedback.light()
                        input = ""
                        draft = nil
                        records = []
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark.circle.fill")
                            Text("清空")
                        }
                        .font(.caption)
                        .foregroundStyle(LedgerPalette.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                LedgerFeedback.light()
                parse()
            } label: {
                HStack(spacing: 6) {
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("正在解析并推断账户…")
                    } else {
                        Image(systemName: "sparkles")
                        Text(records.isEmpty ? "发送并解析" : "重新解析")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .background(
                    (busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !settings.canParse)
                    ? LedgerPalette.secondary.opacity(0.4)
                    : LedgerPalette.cobalt
                )
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !settings.canParse)
            .accessibilityIdentifier("bookkeeping-parse")
        }
        .padding(LedgerSpacing.md)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LedgerPalette.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - AI Questions Non-blocking Banner

    private func aiQuestionsBanner(_ questions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(LedgerPalette.gold)
                    .font(.caption)
                Text("AI 提示与核对建议")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LedgerPalette.ink)
            }
            ForEach(Array(questions.prefix(3).enumerated()), id: \.offset) { _, q in
                Text("• \(q)")
                    .font(.caption2)
                    .foregroundStyle(LedgerPalette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LedgerSpacing.sm)
        .background(LedgerPalette.gold.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(LedgerPalette.gold.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Result Section (Unified Result-First Card)

    private var resultSection: some View {
        VStack(spacing: LedgerSpacing.md) {
            ForEach(Array(records.enumerated()), id: \.element.id) { recordIndex, record in
                transactionCard(record: binding(for: recordIndex), recordIndex: recordIndex)
            }
        }
    }

    private func transactionCard(record: Binding<Record>, recordIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.md) {
            // Header: Amount + Date Badge
            HStack(alignment: .firstTextBaseline) {
                let mainAmount = heroAmount(for: record.wrappedValue)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(mainAmount.currencySymbol)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(mainAmount.isNegative ? LedgerPalette.expense : LedgerPalette.income)
                    Text(mainAmount.text)
                        .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(mainAmount.isNegative ? LedgerPalette.expense : LedgerPalette.income)
                }

                Spacer()

                Button {
                    LedgerFeedback.light()
                    editingDateIndex = recordIndex
                    showDatePicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                        Text(record.wrappedValue.date)
                            .font(.caption.weight(.semibold).monospacedDigit())
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(LedgerPalette.raised)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(LedgerPalette.cardBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            // Payee & Narration Inputs
            HStack(spacing: LedgerSpacing.sm) {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(LedgerPalette.secondary)
                        .font(.caption)
                    TextField("交易对方", text: record.payee)
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(LedgerPalette.raised)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 4) {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(LedgerPalette.secondary)
                        .font(.caption)
                    TextField("说明/摘要", text: record.narration)
                        .font(.subheadline)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(LedgerPalette.raised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Divider().overlay(LedgerPalette.line)

            // Postings / Account Mappings
            if record.wrappedValue.postings.count == 2 {
                // 2-posting flow: Category (Posting 0) & Funding (Posting 1)
                standardTwoPostingView(record: record, recordIndex: recordIndex)
            } else {
                // Split posting flow (3+ legs)
                splitPostingsListView(record: record, recordIndex: recordIndex)
            }
        }
        .padding(LedgerSpacing.md)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LedgerPalette.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - 2-Posting Layout (Result-First Category & Funding)

    private func standardTwoPostingView(record: Binding<Record>, recordIndex: Int) -> some View {
        VStack(spacing: LedgerSpacing.sm) {
            // Posting 0: Category (Expense / Income)
            postingCardRow(
                record: record,
                recordIndex: recordIndex,
                postingIndex: 0,
                roleTitle: "分类",
                isFundingRole: false
            )

            // Posting 1: Funding / Payment
            postingCardRow(
                record: record,
                recordIndex: recordIndex,
                postingIndex: 1,
                roleTitle: "账户",
                isFundingRole: true
            )
        }
    }

    private func postingCardRow(
        record: Binding<Record>,
        recordIndex: Int,
        postingIndex: Int,
        roleTitle: String,
        isFundingRole: Bool
    ) -> some View {
        let postingBinding = record.postings[postingIndex]
        let currentAccount = postingBinding.wrappedValue.account
        let allAccounts = session.ledger?.accounts ?? []
        let currentVisual = TransactionVisualCategory.resolve(account: currentAccount)
        let displayLabel = accountLabel(for: currentAccount, in: allAccounts)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: LedgerSpacing.sm) {
                // Role badge
                Text(roleTitle)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isFundingRole ? LedgerPalette.olive : LedgerPalette.cobalt)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((isFundingRole ? LedgerPalette.olive : LedgerPalette.cobalt).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                // Account label & icon
                HStack(spacing: 5) {
                    Image(systemName: isFundingRole ? "creditcard.fill" : currentVisual.iconName)
                        .font(.caption)
                        .foregroundStyle(isFundingRole ? LedgerPalette.olive : currentVisual.color)

                    Text(currentAccount.isEmpty ? "请选择账户" : displayLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(currentAccount.isEmpty ? LedgerPalette.risk : LedgerPalette.ink)
                        .lineLimit(1)

                    if !currentAccount.isEmpty {
                        Text(currentAccount)
                            .font(.caption2.monospaced())
                            .foregroundStyle(LedgerPalette.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Replace / pick from full list button
                Button {
                    LedgerFeedback.light()
                    openAccountPicker(
                        recordIndex: recordIndex,
                        postingIndex: postingIndex,
                        title: "选择\(roleTitle)",
                        isFunding: isFundingRole
                    )
                } label: {
                    HStack(spacing: 2) {
                        Text("更换")
                            .font(.caption.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(LedgerPalette.cobalt)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(LedgerPalette.cobalt.opacity(0.08))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // Candidate suggestion chips
            let candidates = candidateAccounts(for: recordIndex, postingIndex: postingIndex, isFunding: isFundingRole)
            if !candidates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LedgerSpacing.xs) {
                        ForEach(candidates, id: \.account) { candidate in
                            let isSelected = candidate.account == currentAccount
                            let visual = TransactionVisualCategory.resolve(account: candidate.account)
                            Button {
                                LedgerFeedback.selection()
                                postingBinding.wrappedValue.account = candidate.account
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: isFundingRole ? "creditcard" : visual.iconName)
                                        .font(.caption2)
                                    Text(candidate.displayLabel)
                                        .font(.caption.weight(isSelected ? .semibold : .regular))
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 8, weight: .bold))
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isSelected ? LedgerPalette.cobalt.opacity(0.14) : LedgerPalette.raised)
                                .foregroundStyle(isSelected ? LedgerPalette.cobalt : LedgerPalette.ink)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(isSelected ? LedgerPalette.cobalt : LedgerPalette.cardBorder, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(8)
        .background(LedgerPalette.raised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Split Postings List View (3+ legs)

    private func splitPostingsListView(record: Binding<Record>, recordIndex: Int) -> some View {
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
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(isNegative ? LedgerPalette.expense : LedgerPalette.income)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background((isNegative ? LedgerPalette.expense : LedgerPalette.income).opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        HStack(spacing: 4) {
                            Image(systemName: visual.iconName)
                                .font(.caption2)
                                .foregroundStyle(visual.color)
                            Text(posting.account.isEmpty ? "请选择账户" : displayLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(posting.account.isEmpty ? LedgerPalette.risk : LedgerPalette.ink)
                                .lineLimit(1)
                        }

                        Spacer()

                        TextField("金额", text: postingBinding.amount)
                            .keyboardType(.numbersAndPunctuation)
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)

                        Text(posting.currency)
                            .font(.caption.monospaced())
                            .foregroundStyle(LedgerPalette.secondary)

                        Button {
                            LedgerFeedback.light()
                            openAccountPicker(
                                recordIndex: recordIndex,
                                postingIndex: postingIndex,
                                title: "选择分录账户",
                                isFunding: isNegative
                            )
                        } label: {
                            Image(systemName: "chevron.down.circle")
                                .font(.caption)
                                .foregroundStyle(LedgerPalette.cobalt)
                        }
                        .buttonStyle(.plain)

                        if record.wrappedValue.postings.count > 2 {
                            Button(role: .destructive) {
                                LedgerFeedback.light()
                                record.wrappedValue.postings.remove(at: postingIndex)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption2)
                                    .foregroundStyle(LedgerPalette.risk.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Candidate chips for this leg
                    let candidates = candidateAccounts(for: recordIndex, postingIndex: postingIndex, isFunding: isNegative)
                    if !candidates.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: LedgerSpacing.xs) {
                                ForEach(candidates, id: \.account) { candidate in
                                    let isSelected = candidate.account == posting.account
                                    Button {
                                        LedgerFeedback.selection()
                                        postingBinding.wrappedValue.account = candidate.account
                                    } label: {
                                        Text(candidate.displayLabel)
                                            .font(.caption2.weight(isSelected ? .semibold : .regular))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(isSelected ? LedgerPalette.cobalt.opacity(0.14) : LedgerPalette.raised)
                                            .foregroundStyle(isSelected ? LedgerPalette.cobalt : LedgerPalette.ink)
                                            .clipShape(Capsule())
                                            .overlay(
                                                Capsule().stroke(isSelected ? LedgerPalette.cobalt : LedgerPalette.cardBorder, lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .background(LedgerPalette.raised.opacity(0.5))
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
                Label("添加分录", systemImage: "plus.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LedgerPalette.cobalt)
            }
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: LedgerSpacing.sm) {
            Button {
                LedgerFeedback.light()
                prepare()
            } label: {
                HStack(spacing: 8) {
                    if busy {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("正在校验完整账本…")
                    } else {
                        Image(systemName: "checkmark.shield.fill")
                        Text("确认并生成预览")
                    }
                }
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(canPrepare ? LedgerPalette.cobalt : LedgerPalette.secondary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(busy || !canPrepare)
            .accessibilityIdentifier("bookkeeping-prepare")

            Text("本地 Beancount 引擎将自动校验复式平衡与语法规范。")
                .font(.caption2)
                .foregroundStyle(LedgerPalette.secondary)
        }
        .padding(.top, LedgerSpacing.xs)
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
        // Find first positive or primary expense amount
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

                // Automatically run Jev account classification if enabled!
                if classificationSettings.isEnabled(for: ledgerID) {
                    if let classifier = try? classificationSettings.classifier() {
                        try? await session.loadGlobalTransactions(forceRefresh: false)
                        if let enriched = try? await BookkeepingPipeline.enrich(
                            result,
                            accounts: session.ledger?.accounts ?? [],
                            history: session.visibleGlobalTransactions,
                            provider: classifier
                        ) {
                            result = enriched
                        }
                    }
                }

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

                // If any accounts are still empty, use heuristic keyword matching!
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
        // Auto-clear questions since user confirmed fields
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
