import SwiftUI

struct NaturalLanguageBookkeepingView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = BookkeepingSettings.shared
    @ObservedObject private var classificationSettings = ImportClassificationSettings.shared
    @State private var input = ""
    @State private var draft: BookkeepingDraft?
    @State private var records: [Record] = []
    @State private var reviewedQuestions = false
    @State private var busy = false
    @State private var error: String?
    @State private var preview: PreparedBookkeepingChange?
    @State private var operation: Task<Void, Never>?
    @State private var runID = UUID()
    @FocusState private var inputFocused: Bool

    private struct Record: Identifiable {
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
        .init(label: "买书垫付", icon: "book.closed", text: "昨天用招行信用卡买书 128 元，其中 48 元替同事垫付。"),
        .init(label: "餐饮外卖", icon: "fork.knife", text: "中午在美团外卖点餐 35 元，微信零钱支付。"),
        .init(label: "聚餐分摊", icon: "person.2", text: "昨晚和朋友吃火锅微信支付 240 元，收到转账 120 元。"),
        .init(label: "地铁出行", icon: "tram", text: "今早乘坐地铁 7 元，支付宝花呗扣款。"),
        .init(label: "信用卡还款", icon: "creditcard", text: "从工行储蓄卡转账 3000 元还招商银行信用卡。")
    ]

    var body: some View {
        NavigationStack {
            Form {
                if !settings.canParse {
                    unconfiguredNoticeSection
                }

                inputSection

                if let error {
                    Section {
                        StatusBanner(message: error) { self.error = nil }
                    }
                }

                if let draft, !draft.questions.isEmpty {
                    questionsSection(draft)
                }

                ForEach($records) { $record in
                    recordSection($record)
                }

                if !records.isEmpty {
                    actionsSection
                }
            }
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
        }
        .sheet(item: $preview) { prepared in
            BookkeepingPreviewView(preview: prepared) { _ in dismiss() }
        }
        .onChange(of: input) { _, _ in
            cancel()
            draft = nil
            records = []
            reviewedQuestions = false
        }
        .onChange(of: records.map(\.entry)) { before, after in
            draft?.proposals = BookkeepingPipeline.validProposals(draft?.proposals ?? [], before: before, after: after)
            reviewedQuestions = false
        }
        .onChange(of: session.phase) { _, phase in if phase != .ready { cancel() } }
        .onChange(of: settings.revision) { _, _ in cancel() }
        .onChange(of: classificationSettings.revision) { _, _ in cancel() }
        .onChange(of: session.privacyShielded) { _, shielded in if shielded { cancel() } }
        .onChange(of: session.currentLocalLedgerDescriptor?.id) { _, _ in cancel(); draft = nil; records = [] }
        .onDisappear { cancel() }
        .ledgerPrivacyProtectedSheet()
    }

    // MARK: - Sections

    private var unconfiguredNoticeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
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
                }
                NavigationLink("前往配置语义解析") {
                    BookkeepingSettingsView()
                }
                .font(.footnote.weight(.medium))
            }
            .padding(.vertical, LedgerSpacing.xs)
        }
    }

    private var inputSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if input.isEmpty {
                    Text("例如：昨天用招行信用卡买书 128 元，其中 48 元替同事垫付。")
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: .placeholderText))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $input)
                    .frame(minHeight: 100)
                    .focused($inputFocused)
                    .accessibilityIdentifier("bookkeeping-natural-input")
            }

            // Quick Example Prompt Chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LedgerSpacing.sm) {
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
                            .background(LedgerPalette.canvas)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(LedgerPalette.cardBorder, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
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
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(LedgerPalette.secondary)
                            .font(.caption)
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
                        Text("AI 正在解析…")
                    } else {
                        Image(systemName: "sparkles")
                        Text("发送并解析")
                    }
                }
                .frame(maxWidth: .infinity)
                .font(.headline.weight(.medium))
            }
            .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !settings.canParse)
            .accessibilityIdentifier("bookkeeping-parse")

            if busy {
                Button("停止解析", role: .cancel) {
                    cancel()
                }
                .frame(maxWidth: .infinity)
                .font(.caption)
            }
        } header: {
            Text("描述交易")
        } footer: {
            Text("由 \(settings.configuration.baseURL.isEmpty ? "未配置接口" : settings.configuration.baseURL) 解析为结构化草稿。包含文字、参考日期、时区与账户列表；结果将在本机由 Beancount 校验后保存。")
                .font(.caption2)
        }
    }

    private func questionsSection(_ draft: BookkeepingDraft) -> some View {
        Section {
            VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
                HStack(spacing: LedgerSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(LedgerPalette.gold)
                    Text("需要补充或核对")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LedgerPalette.gold)
                }
                ForEach(Array(draft.questions.enumerated()), id: \.offset) { _, question in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(LedgerPalette.secondary)
                        Text(question)
                            .font(.footnote)
                            .foregroundStyle(LedgerPalette.ink)
                    }
                }
            }
            .padding(.vertical, 2)

            Toggle("已根据提示补全并核对", isOn: $reviewedQuestions)
                .font(.subheadline)
        } header: {
            Text("解析提示")
        }
    }

    private func recordSection(_ record: Binding<Record>) -> some View {
        Section {
            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(LedgerPalette.secondary)
                    .frame(width: 20)
                TextField("日期 YYYY-MM-DD", text: record.date)
                    .keyboardType(.numbersAndPunctuation)
            }
            HStack {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(LedgerPalette.secondary)
                    .frame(width: 20)
                TextField("交易对方", text: record.payee)
            }
            HStack {
                Image(systemName: "text.bubble")
                    .foregroundStyle(LedgerPalette.secondary)
                    .frame(width: 20)
                TextField("说明", text: record.narration)
            }

            ForEach(record.postings) { posting in
                postingCard(posting: posting, record: record)
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
                    .font(.subheadline)
            }

            if records.count > 1 {
                Button(role: .destructive) {
                    LedgerFeedback.light()
                    let id = record.wrappedValue.id
                    records.removeAll { $0.id == id }
                } label: {
                    Label("移除这笔交易", systemImage: "trash")
                        .font(.subheadline)
                }
            }
        } header: {
            Text("交易草稿")
        }
        .disabled(busy)
    }

    private func postingCard(posting: Binding<EditableTransactionPosting>, record: Binding<Record>) -> some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
            HStack {
                Picker("账户", selection: posting.account) {
                    Text("选择账户").tag("")
                    ForEach(session.ledger?.accounts ?? [], id: \.account) { account in
                        Text(account.displayLabel).tag(account.account)
                    }
                }
                .pickerStyle(.menu)

                Spacer()

                Button(role: .destructive) {
                    LedgerFeedback.light()
                    let id = posting.wrappedValue.id
                    record.wrappedValue.postings.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(LedgerPalette.risk.opacity(0.8))
                }
                .buttonStyle(.plain)
            }

            if posting.wrappedValue.account.isEmpty,
               let recordIndex = records.firstIndex(where: { $0.id == record.wrappedValue.id }),
               let postingIndex = record.wrappedValue.postings.firstIndex(where: { $0.id == posting.wrappedValue.id }),
               let proposal = draft?.proposals.first(where: { $0.recordIndex == recordIndex && $0.postingIndex == postingIndex }) {
                HStack(spacing: LedgerSpacing.xs) {
                    ForEach(proposal.decision.candidates, id: \.value) { candidate in
                        Button {
                            LedgerFeedback.selection()
                            posting.wrappedValue.account = candidate.value
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "sparkles")
                                    .font(.caption2)
                                Text("建议：\(candidate.value)")
                                    .font(.caption2.weight(.medium))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(LedgerPalette.cobalt.opacity(0.12))
                            .foregroundStyle(LedgerPalette.cobalt)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if proposal.decision.value == "review" {
                    Text("证据不足，请手动确认账户。")
                        .font(.caption2)
                        .foregroundStyle(LedgerPalette.gold)
                }
            }

            HStack(spacing: LedgerSpacing.sm) {
                HStack(spacing: 4) {
                    let isNegative = posting.wrappedValue.amount.hasPrefix("-")
                    Text(isNegative ? "出" : "入")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isNegative ? LedgerPalette.expense : LedgerPalette.income)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background((isNegative ? LedgerPalette.expense : LedgerPalette.income).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    TextField("金额（支出正数/扣款负数）", text: posting.amount)
                        .keyboardType(.numbersAndPunctuation)
                        .font(.subheadline.monospacedDigit())
                }

                TextField("币种", text: posting.currency)
                    .frame(width: 54)
                    .textInputAutocapitalization(.characters)
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.center)
                    .background(LedgerPalette.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 4)
    }

    private var actionsSection: some View {
        Section {
            if let ledgerID = session.currentLocalLedgerDescriptor?.id {
                NavigationLink {
                    ImportClassificationSettingsView(ledgerID: ledgerID)
                } label: {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(LedgerPalette.cobalt)
                        Text("分类与账户判断设置")
                            .font(.subheadline)
                    }
                }

                if classificationSettings.isEnabled(for: ledgerID) {
                    Button {
                        LedgerFeedback.light()
                        suggestAccounts()
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundStyle(LedgerPalette.cobalt)
                            Text("补充账户建议 (TypeSafe Jev)")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .disabled(busy)
                }
            }

            Button {
                LedgerFeedback.light()
                prepare()
            } label: {
                HStack {
                    Image(systemName: "checkmark.shield.fill")
                    Text("生成并校验预览")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(busy || (draft?.questions.isEmpty == false && !reviewedQuestions))
            .accessibilityIdentifier("bookkeeping-prepare")
        } footer: {
            Text("所有分录在本机 Beancount 引擎中完整校验，经你二次预览确认后写入账本。")
                .font(.caption2)
        }
    }

    // MARK: - Actions

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
                let result = try await parser.parse(request)
                try Task.checkCancellation()
                guard runID == id, input == text, settings.revision == settingsRevision,
                      session.currentLocalLedgerDescriptor?.id == ledgerID,
                      session.phase == .ready, !session.privacyShielded else { return }
                draft = result
                records = result.records.map(Record.init)
                reviewedQuestions = false
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
        if reviewedQuestions { next.questions = [] }
        // Natural-language incomplete amounts always require user resolution.
        guard next.records.allSatisfy({ $0.postings.allSatisfy { !$0.amount.isEmpty } }) else {
            error = "请补充每条分录的金额。"
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

    private func suggestAccounts() {
        guard var next = draft, let ledgerID = session.currentLocalLedgerDescriptor?.id,
              classificationSettings.isEnabled(for: ledgerID), session.phase == .ready, !session.privacyShielded else { return }
        next.records = records.map(\.entry)
        next.proposals = []
        let snapshot = next, settingsRevision = classificationSettings.revision
        let id = UUID()
        runID = id
        busy = true
        error = nil
        operation = Task { @MainActor in
            defer { if runID == id { busy = false } }
            do {
                let classifier = try classificationSettings.classifier()
                try await session.loadGlobalTransactions(forceRefresh: true)
                try Task.checkCancellation()
                guard runID == id, classificationSettings.revision == settingsRevision,
                      session.currentLocalLedgerDescriptor?.id == ledgerID, !session.privacyShielded else { return }
                let result = try await BookkeepingPipeline.enrich(
                    snapshot,
                    accounts: session.ledger?.accounts ?? [],
                    history: session.visibleGlobalTransactions,
                    provider: classifier
                )
                try Task.checkCancellation()
                guard runID == id, classificationSettings.revision == settingsRevision,
                      session.currentLocalLedgerDescriptor?.id == ledgerID, !session.privacyShielded,
                      session.phase == .ready, records.map(\.entry) == snapshot.records else { return }
                draft = result
            } catch is CancellationError {
            } catch {
                if runID == id { self.error = error.localizedDescription }
            }
        }
    }
}
