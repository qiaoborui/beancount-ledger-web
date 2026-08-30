import Charts
import SwiftUI

struct BQLQueryView: View {
    var showsAppBar = false

    var body: some View {
        VStack(spacing: 0) {
            if showsAppBar {
                LedgerAppBar { PrivacyToolbarButton() }
            }
            BQLWorkbench()
        }
        .background(LedgerPalette.canvas)
        .navigationTitle(showsAppBar ? "" : "BQL 查询")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsAppBar ? .hidden : .visible, for: .navigationBar)
        .toolbarBackground(LedgerPalette.panel, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if !showsAppBar {
                ToolbarItem(placement: .topBarTrailing) { PrivacyToolbarButton() }
            }
        }
    }
}

private struct BQLWorkbench: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var query = BQLQueryExamples.defaultQuery
    @State private var runs: [BQLRun] = []
    @State private var activeViews: [UUID: BQLResultViewKind] = [:]
    @State private var history: [BQLHistoryRecord] = []
    @State private var historyLoading = true
    @State private var historyError: String?
    @State private var isRunning = false
    @State private var renameRecord: BQLHistoryRecord?
    @State private var renameTitle = ""
    @State private var deleteRecord: BQLHistoryRecord?
    @State private var mutationRecordID: String?
    @State private var runTask: Task<Void, Never>?

    private var statements: [String] {
        BQLStatements.split(query)
    }

    private var runSummary: String? {
        guard !runs.isEmpty else { return nil }
        let completed = runs.filter { $0.result != nil }.count
        let failed = runs.filter { $0.error != nil }.count
        let rows = runs.reduce(0) { $0 + ($1.result?.rowCount ?? 0) }
        return "\(runs.count) 条查询 · \(completed) 完成 · \(failed) 失败 · \(rows) 行"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LedgerSpacing.lg) {
                LedgerPageIntro(
                    title: "BQL 查询",
                    detail: "使用只读语句检索 postings 与 transactions，并复用服务器查询历史。",
                    meta: runSummary
                ) { EmptyView() }

                queryAndHistory

                resultsSection
            }
            .padding(.horizontal, horizontalSizeClass == .regular ? 0 : LedgerSpacing.lg)
            .padding(.bottom, horizontalSizeClass == .regular ? LedgerSpacing.xxl : LedgerLayout.compactTabBarClearance)
            .ledgerAdaptivePageWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("bql-workbench")
        .task { await loadHistory() }
        .onDisappear {
            runTask?.cancel()
            runTask = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                dismissSensitivePresentations()
            }
        }
        .onChange(of: session.privacyShielded) { _, shielded in
            if shielded {
                dismissSensitivePresentations()
            }
        }
        .alert("重命名查询", isPresented: renamePresented) {
            TextField("查询标题", text: $renameTitle)
            Button("取消", role: .cancel) { renameRecord = nil }
            Button("保存") {
                guard let record = renameRecord else { return }
                Task { await rename(record, title: renameTitle) }
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("标题最多 40 个字符。")
        }
        .confirmationDialog(
            "删除这条查询历史？",
            isPresented: deletePresented,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let record = deleteRecord else { return }
                Task { await remove(record) }
            }
            Button("取消", role: .cancel) { deleteRecord = nil }
        } message: {
            Text(deleteRecord?.title ?? "")
        }
    }

    @ViewBuilder
    private var queryAndHistory: some View {
        if horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: LedgerSpacing.lg) {
                editorPanel
                    .frame(maxWidth: .infinity)
                historyPanel
                    .frame(width: 304)
            }
        } else {
            VStack(alignment: .leading, spacing: LedgerSpacing.lg) {
                editorPanel
                historyPanel
            }
        }
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LedgerSpacing.md) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LedgerPalette.cobalt)
                    .frame(width: 34, height: 34)
                    .background(LedgerPalette.tag)
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("查询编辑器")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text("\(statements.count) 条语句 · 最多 12,000 字符")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(query.count > 12_000 ? LedgerPalette.risk : LedgerPalette.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    startRun(statements, historyQuery: query.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    HStack(spacing: LedgerSpacing.sm) {
                        if isRunning {
                            ProgressView().tint(LedgerPalette.onBrand)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(isRunning ? "运行中" : "全部运行")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(LedgerPalette.onBrand)
                    .padding(.horizontal, LedgerSpacing.lg)
                    .frame(minHeight: 40)
                    .background(LedgerPalette.cobalt)
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                }
                .buttonStyle(PressScaleButtonStyle())
                .disabled(statements.isEmpty || isRunning || query.count > 12_000)
                .opacity(statements.isEmpty || query.count > 12_000 ? 0.48 : 1)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("bql-run-all")
            }
            .padding(LedgerSpacing.md)

            Divider().overlay(LedgerPalette.line)

            TextEditor(text: $query)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(LedgerPalette.ink)
                .scrollContentBackground(.hidden)
                .padding(LedgerSpacing.sm)
                .frame(minHeight: 196)
                .background(LedgerPalette.raised.opacity(0.72))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel("BQL 查询编辑器")
                .accessibilityIdentifier("bql-editor")

            Divider().overlay(LedgerPalette.line)

            HStack(alignment: .top, spacing: LedgerSpacing.sm) {
                Image(systemName: "command")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LedgerPalette.gold)
                Text("⌘ Return 运行全部语句。支持 AND / OR / NOT、IN、BETWEEN、正则、DISTINCT 与 HAVING。")
                    .font(.system(size: 10))
                    .foregroundStyle(LedgerPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(LedgerSpacing.md)
        }
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LedgerSpacing.sm) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LedgerPalette.gold)
                Text(history.isEmpty ? "示例查询" : "查询历史")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                Spacer(minLength: 0)
                if !history.isEmpty {
                    Text("\(history.count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(LedgerPalette.cobalt)
                        .padding(.horizontal, LedgerSpacing.sm)
                        .frame(minHeight: 24)
                        .background(LedgerPalette.tag)
                        .clipShape(Capsule())
                }
            }
            .padding(LedgerSpacing.md)

            Divider().overlay(LedgerPalette.line)

            if historyLoading {
                HStack(spacing: LedgerSpacing.sm) {
                    ProgressView().tint(LedgerPalette.cobalt)
                    Text("正在加载查询历史")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .padding(LedgerSpacing.lg)
            } else {
                if let historyError {
                    HStack(alignment: .top, spacing: LedgerSpacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(LedgerPalette.risk)
                        Text(historyError)
                            .font(.system(size: 10))
                            .foregroundStyle(LedgerPalette.warm)
                    }
                    .padding(LedgerSpacing.md)
                }

                VStack(spacing: 0) {
                    if history.isEmpty {
                        ForEach(BQLQueryExamples.all) { example in
                            exampleRow(example)
                            if example.id != BQLQueryExamples.all.last?.id {
                                Divider().overlay(LedgerPalette.line).padding(.leading, LedgerSpacing.md)
                            }
                        }
                    } else {
                        ForEach(history) { record in
                            historyRow(record)
                            if record.id != history.last?.id {
                                Divider().overlay(LedgerPalette.line).padding(.leading, LedgerSpacing.md)
                            }
                        }
                    }
                }
            }
        }
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
    }

    private func exampleRow(_ example: BQLQueryExample) -> some View {
        Button {
            query = example.query
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(example.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                Text(example.query.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(LedgerPalette.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LedgerSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel("使用示例：\(example.title)")
    }

    private func historyRow(_ record: BQLHistoryRecord) -> some View {
        HStack(alignment: .top, spacing: LedgerSpacing.sm) {
            Button {
                query = record.query
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                        .lineLimit(1)
                    Text(record.query.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LedgerPalette.secondary)
                        .lineLimit(2)
                    Text("\(BQLHistoryDateText.format(record.lastRunAt)) · \(record.runCount) 次")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())

            Menu {
                Button {
                    query = record.query
                    startRun(BQLStatements.split(record.query), historyQuery: record.query)
                } label: {
                    Label("运行查询", systemImage: "play.fill")
                }
                Button {
                    renameTitle = record.title
                    renameRecord = record
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    deleteRecord = record
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: mutationRecordID == record.id ? "arrow.triangle.2.circlepath" : "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LedgerPalette.cobalt)
                    .frame(width: 40, height: 40)
                    .background(LedgerPalette.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
            }
            .disabled(mutationRecordID == record.id || isRunning)
            .accessibilityLabel("管理查询 \(record.title)")
            .accessibilityIdentifier("bql-history-menu-\(record.id)")
        }
        .padding(LedgerSpacing.md)
    }

    @ViewBuilder
    private var resultsSection: some View {
        if runs.isEmpty {
            LedgerPanel {
                HStack(spacing: LedgerSpacing.md) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(LedgerPalette.cobalt)
                        .frame(width: 42, height: 42)
                        .background(LedgerPalette.tag)
                        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("等待查询结果")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LedgerPalette.ink)
                        Text("运行 BQL 后，这里会显示表格或图表。")
                            .font(.system(size: 11))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                }
                .padding(LedgerSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                BQLResultPanel(
                    run: run,
                    index: index,
                    activeView: activeViews[run.id] ?? .table,
                    onViewChange: { activeViews[run.id] = $0 }
                )
            }
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameRecord != nil },
            set: { if !$0 { renameRecord = nil } }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { deleteRecord != nil },
            set: { if !$0 { deleteRecord = nil } }
        )
    }

    private func startRun(_ requestedStatements: [String], historyQuery: String) {
        guard !isRunning else { return }
        runTask?.cancel()
        runTask = Task {
            await execute(requestedStatements, historyQuery: historyQuery)
        }
    }

    @MainActor
    private func execute(_ requestedStatements: [String], historyQuery: String) async {
        let selected = requestedStatements
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !selected.isEmpty, !isRunning else { return }

        isRunning = true
        runs = selected.map { BQLRun(query: $0) }
        activeViews = [:]
        defer { isRunning = false }

        var allSucceeded = true
        for index in runs.indices {
            guard !Task.isCancelled else { return }
            do {
                let result = try await session.runBQL(query: runs[index].query)
                guard !Task.isCancelled else { return }
                runs[index].result = result
            } catch is CancellationError {
                return
            } catch {
                allSucceeded = false
                runs[index].error = error.localizedDescription
            }
        }

        if allSucceeded, !historyQuery.isEmpty {
            await remember(historyQuery)
        }
    }

    @MainActor
    private func loadHistory() async {
        let snapshot = history
        historyLoading = true
        defer { historyLoading = false }
        do {
            let loaded = try await session.loadBQLHistory()
            history = sortHistory(
                BQLHistoryMerge.reconcile(loaded: loaded, snapshot: snapshot, current: history)
            )
            historyError = nil
        } catch is CancellationError {
            return
        } catch {
            historyError = "查询历史暂时无法加载"
        }
    }

    @MainActor
    private func remember(_ query: String) async {
        do {
            let record = try await session.saveBQLHistory(query: query)
            history = sortHistory([record] + history.filter { $0.id != record.id })
            historyError = nil

            do {
                let titled = try await session.generateBQLHistoryTitle(id: record.id)
                history = history.map { $0.id == titled.id ? titled : $0 }
            } catch is CancellationError {
                return
            } catch {
                // The server fallback title remains usable.
            }
        } catch is CancellationError {
            return
        } catch {
            historyError = "查询已完成，历史未同步"
        }
    }

    @MainActor
    private func rename(_ record: BQLHistoryRecord, title: String) async {
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !trimmed.isEmpty else { return }
        renameRecord = nil
        mutationRecordID = record.id
        defer { mutationRecordID = nil }
        do {
            let updated = try await session.renameBQLHistory(id: record.id, title: trimmed)
            history = history.map { $0.id == updated.id ? updated : $0 }
            historyError = nil
        } catch is CancellationError {
            return
        } catch {
            historyError = "标题保存失败"
        }
    }

    @MainActor
    private func remove(_ record: BQLHistoryRecord) async {
        deleteRecord = nil
        mutationRecordID = record.id
        defer { mutationRecordID = nil }
        do {
            try await session.deleteBQLHistory(id: record.id)
            history.removeAll { $0.id == record.id }
            historyError = nil
        } catch is CancellationError {
            return
        } catch {
            historyError = "历史记录删除失败"
        }
    }

    private func sortHistory(_ records: [BQLHistoryRecord]) -> [BQLHistoryRecord] {
        records.sorted { $0.lastRunAt > $1.lastRunAt }
    }

    private func dismissSensitivePresentations() {
        renameRecord = nil
        renameTitle = ""
        deleteRecord = nil
    }
}

private struct BQLRun: Identifiable {
    let id = UUID()
    let query: String
    var result: BQLResult?
    var error: String?
}

private enum BQLResultViewKind: String, CaseIterable {
    case table
    case bar
    case pie
    case line

    var title: String {
        switch self {
        case .table: "表格"
        case .bar: "柱状图"
        case .pie: "饼图"
        case .line: "折线图"
        }
    }

    var systemImage: String {
        switch self {
        case .table: "tablecells"
        case .bar: "chart.bar"
        case .pie: "chart.pie"
        case .line: "chart.xyaxis.line"
        }
    }
}

private struct BQLResultPanel: View {
    @EnvironmentObject private var session: LedgerSession

    let run: BQLRun
    let index: Int
    let activeView: BQLResultViewKind
    let onViewChange: (BQLResultViewKind) -> Void

    private var chartModel: BQLChartModel? {
        run.result.flatMap(BQLChartModel.init)
    }

    private var visibleView: BQLResultViewKind {
        supports(activeView) ? activeView : .table
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: LedgerSpacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("结果 \(index + 1)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text(run.query.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LedgerPalette.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let result = run.result {
                    VStack(alignment: .trailing, spacing: LedgerSpacing.sm) {
                        Text("\(result.rowCount) 行 · \(result.valuationCurrency)")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(LedgerPalette.secondary)
                        resultModeButtons
                    }
                }
            }
            .padding(LedgerSpacing.md)

            Divider().overlay(LedgerPalette.line)

            if let error = run.error {
                HStack(alignment: .top, spacing: LedgerSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(LedgerPalette.risk)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerPalette.warm)
                        .textSelection(.enabled)
                }
                .padding(LedgerSpacing.lg)
            } else if let result = run.result {
                if !result.warnings.isEmpty {
                    BQLWarningList(warnings: result.warnings)
                }

                if result.rows.isEmpty {
                    HStack(spacing: LedgerSpacing.sm) {
                        Image(systemName: "tray")
                            .foregroundStyle(LedgerPalette.cobalt)
                        Text("查询完成，没有返回行。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    .padding(LedgerSpacing.lg)
                } else if visibleView == .table {
                    BQLResultTable(result: result)
                } else if let chartModel {
                    BQLResultChart(model: chartModel, kind: visibleView)
                }
            } else {
                HStack(spacing: LedgerSpacing.sm) {
                    ProgressView().tint(LedgerPalette.cobalt)
                    Text("正在运行这条查询")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .padding(LedgerSpacing.lg)
            }
        }
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
        .accessibilityIdentifier("bql-result-\(index + 1)")
    }

    private var resultModeButtons: some View {
        HStack(spacing: 1) {
            ForEach(BQLResultViewKind.allCases, id: \.self) { kind in
                let enabled = supports(kind)
                Button {
                    onViewChange(kind)
                } label: {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(visibleView == kind ? LedgerPalette.onBrand : LedgerPalette.secondary)
                        .frame(width: 34, height: 30)
                        .background(visibleView == kind ? LedgerPalette.cobalt : LedgerPalette.canvas)
                }
                .buttonStyle(PressScaleButtonStyle())
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.36)
                .accessibilityLabel(kind.title)
                .accessibilityAddTraits(visibleView == kind ? .isSelected : [])
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
    }

    private func supports(_ kind: BQLResultViewKind) -> Bool {
        switch kind {
        case .table:
            true
        case .bar:
            chartModel?.data.isEmpty == false
        case .pie:
            chartModel?.data.contains { $0.value > 0 } == true
        case .line:
            chartModel?.canLine == true
        }
    }
}

private struct BQLWarningList: View {
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            ForEach(warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: LedgerSpacing.sm) {
                    Circle()
                        .fill(LedgerPalette.gold)
                        .frame(width: 6, height: 6)
                        .padding(.top, 4)
                    Text(warning)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LedgerPalette.warm)
                }
            }
        }
        .padding(.horizontal, LedgerSpacing.md)
        .padding(.vertical, LedgerSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LedgerPalette.tag.opacity(0.62))
        .overlay(alignment: .bottom) { Rectangle().fill(LedgerPalette.line).frame(height: 1) }
    }
}

