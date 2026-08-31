import SwiftUI
import UniformTypeIdentifiers

struct ImportHistoryView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
            allowedContentTypes: [.item],
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
        .task {
            await load(replacingContent: true)
            await loadProviders()
            presentDebugImportFlowIfNeeded()
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
                Task { await load(replacingContent: true) }
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
        .refreshable { await load(replacingContent: false) }
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
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(LedgerPalette.cobalt)
            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(isReadingFile)
        .accessibilityIdentifier("import-select-file")
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
            providers = updated
        } catch is CancellationError {
            return
        } catch {
            providers = []
        }
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
