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
    @State private var reviewFilter: ImportReviewFilter?
    @State private var bulkTagInput = ""
    @State private var bulkCategory = ""
    @State private var batchSheetPresented = false
    @State private var parseOptionsPresented = false
    @State private var parseOptionsApplied = false
    @State private var optionsBeforeSheet: (provider: String?, rounding: Bool)?
    @State private var pendingInboxPresented = false
    @State private var autoStartAttempted = false
    @State private var committedEntries: [LedgerImportEntry] = []
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
        if commitResult != nil { return String(localized: "导入完成") }
        if preview != nil { return String(localized: "核对交易") }
        return String(localized: "导入账单")
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
        if commitOutcomeNeedsReconciliation { return String(localized: "离开保存结果核对？") }
        return pendingExit == .preparation ? String(localized: "重新生成预览？") : String(localized: "离开核对？")
    }

    private var exitConfirmationDetail: String {
        if commitOutcomeNeedsReconciliation {
            return String(localized: "账本可能已完成写入。离开后请先查看导入记录，确认结果再继续操作。")
        }
        if pendingExit == .preparation {
            return String(localized: "按新的解析选项重新生成预览，本次核对修改会清除。")
        }
        return canKeepDraft
            ? String(localized: "保留草稿后，可以从导入页的「待处理」继续核对。原始账单文件保留。")
            : String(localized: "本次尚未提交的设置和核对修改将被清除，原始账单文件保留。")
    }

    /// File-backed reviews persist as a draft; a Gmail preview has no file to reopen,
    /// and drafts are stored per local ledger, so a remote ledger cannot keep one.
    private var canKeepDraft: Bool {
        !startsWithPreview && !file.data.isEmpty && preview != nil && !commitOutcomeNeedsReconciliation
            && session.currentLocalLedgerDescriptor != nil
    }

    private var reviewQueue: ImportReviewQueue {
        ImportReviewQueue(entries: reviewedEntries, included: includedEntryIDs, needsReview: classificationNeedsReview)
    }

    private var activeFilter: ImportReviewFilter {
        reviewFilter ?? reviewQueue.defaultFilter
    }

    /// Parsing starts on its own unless the file needs something first: a ZIP
    /// may need its password, and a failed attempt waits for the person.
    private var showsParsing: Bool {
        isPreparing || (!autoStartAttempted && !startsWithPreview && !file.isZIP && errorMessage == nil)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let commitResult {
                    completionView(commitResult)
                } else if let preview {
                    previewView(preview)
                } else if showsParsing {
                    parsingView
                } else {
                    preparationView
                }
            }
            .background(BalancedPalette.page)
            .alert(exitConfirmationTitle, isPresented: Binding(
                get: { pendingExit != nil },
                set: { if !$0 { pendingExit = nil } }
            ), presenting: pendingExit) { action in
                if action == .close, canKeepDraft {
                    Button("保留草稿") {
                        pendingExit = nil
                        persistDraft()
                        dismiss()
                    }
                    .accessibilityIdentifier("import-exit-keep-draft")
                }
                Button(commitOutcomeNeedsReconciliation ? "离开核对" : (action == .preparation ? "重新生成" : "放弃修改"),
                       role: .destructive) {
                    pendingExit = nil
                    discardDraft()
                    performExit(action)
                }
                Button("继续编辑", role: .cancel) {
                    if action == .preparation { restoreParseOptions() }
                    pendingExit = nil
                }
            } message: { _ in
                Text(exitConfirmationDetail)
            }
            .navigationTitle(currentTitle)
            .terminalNativeChrome()
            .navigationBarTitleDisplayMode(.inline)

            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if preview != nil, commitResult == nil {
                        Button(startsWithPreview ? "关闭" : "返回") { requestExit(.close) }
                            .disabled(isCommitting)
                    } else if commitResult == nil {
                        Button("取消") { requestExit(.close) }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if preview != nil, commitResult == nil {
                        if !startsWithPreview, !file.data.isEmpty {
                            Button {
                                optionsBeforeSheet = (providerOverride, alipayFundRounding)
                                parseOptionsApplied = false
                                parseOptionsPresented = true
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .disabled(isCommitting)
                            .accessibilityLabel("解析选项")
                            .accessibilityIdentifier("import-parse-options")
                        }
                        if let ledgerID = session.currentLocalLedgerDescriptor?.id {
                            NavigationLink {
                                ImportClassificationSettingsView(ledgerID: ledgerID)
                            } label: {
                                Image(systemName: "sparkles")
                            }
                            .accessibilityLabel("智能分类设置")
                            .accessibilityIdentifier("import-classification-settings")
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isCommitting || hasDraftChanges)
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
                evidence: classificationEvidence[entry.id] ?? [],
                position: editorPosition(for: entry.id),
                onSave: { updated in
                    applyEditedEntry(updated)
                },
                onSaveAndNext: { updated in
                    // The saved entry may leave the filter, so find its successor first.
                    let next = nextEditorID(from: entry.id, offset: 1)
                    applyEditedEntry(updated)
                    openEditor(next)
                },
                onStep: { offset in
                    openEditor(nextEditorID(from: entry.id, offset: offset))
                }
            )
            .id(entry.id)
            .ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: $batchSheetPresented) {
            batchSheet
                .presentationDetents([.medium, .large])
                .ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: $parseOptionsPresented, onDismiss: {
            if !parseOptionsApplied { restoreParseOptions() }
        }) {
            parseOptionsSheet
                .presentationDetents([.medium, .large])
                .ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: $pendingInboxPresented) {
            PendingInboxView()
                .environmentObject(session)
                .ledgerPrivacyProtectedSheet()
        }
        .sheet(item: $preparedBookkeeping) { prepared in
            BookkeepingPreviewView(preview: prepared, entryCount: committedEntries.count) { result in
                guard let result else { return }
                commitResult = result
                discardDraft()
                onCommitted(result)
            }
        }
        .sensoryFeedback(.success, trigger: editSaveFeedback)
        .sensoryFeedback(.error, trigger: failureFeedback)
        .ledgerPrivacyProtectedSheet()
        .task {
            restoreDraftIfAvailable()
            await startPreviewIfNeeded()
        }
        .task(id: classificationTaskID) { await classifyPreview() }
        .onChange(of: providerOverride) { _, _ in persistDraft() }
        .onChange(of: alipayFundRounding) { _, _ in persistDraft() }
        .onChange(of: reviewFilter) { _, filter in
            onlyClassificationReview = filter == .pending
            persistDraft()
        }
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
            try Task.checkCancellation()
            guard session.currentLocalLedgerDescriptor?.id == ledgerID, !session.privacyShielded else { return }
            let accounts = session.ledger?.accounts ?? []
            let entries = reviewedEntries
            try await BookkeepingPipeline.classifyImports(entries, accounts: accounts,
                evidence: { try await session.classificationEvidence(for: $0) },
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
                classificationManualReasons[entry.id] = String(localized: "这笔交易包含复杂分录或缺少可用账户，请打开编辑核对。")
                persistDraft()
            }, accept: { job, result, updated in
                let entry = job.entry
                guard let index = reviewedEntries.firstIndex(where: { $0.id == entry.id }) else { return }
                classificationResults[entry.id] = result
                classificationEvidence[entry.id] = job.input.history
                classificationCompletedIDs.insert(entry.id)
                classificationOriginals[entry.id] = entry
                reviewedEntries[index] = updated
                persistDraft()
            })
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            classificationError = (error as? ImportClassificationError)?.localizedDescription
                ?? String(localized: "智能分类暂时不可用，已完成的建议保留，你可以继续核对或重试。")
        }
    }

    private var importDraftStore: LedgerImportDraftStore { .shared }

    private func restoreDraftIfAvailable() {
        guard !startsWithPreview, preview == nil,
              let ledgerID = session.currentLocalLedgerDescriptor?.id,
              let draft = importDraftStore.load(ledgerID: ledgerID),
              draft.fileID == file.id else { return }
        providerOverride = draft.providerOverride
        alipayFundRounding = draft.alipayFundRounding
        preview = draft.preview
        reviewedEntries = draft.reviewedEntries
        includedEntryIDs = draft.includedEntryIDs
        classificationResults = draft.classificationResults
        classificationOriginals = draft.classificationOriginals
        manuallyReviewedIDs = draft.manuallyReviewedIDs
        classificationCompletedIDs = draft.classificationCompletedIDs
        classificationAcceptedFields = draft.classificationAcceptedFields
        classificationManualReasons = draft.classificationManualReasons
        classificationEvidence = draft.classificationEvidence
        onlyClassificationReview = draft.onlyClassificationReview
    }

    private func persistDraft() {
        guard commitResult == nil,
              let ledgerID = session.currentLocalLedgerDescriptor?.id,
              !file.data.isEmpty else { return }
        let draft = LedgerImportDraft(
            ledgerID: ledgerID,
            file: file,
            providerOverride: providerOverride,
            alipayFundRounding: alipayFundRounding,
            preview: preview,
            reviewedEntries: reviewedEntries,
            includedEntryIDs: includedEntryIDs,
            classificationResults: classificationResults,
            classificationOriginals: classificationOriginals,
            manuallyReviewedIDs: manuallyReviewedIDs,
            classificationCompletedIDs: classificationCompletedIDs,
            classificationAcceptedFields: classificationAcceptedFields,
            classificationManualReasons: classificationManualReasons,
            classificationEvidence: classificationEvidence,
            onlyClassificationReview: onlyClassificationReview
        )
        try? importDraftStore.save(draft)
    }

    private func discardDraft() {
        guard let ledgerID = session.currentLocalLedgerDescriptor?.id else { return }
        importDraftStore.remove(ledgerID: ledgerID)
    }

    @ViewBuilder
    private func classificationRow(_ entry: LedgerImportEntry) -> some View {
        if let result = classificationResults[entry.id] {
            let pending = result.pendingFields(for: entry, accepted: classificationAcceptedFields[entry.id] ?? [])
            DisclosureGroup {
                LabeledContent("交易性质", value: ImportClassificationSuggestion.natureLabels[result.nature.value] ?? String(localized: "待判断"))
                classificationAccountChoices(String(localized: "付款 / 收款账户"), field: "funding", entry: entry,
                                             current: entry.fundingAccount, decision: result.funding)
                classificationAccountChoices(String(localized: "分类 / 对应账户"), field: "category", entry: entry,
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
            errorMessage = String(localized: "资金账户和对应账户需使用不同账户，请打开编辑同时调整。")
            return
        }
        reviewedEntries[index] = updated
        acceptClassificationField(field, entryID: entry.id)
        persistDraft()
    }

    private func applyClassificationTag(_ tag: String, to entry: LedgerImportEntry) {
        var tags = entry.tags ?? []
        if tags.contains(tag) { tags.removeAll { $0 == tag } } else { tags.append(tag) }
        guard let checked = try? LedgerTagRules.validating(tags),
              let index = reviewedEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        reviewedEntries[index] = entry.applyingTags(checked)
        manuallyReviewedIDs.insert(entry.id)
        if classificationNeedsReview.isEmpty { onlyClassificationReview = false }
        persistDraft()
    }

    private func acceptClassificationField(_ field: String, entryID: String) {
        classificationAcceptedFields[entryID, default: []].insert(field)
        manuallyReviewedIDs.insert(entryID)
        if classificationNeedsReview.isEmpty { onlyClassificationReview = false }
        persistDraft()
    }

    private func requestExit(_ action: ImportExitAction) {
        guard !isCommitting else { return }
        let needsConfirmation = action == .preparation ? hasReviewChanges : hasDraftChanges
        if needsConfirmation {
            pendingExit = action
        } else {
            discardDraft()
            performExit(action)
        }
    }

    /// `.close` leaves the flow (a running parse is cancelled with the view);
    /// `.preparation` drops the review and parses again with the current options.
    private func performExit(_ action: ImportExitAction) {
        guard !isCommitting else { return }
        if action == .close {
            dismiss()
        } else {
            preview = nil
            reviewedEntries = []
            includedEntryIDs = []
            reviewFilter = nil
            bulkTagInput = ""
            errorMessage = nil
            commitErrorMessage = nil
            commitOutcomeNeedsReconciliation = false
            commitWasReconciled = false
            editedEntryStatus = nil
            resetClassification()
            optionsBeforeSheet = nil
            Task { await generatePreview() }
        }
    }

    private func restoreParseOptions() {
        guard let optionsBeforeSheet else { return }
        providerOverride = optionsBeforeSheet.provider
        alipayFundRounding = optionsBeforeSheet.rounding
        self.optionsBeforeSheet = nil
    }

    private func startPreviewIfNeeded() async {
        guard !autoStartAttempted, !startsWithPreview, preview == nil, !file.isZIP, !file.data.isEmpty else { return }
        autoStartAttempted = true
        await generatePreview()
    }

    /// The file being imported, as the head of the parsing and input steps.
    private var fileHead: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.name).balancedFont(size: 15.5, weight: .medium).foregroundStyle(BalancedPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(fileSizeText).balancedFont(size: 12.5).monospacedDigit().foregroundStyle(BalancedPalette.meta)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    /// Picking a file starts parsing straight away; this page names what the
    /// one parse call is checking, without inventing progress it can't report.
    private var parsingView: some View {
        List {
            Section { fileHead }
            Section {
                parsingStep(String(localized: "读取文件"), detail: fileSizeText, state: .done)
                parsingStep(String(localized: "识别渠道并解析交易"),
                            detail: providerOverride.map { String(localized: "指定渠道 · \(providerLabel($0))") }
                                ?? String(localized: "自动识别 · 可在核对页改选渠道"),
                            state: .running)
                parsingStep(String(localized: "与账本比对重复"), detail: String(localized: "同日同额的交易默认排除"), state: .waiting)
                parsingStep(String(localized: "智能分类"), detail: String(localized: "进入核对页后在后台继续，不需要等"), state: .waiting)
            } footer: {
                Text("离开这一页会停止解析，原始账单文件保留。")
                    .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listRowSeparatorTint(BalancedPalette.rule)
        .accessibilityIdentifier("native-import-parsing")
    }

    private enum ParsingStepState { case done, running, waiting }

    private func parsingStep(_ title: String, detail: String, state: ParsingStepState) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(BalancedPalette.ink)
                case .running:
                    ProgressView().controlSize(.small).tint(BalancedPalette.ink)
                case .waiting:
                    Image(systemName: "circle").foregroundStyle(BalancedPalette.edge)
                }
            }
            .font(.system(size: 15))
            .frame(width: 22, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).balancedFont(size: 15, weight: state == .waiting ? .regular : .medium)
                    .foregroundStyle(state == .waiting ? BalancedPalette.meta : BalancedPalette.ink)
                Text(detail).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    /// Only reached when parsing can't go on by itself: a ZIP that may need
    /// its password, or a failed attempt. The options the old preparation page
    /// always showed live here and in the review page's 解析选项.
    private var preparationView: some View {
        List {
            Section { fileHead }

            if let errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("没能生成预览").balancedFont(size: 15, weight: .semibold).foregroundStyle(BalancedPalette.ink)
                        Text(errorMessage).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("检查文件或手动指定渠道后重试。").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("import-preview-error")
                }
            }

            if file.isZIP {
                Section {
                    SecureField("输入账单压缩包密码", text: $archivePassword)
                        .balancedFont(size: 15)
                        .textContentType(.password)
                        .accessibilityIdentifier("import-archive-password")
                } header: {
                    TerminalSectionLabel(text: String(localized: "压缩包密码")).listRowBackground(BalancedPalette.page)
                } footer: {
                    Text("没有密码的压缩包留空即可。密码只用于这次解压，不会保存。")
                        .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                }
            }

            parseOptionsSections
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listRowSeparatorTint(BalancedPalette.rule)
        .tint(BalancedPalette.ink)
        .disabled(isPreparing)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("native-import-preparation")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                Task { await generatePreview() }
            } label: {
                Text(errorMessage == nil ? "继续解析" : "重新解析")
            }
            .buttonStyle(.balanced(.primary, disabled: isPreparing))
            .disabled(isPreparing)
            .accessibilityIdentifier("import-generate-preview")
            .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
            .ledgerGlassDock()
        }
    }

    /// Channel and Alipay rounding: shared by the input step and the review
    /// page's 解析选项 sheet.
    @ViewBuilder
    private var parseOptionsSections: some View {
        Section {
            Picker("账单渠道", selection: $providerOverride) {
                Text("自动识别").tag(String?.none)
                ForEach(LedgerMobileImportCapabilities.fileImportProviders(from: providers)) { provider in
                    Text(provider.label).tag(Optional(provider.id))
                }
            }
            .balancedFont(size: 15).tint(BalancedPalette.ink)
            .accessibilityIdentifier("import-provider-menu")
        } header: {
            TerminalSectionLabel(text: String(localized: "解析选项")).listRowBackground(BalancedPalette.page)
        } footer: {
            Text(selectedProviderDetail).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
        }

        if providerOverride == nil || providerOverride == "alipay" {
            Section {
                Toggle("支付宝基金 9.99 → 10.00 补差", isOn: $alipayFundRounding)
                    .balancedFont(size: 15).toggleStyle(BalancedToggleStyle())
            } footer: {
                Text("仅在确认该基金定投需要补 0.01 时开启。").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
            }
        }
    }

    private var parseOptionsSheet: some View {
        NavigationStack {
            List {
                parseOptionsSections
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(BalancedPalette.page)
            .tint(BalancedPalette.ink)
            .navigationTitle("解析选项")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("会按新的选项重新生成预览，本次核对修改会清除。")
                        .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    HStack(spacing: 10) {
                        Button("取消") { parseOptionsPresented = false }
                            .buttonStyle(.balanced(.outline))
                        Button("重新生成预览") {
                            parseOptionsApplied = true
                            parseOptionsPresented = false
                            requestExit(.preparation)
                        }
                        .buttonStyle(.balanced(.primary))
                        .accessibilityIdentifier("import-parse-options-apply")
                    }
                }
                .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                .ledgerGlassDock()
            }
        }
    }

    private func friendlyAccountLabel(_ account: String) -> String {
        if account.isEmpty { return String(localized: "待指定账户") }
        if let match = session.ledger?.accounts.first(where: { $0.account == account }) {
            if let alias = match.alias, !alias.isEmpty { return alias }
            if !match.label.isEmpty { return match.label }
        }
        return account.split(separator: ":").last.map(String.init) ?? account
    }

    private func previewView(_ preview: LedgerImportPreview) -> some View {
        let needsReview = classificationNeedsReview
        let queue = ImportReviewQueue(entries: reviewedEntries, included: includedEntryIDs, needsReview: needsReview)
        let filter = reviewFilter ?? queue.defaultFilter
        return List {
            if let errorMessage {
                Section {
                    StatusBanner(message: errorMessage) { self.errorMessage = nil }
                }
            }
            previewSummary(preview)
            reviewFilterBar(queue, selected: filter)
            entrySection(filter, ids: queue.ids(for: filter), needsReview: needsReview)
        }
        .ledgerReadingList()
        .contentMargins(.top, LedgerLayout.pageTopInset, for: .scrollContent)
        .tint(BalancedPalette.ink)
        .disabled(isCommitting)
        .accessibilityIdentifier("native-import-preview")
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            commitBar(preview)
        }
    }

    /// `.settle` filter-result block (b15/b16): 已勾选 N/M, 勾选金额合计, 重复已
    /// 跳过, 将写入 — the one verified total on this screen. Dedup, warnings
    /// and detection detail fold into one disclosure under it.
    private func previewSummary(_ preview: LedgerImportPreview) -> some View {
        let currency = reviewedEntries.first?.currency ?? "CNY"
        let selectedTotal = selectedEntries.reduce(0) { $0 + Int(($1.amount * 100).rounded()) }
        return Section {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(providerLabel(preview.provider) + " · " + importRangeText(preview))
                        .balancedFont(size: 12.5, weight: .medium).foregroundStyle(BalancedPalette.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("已勾选 \(selectedEntries.count) / \(reviewedEntries.count)")
                        .balancedFont(size: 12.5).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                }.padding(.bottom, 14)
                settleRow(String(localized: "勾选金额合计"), amountText(selectedTotal, currency: currency))
                settleRow(String(localized: "重复，已跳过"), amountText(preview.skippedDuplicateCount, currency: "", suffix: String(localized: " 行")))
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("将写入").balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    Spacer(minLength: 0)
                    Text("\(selectedEntries.count) 笔")
                        .font(.custom(BalancedWeight.medium.sansPostscriptName, size: 22, relativeTo: .title2))
                        .monospacedDigit().foregroundStyle(BalancedPalette.ink).lineLimit(1).fixedSize()
                }
                .padding(.top, 14)
                .overlay(alignment: .top) { BalancedPalette.ink.frame(height: 1) }
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BalancedPalette.sunken)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("import-preview-summary")
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            DisclosureGroup(isExpanded: $warningsExpanded) {
                if preview.skippedDuplicateCount > 0, !preview.dedupReport.isEmpty {
                    Text(preview.dedupReport).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                kvRow(String(localized: "识别渠道"), providerLabel(preview.provider))
                kvRow(String(localized: "交易区间"), importRangeText(preview))
                kvRow(String(localized: "候选交易"), String(localized: "\(preview.candidateCount) 条"))
                if preview.skippedDuplicateCount > 0 { kvRow(String(localized: "已跳过重复"), String(localized: "\(preview.skippedDuplicateCount) 条")) }
                if !preview.providerDetection.reason.isEmpty {
                    Text(preview.providerDetection.reason).balancedFont(size: 11.5).foregroundStyle(BalancedPalette.meta)
                }
                ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.ink)
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
                }
            } label: {
                Text(previewDetailTitle(preview)).balancedFont(size: 13).foregroundStyle(BalancedPalette.secondary)
            }
            .tint(BalancedPalette.ink)
            .listRowBackground(BalancedPalette.page)
            .accessibilityIdentifier("import-preview-details")

            if let ledgerID = session.currentLocalLedgerDescriptor?.id,
               classificationSettings.isEnabled(for: ledgerID) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if isClassifying {
                            ProgressView().scaleEffect(0.8)
                            Text("智能分类 \(classificationCompletedIDs.count) / \(reviewedEntries.count)")
                                .balancedFont(size: 12.5).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                            Spacer()
                            Button("停止") { classificationPaused = true }.balancedFont(size: 12.5).foregroundStyle(BalancedPalette.ink)
                        } else {
                            Text(classificationResults.isEmpty ? "智能分类已就绪" : "智能分类已完成 · \(classificationResults.count) 笔已填写")
                                .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                            Spacer()
                            if classificationCompletedIDs.count < reviewedEntries.count {
                                Button("继续分类") {
                                    classificationError = nil
                                    classificationPaused = false
                                    classificationRetry &+= 1
                                }.balancedFont(size: 12.5).foregroundStyle(BalancedPalette.ink)
                            }
                        }
                    }
                    if let classificationError {
                        Text(classificationError).balancedFont(size: 12).foregroundStyle(BalancedPalette.secondary)
                    }
                }
                .listRowBackground(BalancedPalette.page)
            }
        }
    }

    private func previewDetailTitle(_ preview: LedgerImportPreview) -> String {
        var parts: [String] = []
        if preview.skippedDuplicateCount > 0 {
            parts.append(String(localized: "\(preview.skippedDuplicateCount) 行与账本重复，已跳过"))
        }
        if !preview.warnings.isEmpty {
            parts.append(String(localized: "\(preview.warnings.count) 条核对提示"))
        }
        return parts.isEmpty ? String(localized: "解析详情") : parts.joined(separator: " · ")
    }

    private func settleRow(_ label: String, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).balancedFont(size: 15).foregroundStyle(BalancedPalette.secondary)
            Spacer(minLength: 0)
            value.lineLimit(1).fixedSize()
        }.padding(.vertical, 6)
    }

    private func amountText(_ minorUnits: Int, currency: String, suffix: String = "") -> Text {
        let formatted = currency.isEmpty ? "\(minorUnits)\(suffix)" : MoneyText.format(minorUnits: minorUnits, currency: currency, showsCurrency: false) + suffix
        return Text(formatted)
            .font(.custom(BalancedWeight.text.sansPostscriptName, size: 15, relativeTo: .body))
            .monospacedDigit().foregroundColor(BalancedPalette.ink)
    }

    private func kvRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
            Spacer()
            Text(value).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary)
        }
    }

    /// 待确认 / 已就绪 / 未勾选 / 全部 as one glass segment: the page opens on
    /// the entries that need the person, so the rest can be written as they are.
    private func reviewFilterBar(_ queue: ImportReviewQueue, selected: ImportReviewFilter) -> some View {
        Section {
            HStack(spacing: 2) {
                ForEach(ImportReviewFilter.allCases) { filter in
                    let isSelected = filter == selected
                    Button {
                        reviewFilter = filter
                    } label: {
                        HStack(spacing: 4) {
                            Text(filter.title).balancedFont(size: 14, weight: isSelected ? .semibold : .regular)
                            Text("\(queue.count(for: filter))").balancedFont(size: 11.5).monospacedDigit()
                                .foregroundStyle(BalancedPalette.meta)
                        }
                        .foregroundStyle(isSelected ? BalancedPalette.ink : BalancedPalette.meta)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background {
                            if isSelected { Capsule().fill(BalancedPalette.ink.opacity(0.08)) }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("import-filter-\(filter.rawValue)")
                }
            }
            .padding(3)
            .ledgerGlassField()
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func entrySection(_ filter: ImportReviewFilter, ids: [String], needsReview: Set<String>) -> some View {
        let entriesByID = Dictionary(reviewedEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Section {
            if ids.isEmpty {
                Text(emptyFilterText(filter))
                    .balancedFont(size: 13.5).foregroundStyle(BalancedPalette.meta)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("import-filter-empty")
            }
            ForEach(ids, id: \.self) { id in
                if let entry = entriesByID[id] {
                    ImportEntryReviewRow(
                        entry: entry,
                        included: includedEntryIDs.contains(entry.id),
                        isAIClassified: classificationResults[entry.id] != nil,
                        categoryLabel: friendlyAccountLabel(entry.categoryAccount),
                        attention: attentionText(for: entry, needsReview: needsReview),
                        picks: categoryPicks(for: entry),
                        canConfirm: needsReview.contains(entry.id) && classificationResults[entry.id] != nil
                            && !ImportReviewQueue.needsAccount(entry),
                        onToggle: { toggle(entry.id) },
                        onEdit: { editingEntry = entry },
                        onPick: { account in applyClassificationAccount(account, field: "category", to: entry) },
                        onConfirm: { applyEditedEntry(entry) }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--safe-classification-review") {
                        classificationRow(entry)
                    }
#endif
                }
            }
        } footer: {
            Text("点按勾选框决定是否写入；点按一行其余位置打开编辑。")
                .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                .padding(.top, 8)
        }
    }

    private func emptyFilterText(_ filter: ImportReviewFilter) -> String {
        switch filter {
        case .pending: String(localized: "没有需要确认的交易，可以直接写入。")
        case .ready: String(localized: "还没有已就绪的交易。先处理待确认的几笔。")
        case .unchecked: String(localized: "所有交易都已勾选。")
        case .all: String(localized: "这份账单没有可导入的交易。不勾选任何交易时，只归档原始账单。")
        }
    }

    /// Why an included entry still waits for the person, in the order they'd fix it.
    private func attentionText(for entry: LedgerImportEntry, needsReview: Set<String>) -> String? {
        guard includedEntryIDs.contains(entry.id) else { return nil }
        if let reason = classificationManualReasons[entry.id] { return reason }
        if ImportReviewQueue.isMissingAccount(entry.categoryAccount) { return String(localized: "缺少分类") }
        if ImportReviewQueue.isMissingAccount(entry.fundingAccount) { return String(localized: "缺少付款账户") }
        if needsReview.contains(entry.id) { return String(localized: "AI 填写 · 待确认") }
        return nil
    }

    /// The classifier's top category candidates for an entry whose category is
    /// still open, as one-tap picks on the row.
    private func categoryPicks(for entry: LedgerImportEntry) -> [ImportEntryPick] {
        guard includedEntryIDs.contains(entry.id), let result = classificationResults[entry.id],
              result.pendingFields(for: entry, accepted: classificationAcceptedFields[entry.id] ?? []).contains("category")
        else { return [] }
        return result.category.candidates.prefix(2).map {
            ImportEntryPick(account: $0.value, label: friendlyAccountLabel($0.value),
                            probability: $0.probability, selected: $0.value == entry.categoryAccount)
        }
    }

    private var batchTargetIDs: Set<String> {
        Set(reviewQueue.ids(for: activeFilter)).intersection(includedEntryIDs)
    }

    private var bulkCategoryChoices: [LedgerAccountChoice] {
        (session.ledger?.accounts ?? [])
            .filter { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") }
            .map { account in
                LedgerAccountChoice(account: account.account,
                                    label: account.alias?.isEmpty == false ? account.alias! : account.label,
                                    group: account.group, active: account.active)
            }
    }

    /// One selection model: batch edits act on the entries that are checked
    /// for writing within the current filter.
    private var batchSheet: some View {
        let targets = batchTargetIDs
        let uncheckedCount = reviewedEntries.count - includedEntryIDs.count
        return NavigationStack {
            List {
                Section {
                    TextField("travel, trip-2026", text: $bulkTagInput)
                        .balancedFont(size: 15)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("import-bulk-tag-input")
                    HStack(spacing: 10) {
                        Button("添加标签") { applyBulkTags(mode: .add, to: targets) }
                            .buttonStyle(.balanced(.primary, disabled: targets.isEmpty))
                            .disabled(targets.isEmpty)
                            .accessibilityIdentifier("import-bulk-tag-add")
                        Button("移除标签") { applyBulkTags(mode: .remove, to: targets) }
                            .buttonStyle(.balanced(.outline, disabled: targets.isEmpty))
                            .disabled(targets.isEmpty)
                            .accessibilityIdentifier("import-bulk-tag-remove")
                    }
                    .listRowSeparator(.hidden)
                } header: {
                    TerminalSectionLabel(text: String(localized: "标签")).listRowBackground(BalancedPalette.page)
                } footer: {
                    Text("作用于「\(activeFilter.title)」里已勾选的 \(targets.count) 笔。")
                        .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                }

                Section {
                    NavigationLink {
                        LedgerAccountPicker(title: String(localized: "选择分类账户"), accounts: bulkCategoryChoices, selection: $bulkCategory)
                    } label: {
                        batchRowLabel(String(localized: "统一设置分类"),
                                      String(localized: "为这 \(targets.count) 笔选择同一个分类账户"))
                    }
                    .disabled(targets.isEmpty)
                    .accessibilityIdentifier("import-bulk-category")
                    Button {
                        includedEntryIDs = Set(reviewedEntries.map(\.id))
                        persistDraft()
                    } label: {
                        batchRowLabel(String(localized: "全部勾选"), String(localized: "把 \(uncheckedCount) 笔未勾选的也加入写入"))
                    }
                    .disabled(uncheckedCount == 0)
                    .accessibilityIdentifier("import-select-all")
                    Button {
                        includedEntryIDs = []
                        persistDraft()
                    } label: {
                        batchRowLabel(String(localized: "全部取消勾选"), String(localized: "不写入交易时，只归档原始账单"))
                    }
                    .disabled(includedEntryIDs.isEmpty)
                    .accessibilityIdentifier("import-deselect-all")
                } header: {
                    TerminalSectionLabel(text: String(localized: "也可以")).listRowBackground(BalancedPalette.page)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(BalancedPalette.page)
            .tint(BalancedPalette.ink)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("批量修改")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { batchSheetPresented = false }
                        .accessibilityIdentifier("import-batch-done")
                }
            }
            .onChange(of: bulkCategory) { _, account in
                applyBulkCategory(account, to: targets)
            }
        }
    }

    private func batchRowLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
            Text(detail).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// `.sheet-actions` on glass: status lines above 批量… and the write action.
    /// The write button stays enabled on an empty selection: 仅归档账单 is a
    /// real, supported action.
    private func commitBar(_ preview: LedgerImportPreview) -> some View {
        VStack(spacing: 10) {
            if let editedEntryStatus {
                Text(editedEntryStatus).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("import-edit-saved-status")
            }
            if let commitErrorMessage {
                VStack(alignment: .leading, spacing: 3) {
                    Text(commitOutcomeNeedsReconciliation ? "保存结果待确认" : "保存没有完成")
                        .balancedFont(size: 13, weight: .semibold).foregroundStyle(BalancedPalette.ink)
                    Text(commitErrorMessage).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("import-commit-error")
            }
            HStack(spacing: 10) {
                if !commitOutcomeNeedsReconciliation {
                    Button("批量…") { batchSheetPresented = true }
                        .buttonStyle(.balanced(.outline, disabled: isCommitting))
                        .disabled(isCommitting)
                        .accessibilityIdentifier("import-batch")
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
                    ZStack {
                        Text(commitButtonTitle).opacity(isCommitting ? 0 : 1).lineLimit(1).minimumScaleFactor(0.8)
                        if isCommitting { ProgressView().tint(BalancedPalette.page) }
                    }
                }
                .buttonStyle(.balanced(.primary))
                .disabled(isCommitting)
                .accessibilityLabel(commitButtonTitle)
                .accessibilityValue(commitButtonAccessibilityValue)
                .accessibilityHint(commitButtonAccessibilityHint)
                .accessibilityIdentifier("import-commit")
            }
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
        .ledgerGlassDock()
    }

    /// The written batch as a closed account: the double rule, the totals the
    /// person just confirmed, then where to go next.
    private func completionView(_ result: LedgerImportCommitResult) -> some View {
        let currency = committedEntries.first?.currency ?? reviewedEntries.first?.currency ?? "CNY"
        let writtenTotal = committedEntries.reduce(0) { $0 + Int(($1.amount * 100).rounded()) }
        let unclassified = committedEntries.filter { ImportReviewQueue.isMissingAccount($0.categoryAccount) }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(spacing: 2) {
                        BalancedPalette.ink.frame(width: 40, height: 1)
                        BalancedPalette.ink.frame(width: 40, height: 1)
                    }
                    .padding(.bottom, 12)
                    .accessibilityHidden(true)
                    Text(result.count == 0 ? "账单已归档" : "已写入 \(result.count) 条交易")
                        .font(.custom(BalancedWeight.medium.sansPostscriptName, size: 22, relativeTo: .title2))
                        .foregroundStyle(BalancedPalette.ink)
                    Text(completionDetail(result))
                        .balancedFont(size: 13.5).foregroundStyle(BalancedPalette.meta)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(EdgeInsets(top: 18, leading: 20, bottom: 20, trailing: 20))

                if result.count > 0 {
                    VStack(alignment: .leading, spacing: 0) {
                        if let preview {
                            Text(providerLabel(preview.provider) + " · " + importRangeText(preview))
                                .balancedFont(size: 12.5, weight: .medium).foregroundStyle(BalancedPalette.secondary)
                                .padding(.bottom, 10)
                        }
                        if !committedEntries.isEmpty {
                            settleRow(String(localized: "写入金额合计"), amountText(writtenTotal, currency: currency))
                        }
                        if reviewedEntries.count > committedEntries.count, !committedEntries.isEmpty {
                            settleRow(String(localized: "未写入"), amountText(reviewedEntries.count - committedEntries.count,
                                                                              currency: "", suffix: String(localized: " 笔")))
                        }
                        if let preview, preview.skippedDuplicateCount > 0 {
                            settleRow(String(localized: "重复，已跳过"), amountText(preview.skippedDuplicateCount, currency: "",
                                                                               suffix: String(localized: " 行")))
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text("写入").balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                            Spacer(minLength: 0)
                            Text("\(result.count) 笔")
                                .font(.custom(BalancedWeight.medium.sansPostscriptName, size: 22, relativeTo: .title2))
                                .monospacedDigit().foregroundStyle(BalancedPalette.ink)
                        }
                        .padding(.top, 12)
                        .overlay(alignment: .top) { BalancedPalette.ink.frame(height: 1) }
                    }
                    .padding(EdgeInsets(top: 16, leading: 20, bottom: 14, trailing: 20))
                    .background(BalancedPalette.sunken)
                    .accessibilityElement(children: .combine)
                }

                if result.readModelPending == true, let progress = session.importIndexProgress {
                    completionRow(
                        title: progress.phase == .indexed ? String(localized: "索引已完成") : String(localized: "正在更新索引"),
                        detail: progress.phase == .indexed ? String(localized: "最新数据已经可以查询。") : String(localized: "系统允许实时活动时会显示在灵动岛。"),
                        busy: progress.phase != .indexed
                    )
                    .accessibilityIdentifier("import-index-progress")
                }

                if let documentFile = result.documentFile {
                    completionRow(title: String(localized: "归档位置"),
                                  detail: URL(fileURLWithPath: documentFile).lastPathComponent, mono: true)
                }

                if let cleanupError = result.runtimeCleanupError, !cleanupWarningDismissed {
                    StatusBanner(message: cleanupError) { cleanupWarningDismissed = true }
                        .padding(.horizontal, 20).padding(.top, 12)
                }

                if let warning = result.gmailPendingStatusWarning, !cleanupWarningDismissed {
                    StatusBanner(message: warning) { cleanupWarningDismissed = true }
                        .padding(.horizontal, 20).padding(.top, 12)
                }

                if unclassified > 0 {
                    Text("接下来").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        .padding(EdgeInsets(top: 24, leading: 20, bottom: 6, trailing: 20))
                    Button {
                        pendingInboxPresented = true
                    } label: {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("整理 \(unclassified) 笔未分类").balancedFont(size: 15.5).foregroundStyle(BalancedPalette.ink)
                                Text("这批里分类仍是 Unknown 的交易").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                            }
                            Spacer(minLength: 0)
                            Text("待整理").balancedFont(size: 14).foregroundStyle(BalancedPalette.meta)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(BalancedPalette.edge)
                        }
                        .padding(.horizontal, 20)
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                    .accessibilityIdentifier("import-open-pending")
                }
            }
            .padding(.bottom, 24)
            .ledgerAdaptivePageWidth()
        }
        .background(BalancedPalette.page)
        .accessibilityIdentifier("native-import-complete")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("完成") { dismiss() }
                .buttonStyle(.balanced(.primary))
                .accessibilityIdentifier("import-finish")
                .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                .ledgerGlassDock()
        }
    }

    private func completionRow(title: String, detail: String, busy: Bool = false, mono: Bool = false) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).balancedFont(size: 15.5).foregroundStyle(BalancedPalette.ink)
                Group {
                    if mono {
                        Text(detail).balancedMono(size: 11.5)
                    } else {
                        Text(detail).balancedFont(size: 12.5)
                    }
                }
                .foregroundStyle(BalancedPalette.meta)
                .lineLimit(2)
            }
            Spacer(minLength: 0)
            if busy { ProgressView().controlSize(.small).tint(BalancedPalette.ink) }
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private func completionDetail(_ result: LedgerImportCommitResult) -> String {
        if commitWasReconciled {
            return String(localized: "保存响应中断，但已通过导入归档确认账本写入完成。")
        }
        guard result.readModelPending == true else { return String(localized: "账本和导入记录已经更新。") }
        return session.importIndexProgress?.phase == .indexed
            ? String(localized: "账本写入和索引更新已经完成。")
            : String(localized: "账本写入完成，正在等待索引更新。")
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
        editedEntryStatus = String(localized: "\(name.isEmpty ? String(localized: "这条交易") : "“\(name)”")的修改已保存到本次预览")
        editSaveFeedback &+= 1
        persistDraft()
    }

    private var selectedProviderDetail: String {
        guard let providerOverride else { return String(localized: "根据文件名和账单结构选择渠道") }
        return providers.first(where: { $0.id == providerOverride })?.detail ?? String(localized: "使用指定渠道生成预览")
    }

    private var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file)
    }

    private var commitActionTitle: String {
        selectedEntries.isEmpty ? String(localized: "仅归档账单") : String(localized: "写入 \(selectedEntries.count) 条交易")
    }

    private var commitButtonTitle: String {
        if isCommitting {
            return commitOutcomeNeedsReconciliation ? String(localized: "正在核对保存结果") : String(localized: "正在验证并写入账本")
        }
        if commitOutcomeNeedsReconciliation { return String(localized: "重新检查保存结果") }
        return commitErrorMessage == nil ? commitActionTitle : String(localized: "重试保存")
    }

    private var commitButtonAccessibilityValue: String {
        if isCommitting { return String(localized: "处理中") }
        if commitOutcomeNeedsReconciliation { return String(localized: "保存结果待确认") }
        return commitErrorMessage == nil ? String(localized: "可以提交") : String(localized: "上次保存失败")
    }

    private var commitButtonAccessibilityHint: String {
        if isCommitting { return String(localized: "请稍候，完成后会显示保存结果") }
        if commitOutcomeNeedsReconciliation { return String(localized: "只检查导入归档，不会再次提交") }
        return String(localized: "保存前会再次校验预览与账本")
    }

    private var commitConfirmationDetail: String {
        if selectedEntries.isEmpty {
            return String(localized: "原始账单会进入归档记录，交易账本保持不变。")
        }
        return String(localized: "将在这台设备校验预览和账本，写入 \(selectedEntries.count) 条交易。")
    }

    private func providerLabel(_ id: String) -> String {
        providers.first(where: { $0.id == id })?.label
            ?? LedgerImportProvider.provider(id)?.label
            ?? id
    }

    private func confidenceText(_ confidence: String) -> String {
        switch confidence {
        case "high": String(localized: "高置信度")
        case "medium": String(localized: "中等置信度")
        default: String(localized: "需要重点核对")
        }
    }

    private func importRangeText(_ preview: LedgerImportPreview) -> String {
        if let start = preview.dateStart, let end = preview.dateEnd, start != end {
            return String(localized: "\(start) 至 \(end)")
        }
        return preview.dateEnd ?? preview.dateStart ?? String(localized: "日期范围未知")
    }

    private func toggle(_ id: String) {
        if includedEntryIDs.contains(id) {
            includedEntryIDs.remove(id)
        } else {
            includedEntryIDs.insert(id)
        }
        persistDraft()
    }

    private func applyBulkTags(mode: ImportBulkTagMode, to ids: Set<String>) {
        guard !ids.isEmpty else { return }
        do {
            reviewedEntries = try ImportBulkEdit.applyingTags(bulkTagInput, mode: mode, to: reviewedEntries, ids: ids)
            bulkTagInput = ""
            errorMessage = nil
            editedEntryStatus = mode == .add
                ? String(localized: "已为 \(ids.count) 笔交易添加标签")
                : String(localized: "已从 \(ids.count) 笔交易移除标签")
            editSaveFeedback &+= 1
            persistDraft()
        } catch {
            errorMessage = error.localizedDescription
            failureFeedback &+= 1
        }
    }

    private func applyBulkCategory(_ account: String, to ids: Set<String>) {
        guard !account.isEmpty else { return }
        var skipped = 0
        for index in reviewedEntries.indices where ids.contains(reviewedEntries[index].id) {
            let entry = reviewedEntries[index]
            let allowed = importAccountChoices(for: entry).map(\.account)
            if let updated = ImportClassificationContext.applying(category: account, funding: entry.fundingAccount,
                                                                  to: entry, allowed: allowed) {
                reviewedEntries[index] = updated
                classificationAcceptedFields[entry.id, default: []].insert("category")
                manuallyReviewedIDs.insert(entry.id)
            } else {
                skipped += 1
            }
        }
        bulkCategory = ""
        errorMessage = skipped == 0 ? nil
            : String(localized: "\(skipped) 笔包含复杂分录或账户冲突，分类没有修改，请逐笔编辑。")
        editedEntryStatus = String(localized: "已为 \(ids.count - skipped) 笔交易设置分类")
        persistDraft()
    }

    /// Previous / next within the filter the editor was opened from, so the
    /// person can work through 待确认 without returning to the list.
    private func editorPosition(for id: String) -> ImportEditorPosition? {
        guard let position = reviewQueue.position(of: id, in: activeFilter) else { return nil }
        return ImportEditorPosition(title: activeFilter.title, index: position.index, count: position.count)
    }

    private func nextEditorID(from id: String, offset: Int) -> String? {
        let queue = reviewQueue
        if let neighbor = queue.neighbor(of: id, in: activeFilter, offset: offset) { return neighbor }
        return offset > 0 ? queue.ids(for: activeFilter).first { $0 != id } : nil
    }

    /// Replacing the sheet's item swaps the editor in place; nil closes it.
    private func openEditor(_ id: String?) {
        editingEntry = id.flatMap { id in reviewedEntries.first { $0.id == id } }
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
            reviewFilter = nil
            bulkTagInput = ""
            commitErrorMessage = nil
            commitOutcomeNeedsReconciliation = false
            commitWasReconciled = false
            editedEntryStatus = nil
            resetClassification()
            persistDraft()
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
        committedEntries = entries
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
        committedEntries = entries
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
            discardDraft()
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
                commitErrorMessage = String(localized: "保存失败：\(error.localizedDescription) 你的核对修改仍在，可重试。")
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
            discardDraft()
            onCommitted(result)
            return
        }
        commitOutcomeNeedsReconciliation = true
        commitErrorMessage = String(localized: "保存结果待确认：操作已中断，请先重新检查导入归档，再继续记账。")
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
    let evidence: [ImportClassificationRequest.Example]
    let position: ImportEditorPosition?
    let onSave: (LedgerImportEntry) -> Void
    let onSaveAndNext: ((LedgerImportEntry) -> Void)?
    let onStep: (Int) -> Void

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
        evidence: [ImportClassificationRequest.Example] = [],
        position: ImportEditorPosition? = nil,
        onSave: @escaping (LedgerImportEntry) -> Void,
        onSaveAndNext: ((LedgerImportEntry) -> Void)? = nil,
        onStep: @escaping (Int) -> Void = { _ in }
    ) {
        self.entry = entry
        self.accounts = accounts
        self.suggestion = suggestion
        self.evidence = evidence
        self.position = position
        self.onSave = onSave
        self.onSaveAndNext = onSaveAndNext
        self.onStep = onStep
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
            List {
                if let position, position.count > 1 {
                    Section {
                        queueHeader(position)
                    }
                    .listRowBackground(Color.clear)
                }
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
                        LedgerAccountPicker(title: String(localized: "选择来源账户"), accounts: accounts, selection: $fundingAccount)
                    } label: {
                        LabeledContent("来源账户", value: accountChoice(fundingAccount).label)
                    }
                    .accessibilityIdentifier("import-edit-source-account")

                    if let candidates = suggestion?.funding.candidates, !candidates.isEmpty {
                        candidatePicks(candidates, selection: $fundingAccount)
                    }

                    NavigationLink {
                        LedgerAccountPicker(title: String(localized: "选择目标账户"), accounts: accounts, selection: $categoryAccount)
                    } label: {
                        LabeledContent("目标账户", value: accountChoice(categoryAccount).label)
                    }
                    .accessibilityIdentifier("import-edit-target-account")

                    if let candidates = suggestion?.category.candidates, !candidates.isEmpty {
                        candidatePicks(candidates, selection: $categoryAccount)
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
                        // Tags are ASCII only; a Pinyin keyboard would hold them as uncommitted marked text.
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .tags)
                        .accessibilityIdentifier("import-edit-tags")

                    if let tags = suggestion?.tags, !tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(tags.filter { $0.probability >= 0.5 }, id: \.value) { tag in
                                    ImportPickButton(
                                        label: "#\(tag.value)",
                                        probability: tag.probability,
                                        selected: (parsedTags ?? []).contains(tag.value)
                                    ) {
                                        var current = tagsText.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
                                        if current.contains(tag.value) {
                                            current.removeAll { $0 == tag.value }
                                        } else {
                                            current.append(tag.value)
                                        }
                                        tagsText = current.joined(separator: " ")
                                    }
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
                Section {
                    if let method = entry.method, !method.isEmpty {
                        LabeledContent("支付方式", value: method)
                    }
                    if let orderID = entry.orderID, !orderID.isEmpty {
                        LabeledContent("订单号") {
                            Text(orderID).balancedMono(size: 12.5).textSelection(.enabled)
                        }
                    }
                    ForEach(Array(entry.postings.enumerated()), id: \.offset) { _, posting in
                        LabeledContent {
                            Text(posting.amount + " " + posting.currency).monospacedDigit()
                        } label: {
                            Text(posting.account).balancedMono(size: 12.5).textSelection(.enabled)
                        }
                    }
                    if !evidence.isEmpty {
                        DisclosureGroup("参考历史 · \(evidence.count) 条") {
                            ForEach(Array(evidence.enumerated()), id: \.offset) { _, example in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(example.payee + " · " + example.narration)
                                    if !example.method.isEmpty { Text(example.method).foregroundStyle(.secondary) }
                                    Text(example.accounts.joined(separator: " · ")).balancedMono(size: 11.5).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("import-edit-evidence")
                    }
                } header: {
                    Text("原始账单")
                }
            }
            .accessibilityIdentifier("import-edit-content")
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let position, position.count > 1, onSaveAndNext != nil {
                    HStack(spacing: 10) {
                        Button("跳过") { onStep(1) }
                            .buttonStyle(.balanced(.outline, disabled: hasChanges))
                            .disabled(hasChanges)
                            .accessibilityIdentifier("import-edit-skip")
                        Button("保存，下一条", action: saveAndNext)
                            .buttonStyle(.balanced(.primary, disabled: !canSave))
                            .disabled(!canSave)
                            .accessibilityIdentifier("import-edit-save-next")
                    }
                    .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                    .ledgerGlassDock()
                }
            }
            .navigationTitle("编辑交易")
            .terminalNativeChrome()
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

    /// 待确认 2 / 5 with previous / next. Moving away is blocked while this
    /// entry has unsaved edits, so nothing is dropped silently.
    private func queueHeader(_ position: ImportEditorPosition) -> some View {
        HStack(spacing: 12) {
            Text("\(position.title) \(position.index) / \(position.count)")
                .balancedFont(size: 12.5).monospacedDigit().foregroundStyle(BalancedPalette.meta)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button { onStep(-1) } label: {
                    Image(systemName: "chevron.up").frame(width: 40, height: 36)
                }
                .disabled(hasChanges || position.index <= 1)
                .accessibilityLabel("上一条")
                .accessibilityIdentifier("import-edit-previous")
                Button { onStep(1) } label: {
                    Image(systemName: "chevron.down").frame(width: 40, height: 36)
                }
                .disabled(hasChanges || position.index >= position.count)
                .accessibilityLabel("下一条")
                .accessibilityIdentifier("import-edit-next")
            }
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(BalancedPalette.ink)
            .ledgerGlassControl()
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 0))
    }

    private func candidatePicks(_ candidates: [ImportClassificationSuggestion.Candidate],
                                selection: Binding<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(candidates, id: \.value) { candidate in
                    ImportPickButton(
                        label: accountChoice(candidate.value).label,
                        probability: candidate.probability,
                        selected: selection.wrappedValue == candidate.value
                    ) {
                        selection.wrappedValue = candidate.value
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func saveAndNext() {
        guard canSave, let onSaveAndNext else { return }
        focusedField = nil
        onSaveAndNext(reviewedEntry)
    }

    private var reviewedEntry: LedgerImportEntry {
        entry.applyingReviewEdits(
            date: Self.formatDate(date),
            flag: flag,
            payee: payee,
            narration: narration,
            amount: parsedAmount ?? entry.amount,
            categoryAccount: categoryAccount,
            fundingAccount: fundingAccount,
            tags: parsedTags ?? entry.tags ?? []
        )
    }

    private func requestDismiss() {
        focusedField = nil
        if hasChanges { discardConfirmationPresented = true }
        else { dismiss() }
    }

    private func save() {
        guard canSave else { return }
        focusedField = nil
        onSave(reviewedEntry)
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

struct ImportEditorPosition: Equatable {
    let title: String
    let index: Int
    let count: Int
}

struct ImportEntryPick: Identifiable, Equatable {
    let account: String
    let label: String
    let probability: Double
    let selected: Bool

    var id: String { account }
}

/// A suggested account or tag: a square outlined control in ink, filled when
/// chosen, with the classifier's probability in meta. No chip fill or tint.
private struct ImportPickButton: View {
    let label: String
    let probability: Double?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).balancedFont(size: 13).lineLimit(1)
                if let probability {
                    Text("\(Int((probability * 100).rounded()))%").balancedFont(size: 11.5).monospacedDigit()
                        .opacity(0.7)
                }
            }
            .foregroundStyle(selected ? BalancedPalette.page : BalancedPalette.ink)
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background(selected ? BalancedPalette.ink : Color.clear)
            .overlay { Rectangle().stroke(selected ? BalancedPalette.ink : BalancedPalette.edge, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// `.imp` — a flat checkbox box, who/meta/cat stacked left, amount right.
/// An entry that still needs the person says why in ink, and offers the
/// classifier's top categories as one-tap picks; everything else opens the
/// editor. Excluded rows dim to ink-3 rather than drawing a status colour.
private struct ImportEntryReviewRow: View {
    let entry: LedgerImportEntry
    let included: Bool
    let isAIClassified: Bool
    let categoryLabel: String
    let attention: String?
    let picks: [ImportEntryPick]
    let canConfirm: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onPick: (String) -> Void
    let onConfirm: () -> Void

    private var payeeText: String {
        entry.payee.isEmpty ? String(localized: "未命名交易") : entry.payee
    }

    private var metaText: String {
        let detail = [entry.method, entry.narration.isEmpty ? nil : entry.narration]
            .compactMap { $0 }.filter { !$0.isEmpty }.first ?? String(localized: "无摘要")
        return "\(entry.date) · \(detail)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                ZStack {
                    Rectangle().fill(included ? BalancedPalette.ink : Color.clear)
                    Rectangle().stroke(included ? BalancedPalette.ink : BalancedPalette.edge, lineWidth: 1)
                }
                .frame(width: 18, height: 18)
                .frame(width: 44, height: 44)
                // A clear fill is not hit-tested, so an excluded entry would
                // only respond on its 1pt border without an explicit shape.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(included ? "排除 \(payeeText)" : "包含 \(payeeText)")
            .accessibilityIdentifier("import-entry-toggle-\(entry.id)")

            VStack(alignment: .leading, spacing: 0) {
                Button(action: onEdit) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(payeeText)
                                .balancedFont(size: 15, weight: .medium)
                                .foregroundStyle(included ? BalancedPalette.ink : BalancedPalette.meta)
                                .lineLimit(1)
                            Text(metaText)
                                .balancedFont(size: 12.5).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                                .lineLimit(1)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("→ " + (ImportReviewQueue.isMissingAccount(entry.categoryAccount) ? String(localized: "未选择分类") : categoryLabel))
                                    .balancedMono(size: 12)
                                    .foregroundStyle(attention == nil ? BalancedPalette.secondary : BalancedPalette.ink)
                                    .lineLimit(1)
                                if isAIClassified {
                                    Text("AI").balancedFont(size: 10, weight: .medium).foregroundStyle(BalancedPalette.meta)
                                        .padding(.horizontal, 3)
                                        .overlay { Rectangle().stroke(BalancedPalette.ruleStrong, lineWidth: 1) }
                                }
                                if let tags = entry.tags, !tags.isEmpty {
                                    Text(tags.prefix(2).map { "#\($0)" }.joined(separator: " "))
                                        .balancedFont(size: 11).foregroundStyle(BalancedPalette.meta).lineLimit(1)
                                }
                            }
                            if let attention {
                                HStack(spacing: 6) {
                                    Circle().stroke(BalancedPalette.ink, lineWidth: 1.5).frame(width: 6, height: 6)
                                    Text(attention).balancedFont(size: 12, weight: .semibold).foregroundStyle(BalancedPalette.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.top, 2)
                                .accessibilityIdentifier("import-entry-attention-\(entry.id)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(importAmountText(entry))
                            .font(.custom(BalancedWeight.medium.sansPostscriptName, size: 15, relativeTo: .body))
                            .monospacedDigit().foregroundStyle(included ? BalancedPalette.ink : BalancedPalette.meta)
                            .lineLimit(1).fixedSize()
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开编辑")
                .accessibilityIdentifier("import-entry-edit-\(entry.id)")

                if !picks.isEmpty || canConfirm {
                    VStack(alignment: .leading, spacing: 6) {
                        if !picks.isEmpty {
                            Text("建议分类").balancedFont(size: 11.5).foregroundStyle(BalancedPalette.meta)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(picks) { pick in
                                    ImportPickButton(label: pick.label, probability: pick.probability, selected: pick.selected) {
                                        onPick(pick.account)
                                    }
                                    .accessibilityIdentifier("import-entry-pick-\(entry.id)-\(pick.account)")
                                }
                                if canConfirm {
                                    ImportPickButton(label: String(localized: "确认"), probability: nil, selected: false, action: onConfirm)
                                        .accessibilityIdentifier("import-entry-confirm-\(entry.id)")
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
    }

    private func importAmountText(_ entry: LedgerImportEntry) -> String {
        let minorUnits = Int((entry.amount * 100).rounded())
        return MoneyText.format(minorUnits: minorUnits, currency: entry.currency, showsCurrency: false)
    }
}