private struct BQLResultTable: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let result: BQLResult

    private var widths: [CGFloat] {
        result.columns.map { column in
            if horizontalSizeClass == .regular {
                if column.isNumeric { return 144 }
                if column.isTimeDimension { return 120 }
                return 672
            }
            if column.isNumeric { return 104 }
            if column.isTimeDimension { return 80 }
            return 190
        }
    }

    private var totalWidth: CGFloat {
        max(widths.reduce(0, +), 320)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(result.rows.indices, id: \.self) { rowIndex in
                        HStack(spacing: 0) {
                            ForEach(result.columns.indices, id: \.self) { columnIndex in
                                BQLCellText(
                                    cell: result.rows[rowIndex].indices.contains(columnIndex)
                                        ? result.rows[rowIndex][columnIndex]
                                        : .null,
                                    column: result.columns[columnIndex]
                                )
                                .padding(.horizontal, LedgerSpacing.md)
                                .frame(
                                    width: widths[columnIndex],
                                    alignment: result.columns[columnIndex].isNumeric ? .trailing : .leading
                                )
                            }
                        }
                        .frame(height: 42)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(rowIndex.isMultiple(of: 2) ? LedgerPalette.panel : LedgerPalette.canvas.opacity(0.54))
                        .overlay(alignment: .bottom) { Rectangle().fill(LedgerPalette.line).frame(height: 1) }
                    }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(result.columns.indices, id: \.self) { columnIndex in
                            Text(result.columns[columnIndex].name)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(LedgerPalette.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, LedgerSpacing.md)
                                .frame(
                                    width: widths[columnIndex],
                                    alignment: result.columns[columnIndex].isNumeric ? .trailing : .leading
                                )
                        }
                    }
                    .frame(height: 36)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LedgerPalette.tag)
                    .overlay(alignment: .bottom) { Rectangle().fill(LedgerPalette.lineStrong).frame(height: 1) }
                }
            }
            .containerRelativeFrame(.horizontal, alignment: .leading) { availableWidth, _ in
                max(availableWidth, totalWidth)
            }
        }
        .accessibilityLabel("BQL 查询结果表格，\(result.rowCount) 行")
    }
}

