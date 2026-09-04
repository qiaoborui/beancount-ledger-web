import SwiftUI
import UniformTypeIdentifiers

struct ImportHistoryView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var showsAppBar = false

    @State private var documents: [LedgerImportDocument] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var loadedAt: Date?
    @State private var providers: [LedgerImportProviderInfo] = []
    @State private var fileImporterPresented = false
    @State private var activeImportFile: LedgerImportSelectedFile?
    @State private var isReadingFile = false
    @State private var debugImportFlowPresented = false
    @State private var gmailStatus: LedgerGmailStatus?
    @State private var gmailPending: [LedgerGmailPendingImport] = []
    @State private var gmailErrorMessage: String?
    @State private var gmailResultMessage: String?
    @State private var isLoadingGmail = true
    @State private var gmailAction: GmailAction?
    @State private var gmailReview: GmailImportReview?
    @State private var disconnectConfirmationPresented = false
    @State private var pendingToDismiss: LedgerGmailPendingImport?
    @State private var gmailRealtimeConnected = false
    @State private var handledGmailOAuthResultID: UUID?
    @State private var gmailLoadGeneration = 0

    private static let supportedFileTypes = LedgerMobileImportCapabilities.supportedManualFileExtensions
        .compactMap { UTType(filenameExtension: String($0.dropFirst())) }

    private var statuses: [LedgerImportChannelStatus] {
        LedgerImportHistory.channelStatuses(documents: documents)
    }

    private var sortedDocuments: [LedgerImportDocument] {
        LedgerImportHistory.sortedDocuments(documents)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsAppBar {
                LedgerAppBar { PrivacyToolbarButton() }
            }

            Group {
                if isLoading && documents.isEmpty {
                    loadingState
                } else if documents.isEmpty, let errorMessage {
                    failureState(errorMessage)
                } else {
                    content
                }
            }
        }
        .background(LedgerPalette.canvas)
        .navigationTitle(showsAppBar ? "" : "导入记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsAppBar ? .hidden : .visible, for: .navigationBar)
        .toolbarBackground(LedgerPalette.panel, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if !showsAppBar {
                ToolbarItem(placement: .topBarTrailing) { PrivacyToolbarButton() }
            }
        }
        .fileImporter(
            isPresented: $fileImporterPresented,
            allowedContentTypes: Self.supportedFileTypes,
            allowsMultipleSelection: false
        ) { result in
            Task { await handleFileSelection(result) }
        }
        .sheet(item: $activeImportFile) { file in
            NativeImportFlowView(file: file, providers: providers) { _ in
                Task { await load(replacingContent: false) }
            }
            .environmentObject(session)
        }
        .sheet(item: $gmailReview) { review in
            NativeImportFlowView(preview: review.preview, providers: providers) { _ in
                Task { await refreshAll(replacingContent: false) }
            }
            .environmentObject(session)
        }
        .confirmationDialog(
            "断开 Gmail？",
            isPresented: $disconnectConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("断开 Gmail", role: .destructive) {
                Task { await disconnectGmail() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("服务器会撤销授权并停止接收新邮件；已有导入记录和账本内容不会删除。")
        }
        .confirmationDialog(
            "忽略这封账单？",
            isPresented: Binding(
                get: { pendingToDismiss != nil },
                set: { if !$0 { pendingToDismiss = nil } }
            ),
            presenting: pendingToDismiss
        ) { item in
            Button("忽略账单", role: .destructive) {
                Task { await dismissPending(item) }
            }
            Button("取消", role: .cancel) { pendingToDismiss = nil }
        } message: { item in
            Text("“\(pendingTitle(item))”会从待核对列表移除，不会写入账本。")
        }
        .task {
            await refreshAll(replacingContent: true)
            await applyGmailOAuthResult(session.gmailOAuthResult)
            presentDebugImportFlowIfNeeded()
        }
        .task(id: gmailEventTaskID) {
            await listenForGmailPendingEvents()
        }
        .onChange(of: scenePhase) { _, updatedPhase in
            guard updatedPhase == .active else {
                gmailRealtimeConnected = false
                return
            }
            Task { await loadGmail(replacingContent: false) }
        }
        .onChange(of: session.gmailOAuthResult) { _, result in
            Task { await applyGmailOAuthResult(result) }
        }
    }

    private var loadingState: some View {
        VStack(spacing: LedgerSpacing.md) {
            ProgressView().tint(LedgerPalette.cobalt)
            Text("正在整理导入记录")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: LedgerSpacing.lg) {
            EmptyLedgerState(
                icon: "tray.and.arrow.down",
                title: "导入记录加载失败",
                detail: message
            )
            Button("重新加载") {
                Task { await refreshAll(replacingContent: true) }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(LedgerPalette.onBrand)
            .padding(.horizontal, LedgerSpacing.xl)
            .frame(minHeight: 44)
            .background(LedgerPalette.cobalt)
            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
            .buttonStyle(PressScaleButtonStyle())
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LedgerSpacing.xl) {
                pageIntro

                if let errorMessage {
                    StatusBanner(message: errorMessage) { self.errorMessage = nil }
                }

                importSection
                gmailAutomationSection
                updateSummary
                channelSection
                historySection
                importSafetyNotice
            }
            .padding(.horizontal, horizontalSizeClass == .regular ? 0 : LedgerSpacing.lg)
            .padding(.top, horizontalSizeClass == .regular ? LedgerSpacing.xl : LedgerSpacing.lg)
            .padding(.bottom, horizontalSizeClass == .regular ? LedgerSpacing.xxl : LedgerLayout.compactTabBarClearance)
            .ledgerAdaptivePageWidth()
        }
        .refreshable { await refreshAll(replacingContent: false) }
        .privacySensitive()
        .accessibilityIdentifier("import-history-content")
    }

    @ViewBuilder
    private var pageIntro: some View {
        if showsAppBar {
            LedgerPageIntro(
                title: "导入",
                detail: "导入新账单，查看各个渠道的覆盖日期、更新状态和历史归档。",
                meta: loadedAt.map { "刚刚检查 · \($0.formatted(date: .omitted, time: .shortened))" } ?? "等待检查",
                style: .inline
            ) { EmptyView() }
        } else {
            LedgerPageContext(
                detail: "导入新账单，查看各个渠道的覆盖日期、更新状态和历史归档。",
                meta: loadedAt.map { "刚刚检查 · \($0.formatted(date: .omitted, time: .shortened))" } ?? "等待检查"
            )
        }
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            SectionHeading(title: "导入新账单", detail: "预览后确认写入")
            LedgerPanel {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: LedgerSpacing.lg) {
                        importFileLead
                        importFileButton
                    }

                    VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                        importFileLead
                        importFileButton
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(LedgerSpacing.lg)
            }
        }
    }

    private var importFileLead: some View {
        HStack(alignment: .center, spacing: LedgerSpacing.md) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(width: 44, height: 44)
                .background(LedgerPalette.tag)
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("从“文件”选择账单")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                Text("支持 CSV、Excel、PDF、邮件和 ZIP，单个文件最大 10MB。")
                    .font(.system(size: 11))
                    .foregroundStyle(LedgerPalette.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var importFileButton: some View {
        Button {
            fileImporterPresented = true
        } label: {
            Group {
                if isReadingFile {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LedgerPalette.onBrand)
                } else {
                    Text("选择文件")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(LedgerPalette.onBrand)
            .padding(.horizontal, LedgerSpacing.md)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(LedgerPalette.cobalt)
            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(isReadingFile)
        .accessibilityIdentifier("import-select-file")
    }

    private var gmailAutomationSection: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            SectionHeading(title: "Gmail 自动账单", detail: gmailSectionDetail)
            LedgerPanel {
                VStack(spacing: 0) {
                    gmailStatusContent

                    if !visibleGmailPending.isEmpty {
                        Divider().overlay(LedgerPalette.line)
                        VStack(spacing: 0) {
                            ForEach(Array(visibleGmailPending.enumerated()), id: \.element.id) { index, item in
                                gmailPendingRow(item)
                                if index < visibleGmailPending.count - 1 {
                                    Divider().overlay(LedgerPalette.line).padding(.leading, 64)
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("gmail-automation-section")
    }

    @ViewBuilder
    private var gmailStatusContent: some View {
        if isLoadingGmail, gmailStatus == nil {
            HStack(spacing: LedgerSpacing.md) {
                ProgressView().tint(LedgerPalette.cobalt)
                Text("正在检查 Gmail 自动导入")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LedgerPalette.secondary)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .padding(LedgerSpacing.lg)
            .accessibilityElement(children: .combine)
            .accessibilityValue("处理中")
        } else if let status = gmailStatus {
            VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                HStack(alignment: .center, spacing: LedgerSpacing.md) {
                    Image(systemName: status.connected ? "envelope.badge.fill" : "envelope.badge")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(status.connected ? LedgerPalette.success : LedgerPalette.cobalt)
                        .frame(width: 44, height: 44)
                        .background((status.connected ? LedgerPalette.success : LedgerPalette.cobalt).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(gmailStatusTitle(status))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LedgerPalette.ink)
                            .lineLimit(2)
                        Text(gmailDeliveryDetail(status))
                            .font(.caption)
                            .foregroundStyle(LedgerPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if status.connected, isLoadingGmail {
                        ProgressView()
                            .controlSize(.small)
                            .tint(LedgerPalette.cobalt)
                            .accessibilityLabel("正在刷新 Gmail 状态")
                    }
                }

                if let lastError = status.lastError, !lastError.isEmpty {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(LedgerPalette.risk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let gmailErrorMessage {
                    Label(gmailErrorMessage, systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(LedgerPalette.risk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("gmail-action-error")
                }
                if let gmailResultMessage {
                    Label(gmailResultMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(LedgerPalette.success)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("gmail-action-result")
                }

                gmailActions(status)
            }
            .padding(LedgerSpacing.lg)
        } else {
            VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                Label("Gmail 自动导入暂不可用", systemImage: "envelope.badge")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LedgerPalette.ink)
                Text(gmailErrorMessage ?? "请更新服务器后重试，文件导入和已有导入记录不受影响。")
                    .font(.caption)
                    .foregroundStyle(LedgerPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重新检查") {
                    Task { await loadGmail(replacingContent: true) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(minHeight: 44)
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityIdentifier("gmail-reload")
            }
            .padding(LedgerSpacing.lg)
        }
    }

    @ViewBuilder
    private func gmailActions(_ status: LedgerGmailStatus) -> some View {
        if !status.configured {
            Text("请先在服务器配置 Google OAuth；App 不会在设备上保存 Gmail 凭据。")
                .font(.caption)
                .foregroundStyle(LedgerPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("gmail-not-configured")
        } else if !status.connected {
            Button {
                Task { await connectGmail() }
            } label: {
                PrimaryButtonLabel(title: "连接 Gmail", loading: gmailAction == .connect)
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(gmailAction != nil)
            .opacity(gmailAction == nil ? 1 : 0.72)
            .accessibilityValue(gmailAction == .connect ? "处理中" : "未连接")
            .accessibilityIdentifier("gmail-connect")
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: LedgerSpacing.sm) {
                    gmailSyncButton
                    gmailDisconnectButton
                }
                VStack(spacing: LedgerSpacing.sm) {
                    gmailSyncButton
                    gmailDisconnectButton
                }
            }
        }
    }

    private var gmailSyncButton: some View {
        Button {
            Task { await syncGmail() }
        } label: {
            HStack(spacing: LedgerSpacing.sm) {
                if gmailAction == .sync {
                    ProgressView().controlSize(.small).tint(LedgerPalette.onBrand)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(gmailAction == .sync ? "正在同步" : "立即同步")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LedgerPalette.onBrand)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(LedgerPalette.cobalt)
            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(gmailAction != nil)
        .opacity(gmailAction == nil ? 1 : 0.72)
        .accessibilityValue(gmailAction == .sync ? "处理中" : "可以同步")
        .accessibilityIdentifier("gmail-sync")
    }

    private var gmailDisconnectButton: some View {
        Button(role: .destructive) {
            disconnectConfirmationPresented = true
        } label: {
            HStack(spacing: LedgerSpacing.sm) {
                if gmailAction == .disconnect {
                    ProgressView().controlSize(.small).tint(LedgerPalette.risk)
                }
                Text(gmailAction == .disconnect ? "正在断开" : "断开")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LedgerPalette.risk)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(LedgerPalette.risk.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(gmailAction != nil)
        .accessibilityValue(gmailAction == .disconnect ? "处理中" : "已连接")
        .accessibilityIdentifier("gmail-disconnect")
    }

    private func gmailPendingRow(_ item: LedgerGmailPendingImport) -> some View {
        HStack(alignment: .center, spacing: LedgerSpacing.md) {
            Image(systemName: gmailPendingIcon(item))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(gmailPendingColor(item))
                .frame(width: 36, height: 36)
                .background(gmailPendingColor(item).opacity(0.11))
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(pendingTitle(item))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(2)
                Text(gmailPendingDetail(item))
                    .font(.caption)
                    .foregroundStyle(item.isRetryable ? LedgerPalette.risk : LedgerPalette.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            gmailPendingActions(item)
        }
        .padding(LedgerSpacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gmail-pending-\(item.id)")
    }

    @ViewBuilder
    private func gmailPendingActions(_ item: LedgerGmailPendingImport) -> some View {
        if item.isReviewable {
            Button {
                Task { await openPending(item) }
            } label: {
                Group {
                    if gmailAction == .pending(item.id) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(LedgerPalette.cobalt)
                    } else {
                        Text("核对")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(minWidth: 52, minHeight: 44)
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(gmailAction != nil)
            .accessibilityValue(gmailAction == .pending(item.id) ? "处理中" : "可以核对")
            .accessibilityIdentifier("gmail-review-\(item.id)")
        } else if item.isRetryable {
            Menu {
                Button("重新处理") { Task { await retryPending(item) } }
                Button("忽略", role: .destructive) { pendingToDismiss = item }
            } label: {
                Image(systemName: gmailAction == .pending(item.id) ? "hourglass" : "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(LedgerPalette.cobalt)
                    .frame(width: 44, height: 44)
            }
            .disabled(gmailAction != nil)
            .accessibilityLabel("处理失败账单")
            .accessibilityIdentifier("gmail-failed-menu-\(item.id)")
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(LedgerPalette.cobalt)
                .frame(width: 44, height: 44)
                .accessibilityLabel("账单处理中")
                .accessibilityValue("处理中")
        }
    }

    private var updateSummary: some View {
        let recorded = statuses.filter { $0.document != nil }
        let needsUpdate = recorded.filter { $0.freshness == .attention || $0.freshness == .overdue }.count
        let missing = statuses.count - recorded.count

        return LedgerPanel {
            HStack(alignment: .center, spacing: LedgerSpacing.lg) {
                Image(systemName: needsUpdate > 0 ? "clock.badge.exclamationmark" : "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(needsUpdate > 0 ? LedgerPalette.gold : LedgerPalette.success)
                    .frame(width: 44, height: 44)
                    .background((needsUpdate > 0 ? LedgerPalette.gold : LedgerPalette.success).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(summaryTitle(recorded: recorded.count, needsUpdate: needsUpdate))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text("已归档 \(recorded.count) 个渠道 · \(missing) 个渠道暂无记录")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                }

                Spacer(minLength: 0)

                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LedgerPalette.cobalt)
                        .accessibilityLabel("正在刷新导入记录")
                }
            }
            .padding(LedgerSpacing.lg)
        }
    }

    private func summaryTitle(recorded: Int, needsUpdate: Int) -> String {
        if recorded == 0 { return "还没有导入记录" }
        if needsUpdate > 0 { return "\(needsUpdate) 个渠道建议更新" }
        return "已归档渠道都在建议周期内"
    }

    private var channelSection: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            SectionHeading(title: "渠道状态", detail: "账单覆盖日期")
            LedgerPanel {
                VStack(spacing: 0) {
                    ForEach(Array(statuses.enumerated()), id: \.element.id) { index, status in
                        ImportChannelRow(status: status)
                        if index < statuses.count - 1 {
                            Divider().overlay(LedgerPalette.line).padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            SectionHeading(title: "导入记录", detail: "\(sortedDocuments.count) 个归档文件")
            if sortedDocuments.isEmpty {
                LedgerPanel {
                    EmptyLedgerState(
                        icon: "tray",
                        title: "暂无归档记录",
                        detail: "完成一次账单导入后，渠道覆盖日期和历史文件会显示在这里。"
                    )
                }
            } else {
                LedgerPanel {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(sortedDocuments.enumerated()), id: \.element.id) { index, document in
                            ImportDocumentRow(document: document)
                            if index < sortedDocuments.count - 1 {
                                Divider().overlay(LedgerPalette.line).padding(.leading, 64)
                            }
                        }
                    }
                }
            }
        }
    }

    private var importSafetyNotice: some View {
        HStack(alignment: .top, spacing: LedgerSpacing.md) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text("预览确认后写入")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                Text("服务端会先完成渠道识别、重复交易检查和账本验证，确认页会明确列出本次写入的交易。")
                    .font(.system(size: 11))
                    .foregroundStyle(LedgerPalette.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(LedgerSpacing.lg)
        .background(LedgerPalette.tag.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
    }

    private func loadProviders() async {
        do {
            let updated = try await session.importProviders()
            guard !Task.isCancelled else { return }
            providers = LedgerMobileImportCapabilities.fileImportProviders(from: updated)
        } catch is CancellationError {
            return
        } catch {
            providers = []
        }
    }

    private var visibleGmailPending: [LedgerGmailPendingImport] {
        gmailPending.filter(\.isVisible)
    }

    private var gmailSectionDetail: String {
        guard let status = gmailStatus else { return "服务器处理，App 前台实时更新" }
        guard status.connected else { return status.configured ? "等待连接" : "需要服务器配置" }
        let count = visibleGmailPending.count
        return count == 0 ? "暂无待核对" : "\(count) 封待处理"
    }

    private var gmailEventTaskID: String {
        let phase = scenePhase == .active ? "active" : "inactive"
        return "\(gmailStatus?.connected == true)-\(phase)"
    }

    private func gmailStatusTitle(_ status: LedgerGmailStatus) -> String {
        if status.connected {
            return status.email.map { "已连接 \($0)" } ?? "Gmail 已连接"
        }
        return status.configured ? "连接后自动识别账单邮件" : "服务器尚未配置 Gmail"
    }

    private func gmailDeliveryDetail(_ status: LedgerGmailStatus) -> String {
        guard status.connected else {
            return "授权由服务器保管，账单仍需在 App 中预览确认。"
        }
        if status.usesServerPush {
            return gmailRealtimeConnected
                ? "Gmail 推送 · 当前页面已实时连接"
                : "Gmail 推送 · 正在连接实时更新"
        }
        return "服务器轮询 · 可点“立即同步”，当前页面仍会实时接收处理结果"
    }

    private func gmailPendingIcon(_ item: LedgerGmailPendingImport) -> String {
        if item.isReviewable { return "doc.text.magnifyingglass" }
        if item.isRetryable { return "exclamationmark.arrow.triangle.2.circlepath" }
        return "hourglass"
    }

    private func gmailPendingColor(_ item: LedgerGmailPendingImport) -> Color {
        if item.isReviewable { return LedgerPalette.cobalt }
        if item.isRetryable { return LedgerPalette.risk }
        return LedgerPalette.gold
    }

    private func pendingTitle(_ item: LedgerGmailPendingImport) -> String {
        let subject = item.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if !subject.isEmpty { return subject }
        let filename = item.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        return filename.isEmpty ? "邮件账单" : filename
    }

    private func gmailPendingDetail(_ item: LedgerGmailPendingImport) -> String {
        if item.isRetryable, let error = item.error, !error.isEmpty { return error }
        if item.isReviewable {
            let source = item.sender.isEmpty ? item.filename : item.sender
            return "\(source) · \(item.candidateCount) 条候选交易"
        }
        return "服务器正在解析、去重并生成预览"
    }

    private func refreshAll(replacingContent: Bool) async {
        async let history: Void = load(replacingContent: replacingContent)
        async let providerInfo: Void = loadProviders()
        async let gmail: Void = loadGmail(replacingContent: replacingContent)
        _ = await (history, providerInfo, gmail)
    }

    private func loadGmail(replacingContent: Bool) async {
        gmailLoadGeneration += 1
        let generation = gmailLoadGeneration
        if replacingContent || gmailStatus == nil { isLoadingGmail = true }
        defer {
            if generation == gmailLoadGeneration { isLoadingGmail = false }
        }
        do {
            let (status, pending) = try await session.gmailAutomation()
            guard !Task.isCancelled, generation == gmailLoadGeneration else { return }
            gmailStatus = status
            gmailPending = pending
            gmailErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == gmailLoadGeneration else { return }
            if gmailStatus == nil { gmailPending = [] }
            gmailErrorMessage = error.localizedDescription
        }
    }

    private func connectGmail() async {
        guard gmailAction == nil else { return }
        gmailAction = .connect
        gmailErrorMessage = nil
        gmailResultMessage = nil
        defer { gmailAction = nil }
        do {
            let url = try await session.connectGmail()
            guard !Task.isCancelled else { return }
            openURL(url)
            gmailResultMessage = "已打开 Google 授权；完成后返回 App，将自动检查连接状态。"
        } catch is CancellationError {
            return
        } catch {
            gmailErrorMessage = error.localizedDescription
        }
    }

    private func applyGmailOAuthResult(_ result: LedgerGmailOAuthResult?) async {
        guard let result, handledGmailOAuthResultID != result.id else { return }
        handledGmailOAuthResultID = result.id
        session.consumeGmailOAuthResult(id: result.id)
        switch result.status {
        case .connected:
            await loadGmail(replacingContent: false)
            if gmailStatus?.connected == true {
                gmailErrorMessage = nil
                gmailResultMessage = "Gmail 授权成功，正在接收自动账单。"
            } else {
                gmailResultMessage = nil
                gmailErrorMessage = "授权回调已返回，但服务器尚未确认连接；请刷新后重试。"
            }
        case .error:
            gmailResultMessage = nil
            gmailErrorMessage = result.reason == "cancelled"
                ? "Google 授权已取消，未更改 Gmail 连接。"
                : "Google 授权未完成，请重新连接。"
        }
    }

    private func syncGmail() async {
        guard gmailAction == nil else { return }
        gmailAction = .sync
        gmailErrorMessage = nil
        gmailResultMessage = nil
        defer { gmailAction = nil }
        do {
            let result = try await session.syncGmail()
            gmailResultMessage = result.retryPending == true
                ? "同步已接收，服务器会继续重试临时失败的邮件。"
                : "同步完成，处理了 \(result.processed ?? 0) 个邮件事件。"
            await loadGmail(replacingContent: false)
        } catch is CancellationError {
            return
        } catch {
            gmailErrorMessage = error.localizedDescription
        }
    }

    private func disconnectGmail() async {
        guard gmailAction == nil else { return }
        gmailAction = .disconnect
        gmailErrorMessage = nil
        gmailResultMessage = nil
        defer { gmailAction = nil }
        do {
            try await session.disconnectGmail()
            gmailRealtimeConnected = false
            gmailResultMessage = "Gmail 已断开；已有导入记录保持不变。"
            await loadGmail(replacingContent: false)
        } catch is CancellationError {
            return
        } catch {
            gmailErrorMessage = error.localizedDescription
        }
    }

    private func openPending(_ item: LedgerGmailPendingImport) async {
        guard gmailAction == nil else { return }
        gmailAction = .pending(item.id)
        gmailErrorMessage = nil
        defer { gmailAction = nil }
        do {
            let detail = try await session.gmailPendingImport(id: item.id)
            guard let preview = detail.preview else {
                gmailErrorMessage = "这封邮件尚未生成可核对的预览，请稍后重试。"
                return
            }
            gmailReview = GmailImportReview(itemID: detail.item.id, preview: preview)
        } catch is CancellationError {
            return
        } catch {
            gmailErrorMessage = error.localizedDescription
        }
    }

    private func retryPending(_ item: LedgerGmailPendingImport) async {
        guard gmailAction == nil else { return }
        gmailAction = .pending(item.id)
        gmailErrorMessage = nil
        gmailResultMessage = nil
        defer { gmailAction = nil }
        do {
            _ = try await session.syncGmail(pendingID: item.id)
            gmailResultMessage = "已重新处理“\(pendingTitle(item))”。"
            await loadGmail(replacingContent: false)
        } catch is CancellationError {
            return
        } catch {
            gmailErrorMessage = error.localizedDescription
        }
    }

    private func dismissPending(_ item: LedgerGmailPendingImport) async {
        guard gmailAction == nil else { return }
        pendingToDismiss = nil
        gmailAction = .pending(item.id)
        gmailErrorMessage = nil
        gmailResultMessage = nil
        defer { gmailAction = nil }
        do {
            try await session.dismissGmailPendingImport(id: item.id)
            gmailResultMessage = "已忽略“\(pendingTitle(item))”，未写入账本。"
            await loadGmail(replacingContent: false)
        } catch is CancellationError {
            return
        } catch {
            gmailErrorMessage = error.localizedDescription
        }
    }

    private func listenForGmailPendingEvents() async {
        guard scenePhase == .active, gmailStatus?.connected == true else {
            gmailRealtimeConnected = false
            return
        }
        var reconnectDelay: UInt64 = 1_000_000_000
        while !Task.isCancelled, scenePhase == .active, gmailStatus?.connected == true {
            do {
                let events = try session.gmailPendingEvents()
                for try await _ in events {
                    guard !Task.isCancelled else { return }
                    gmailRealtimeConnected = true
                    reconnectDelay = 1_000_000_000
                    await loadGmail(replacingContent: false)
                }
            } catch is CancellationError {
                return
            } catch {
                // Transient stream failures reconnect below without replacing actionable content.
            }
            gmailRealtimeConnected = false
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: reconnectDelay)
            reconnectDelay = min(reconnectDelay * 2, 30_000_000_000)
        }
        gmailRealtimeConnected = false
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) async {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            isReadingFile = true
            errorMessage = nil
            defer { isReadingFile = false }
            do {
                let file = try await Self.readImportFile(at: url, providers: providers)
                guard !Task.isCancelled else { return }
                activeImportFile = file
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        case let .failure(error):
            if (error as NSError).code != NSUserCancelledError {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func readImportFile(
        at url: URL,
        providers: [LedgerImportProviderInfo]
    ) async throws -> LedgerImportSelectedFile {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }
        return try await Task.detached(priority: .userInitiated) {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile != false else {
                throw LedgerImportFileValidationError.notRegularFile
            }
            if let byteCount = values.fileSize {
                try LedgerImportFileValidator.validate(
                    name: url.lastPathComponent,
                    byteCount: byteCount,
                    providers: providers
                )
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try LedgerImportFileValidator.validate(
                name: url.lastPathComponent,
                byteCount: data.count,
                providers: providers
            )
            return LedgerImportSelectedFile(name: url.lastPathComponent, data: data)
        }.value
    }

    private func presentDebugImportFlowIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--safe-import-flow"),
              !debugImportFlowPresented else { return }
        debugImportFlowPresented = true
        activeImportFile = LedgerImportSelectedFile(
            name: "wechat-2026-08.xlsx",
            data: Data("safe import preview".utf8)
        )
        #endif
    }

    private func load(replacingContent: Bool) async {
        if replacingContent { isLoading = true }
        isRefreshing = !replacingContent
        errorMessage = nil
        defer {
            isLoading = false
            isRefreshing = false
        }

        do {
            let updated = try await session.importDocuments()
            guard !Task.isCancelled else { return }
            documents = updated
            loadedAt = Date()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum GmailAction: Equatable {
    case connect
    case sync
    case disconnect
    case pending(String)
}

private struct GmailImportReview: Identifiable {
    let itemID: String
    let preview: LedgerImportPreview

    var id: String { itemID }
}

private struct ImportChannelRow: View {
    let status: LedgerImportChannelStatus

    var body: some View {
        HStack(spacing: LedgerSpacing.md) {
            Image(systemName: status.provider.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(width: 36, height: 36)
                .background(LedgerPalette.tag)
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(status.provider.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(1)
                Text(channelDetail)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(LedgerPalette.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(status.freshness.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 9)
                .frame(minHeight: 28)
                .background(statusColor.opacity(0.11))
                .clipShape(Capsule())
        }
        .padding(LedgerSpacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("import-provider-\(status.provider.id)")
    }

    private var channelDetail: String {
        guard let document = status.document else { return "完成首次导入后会显示覆盖日期" }
        let coverage = LedgerImportHistory.coverageText(document)
        if let days = status.daysSinceCoverage {
            return "\(coverage) · 距今 \(days) 天"
        }
        return coverage
    }

    private var statusColor: Color {
        switch status.freshness {
        case .overdue: LedgerPalette.risk
        case .attention: LedgerPalette.gold
        case .current: LedgerPalette.success
        case .missing: LedgerPalette.secondary
        }
    }
}

private struct ImportDocumentRow: View {
    let document: LedgerImportDocument

    private var provider: LedgerImportProvider? {
        LedgerImportProvider.provider(document.provider)
    }

    var body: some View {
        HStack(alignment: .top, spacing: LedgerSpacing.md) {
            Image(systemName: provider?.systemImage ?? "doc.text")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(width: 36, height: 36)
                .background(LedgerPalette.tag)
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: LedgerSpacing.sm) {
                    Text(provider?.label ?? "其他渠道")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text(LedgerImportHistory.coverageText(document))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(LedgerPalette.cobalt)
                }
                Text(document.name ?? "账单归档文件")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LedgerPalette.olive)
                    .lineLimit(1)
                HStack(spacing: LedgerSpacing.sm) {
                    Text(LedgerImportHistory.fullArchivedText(document))
                    if let size = LedgerImportHistory.fileSizeText(document) {
                        Text("·")
                        Text(size)
                    }
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(LedgerPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(LedgerImportHistory.archivedText(document))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(LedgerPalette.secondary)
                .lineLimit(1)
        }
        .padding(LedgerSpacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("import-document-\(document.id)")
    }
}
