import SwiftUI

struct NativeImportFlowView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss

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
    @State private var editingEntry: LedgerImportEntry?
    @State private var commitResult: LedgerImportCommitResult?
    @State private var errorMessage: String?
    @State private var isPreparing = false
    @State private var isCommitting = false
    @State private var confirmationPresented = false
    @State private var cleanupWarningDismissed = false
    @State private var commitErrorMessage: String?
    @State private var commitOutcomeNeedsReconciliation = false
    @State private var commitWasReconciled = false
    @State private var editedEntryStatus: String?
    @State private var editSaveFeedback = 0

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
            .navigationTitle(currentTitle)
            .navigationBarTitleDisplayMode(.inline)

            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if preview != nil, commitResult == nil {
                        Button(startsWithPreview ? "关闭" : "返回") {
                            if startsWithPreview {
                                dismiss()
                            } else {
                                self.preview = nil
                                reviewedEntries = []
                                includedEntryIDs = []
                                selectedTagEntryIDs = []
                                bulkTagInput = ""
                                errorMessage = nil
                                commitErrorMessage = nil
                                commitOutcomeNeedsReconciliation = false
                                commitWasReconciled = false
                                editedEntryStatus = nil
                            }
                        }
                        .disabled(isCommitting)
                    } else if commitResult == nil {
                        Button("取消") { dismiss() }
                            .disabled(isPreparing)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isPreparing || isCommitting)
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
                onSave: { updated in
                    applyEditedEntry(updated)
                }
            )
            .ledgerPrivacyProtectedSheet()
        }
        .sensoryFeedback(.success, trigger: editSaveFeedback)
        .ledgerPrivacyProtectedSheet()
    }

    private var preparationView: some View {
        Form {
            if let errorMessage {
                Section { StatusBanner(message: errorMessage) { self.errorMessage = nil } }
            }
            Section("账单文件") {
                Label(file.name, systemImage: file.isZIP ? "doc.zipper" : "doc.text")
                LabeledContent("文件大小", value: fileSizeText)
            }
            Section {
                Picker("账单渠道", selection: $providerOverride) {
                    Text("自动识别").tag(String?.none)
                    ForEach(providers) { provider in
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
                    if isPreparing { ProgressView("正在生成预览") }
                    else { Text("生成导入预览") }
                }
                .accessibilityIdentifier("import-generate-preview")
            } footer: {
                Text("预览会检查渠道与重复交易。核对并确认后写入账本，关闭页面会丢弃当前预览。")
            }
        }
        .disabled(isPreparing)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("native-import-preparation")
    }

    private func previewView(_ preview: LedgerImportPreview) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LedgerSpacing.xl) {
                if let errorMessage {
                    StatusBanner(message: errorMessage) { self.errorMessage = nil }
                }

                previewSummary(preview)

                if !preview.warnings.isEmpty {
                    warningSection(preview.warnings)
                }

                bulkTagSection
                entrySection(preview)
            }
            .padding(.horizontal, LedgerSpacing.lg)
            .padding(.top, LedgerSpacing.xl)
            .padding(.bottom, LedgerSpacing.xxl)
            .ledgerAdaptivePageWidth()
            .disabled(isCommitting)
        }
        .accessibilityIdentifier("native-import-preview")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            commitBar(preview)
        }
    }

    private func previewSummary(_ preview: LedgerImportPreview) -> some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            SectionHeading(title: "预览摘要", detail: confidenceText(preview.providerDetection.confidence))
            LedgerPanel {
                VStack(spacing: 0) {
                    ImportPreviewMetricRow(
                        icon: "wand.and.stars",
                        title: providerLabel(preview.provider),
                        detail: preview.providerDetection.reason,
                        value: "已识别"
                    )
                    Divider().overlay(LedgerPalette.line).padding(.leading, 64)
                    ImportPreviewMetricRow(
                        icon: "calendar",
                        title: importRangeText(preview),
                        detail: "账单覆盖范围",
                        value: "\(preview.candidateCount) 条"
                    )
                    Divider().overlay(LedgerPalette.line).padding(.leading, 64)
                    ImportPreviewMetricRow(
                        icon: "arrow.triangle.2.circlepath",
                        title: preview.dedupReport,
                        detail: "服务端去重结果",
                        value: preview.skippedDuplicateCount > 0 ? "跳过 \(preview.skippedDuplicateCount)" : "无重复"
                    )
                }
            }
        }
    }

    private func warningSection(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            SectionHeading(title: "核对提示", detail: "\(warnings.count) 项")
            LedgerPanel {
                VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { index, warning in
                        HStack(alignment: .top, spacing: LedgerSpacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(LedgerPalette.gold)
                                .frame(width: 18)
                            Text(warning)
                                .font(.system(size: 11))
                                .foregroundStyle(LedgerPalette.olive)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if index < warnings.count - 1 {
                            Divider().overlay(LedgerPalette.line)
                        }
                    }
                }
                .padding(LedgerSpacing.lg)
            }
        }
    }

    private func entrySection(_ preview: LedgerImportPreview) -> some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("候选交易")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.15)
                        .foregroundStyle(LedgerPalette.ink)
                    Text("已选择 \(selectedEntries.count) / \(reviewedEntries.count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                }
                Spacer(minLength: 0)
                Button(includedEntryIDs.count == reviewedEntries.count ? "取消全选" : "全选") {
                    if includedEntryIDs.count == reviewedEntries.count {
                        includedEntryIDs = []
                    } else {
                        includedEntryIDs = Set(reviewedEntries.map(\.id))
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(minHeight: 44)
                .buttonStyle(PressScaleButtonStyle())
            }

            LedgerPanel {
                LazyVStack(spacing: 0) {
                    ForEach(Array(reviewedEntries.enumerated()), id: \.element.id) { index, entry in
                        ImportEntryReviewRow(
                            entry: entry,
                            included: includedEntryIDs.contains(entry.id),
                            tagSelected: selectedTagEntryIDs.contains(entry.id),
                            onToggle: { toggle(entry.id) },
                            onToggleTag: { toggleTagSelection(entry.id) },
                            onEdit: { editingEntry = entry }
                        )
                        if index < reviewedEntries.count - 1 {
                            Divider().overlay(LedgerPalette.line).padding(.leading, 52)
                        }
                    }
                }
            }
        }
    }

    private var bulkTagSection: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading(title: "批量标签", detail: "已选 \(selectedTagEntryIDs.count) 条")
                Spacer()
                Button(allEntriesSelectedForTags ? "清空" : "全选") {
                    selectedTagEntryIDs = allEntriesSelectedForTags
                        ? []
                        : Set(reviewedEntries.map(\.id))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(minHeight: 44)
            }
            LedgerPanel {
                VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                    TextField("travel, trip-2026", text: $bulkTagInput)
                        .font(.system(size: 14, weight: .medium))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("import-bulk-tag-input")
                    HStack(spacing: LedgerSpacing.sm) {
                        Button("添加标签") { applyBulkTags(mode: .add) }
                            .foregroundStyle(LedgerPalette.onBrand)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(LedgerPalette.cobalt)
                            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                            .accessibilityIdentifier("import-bulk-tag-add")
                        Button("移除标签") { applyBulkTags(mode: .remove) }
                            .foregroundStyle(LedgerPalette.olive)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(LedgerPalette.tag)
                            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                            .accessibilityIdentifier("import-bulk-tag-remove")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(PressScaleButtonStyle())
                    .disabled(selectedTagEntryIDs.isEmpty)
                    .opacity(selectedTagEntryIDs.isEmpty ? 0.52 : 1)
                    Text("交易行中的标签图标用于选择批量操作对象；提交时会发送编辑后的完整标签列表。")
                        .font(.system(size: 10))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .padding(LedgerSpacing.lg)
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text(providerLabel(preview.provider) + " · " + importRangeText(preview))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                }
                Spacer(minLength: 0)
            }

            Button {
                if commitOutcomeNeedsReconciliation {
                    startCommitReconciliation()
                } else {
                    confirmationPresented = true
                }
            } label: {
                PrimaryButtonLabel(
                    title: commitButtonTitle,
                    loading: isCommitting
                )
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(isCommitting)
            .opacity(isCommitting ? 0.72 : 1)
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
                        HStack(alignment: .top, spacing: LedgerSpacing.md) {
                            Image(systemName: "archivebox.fill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(LedgerPalette.cobalt)
                                .frame(width: 36, height: 36)
                                .background(LedgerPalette.tag)
                                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("归档位置")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.ink)
                                Text(documentFile)
                                    .font(.system(size: 10, weight: .medium).monospaced())
                                    .foregroundStyle(LedgerPalette.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
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
        return "提交前服务器会再次校验预览"
    }

    private var commitConfirmationDetail: String {
        if selectedEntries.isEmpty {
            return "原始账单会进入归档记录，交易账本保持不变。"
        }
        return "服务器会再次校验预览和原文件，然后写入 \(selectedEntries.count) 条交易。"
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
        } catch {
            errorMessage = error.localizedDescription
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
        } catch is CancellationError {
            return
        } catch {
            archivePassword = ""
            errorMessage = error.localizedDescription
        }
    }

    private func startCommit() {
        guard let preview, !isCommitting else { return }
        let entries = selectedEntries
        isCommitting = true
        commitErrorMessage = nil
        commitOutcomeNeedsReconciliation = false
        Task { await commit(preview: preview, entries: entries) }
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
        commitErrorMessage = "保存结果待确认：连接中断，服务器可能已完成写入。请勿重复提交；可重新检查导入归档。"
    }
}