private struct BQLCellText: View {
    @EnvironmentObject private var session: LedgerSession

    let cell: BQLCell
    let column: BQLColumn

    private var text: String {
        if column.type == "money" {
            guard session.amountsVisible else { return "••••••" }
            guard let value = cell.numberValue else { return cell.plainText }
            return BQLNumberText.money(value)
        }
        if column.type == "number", let value = cell.numberValue {
            return BQLNumberText.number(value)
        }
        return cell.plainText
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: column.isNumeric ? .medium : .regular, design: .monospaced))
            .foregroundStyle(LedgerPalette.ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .accessibilityLabel(column.type == "money" && !session.amountsVisible ? "金额已隐藏" : text)
    }
}

private struct BQLChartDatum: Identifiable {
    let id: Int
    let label: String
    let value: Double
}

private struct BQLChartModel {
    let labelColumn: BQLColumn
    let valueColumn: BQLColumn
    let data: [BQLChartDatum]
    let canLine: Bool

    init?(_ result: BQLResult) {
        guard let valueIndex = result.columns.firstIndex(where: \.isNumeric),
              let labelIndex = result.columns.indices.first(where: {
                  $0 != valueIndex && !result.columns[$0].isNumeric
              }) else {
            return nil
        }
        let values = result.rows.enumerated().compactMap { index, row -> BQLChartDatum? in
            guard row.indices.contains(valueIndex),
                  let value = row[valueIndex].numberValue,
                  value.isFinite else {
                return nil
            }
            let label: String
            if row.indices.contains(labelIndex), !row[labelIndex].plainText.isEmpty {
                label = row[labelIndex].plainText
            } else {
                label = "行 \(index + 1)"
            }
            return BQLChartDatum(id: index, label: label, value: value)
        }
        guard !values.isEmpty else { return nil }
        labelColumn = result.columns[labelIndex]
        valueColumn = result.columns[valueIndex]
        data = values
        canLine = labelColumn.isTimeDimension
    }
}

