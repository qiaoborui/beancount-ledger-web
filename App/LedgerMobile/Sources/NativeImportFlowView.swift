import SwiftUI

struct NativeImportFlowView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var classificationSettings = ImportClassificationSettings.shared

    let file: LedgerImportSelectedFile
    let providers: [LedgerImportProviderInfo]
    let onCommitted: (LedgerImportCommitResult) -> Void
    private let startsWithPreview: Bool

    @State private var providerOverride: String?
    @State private var alipayFundRounding = false
    @State private var archivePassword = ""
    @State private var preview: LedgerImportPreview?
    @State private var reviewedEntries: [LedgerImportEntry] = []
    @State private var includedEntryIDs: Set<String> = []
    @State private var selectedTagEntryIDs: Set<String> = []
    @State private var bulkTagInput = ""
    @FocusState private var bulkTagInputFocused: Bool
    @State private var editingEntry: LedgerImportEntry?
    @State private var commitResult: LedgerImportCommitResult?
    @State private var errorMessage: String?
    @State private var isPreparing = false
    @State private var isCommitting = false
    @State private var confirmationPresented = false
    @State private var preparedBookkeeping: PreparedBookkeepingChange?
    @State private var cleanupWarningDismissed = false
    @State private var commitErrorMessage: String?
    @State private var commitOutcomeNeedsReconciliation = false
    @State private var commitWasReconciled = false
    @State private var editedEntryStatus: String?
    @State private var editSaveFeedback = 0
    @State private var failureFeedback = 0
    @State private var pendingExit: ImportExitAction?
    @State private var classificationResults: [String: ImportClassificationSuggestion] = [:]
    @State private var classificationOriginals: [String: LedgerImportEntry] = [:]
    @State private var manuallyReviewedIDs: Set<String> = []
    @State private var classificationCompletedIDs: Set<String> = []
    @State private var classificationPaused = false
    @State private var isClassifying = false
    @State private var classificationError: String?
    @State private var classificationRetry = 0
    @State private var onlyClassificationReview = false
    @State private var classificationAcceptedFields: [String: Set<String>] = [:]
    @State private var classificationManualReasons: [String: String] = [:]
    @State private var classificationRunID = UUID()
    @State private var classificationEvidence: [String: [ImportClassificationRequest.Example]] = [:]
    @State private var warningsExpanded = false

    private enum ImportExitAction { case close, preparation }

    init(
        file: LedgerImportSelectedFile,
        providers: [LedgerImportProviderInfo],
        onCommitted: @escaping (LedgerImportCommitResult) -> Void
    ) {
        self.file = file
        self.providers = providers
        self.onCommitted = onCommitted
        startsWithPreview = false
    }

    init(
        preview: LedgerImportPreview,
        providers: [LedgerImportProviderInfo],
        onCommitted: @escaping (LedgerImportCommitResult) -> Void
    ) {
        file = LedgerImportSelectedFile(name: preview.originalFilename, data: Data())
        self.providers = providers
        self.onCommitted = onCommitted
        startsWithPreview = true
        _preview = State(initialValue: preview)
        _reviewedEntries = State(initialValue: preview.entries)
        _includedEntryIDs = State(initialValue: Set(preview.entries.map(\.id)))
    }

    private var selectedEntries: [LedgerImportEntry] {
        reviewedEntries.filter { includedEntryIDs.contains($0.id) }
    }

    private var currentTitle: String {
        if commitResult != nil { return "导入完成" }
        if preview != nil { return "核对交易" }
        return "导入账单"
    }

    private var hasReviewChanges: Bool {
        guard let preview, commitResult == nil else { return false }
        return reviewedEntries != preview.entries
            || includedEntryIDs != Set(preview.entries.map(\.id))
            || !bulkTagInput.isEmpty
            || commitOutcomeNeedsReconciliation
    }

    private var hasDraftChanges: Bool {
        guard commitResult == nil else { return false }
        return hasReviewChanges || providerOverride != nil || alipayFundRounding || !archivePassword.isEmpty
    }

    private var exitConfirmationTitle: String {
        commitOutcomeNeedsReconciliation ? "离开保存结果核对？" : "放弃本次修改？"
    }

    private var exitConfirmationDetail: String {
        if commitOutcomeNeedsReconciliation {
            return "账本可能已完成写入。离开后请先查看导入记录，确认结果再继续操作。"
        }
        return pendingExit == .preparation
            ? "返回后会清除本次核对修改，你可以重新生成预览。"
            : "本次尚未提交的设置和核对修改将被清除，原始账单文件保留。"
    }

    var body: some View {
        NavigationStack {
            Group {
                if let commitResult {
                    completionView(commitResult)
                } else if let preview {
                    previewView(preview)
                } else {
                    preparationView
                }
            }
            .background(LedgerPalette.canvas)
            .alert(exitConfirmationTitle, isPresented: Binding(
                get: { pendingExit != nil },
                set: { if !$0 { pendingExit = nil } }
            ), presenting: pendingExit) { action in
                Button(commitOutcomeNeedsReconciliation ? "离开核对" : "放弃修改", role: .destructive) {
                    pendingExit = nil
                    performExit(action)
                }
                Button("继续编辑", role: .cancel) { pendingExit = nil }
            } message: { _ in
                Text(exitConfirmationDetail)
            }
            .navigationTitle(currentTitle)
            .navigationBarTitleDisplayMode(.inline)

            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if preview != nil, commitResult == nil {
                        Button(startsWithPreview ? "关闭" : "返回") {
                            requestExit(startsWithPreview ? .close : .preparation)
                        }
                        .disabled(isCommitting)
                    } else if commitResult == nil {
                        Button("取消") { requestExit(.close) }
                            .disabled(isPreparing)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if preview != nil, commitResult == nil,
                       let ledgerID = session.currentLocalLedgerDescriptor?.id {
                        NavigationLink {
                            ImportClassificationSettingsView(ledgerID: ledgerID)
                        } label: {
                            Image(systemName: "sparkles")
                        }
                        .accessibilityIdentifier("import-classification-settings")
                    }
                }
            }
        }
        .interactiveDismissDisabled(isPreparing || isCommitting || hasDraftChanges)
        .privacySensitive()
        .alert("确认写入账本？", isPresented: $confirmationPresented) {
            Button(commitActionTitle) {
                startCommit()
            }
            Button("继续核对", role: .cancel) {}
        } message: {
            Text(commitConfirmationDetail)
        }
        .sheet(item: $editingEntry) { entry in
            ImportEntryEditor(
                entry: entry,
                accounts: importAccountChoices(for: entry),
                suggestion: classificationResults[entry.id],
                onSave: { updated in
                    applyEditedEntry(updated)
                }
            )
            .ledgerPrivacyProtectedSheet()
        }
        .sheet(item: $preparedBookkeeping) { prepared in
            BookkeepingPreviewView(preview: prepared) { result in
                guard let result else { return }
                commitResult = result
                onCommitted(result)
            }
        }
        .sensoryFeedback(.success, trigger: editSaveFeedback)
        .sensoryFeedback(.error, trigger: failureFeedback)
        .ledgerPrivacyProtectedSheet()
        .task(id: classificationTaskID) { await classifyPreview() }
    }

    private var classificationTaskID: String {
        [preview?.importID ?? "", session.currentLocalLedgerDescriptor?.id.uuidString ?? "",
         String(classificationSettings.revision), String(session.privacyShielded), String(session.phase == .ready),
         String(classificationPaused), String(confirmationPresented), String(isCommitting), String(commitResult != nil), String(classificationRetry)].joined(separator: ":")
    }

    private var classificationNeedsReview: Set<String> {
        Set(reviewedEntries.filter { entry in
            classificationManualReasons[entry.id] != nil || classificationResults[entry.id].map {
                !$0.pendingFields(for: entry, accepted: classificationAcceptedFields[entry.id] ?? []).isEmpty
            } == true
        }.map(\.id))
    }

    private func classifyPreview() async {
        guard let importID = preview?.importID, let ledgerID = session.currentLocalLedgerDescriptor?.id,
              classificationSettings.isEnabled(for: ledgerID), !session.privacyShielded, session.phase == .ready,
              !classificationPaused, !confirmationPresented, !isCommitting, commitResult == nil else { return }
        let runID = UUID()
        classificationRunID = runID
        isClassifying = true
        defer { if classificationRunID == runID { isClassifying = false } }
        do {
            let classifier = try classificationSettings.classifier()
            let settingsRevision = classificationSettings.revision
            try await session.loadGlobalTransactions(forceRefresh: true)
            try Task.checkCancellation()
            guard session.currentLocalLedgerDescriptor?.id == ledgerID, !session.privacyShielded else { return }
            let accounts = session.ledger?.accounts ?? []
            let history = session.visibleGlobalTransactions
            let entries = reviewedEntries
            try await BookkeepingPipeline.classifyImports(entries, accounts: accounts, history: history,
                provider: classifier, canContinue: {
                preview?.importID == importID && session.currentLocalLedgerDescriptor?.id == ledgerID
                    && !session.privacyShielded && session.phase == .ready
                    && classificationSettings.isEnabled(for: ledgerID) && classificationSettings.revision == settingsRevision
                    && !classificationPaused && !confirmationPresented && !isCommitting && commitResult == nil
            }, currentEntry: { id in
                reviewedEntries.first { $0.id == id }
            }, isEligible: { id in
                includedEntryIDs.contains(id) && !classificationCompletedIDs.contains(id)
                    && !manuallyReviewedIDs.contains(id) && editingEntry?.id != id
            }, unsupported: { entry in
                classificationCompletedIDs.insert(entry.id)
                classificationManualReasons[entry.id] = "这笔交易包含复杂分录或缺少可用账户，请打开编辑核对。"
            }, accept: { job, result, updated in
                let entry = job.entry
                guard let index = reviewedEntries.firstIndex(where: { $0.id == entry.id }) else { return }
                classificationResults[entry.id] = result
                classificationEvidence[entry.id] = job.input.history
                classificationCompletedIDs.insert(entry.id)
                classificationOriginals[entry.id] = entry
                reviewedEntries[index] = updated
            })
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            classificationError = (error as? ImportClassificationError)?.localizedDescription
                ?? "智能分类暂时不可用，已完成的建议保留，你可以继续核对或重试。"
        }
    }

    @ViewBuilder
    private func classificationRow(_ entry: LedgerImportEntry) -> some View {
        if let result = classificationResults[entry.id] {
            let pending = result.pendingFields(for: entry, accepted: classificationAcceptedFields[entry.id] ?? [])
            DisclosureGroup {
                LabeledContent("交易性质", value: ImportClassificationSuggestion.natureLabels[result.nature.value] ?? "待判断")
                classificationAccountChoices("付款 / 收款账户", field: "funding", entry: entry,
                                             current: entry.fundingAccount, decision: result.funding)
                classificationAccountChoices("分类 / 对应账户", field: "category", entry: entry,
                                             current: entry.categoryAccount, decision: result.category)
                if !result.tags.isEmpty {
                    DisclosureGroup {
                        ForEach(result.tags.filter { $0.probability >= 0.5 }, id: \.value) { tag in
                            Button {
                                applyClassificationTag(tag.value, to: entry)
                            } label: {
                                Label(tag.value, systemImage: (entry.tags ?? []).contains(tag.value) ? "checkmark.circle.fill" : "plus.circle")
                            }
                            .accessibilityIdentifier("import-suggestion-tag-\(tag.value)")
                        }
                        Button("保留当前标签") { acceptClassificationField("tags", entryID: entry.id) }
                    } label: {
                        Text("标签建议")
                    }
                }
                if let original = classificationOriginals[entry.id], original != entry {
                    Button("恢复原草稿") { applyEditedEntry(original) }
                }
                Button("确认这笔草稿") { applyEditedEntry(entry) }
                    .accessibilityIdentifier("import-suggestion-confirm-\(entry.id)")
                if let evidence = classificationEvidence[entry.id], !evidence.isEmpty {
                    DisclosureGroup("参考历史 · \(evidence.count) 条") {
                        ForEach(Array(evidence.enumerated()), id: \.offset) { _, example in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(example.payee + " · " + example.narration)
                                if !example.method.isEmpty { Text(example.method).foregroundStyle(.secondary) }
                                Text(example.accounts.joined(separator: " · ")).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } label: {
                Text(pending.isEmpty ? "草稿已补全 · 点按核对" : "导入信息待确认 · 查看建议")
                    .foregroundStyle(pending.isEmpty ? LedgerPalette.secondary : LedgerPalette.cobalt)
            }
            .font(.caption)
            .foregroundStyle(.primary)
            .buttonStyle(.borderless)
        } else if let reason = classificationManualReasons[entry.id] {
            Button { editingEntry = entry } label: {
                Label(reason, systemImage: "exclamationmark.circle")
            }
            .font(.caption)
            .foregroundStyle(LedgerPalette.warm)
            .buttonStyle(.borderless)
        }
    }

    private func classificationAccountChoices(_ title: String, field: String, entry: LedgerImportEntry,
                                              current: String, decision: ImportClassificationSuggestion.Field) -> some View {
        DisclosureGroup {
            if decision.value == "review" {
                Text("现有信息不足，请核对支付信息后选择账户。").foregroundStyle(.secondary)
            }
            ForEach(decision.candidates, id: \.value) { candidate in
                Button {
                    applyClassificationAccount(candidate.value, field: field, to: entry)
                } label: {
                    Label(candidate.value, systemImage: current == candidate.value ? "checkmark.circle.fill" : "circle")
                        .lineLimit(3)
                }
                .accessibilityIdentifier("import-suggestion-\(field)-\(candidate.value)")
            }
            Button("保留当前账户") { acceptClassificationField(field, entryID: entry.id) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(current).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    private func applyClassificationAccount(_ account: String, field: String, to entry: LedgerImportEntry) {
        let category = field == "category" ? account : entry.categoryAccount
        let funding = field == "funding" ? account : entry.fundingAccount
        let allowed = importAccountChoices(for: entry).map(\.account)
        guard let updated = ImportClassificationContext.applying(category: category, funding: funding, to: entry, allowed: allowed),
              let index = reviewedEntries.firstIndex(where: { $0.id == entry.id }) else {
            errorMessage = "资金账户和对应账户需使用不同账户，请打开编辑同时调整。"
            return
        }
        reviewedEntries[index] = updated
        acceptClassificationField(field, entryID: entry.id)
    }

    private func applyClassificationTag(_ tag: String, to entry: LedgerImportEntry) {
        var tags = entry.tags ?? []
        if tags.contains(tag) { tags.removeAll { $0 == tag } } else { tags.append(tag) }
        guard let checked = try? LedgerTagRules.validating(tags),
              let index = reviewedEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        reviewedEntries[index] = entry.applyingTags(checked)
        manuallyReviewedIDs.insert(entry.id)
        if classificationNeedsReview.isEmpty { onlyClassificationReview = false }
    }

    private func acceptClassificationField(_ field: String, entryID: String) {
        classificationAcceptedFields[entryID, default: []].insert(field)
        manuallyReviewedIDs.insert(entryID)
        if classificationNeedsReview.isEmpty { onlyClassificationReview = false }
    }

    private func requestExit(_ action: ImportExitAction) {
        guard !isPreparing, !isCommitting else { return }
        let needsConfirmation = action == .preparation ? hasReviewChanges : hasDraftChanges
        if needsConfirmation { pendingExit = action }
        else { performExit(action) }
    }

    private func performExit(_ action: ImportExitAction) {
        guard !isPreparing, !isCommitting else { return }
        if action == .close {
            dismiss()
        } else {
            preview = nil
            reviewedEntries = []
            includedEntryIDs = []
            selectedTagEntryIDs = []
            bulkTagInput = ""
            errorMessage = nil
            commitErrorMessage = nil
            commitOutcomeNeedsReconciliation = false
            commitWasReconciled = false
            editedEntryStatus = nil
            resetClassification()
        }
    }

    private var preparationView: some View {
        Form {
            if let errorMessage {
                Section { StatusBanner(message: errorMessage) { self.errorMessage = nil } }
            }
            Section("账单文件") {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LedgerPalette.cobalt.opacity(0.12))
                            .frame(width: 38, height: 38)
                        Image(systemName: file.isZIP ? "doc.zipper" : "doc.text")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(LedgerPalette.cobalt)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(LedgerPalette.ink)
                            .lineLimit(1)
                        Text(fileSizeText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            Section {
                Picker("账单渠道", selection: $providerOverride) {
                    Text("自动识别").tag(String?.none)
                    ForEach(LedgerMobileImportCapabilities.fileImportProviders(from: providers)) { provider in
                        Text(provider.label).tag(Optional(provider.id))
                    }
                }
                .accessibilityIdentifier("import-provider-menu")
            } footer: {
                Text(selectedProviderDetail)
            }
            if file.isZIP {
                Section("压缩包密码") {
                    SecureField("输入账单压缩包密码", text: $archivePassword)
                        .textContentType(.password)
                        .accessibilityIdentifier("import-archive-password")
                }
            }
            if providerOverride == nil || providerOverride == "alipay" {
                Section {
                    Toggle("支付宝基金 9.99 → 10.00 补差", isOn: $alipayFundRounding)
                } footer: {
                    Text("仅在确认该基金定投需要补 0.01 时开启。")
                }
            }
            Section {
                Button {
                    Task { await generatePreview() }
                } label: {
                    HStack(spacing: 8) {
                        if isPreparing {
                            ProgressView().tint(LedgerPalette.onBrand)
                            Text("正在生成预览...")
                        } else {
                            Image(systemName: "sparkles")
                            Text("生成导入预览")
                        }
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(LedgerPalette.onBrand)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(LedgerPalette.cobalt)
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityIdentifier("import-generate-preview")
            } footer: {
                Text("预览会检查渠道与重复交易。核对并确认后写入账本，关闭页面会丢弃当前预览。")
            }
        }
        .disabled(isPreparing)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("native-import-preparation")
    }

    private func friendlyAccountLabel(_ account: String) -> String {
        if account.isEmpty { return "待指定账户" }
        if let match = session.ledger?.accounts.first(where: { $0.account == account }) {
            if let alias = match.alias, !alias.isEmpty { return alias }
            if !match.label.isEmpty { return match.label }
        }
        return account.split(separator: ":").last.map(String.init) ?? account
    }

    private func previewView(_ preview: LedgerImportPreview) -> some View {
        List {
            if let errorMessage {
                Section {
                    StatusBanner(message: errorMessage) { self.errorMessage = nil }
                }
            }
            previewSummary(preview)
            bulkTagSection
            entrySection(preview)
        }
        .ledgerReadingList()
        .contentMargins(.top, LedgerLayout.pageTopInset, for: .scrollContent)
        .tint(LedgerPalette.cobalt)
        .disabled(isCommitting)
        .accessibilityIdentifier("native-import-preview")
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            commitBar(preview)
        }
    }

    private func previewSummary(_ preview: LedgerImportPreview) -> some View {
        Section {
            DisclosureGroup {
                LabeledContent("识别渠道", value: providerLabel(preview.provider))
                LabeledContent("交易区间", value: importRangeText(preview))
                LabeledContent("候选交易", value: "\(preview.candidateCount) 条")
                if preview.skippedDuplicateCount > 0 {
                    LabeledContent("已跳过重复", value: "\(preview.skippedDuplicateCount) 条")
                }
                if !preview.providerDetection.reason.isEmpty {
                    Text(preview.providerDetection.reason)
                        .font(.caption)
                        .foregroundStyle(LedgerPalette.secondary)
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LedgerPalette.cobalt.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(LedgerPalette.cobalt)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(providerLabel(preview.provider))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LedgerPalette.ink)
                        Text(importRangeText(preview) + (preview.skippedDuplicateCount > 0 ? " · 已跳过 \(preview.skippedDuplicateCount) 条重复交易" : ""))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("import-preview-summary")
            }

            if let ledgerID = session.currentLocalLedgerDescriptor?.id,
               classificationSettings.isEnabled(for: ledgerID) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(LedgerPalette.cobalt)
                    if isClassifying {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("智能匹配中 (\(classificationCompletedIDs.count)/\(reviewedEntries.count))...")
                            .font(.caption)
                            .foregroundStyle(LedgerPalette.secondary)
                        Spacer()
                        Button("停止") { classificationPaused = true }
                            .font(.caption)
                    } else {
                        Text(classificationResults.isEmpty ? "智能分类已就绪" : "已自动完成智能匹配 · \(classificationResults.count) 条已填充")
                            .font(.caption)
                            .foregroundStyle(LedgerPalette.secondary)
                        Spacer()
                        if classificationCompletedIDs.count < reviewedEntries.count {
                            Button("继续分类") {
                                classificationError = nil
                                classificationPaused = false
                                classificationRetry &+= 1
                            }
                            .font(.caption)
                        }
                    }
                }
                .padding(.vertical, 2)
                if let classificationError {
                    Text(classificationError)
                        .font(.caption)
                        .foregroundStyle(LedgerPalette.risk)
                }
            }

            if !preview.warnings.isEmpty {
                DisclosureGroup(isExpanded: $warningsExpanded) {
                    ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                        HStack(alignment: .top, spacing: LedgerSpacing.xs) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(LedgerPalette.warm)
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(LedgerPalette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                } label: {
                    HStack(spacing: LedgerSpacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(LedgerPalette.warm)
                        Text("\(preview.warnings.count) 条账单核对提示")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(LedgerPalette.warm)
                        Spacer()
                        Text(warningsExpanded ? "收起" : "展开查看")
                            .font(.caption2)
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                }
            }
        }
        .font(.subheadline)
    }

    private func entrySection(_ preview: LedgerImportPreview) -> some View {
        Section {
            ForEach(reviewedEntries.filter { !onlyClassificationReview || classificationNeedsReview.contains($0.id) }) { entry in
                ImportEntryReviewRow(
                    entry: entry,
                    included: includedEntryIDs.contains(entry.id),
                    tagSelected: selectedTagEntryIDs.contains(entry.id),
                    isAIClassified: classificationResults[entry.id] != nil,
                    categoryLabel: friendlyAccountLabel(entry.categoryAccount),
                    fundingLabel: friendlyAccountLabel(entry.fundingAccount),
                    onToggle: { toggle(entry.id) },
                    onToggleTag: { toggleTagSelection(entry.id) },
                    onEdit: { editingEntry = entry }
                )
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--safe-classification-review") {
                    classificationRow(entry)
                }
#endif
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("交易明细 · 已选 \(selectedEntries.count)/\(reviewedEntries.count)")
                Spacer(minLength: 0)
                if !classificationNeedsReview.isEmpty {
                    Toggle("只看待核对", isOn: $onlyClassificationReview)
                        .toggleStyle(.button)
                        .font(.caption)
                        .tint(LedgerPalette.cobalt)
                        .accessibilityIdentifier("import-classification-review-filter")
                }
                Button(includedEntryIDs.count == reviewedEntries.count ? "取消全选" : "全选") {
                    if includedEntryIDs.count == reviewedEntries.count {
                        includedEntryIDs = []
                    } else {
                        includedEntryIDs = Set(reviewedEntries.map(\.id))
                    }
                }
                .frame(minHeight: 44)
                .textCase(nil)
            }
        }
    }

    private var bulkTagSection: some View {
        Section {
            DisclosureGroup {
                Button(allEntriesSelectedForTags ? "清空" : "全选") {
                    selectedTagEntryIDs = allEntriesSelectedForTags
                        ? []
                        : Set(reviewedEntries.map(\.id))
                }
                TextField("travel, trip-2026", text: $bulkTagInput)
                    .focused($bulkTagInputFocused)
                    .onSubmit { bulkTagInputFocused = false }
                    .font(.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("import-bulk-tag-input")
                Button("添加标签") { applyBulkTags(mode: .add) }
                    .disabled(selectedTagEntryIDs.isEmpty)
                    .accessibilityIdentifier("import-bulk-tag-add")
                Button("移除标签") { applyBulkTags(mode: .remove) }
                    .disabled(selectedTagEntryIDs.isEmpty)
                    .accessibilityIdentifier("import-bulk-tag-remove")
                Text("展开交易可选择标签操作对象，也可全选。核对并确认后保存标签修改。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } label: {
                LabeledContent("批量标签", value: "已选 \(selectedTagEntryIDs.count) 条")
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("import-bulk-tags")
            }
        }
    }

    private var allEntriesSelectedForTags: Bool {
        !reviewedEntries.isEmpty && reviewedEntries.allSatisfy { selectedTagEntryIDs.contains($0.id) }
    }

    private func commitBar(_ preview: LedgerImportPreview) -> some View {
        VStack(spacing: LedgerSpacing.sm) {
            if let editedEntryStatus {
                Label(editedEntryStatus, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LedgerPalette.success)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("import-edit-saved-status")
            }

            if let commitErrorMessage {
                Label(commitErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(LedgerPalette.risk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("import-commit-error")
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedEntries.isEmpty ? "仅归档原始账单" : "准备写入 \(selectedEntries.count) 条交易")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(LedgerPalette.ink)
                    Text(providerLabel(preview.provider) + " · " + importRangeText(preview))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                }
                Spacer(minLength: 0)
            }

            Button {
                if commitOutcomeNeedsReconciliation {
                    startCommitReconciliation()
                } else {
                    classificationPaused = true
                    if session.localRepository != nil { Task { await prepareLocalImport() } }
                    else { confirmationPresented = true }
                }
            } label: {
                HStack {
                    if isCommitting { ProgressView().tint(.white) }
                    Text(commitButtonTitle).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(LedgerPalette.cobalt)
            .disabled(isCommitting)
            .accessibilityLabel(commitButtonTitle)
            .accessibilityValue(commitButtonAccessibilityValue)
            .accessibilityHint(commitButtonAccessibilityHint)
            .accessibilityIdentifier("import-commit")
        }
        .padding(.horizontal, LedgerSpacing.lg)
        .padding(.top, LedgerSpacing.md)
        .padding(.bottom, LedgerSpacing.sm)
        .ledgerFloatingActionSurface()
    }

    private func completionView(_ result: LedgerImportCommitResult) -> some View {
        ScrollView {
            VStack(spacing: LedgerSpacing.xl) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(LedgerPalette.success)

                VStack(spacing: LedgerSpacing.sm) {
                    Text(result.count == 0 ? "账单已归档" : "已写入 \(result.count) 条交易")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                        .multilineTextAlignment(.center)
                    Text(completionDetail(result))
                        .font(.system(size: 13))
                        .foregroundStyle(LedgerPalette.secondary)
                        .multilineTextAlignment(.center)
                }

                if result.readModelPending == true, let progress = session.importIndexProgress {
                    LedgerPanel {
                        HStack(spacing: LedgerSpacing.md) {
                            Group {
                                if progress.phase == .indexed {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(LedgerPalette.success)
                                } else {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(LedgerPalette.cobalt)
                                }
                            }
                            .frame(width: 36, height: 36)
                            .background(
                                (progress.phase == .indexed ? LedgerPalette.success : LedgerPalette.cobalt)
                                    .opacity(0.12)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(progress.phase == .indexed ? "索引已完成" : "正在更新索引")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.ink)
                                Text(progress.phase == .indexed ? "最新数据已经可以查询。" : "系统允许实时活动时会显示在灵动岛。")
                                    .font(.system(size: 11))
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(LedgerSpacing.lg)
                    }
                    .accessibilityIdentifier("import-index-progress")
                }

                if let documentFile = result.documentFile {
                    LedgerPanel {
                        HStack(alignment: .center, spacing: LedgerSpacing.md) {
                            Image(systemName: "archivebox.fill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(LedgerPalette.cobalt)
                                .frame(width: 36, height: 36)
                                .background(LedgerPalette.tag)
                                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("账单已归档")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.ink)
                                Text(URL(fileURLWithPath: documentFile).lastPathComponent)
                                    .font(.system(size: 11, weight: .medium).monospaced())
                                    .foregroundStyle(LedgerPalette.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(LedgerSpacing.lg)
                    }
                }

                if let cleanupError = result.runtimeCleanupError, !cleanupWarningDismissed {
                    StatusBanner(message: cleanupError) { cleanupWarningDismissed = true }
                }

                if let warning = result.gmailPendingStatusWarning, !cleanupWarningDismissed {
                    StatusBanner(message: warning) { cleanupWarningDismissed = true }
                }

                Button {
                    dismiss()
                } label: {
                    PrimaryButtonLabel(title: "完成", loading: false)
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityIdentifier("import-finish")
            }
            .padding(.horizontal, LedgerSpacing.xl)
            .padding(.vertical, LedgerSpacing.xxl)
            .ledgerAdaptivePageWidth()
        }
        .accessibilityIdentifier("native-import-complete")
    }

    private func completionDetail(_ result: LedgerImportCommitResult) -> String {
        if commitWasReconciled {
            return "保存响应中断，但已通过导入归档确认账本写入完成。"
        }
        guard result.readModelPending == true else { return "账本和导入记录已经更新。" }
        return session.importIndexProgress?.phase == .indexed
            ? "账本写入和索引更新已经完成。"
            : "账本写入完成，正在等待索引更新。"
    }

    private func importAccountChoices(for entry: LedgerImportEntry) -> [LedgerAccountChoice] {
        var choices = Dictionary(uniqueKeysWithValues: (session.ledger?.accounts ?? []).map { account in
            (
                account.account,
                LedgerAccountChoice(
                    account: account.account,
                    label: account.alias?.isEmpty == false ? account.alias! : account.label,
                    group: account.group,
                    active: account.active
                )
            )
        })
        let currentAccounts = Set(
            entry.postings.map(\.account) + [entry.categoryAccount, entry.fundingAccount]
        )
        for account in currentAccounts where choices[account] == nil {
            choices[account] = LedgerAccountChoice(
                account: account,
                label: account.split(separator: ":").last.map(String.init) ?? account,
                group: "current",
                active: true
            )
        }
        return choices.values.sorted { left, right in
            if left.active != right.active { return left.active && !right.active }
            let labelOrder = left.label.localizedStandardCompare(right.label)
            return labelOrder == .orderedSame
                ? left.account.localizedStandardCompare(right.account) == .orderedAscending
                : labelOrder == .orderedAscending
        }
    }

    private func applyEditedEntry(_ updated: LedgerImportEntry) {
        guard let index = reviewedEntries.firstIndex(where: { $0.id == updated.id }) else { return }
        reviewedEntries[index] = updated
        manuallyReviewedIDs.insert(updated.id)
        classificationCompletedIDs.insert(updated.id)
        classificationResults.removeValue(forKey: updated.id)
        classificationOriginals.removeValue(forKey: updated.id)
        classificationEvidence.removeValue(forKey: updated.id)
        classificationAcceptedFields.removeValue(forKey: updated.id)
        classificationManualReasons.removeValue(forKey: updated.id)
        if classificationNeedsReview.isEmpty { onlyClassificationReview = false }
        let name = updated.payee.trimmingCharacters(in: .whitespacesAndNewlines)
        editedEntryStatus = "\(name.isEmpty ? "这条交易" : "“\(name)”")的修改已保存到本次预览"
        editSaveFeedback &+= 1
    }

    private var selectedProviderDetail: String {
        guard let providerOverride else { return "根据文件名和账单结构选择渠道" }
        return providers.first(where: { $0.id == providerOverride })?.detail ?? "使用指定渠道生成预览"
    }

    private var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file)
    }

    private var commitActionTitle: String {
        selectedEntries.isEmpty ? "仅归档账单" : "写入 \(selectedEntries.count) 条交易"
    }

    private var commitButtonTitle: String {
        if isCommitting {
            return commitOutcomeNeedsReconciliation ? "正在核对保存结果" : "正在验证并写入账本"
        }
        if commitOutcomeNeedsReconciliation { return "重新检查保存结果" }
        return commitErrorMessage == nil ? commitActionTitle : "重试保存"
    }

    private var commitButtonAccessibilityValue: String {
        if isCommitting { return "处理中" }
        if commitOutcomeNeedsReconciliation { return "保存结果待确认" }
        return commitErrorMessage == nil ? "可以提交" : "上次保存失败"
    }

    private var commitButtonAccessibilityHint: String {
        if isCommitting { return "请稍候，完成后会显示保存结果" }
        if commitOutcomeNeedsReconciliation { return "只检查导入归档，不会再次提交" }
        return "保存前会再次校验预览与账本"
    }

    private var commitConfirmationDetail: String {
        if selectedEntries.isEmpty {
            return "原始账单会进入归档记录，交易账本保持不变。"
        }
        return "将在这台设备校验预览和账本，写入 \(selectedEntries.count) 条交易。"
    }

    private func providerLabel(_ id: String) -> String {
        providers.first(where: { $0.id == id })?.label
            ?? LedgerImportProvider.provider(id)?.label
            ?? id
    }

    private func confidenceText(_ confidence: String) -> String {
        switch confidence {
        case "high": "高置信度"
        case "medium": "中等置信度"
        default: "需要重点核对"
        }
    }

    private func importRangeText(_ preview: LedgerImportPreview) -> String {
        if let start = preview.dateStart, let end = preview.dateEnd, start != end {
            return "\(start) 至 \(end)"
        }
        return preview.dateEnd ?? preview.dateStart ?? "日期范围未知"
    }

    private func toggle(_ id: String) {
        if includedEntryIDs.contains(id) {
            includedEntryIDs.remove(id)
        } else {
            includedEntryIDs.insert(id)
        }
    }

    private func toggleTagSelection(_ id: String) {
        if selectedTagEntryIDs.contains(id) {
            selectedTagEntryIDs.remove(id)
        } else {
            selectedTagEntryIDs.insert(id)
        }
    }

    private enum BulkTagMode {
        case add
        case remove
    }

    private func applyBulkTags(mode: BulkTagMode) {
        guard !selectedTagEntryIDs.isEmpty else {
            errorMessage = "请先选择需要修改标签的交易。"
            failureFeedback &+= 1
            return
        }
        do {
            let tags = try LedgerTagRules.parse(bulkTagInput)
            let changed = Set(tags)
            reviewedEntries = try reviewedEntries.map { entry in
                guard selectedTagEntryIDs.contains(entry.id) else { return entry }
                let existing = LedgerTagRules.normalized(entry.tags ?? [])
                let updated: [String]
                switch mode {
                case .add:
                    updated = try LedgerTagRules.validating(existing + tags)
                case .remove:
                    updated = existing.filter { !changed.contains($0) }
                }
                return entry.applyingTags(updated)
            }
            bulkTagInput = ""
            errorMessage = nil
            bulkTagInputFocused = false
        } catch {
            errorMessage = error.localizedDescription
            failureFeedback &+= 1
        }
    }

    private func generatePreview() async {
        guard !isPreparing else { return }
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }
        do {
            let updated = try await session.previewImport(
                file: file,
                provider: providerOverride,
                alipayFundRounding: alipayFundRounding,
                archivePassword: archivePassword
            )
            guard !Task.isCancelled else { return }
            archivePassword = ""
            preview = updated
            reviewedEntries = updated.entries
            includedEntryIDs = Set(updated.entries.map(\.id))
            selectedTagEntryIDs = []
            bulkTagInput = ""
            commitErrorMessage = nil
            commitOutcomeNeedsReconciliation = false
            commitWasReconciled = false
            editedEntryStatus = nil
            resetClassification()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--safe-preview"),
               ProcessInfo.processInfo.arguments.contains("--safe-classification-review"),
               let entry = reviewedEntries.first,
               let original = ImportClassificationContext.applying(category: "Expenses:Unknown",
                   funding: entry.fundingAccount, to: entry, allowed: ["Expenses:Unknown", entry.fundingAccount]),
               let input = ImportClassificationContext.request(for: original,
                   accounts: session.ledger?.accounts ?? [], history: []) {
                let result = ImportClassificationSuggestion(model: "fixture",
                    category: .init(value: entry.categoryAccount, confidence: 0.5,
                                    candidates: [.init(value: entry.categoryAccount, probability: 0.6)]),
                    funding: .init(value: "Liabilities:CreditCard", confidence: 0.5,
                                   candidates: [.init(value: "Liabilities:CreditCard", probability: 0.6)]),
                    nature: .init(value: "expense", confidence: 0.99,
                                  candidates: [.init(value: "expense", probability: 0.99)]),
                    tags: [.init(value: "travel", probability: 0.7)])
                classificationResults[entry.id] = result
                classificationOriginals[entry.id] = original
                reviewedEntries[0] = ImportClassificationContext.autofilled(original, suggestion: result, input: input)
                onlyClassificationReview = true
            }
#endif
        } catch is CancellationError {
            return
        } catch {
            archivePassword = ""
            errorMessage = error.localizedDescription
            failureFeedback &+= 1
        }
    }

    private func prepareLocalImport() async {
        guard let preview, let repository = session.localRepository, !isCommitting,
              session.phase == .ready, !session.privacyShielded else { return }
        let entries = selectedEntries
        isCommitting = true
        commitErrorMessage = nil
        defer { isCommitting = false }
        do {
            let prepared = try await repository.prepareImport(.init(importID: preview.importID,
                provider: preview.provider, entries: entries))
            guard !Task.isCancelled, session.phase == .ready, !session.privacyShielded,
                  session.currentLocalLedgerDescriptor?.id == repository.descriptor.id, selectedEntries == entries else {
                await repository.discardPrepared(prepared); return
            }
            preparedBookkeeping = prepared
        } catch { commitErrorMessage = error.localizedDescription }
    }

    private func startCommit() {
        guard let preview, !isCommitting else { return }
        let entries = selectedEntries
        classificationPaused = true
        isCommitting = true
        commitErrorMessage = nil
        commitOutcomeNeedsReconciliation = false
        Task { await commit(preview: preview, entries: entries) }
    }

    private func resetClassification() {
        classificationResults = [:]
        classificationOriginals = [:]
        classificationEvidence = [:]
        classificationAcceptedFields = [:]
        classificationManualReasons = [:]
        manuallyReviewedIDs = []
        classificationCompletedIDs = []
        classificationPaused = false
        classificationError = nil
        onlyClassificationReview = false
    }

    private func commit(preview: LedgerImportPreview, entries: [LedgerImportEntry]) async {
        defer { isCommitting = false }
        do {
            let result = try await session.commitImport(preview: preview, entries: entries)
            guard !Task.isCancelled else { return }
            commitResult = result
            session.startImportIndexTracking(
                result: result,
                providerLabel: providerLabel(preview.provider),
                baselineGitSHA: nil
            )
            onCommitted(result)
        } catch is CancellationError {
            return
        } catch {
            if LedgerImportCommitFailureDisposition(error: error) == .outcomeUnknown {
                await reconcileCommit(preview: preview, entries: entries)
            } else {
                commitErrorMessage = "保存失败：\(error.localizedDescription) 你的核对修改仍在，可重试。"
                failureFeedback &+= 1
            }
        }
    }

    private func startCommitReconciliation() {
        guard let preview, !isCommitting else { return }
        let entries = selectedEntries
        isCommitting = true
        Task {
            await reconcileCommit(preview: preview, entries: entries)
            isCommitting = false
        }
    }

    private func reconcileCommit(preview: LedgerImportPreview, entries: [LedgerImportEntry]) async {
        let documents = try? await session.importDocuments()
        guard !Task.isCancelled else { return }
        if let document = documents.flatMap({
            LedgerImportCommitReconciliation.archivedDocument(importID: preview.importID, in: $0)
        }) {
            let result = LedgerImportCommitResult(
                ok: true,
                outputFile: nil,
                includeFile: nil,
                documentFile: document.path,
                count: entries.count,
                beanText: nil,
                readModelPending: nil,
                indexGitSHA: nil,
                runtimeCleanupError: nil,
                gmailPendingStatusWarning: nil
            )
            commitWasReconciled = true
            commitOutcomeNeedsReconciliation = false
            commitErrorMessage = nil
            commitResult = result
            onCommitted(result)
            return
        }
        commitOutcomeNeedsReconciliation = true
        commitErrorMessage = "保存结果待确认：操作已中断，请先重新检查导入归档，再继续记账。"
        failureFeedback &+= 1
    }
}

private enum ImportEditorField: Hashable {
    case payee
    case narration
    case tags
    case amount
}

private struct ImportEntryEditor: View {
    @Environment(\.dismiss) private var dismiss

    let entry: LedgerImportEntry
    let accounts: [LedgerAccountChoice]
    let suggestion: ImportClassificationSuggestion?
    let onSave: (LedgerImportEntry) -> Void

    @State private var date: Date
    @State private var flag: String
    @State private var payee: String
    @State private var narration: String
    @State private var tagsText: String
    @State private var amountText: String
    @State private var fundingAccount: String
    @State private var categoryAccount: String
    @State private var discardConfirmationPresented = false
    @FocusState private var focusedField: ImportEditorField?

    init(
        entry: LedgerImportEntry,
        accounts: [LedgerAccountChoice],
        suggestion: ImportClassificationSuggestion? = nil,
        onSave: @escaping (LedgerImportEntry) -> Void
    ) {
        self.entry = entry
        self.accounts = accounts
        self.suggestion = suggestion
        self.onSave = onSave
        _date = State(initialValue: Self.parseDate(entry.date) ?? Date())
        _flag = State(initialValue: entry.flag == "!" ? "!" : "*")
        _payee = State(initialValue: entry.payee)
        _narration = State(initialValue: entry.narration)
        _tagsText = State(initialValue: (entry.tags ?? []).joined(separator: " "))
        _amountText = State(initialValue: Self.amountText(
            entry.amount,
            fixedToMinorUnits: entry.supportsMainAmountEditing
        ))
        _fundingAccount = State(initialValue: entry.fundingAccount)
        _categoryAccount = State(initialValue: entry.categoryAccount)
    }

    private var parsedAmount: Double? {
        let normalized = amountText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count <= 2,
              components.last.map({ $0.count <= 2 }) ?? true,
              let value = Double(normalized),
              value.isFinite,
              value > 0,
              value <= LedgerImportEntry.maximumEditableMainAmount else { return nil }
        return value
    }

    private var canSave: Bool {
        !fundingAccount.isEmpty
            && !categoryAccount.isEmpty
            && fundingAccount != categoryAccount
            && (!entry.supportsMainAmountEditing || parsedAmount != nil)
            && parsedTags != nil
    }

    private var parsedTags: [String]? {
        if tagsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        return try? LedgerTagRules.parse(tagsText)
    }

    private var hasChanges: Bool {
        Self.formatDate(date) != entry.date
            || flag != (entry.flag == "!" ? "!" : "*")
            || payee != entry.payee
            || narration != entry.narration
            || tagsText != (entry.tags ?? []).joined(separator: " ")
            || amountText != Self.amountText(entry.amount, fixedToMinorUnits: entry.supportsMainAmountEditing)
            || fundingAccount != entry.fundingAccount
            || categoryAccount != entry.categoryAccount
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("交易信息") {
                    TextField("商家", text: $payee)
                        .textContentType(.organizationName)
                        .focused($focusedField, equals: .payee)
                        .accessibilityIdentifier("import-edit-payee")
                    TextField("标题", text: $narration)
                        .focused($focusedField, equals: .narration)
                        .accessibilityIdentifier("import-edit-narration")
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    Picker("状态", selection: $flag) {
                        Text("已确认").tag("*")
                        Text("待核对").tag("!")
                    }
                }
                Section {
                    NavigationLink {
                        LedgerAccountPicker(title: "选择来源账户", accounts: accounts, selection: $fundingAccount)
                    } label: {
                        LabeledContent("来源账户", value: accountChoice(fundingAccount).label)
                    }
                    .accessibilityIdentifier("import-edit-source-account")

                    if let candidates = suggestion?.funding.candidates, !candidates.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(candidates, id: \.value) { candidate in
                                    Button {
                                        fundingAccount = candidate.value
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(accountChoice(candidate.value).label)
                                            Text("\(Int((candidate.probability * 100).rounded()))%")
                                                .font(.caption2)
                                                .opacity(0.8)
                                        }
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(fundingAccount == candidate.value ? LedgerPalette.cobalt.opacity(0.15) : Color.secondary.opacity(0.1))
                                        .foregroundStyle(fundingAccount == candidate.value ? LedgerPalette.cobalt : LedgerPalette.ink)
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    NavigationLink {
                        LedgerAccountPicker(title: "选择目标账户", accounts: accounts, selection: $categoryAccount)
                    } label: {
                        LabeledContent("目标账户", value: accountChoice(categoryAccount).label)
                    }
                    .accessibilityIdentifier("import-edit-target-account")

                    if let candidates = suggestion?.category.candidates, !candidates.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(candidates, id: \.value) { candidate in
                                    Button {
                                        categoryAccount = candidate.value
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(accountChoice(candidate.value).label)
                                            Text("\(Int((candidate.probability * 100).rounded()))%")
                                                .font(.caption2)
                                                .opacity(0.8)
                                        }
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(categoryAccount == candidate.value ? LedgerPalette.cobalt.opacity(0.15) : Color.secondary.opacity(0.1))
                                        .foregroundStyle(categoryAccount == candidate.value ? LedgerPalette.cobalt : LedgerPalette.ink)
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    if fundingAccount == categoryAccount {
                        Text("来源账户和目标账户需使用不同账户。").foregroundStyle(LedgerPalette.risk)
                    }
                } header: {
                    Text("资金流向")
                }
                Section {
                    LabeledContent(entry.currency) {
                        TextField("0.00", text: $amountText)
                            .font(.title3.monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .disabled(!entry.supportsMainAmountEditing)
                            .focused($focusedField, equals: .amount)
                            .accessibilityIdentifier("import-edit-amount")
                    }
                } header: {
                    Text("金额")
                } footer: {
                    if entry.supportsMainAmountEditing {
                        Text(parsedAmount == nil ? "请输入大于 0 且最多两位小数的金额。" : "金额会同步应用到来源与目标分录。")
                            .foregroundStyle(parsedAmount == nil ? LedgerPalette.risk : LedgerPalette.secondary)
                    } else {
                        Text("该交易包含拆分、多币种或价格信息，当前保留原分录金额。")
                    }
                }
                Section {
                    TextField("空格或逗号分隔", text: $tagsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .tags)
                        .accessibilityIdentifier("import-edit-tags")

                    if let tags = suggestion?.tags, !tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(tags.filter { $0.probability >= 0.5 }, id: \.value) { tag in
                                    Button {
                                        var current = tagsText.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
                                        if current.contains(tag.value) {
                                            current.removeAll { $0 == tag.value }
                                        } else {
                                            current.append(tag.value)
                                        }
                                        tagsText = current.joined(separator: " ")
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text("#\(tag.value)")
                                            Text("\(Int((tag.probability * 100).rounded()))%")
                                                .font(.caption2)
                                                .opacity(0.8)
                                        }
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(tagsText.contains(tag.value) ? LedgerPalette.olive.opacity(0.15) : Color.secondary.opacity(0.1))
                                        .foregroundStyle(tagsText.contains(tag.value) ? LedgerPalette.olive : LedgerPalette.ink)
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text("标签")
                } footer: {
                    if parsedTags == nil {
                        Text("标签仅支持字母、数字、下划线和连字符，单个最长 64 个字符。")
                            .foregroundStyle(LedgerPalette.risk)
                    } else {
                        Text("保存后返回核对，确认导入时才会写入账本。")
                    }
                }
            }
            .accessibilityIdentifier("import-edit-content")
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("编辑交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: requestDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存修改", action: save)
                        .disabled(!canSave)
                        .accessibilityIdentifier("import-edit-save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                        .accessibilityIdentifier("import-edit-keyboard-done")
                }
            }
        }
        .privacySensitive()
        .interactiveDismissDisabled(hasChanges)
        .alert("放弃交易修改？", isPresented: $discardConfirmationPresented) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("这条交易将保留打开编辑页时的内容。")
        }
    }

    private func requestDismiss() {
        focusedField = nil
        if hasChanges { discardConfirmationPresented = true }
        else { dismiss() }
    }

    private func save() {
        guard canSave else { return }
        focusedField = nil
        let updated = entry.applyingReviewEdits(
            date: Self.formatDate(date),
            flag: flag,
            payee: payee,
            narration: narration,
            amount: parsedAmount ?? entry.amount,
            categoryAccount: categoryAccount,
            fundingAccount: fundingAccount,
            tags: parsedTags ?? entry.tags ?? []
        )
        onSave(updated)
        dismiss()
    }

    private func accountChoice(_ account: String) -> LedgerAccountChoice {
        accounts.first(where: { $0.account == account })
            ?? LedgerAccountChoice(account: account, label: account, group: "current", active: true)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func amountText(_ amount: Double, fixedToMinorUnits: Bool) -> String {
        if fixedToMinorUnits {
            return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)
        }
        return String(amount)
    }
}

private struct ImportEntryReviewRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: LedgerImportEntry
    let included: Bool
    let tagSelected: Bool
    let isAIClassified: Bool
    let categoryLabel: String
    let fundingLabel: String
    let onToggle: () -> Void
    let onToggleTag: () -> Void
    let onEdit: () -> Void

    @State private var expanded = false

    private var categoryMissing: Bool {
        entry.categoryAccount.isEmpty || entry.categoryAccount.lowercased().contains("unknown")
    }

    private var fundingMissing: Bool {
        entry.fundingAccount.isEmpty || entry.fundingAccount.lowercased().contains("unknown")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: LedgerSpacing.sm) {
                Button(action: onToggle) {
                    Image(systemName: included ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(included ? LedgerPalette.cobalt : LedgerPalette.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel(included ? "排除 \(entry.payee)" : "包含 \(entry.payee)")
                .accessibilityIdentifier("import-entry-toggle-\(entry.id)")

                Button {
                    expanded.toggle()
                } label: {
                    HStack(alignment: .center, spacing: LedgerSpacing.sm) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.payee.isEmpty ? "未命名交易" : entry.payee)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(LedgerPalette.ink)
                                .lineLimit(1)
                            Text("\(entry.date) · \(entry.narration.isEmpty ? "无摘要" : entry.narration)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(LedgerPalette.secondary)
                                .lineLimit(1)
                            HStack(alignment: .center, spacing: 5) {
                                Text(categoryLabel)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(categoryMissing ? LedgerPalette.risk : LedgerPalette.cobalt)
                                    .lineLimit(1)

                                Image(systemName: "arrow.left")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.secondary.opacity(0.6))

                                Text(fundingLabel)
                                    .font(.caption)
                                    .foregroundStyle(fundingMissing ? LedgerPalette.risk : LedgerPalette.olive)
                                    .lineLimit(1)

                                if isAIClassified {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 9))
                                        .foregroundStyle(LedgerPalette.cobalt)
                                }

                                if let tags = entry.tags, !tags.isEmpty {
                                    Spacer(minLength: 4)
                                    Text(tags.prefix(2).map { "#\($0)" }.joined(separator: " "))
                                        .font(.caption2)
                                        .foregroundStyle(LedgerPalette.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ViewThatFits(in: .horizontal) {
                            Text(importAmountText(entry))
                                .fixedSize(horizontal: true, vertical: false)
                            Text(importCompactAmountText(entry))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(included ? LedgerPalette.warm : LedgerPalette.secondary)
                        .accessibilityLabel(importAmountText(entry))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LedgerPalette.secondary)
                            .frame(width: 18)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("import-entry-\(entry.id)")

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.body)
                        .foregroundStyle(LedgerPalette.cobalt)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("编辑 \(entry.payee.isEmpty ? "未命名交易" : entry.payee)")
                .accessibilityIdentifier("import-entry-edit-\(entry.id)")
            }

            if expanded {
                VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                    Button(action: onToggleTag) {
                        Label(tagSelected ? "已选为标签操作对象" : "选择为标签操作对象",
                              systemImage: tagSelected ? "tag.fill" : "tag")
                            .font(.subheadline)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(tagSelected ? "取消选择 \(entry.payee) 的标签操作" : "选择 \(entry.payee) 的标签操作")
                    .accessibilityIdentifier("import-entry-tag-toggle-\(entry.id)")
                    ImportEntryDetailLine(label: "分类账户", value: entry.categoryAccount)
                    ImportEntryDetailLine(label: "资金账户", value: entry.fundingAccount)
                    ForEach(Array(entry.postings.enumerated()), id: \.offset) { _, posting in
                        ImportEntryDetailLine(
                            label: posting.amount + " " + posting.currency,
                            value: posting.account
                        )
                    }
                    if let method = entry.method, !method.isEmpty {
                        ImportEntryDetailLine(label: "支付方式", value: method)
                    }
                    if let orderID = entry.orderID, !orderID.isEmpty {
                        ImportEntryDetailLine(label: "订单号", value: orderID)
                    }
                    if let tags = entry.tags, !tags.isEmpty {
                        ImportEntryDetailLine(label: "标签", value: tags.map { "#\($0)" }.joined(separator: " "))
                    }
                }
                .padding(.leading, 52)
                .padding(.bottom, LedgerSpacing.lg)
                .transition(.opacity)
            }
        }
        .opacity(included ? 1 : 0.58)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: expanded)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: included)
    }

    private func importAmountText(_ entry: LedgerImportEntry) -> String {
        let minorUnits = Int((entry.amount * 100).rounded())
        return MoneyText.format(minorUnits: minorUnits, currency: entry.currency)
    }

    private func importCompactAmountText(_ entry: LedgerImportEntry) -> String {
        let minorUnits = Int((entry.amount * 100).rounded())
        return MoneyText.formatCompact(minorUnits: minorUnits, currency: entry.currency)
    }
}

private struct ImportEntryDetailLine: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(LedgerPalette.secondary)
            Text(value)
                .font(.subheadline.monospaced())
                .foregroundStyle(LedgerPalette.olive)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