private struct ImportPreviewMetricRow: View {
    let icon: String
    let title: String
    let detail: String
    let value: String

    var body: some View {
        HStack(alignment: .center, spacing: LedgerSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(width: 36, height: 36)
                .background(LedgerPalette.tag)
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(2)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(LedgerPalette.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(LedgerPalette.cobalt)
                .padding(.horizontal, 9)
                .frame(minHeight: 28)
                .background(LedgerPalette.tag)
                .clipShape(Capsule())
        }
        .padding(LedgerSpacing.lg)
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
    let onSave: (LedgerImportEntry) -> Void

    @State private var date: Date
    @State private var flag: String
    @State private var payee: String
    @State private var narration: String
    @State private var tagsText: String
    @State private var amountText: String
    @State private var fundingAccount: String
    @State private var categoryAccount: String
    @FocusState private var focusedField: ImportEditorField?

    init(
        entry: LedgerImportEntry,
        accounts: [LedgerAccountChoice],
        onSave: @escaping (LedgerImportEntry) -> Void
    ) {
        self.entry = entry
        self.accounts = accounts
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
                    NavigationLink {
                        LedgerAccountPicker(title: "选择目标账户", accounts: accounts, selection: $categoryAccount)
                    } label: {
                        LabeledContent("目标账户", value: accountChoice(categoryAccount).label)
                    }
                    .accessibilityIdentifier("import-edit-target-account")
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
                    Button("取消") { dismiss() }
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
    let entry: LedgerImportEntry
    let included: Bool
    let tagSelected: Bool
    let onToggle: () -> Void
    let onToggleTag: () -> Void
    let onEdit: () -> Void

    @State private var expanded = false

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

                Button(action: onToggleTag) {
                    Image(systemName: tagSelected ? "tag.fill" : "tag")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tagSelected ? LedgerPalette.cobalt : LedgerPalette.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel(tagSelected ? "取消选择 \(entry.payee) 的标签操作" : "选择 \(entry.payee) 的标签操作")
                .accessibilityIdentifier("import-entry-tag-toggle-\(entry.id)")

                Button {
                    expanded.toggle()
                } label: {
                    HStack(alignment: .center, spacing: LedgerSpacing.sm) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.payee.isEmpty ? "未命名交易" : entry.payee)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LedgerPalette.ink)
                                .lineLimit(1)
                            Text("\(entry.date) · \(entry.narration.isEmpty ? "无摘要" : entry.narration)")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(LedgerPalette.secondary)
                                .lineLimit(2)
                            if let tags = entry.tags, !tags.isEmpty {
                                Text(tags.prefix(3).map { "#\($0)" }.joined(separator: "  "))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.olive)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ViewThatFits(in: .horizontal) {
                            Text(importAmountText(entry))
                                .fixedSize(horizontal: true, vertical: false)
                            Text(importCompactAmountText(entry))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(included ? LedgerPalette.warm : LedgerPalette.secondary)
                        .accessibilityLabel(importAmountText(entry))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(LedgerPalette.secondary)
                            .frame(width: 18)
                    }
                    .padding(.vertical, LedgerSpacing.md)
                    .padding(.trailing, LedgerSpacing.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityIdentifier("import-entry-\(entry.id)")

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LedgerPalette.cobalt)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel("编辑 \(entry.payee.isEmpty ? "未命名交易" : entry.payee)")
                .accessibilityIdentifier("import-entry-edit-\(entry.id)")
            }

            if expanded {
                VStack(alignment: .leading, spacing: LedgerSpacing.md) {
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
                .padding(.trailing, LedgerSpacing.lg)
                .padding(.bottom, LedgerSpacing.lg)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .opacity(included ? 1 : 0.58)
        .animation(.easeOut(duration: 0.16), value: expanded)
        .animation(.easeOut(duration: 0.16), value: included)
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
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
            Text(value)
                .font(.system(size: 10, weight: .medium).monospaced())
                .foregroundStyle(LedgerPalette.olive)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