private struct BQLResultChart: View {
    @EnvironmentObject private var session: LedgerSession

    let model: BQLChartModel
    let kind: BQLResultViewKind

    private var visibleData: [BQLChartDatum] {
        if kind == .pie {
            return Array(model.data.filter { $0.value > 0 }.prefix(12))
        }
        return Array(model.data.prefix(80))
    }

    var body: some View {
        if model.valueColumn.type == "money" && !session.amountsVisible {
            VStack(spacing: LedgerSpacing.sm) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(LedgerPalette.cobalt)
                Text("显示金额后可查看图表")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 230)
            .accessibilityLabel("金额已隐藏")
        } else {
            chart
                .frame(height: 250)
                .padding(LedgerSpacing.lg)
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch kind {
        case .bar:
            Chart(visibleData) { item in
                BarMark(
                    x: .value(model.labelColumn.name, item.label),
                    y: .value(model.valueColumn.name, displayValue(item.value))
                )
                .foregroundStyle(LedgerPalette.cobalt)
                .cornerRadius(3)
            }
            .chartXAxis(.hidden)
            .chartYAxis { chartAxisMarks }
        case .line:
            Chart(visibleData) { item in
                LineMark(
                    x: .value(model.labelColumn.name, item.label),
                    y: .value(model.valueColumn.name, displayValue(item.value))
                )
                .foregroundStyle(LedgerPalette.cobalt)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                PointMark(
                    x: .value(model.labelColumn.name, item.label),
                    y: .value(model.valueColumn.name, displayValue(item.value))
                )
                .foregroundStyle(LedgerPalette.gold)
                .symbolSize(18)
            }
            .chartXAxis(.hidden)
            .chartYAxis { chartAxisMarks }
        case .pie:
            Chart(visibleData) { item in
                SectorMark(
                    angle: .value(model.valueColumn.name, displayValue(item.value)),
                    innerRadius: .ratio(0.5),
                    angularInset: 1
                )
                .cornerRadius(2)
                .foregroundStyle(BQLChartColors.color(item.id))
            }
            .chartLegend(.hidden)
        case .table:
            EmptyView()
        }
    }

