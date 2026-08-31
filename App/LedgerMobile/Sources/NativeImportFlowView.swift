import SwiftUI

struct NativeImportFlowView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss

    let file: LedgerImportSelectedFile
    let providers: [LedgerImportProviderInfo]
    let onCommitted: (LedgerImportCommitResult) -> Void

    @State private var providerOverride: String?
    @State private var alipayFundRounding = false
    @State private var archivePassword = ""
    @State private var preview: LedgerImportPreview?
    @State private var includedEntryIDs: Set<String> = []
    @State private var commitResult: LedgerImportCommitResult?
    @State private var errorMessage: String?
    @State private var isPreparing = false
    @State private var isCommitting = false
    @State private var confirmationPresented = false
    @State private var cleanupWarningDismissed = false

    private var selectedEntries: [LedgerImportEntry] {
        preview?.entries.filter { includedEntryIDs.contains($0.id) } ?? []
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
            .toolbarBackground(LedgerPalette.panel, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if preview != nil, commitResult == nil {
                        Button("返回") {
                            self.preview = nil
                            includedEntryIDs = []
                            errorMessage = nil
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
                Task { await commit() }
            }
            Button("继续核对", role: .cancel) {}
        } message: {
            Text(commitConfirmationDetail)
        }
    }

    private var preparationView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LedgerSpacing.xl) {
                if let errorMessage {
                    StatusBanner(message: errorMessage) { self.errorMessage = nil }
                }

                LedgerPageIntro(
                    title: "选择识别方式",
                    detail: "服务器会先解析、去重并生成候选交易，确认后才会写入账本。",
                    meta: "预览优先 · 手动确认",
                    style: .inline
                ) { EmptyView() }

                filePanel
                providerPanel

                if file.isZIP {
                    archivePasswordPanel
                }

                if providerOverride == nil || providerOverride == "alipay" {
                    fundRoundingPanel
                }

                Button {
                    Task { await generatePreview() }
                } label: {
                    PrimaryButtonLabel(title: "生成导入预览", loading: isPreparing)
                }
                .buttonStyle(PressScaleButtonStyle())
                .disabled(isPreparing)
                .opacity(isPreparing ? 0.72 : 1)
                .accessibilityIdentifier("import-generate-preview")

                importSafetyNote
            }
            .padding(.horizontal, LedgerSpacing.lg)
            .padding(.vertical, LedgerSpacing.xl)
            .ledgerAdaptivePageWidth()
        }
        .accessibilityIdentifier("native-import-preparation")
    }

    private var filePanel: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            SectionHeading(title: "账单文件", detail: fileSizeText)
            LedgerPanel {
                HStack(spacing: LedgerSpacing.md) {
                    Image(systemName: file.isZIP ? "doc.zipper" : "doc.text.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(LedgerPalette.cobalt)
                        .frame(width: 40, height: 40)
                        .background(LedgerPalette.tag)
                        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LedgerPalette.ink)
                            .lineLimit(2)
                        Text(file.fileExtension.uppercased())
                            .font(.system(size: 10, weight: .medium).monospaced())
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(LedgerSpacing.lg)
            }
        }
    }

    private var providerPanel: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            SectionHeading(title: "账单渠道", detail: "默认自动识别")
            LedgerPanel {
                Menu {
                    Button {
                        providerOverride = nil
                    } label: {
                        Label("自动识别", systemImage: providerOverride == nil ? "checkmark" : "wand.and.stars")
                    }
                    ForEach(providers) { provider in
                        Button {
                            providerOverride = provider.id
                        } label: {
                            Label(provider.label, systemImage: providerOverride == provider.id ? "checkmark" : "doc")
                        }
                    }
                } label: {
                    HStack(spacing: LedgerSpacing.md) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(LedgerPalette.cobalt)
                            .frame(width: 36, height: 36)
                            .background(LedgerPalette.tag)
                            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedProviderLabel)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(LedgerPalette.ink)
                            Text(selectedProviderDetail)
                                .font(.system(size: 11))
                                .foregroundStyle(LedgerPalette.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    .padding(LedgerSpacing.lg)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityIdentifier("import-provider-menu")
            }
        }
    }

    private var archivePasswordPanel: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            SectionHeading(title: "压缩包密码", detail: "可选")
            LedgerPanel {
                SecureField("输入账单压缩包密码", text: $archivePassword)
                    .textContentType(.password)
                    .font(.system(size: 14))
                    .padding(LedgerSpacing.lg)
                    .accessibilityIdentifier("import-archive-password")
            }
        }
    }

    private var fundRoundingPanel: some View {
        LedgerPanel {
            Toggle(isOn: $alipayFundRounding) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("支付宝基金 9.99 → 10.00 补差")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text("仅在确认该基金定投需要补 0.01 时开启。")
                        .font(.system(size: 11))
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }
            .tint(LedgerPalette.cobalt)
            .padding(LedgerSpacing.lg)
        }
    }

    private var importSafetyNote: some View {
        HStack(alignment: .top, spacing: LedgerSpacing.md) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(width: 20)
            Text("预览会检查渠道、重复交易、账本账户和生成结果。关闭此页面会丢弃当前预览。")
                .font(.system(size: 11))
                .foregroundStyle(LedgerPalette.secondary)
            Spacer(minLength: 0)
        }
        .padding(LedgerSpacing.lg)
        .background(LedgerPalette.tag.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
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

                entrySection(preview)
            }
            .padding(.horizontal, LedgerSpacing.lg)
            .padding(.top, LedgerSpacing.xl)
            .padding(.bottom, 112)
            .ledgerAdaptivePageWidth()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            commitBar(preview)
        }
        .accessibilityIdentifier("native-import-preview")
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
                    Text("已选择 \(selectedEntries.count) / \(preview.entries.count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                }
                Spacer(minLength: 0)
                Button(includedEntryIDs.count == preview.entries.count ? "取消全选" : "全选") {
                    if includedEntryIDs.count == preview.entries.count {
                        includedEntryIDs = []
                    } else {
                        includedEntryIDs = Set(preview.entries.map(\.id))
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(minHeight: 40)
                .buttonStyle(PressScaleButtonStyle())
            }

            LedgerPanel {
                LazyVStack(spacing: 0) {
                    ForEach(Array(preview.entries.enumerated()), id: \.element.id) { index, entry in
                        ImportEntryReviewRow(
                            entry: entry,
                            included: includedEntryIDs.contains(entry.id),
                            onToggle: { toggle(entry.id) }
                        )
                        if index < preview.entries.count - 1 {
                            Divider().overlay(LedgerPalette.line).padding(.leading, 52)
                        }
                    }
                }
            }
        }
    }

    private func commitBar(_ preview: LedgerImportPreview) -> some View {
        VStack(spacing: LedgerSpacing.sm) {
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
                confirmationPresented = true
            } label: {
                PrimaryButtonLabel(title: commitActionTitle, loading: isCommitting)
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(isCommitting)
            .opacity(isCommitting ? 0.72 : 1)
            .accessibilityIdentifier("import-commit")
        }
        .padding(.horizontal, LedgerSpacing.lg)
        .padding(.top, LedgerSpacing.md)
        .padding(.bottom, LedgerSpacing.sm)
        .background(LedgerPalette.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(LedgerPalette.line).frame(height: 1)
        }
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
                    Text(result.readModelPending == true ? "账本写入完成，索引正在后台更新。" : "账本和导入记录已经更新。")
                        .font(.system(size: 13))
                        .foregroundStyle(LedgerPalette.secondary)
                        .multilineTextAlignment(.center)
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

    private var selectedProviderLabel: String {
        guard let providerOverride else { return "自动识别" }
        return providerLabel(providerOverride)
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
            includedEntryIDs = Set(updated.entries.map(\.id))
        } catch is CancellationError {
            return
        } catch {
            archivePassword = ""
            errorMessage = error.localizedDescription
        }
    }

    private func commit() async {
        guard let preview, !isCommitting else { return }
        isCommitting = true
        errorMessage = nil
        defer { isCommitting = false }
        do {
            let result = try await session.commitImport(preview: preview, entries: selectedEntries)
            guard !Task.isCancelled else { return }
            commitResult = result
            onCommitted(result)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
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

private struct ImportEntryReviewRow: View {
    let entry: LedgerImportEntry
    let included: Bool
    let onToggle: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: LedgerSpacing.sm) {
                Button(action: onToggle) {
                    Image(systemName: included ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(included ? LedgerPalette.cobalt : LedgerPalette.secondary)
                        .frame(width: 40, height: 44)
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
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LedgerPalette.ink)
                                .lineLimit(1)
                            Text("\(entry.date) · \(entry.narration.isEmpty ? "无摘要" : entry.narration)")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(LedgerPalette.secondary)
                                .lineLimit(2)
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
                    .padding(.trailing, LedgerSpacing.lg)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityIdentifier("import-entry-\(entry.id)")
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