    private func displayValue(_ value: Double) -> Double {
        model.valueColumn.type == "money" ? value / 100 : value
    }

    @AxisContentBuilder
    private var chartAxisMarks: some AxisContent {
        AxisMarks(position: .leading) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(LedgerPalette.line)
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(BQLNumberText.compact(number))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }
        }
    }
}

private enum BQLChartColors {
    private static let palette = [
        LedgerPalette.cobalt,
        LedgerPalette.gold,
        LedgerPalette.income,
        LedgerPalette.cobaltLight,
        LedgerPalette.expense,
        LedgerPalette.olive,
    ]

    static func color(_ index: Int) -> Color {
        palette[index % palette.count]
    }
}

private enum BQLNumberText {
    static func money(_ minorUnits: Double) -> String {
        decimal(minorUnits / 100, minimumFractionDigits: 2, maximumFractionDigits: 2)
    }

    static func number(_ value: Double) -> String {
        decimal(value, minimumFractionDigits: 0, maximumFractionDigits: 6)
    }

    static func compact(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        let absolute = abs(value)
        let scaled: (Double, String)
        switch absolute {
        case 100_000_000...: scaled = (value / 100_000_000, "亿")
        case 10_000...: scaled = (value / 10_000, "w")
        case 1_000...: scaled = (value / 1_000, "k")
        default: scaled = (value, "")
        }
        return "\(formatter.string(from: NSNumber(value: scaled.0)) ?? String(scaled.0))\(scaled.1)"
    }

    private static func decimal(
        _ value: Double,
        minimumFractionDigits: Int,
        maximumFractionDigits: Int
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

private enum BQLHistoryDateText {
    static func format(_ raw: String) -> String {
        let input = ISO8601DateFormatter()
        input.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = input.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return "刚刚运行" }
        let output = DateFormatter()
        output.locale = Locale(identifier: "zh_CN")
        output.dateFormat = "M月d日 HH:mm"
        return output.string(from: date)
    }
}

private struct BQLQueryExample: Identifiable {
    let id: String
    let title: String
    let query: String
}

private enum BQLQueryExamples {
    private static var year: Int {
        Calendar.current.component(.year, from: Date())
    }

    static var defaultQuery: String {
        """
        SELECT month, account, sum(value) AS total
        FROM postings
        WHERE date >= '\(year)-01-01' AND account LIKE 'Expenses:%'
        GROUP BY month, account
        ORDER BY month DESC, total DESC
        LIMIT 100
        """
    }

    static var all: [BQLQueryExample] {
        [
            BQLQueryExample(id: "monthly", title: "月度分类支出", query: defaultQuery),
            BQLQueryExample(
                id: "merchants",
                title: "商户排行",
                query: """
                SELECT payee, count(*) AS tx_count, sum(value) AS total
                FROM transactions
                WHERE date >= '\(year)-01-01' AND type = 'expense'
                GROUP BY payee
                ORDER BY total DESC
                LIMIT 50
                """
            ),
            BQLQueryExample(
                id: "income",
                title: "收入账户",
                query: """
                SELECT month, account, sum(value) AS total
                FROM postings
                WHERE account LIKE 'Income:%'
                GROUP BY month, account
                ORDER BY month DESC
                LIMIT 100
                """
            ),
            BQLQueryExample(
                id: "compound",
                title: "复合条件与聚合筛选",
                query: """
                SELECT payee, count(*) AS tx_count, sum(value) AS total
                FROM transactions
                WHERE (payee ~ 'coffee|store' OR 'food' IN tags) AND date BETWEEN '\(year)-01-01' AND '\(year)-12-31'
                GROUP BY payee
                HAVING tx_count >= 2 OR total > 1000
                ORDER BY total DESC
                LIMIT 50
                """
            ),
        ]
    }
}
