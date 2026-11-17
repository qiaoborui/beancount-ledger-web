#if os(iOS)
import SwiftUI

/// 定时任务, from the assistant's drawer. The tasks come first: each file in
/// the ledger's automations/ folder with its schedule, next run and last
/// result; they are created, edited, paused and deleted here and reach the
/// always-on host through Git sync. Below them, every run the host pushed,
/// newest first. A run opens as a conversation to continue, with its draft
/// on the change card the first time.
struct LedgerAutomationView: View {
    /// Opens the run's conversation on the chat page; true reloads its draft.
    var onOpen: (LedgerAutomationRun, Bool) -> Void

    @ObservedObject private var center = LedgerAutomationCenter.shared
    @State private var editing: EditorTarget?
    @State private var failure: String?

    var body: some View {
        List {
            if let error = center.error {
                Section {
                    Label {
                        Text(verbatim: error).balancedFont(size: 13).foregroundStyle(BalancedPalette.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(BalancedPalette.secondary)
                    }
                }
            }
            tasksSection
            runsSection
        }
        .navigationTitle("定时任务")
        .terminalNativeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { newTaskMenu }
        }
        .refreshable { await center.refresh() }
        .task {
            await center.refresh()
            center.markSeen()
        }
        .onDisappear { center.markSeen() }
        .sheet(item: $editing) { target in
            NavigationStack {
                LedgerAutomationTaskEditor(task: target.task, isNew: target.isNew,
                                           takenIDs: Set(center.tasks.tasks.map(\.id)))
            }
            .ledgerPrivacyProtectedSheet()
        }
        .alert("没有保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(verbatim: failure ?? "")
        }
    }

    struct EditorTarget: Identifiable {
        let id = UUID()
        let task: LedgerAutomationTask
        let isNew: Bool
    }

    // MARK: Tasks

    private var newTaskMenu: some View {
        Menu {
            Button { startNew(nil) } label: { Label("空白任务", systemImage: "square.and.pencil") }
            Section("从模板开始") {
                ForEach(LedgerAutomationTask.templates(timezone: TimeZone.current.identifier), id: \.id) { template in
                    Button(template.name) { startNew(template) }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("新建任务")
        .accessibilityIdentifier("ledger-automation-new-task")
    }

    private func startNew(_ template: LedgerAutomationTask?) {
        let taken = Set(center.tasks.tasks.map(\.id))
        var task = template ?? LedgerAutomationTask(id: "", name: "", schedule: .init(kind: .daily, hour: 21, minute: 0),
                                                    timezone: TimeZone.current.identifier, prompt: "")
        task.id = LedgerAutomationTask.newID(for: template?.id ?? "task", taken: taken)
        editing = EditorTarget(task: task, isNew: true)
    }

    @ViewBuilder private var tasksSection: some View {
        Section {
            if center.tasks.tasks.isEmpty && center.tasks.problems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("还没有任务").balancedFont(size: 15, weight: .medium).foregroundStyle(BalancedPalette.ink)
                    Text("点右上角的 + 新建一个，比如每天晚上巡检一次账本。任务存在账本仓库的 automations/ 里，随 Git 同步到家里常开的机器，由它按时运行。")
                        .balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                }
                .padding(.vertical, 6)
            }
            ForEach(center.tasks.tasks) { task in taskRow(task) }
            ForEach(center.tasks.problems.sorted(by: { $0.key < $1.key }), id: \.key) { id, problem in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "automations/\(id).md").balancedFont(size: 14, weight: .medium)
                        .foregroundStyle(BalancedPalette.ink)
                    Text(verbatim: problem).balancedFont(size: 12).foregroundStyle(BalancedPalette.secondary)
                }
            }
        } header: {
            Text("任务")
        } footer: {
            if !center.tasks.tasks.isEmpty {
                Text(center.availability == .none
                     ? "改动随账本同步到仓库。还没收到主机的运行记录：确认家里的机器装好了 ledger-automation。"
                     : "改动随账本同步到仓库，主机最多 5 分钟后读到。")
            }
        }
    }

    private func taskRow(_ task: LedgerAutomationTask) -> some View {
        NavigationLink {
            LedgerAutomationTaskDetail(taskID: task.id, onOpen: onOpen,
                                       edit: { editing = EditorTarget(task: $0, isNew: false) })
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: task.name).balancedFont(size: 15, weight: .medium)
                        .foregroundStyle(task.enabled ? BalancedPalette.ink : BalancedPalette.meta).lineLimit(1)
                    Spacer(minLength: 6)
                    if !task.enabled {
                        Text("已暂停").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    }
                }
                Text(verbatim: LedgerAutomationTaskText.caption(task, state: center.states[task.id], runs: center.runs(of: task.id)))
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).lineLimit(2)
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .leading) {
            Button(task.enabled ? "暂停" : "启用") { toggle(task) }
                .tint(BalancedPalette.secondary)
        }
        .contextMenu {
            Button { editing = EditorTarget(task: task, isNew: false) } label: { Label("编辑", systemImage: "pencil") }
            Button { toggle(task) } label: {
                task.enabled ? Label("暂停", systemImage: "pause") : Label("启用", systemImage: "play")
            }
        }
        .accessibilityIdentifier("ledger-automation-task")
    }

    private func toggle(_ task: LedgerAutomationTask) {
        Task {
            do { try await center.setEnabled(!task.enabled, for: task) } catch { failure = error.localizedDescription }
        }
    }

    // MARK: Runs

    @ViewBuilder private var runsSection: some View {
        Section {
            if center.availability == .unknown, center.refreshing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在读取运行记录…").balancedFont(size: 14).foregroundStyle(BalancedPalette.meta)
                }
            } else if center.runs.isEmpty {
                Text(center.availability == .none
                     ? "还没有运行记录。家里常开的机器装好 ledger-automation 后，每次运行会推到账本仓库的 automation-runs 分支，结果就出现在这里。账本需要用 Git 同步。"
                     : "还没有运行记录，任务到点运行后会出现在这里。")
                    .balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    .padding(.vertical, 4)
            }
            ForEach(center.runs) { run in LedgerAutomationRunRow(run: run, onOpen: onOpen) }
        } header: {
            Text("运行记录")
        }
    }
}

/// One task: what it does, when, and its runs, from the task list.
private struct LedgerAutomationTaskDetail: View {
    let taskID: String
    var onOpen: (LedgerAutomationRun, Bool) -> Void
    var edit: (LedgerAutomationTask) -> Void

    @ObservedObject private var center = LedgerAutomationCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var failure: String?

    private var task: LedgerAutomationTask? { center.tasks.tasks.first { $0.id == taskID } }

    var body: some View {
        List {
            if let task {
                Section {
                    LabeledContent("频率", value: task.schedule.title)
                    if let next = task.enabled ? task.schedule.nextSlot(after: Date(), in: task.zone) : nil {
                        LabeledContent("下次运行", value: next.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("状态", value: task.enabled ? String(localized: "启用") : String(localized: "已暂停"))
                    LabeledContent("先跑确定性巡检", value: task.audit ? String(localized: "是") : String(localized: "否"))
                    if !task.model.isEmpty { LabeledContent("模型", value: task.model) }
                } footer: {
                    Text(verbatim: "automations/\(task.id).md")
                }
                Section("要助手做什么") {
                    Text(verbatim: task.prompt).balancedFont(size: 14).foregroundStyle(BalancedPalette.ink)
                        .textSelection(.enabled)
                }
                Section("运行记录") {
                    let runs = center.runs(of: task.id)
                    if runs.isEmpty {
                        Text("还没有运行过。").balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    }
                    ForEach(runs) { run in LedgerAutomationRunRow(run: run, onOpen: onOpen, showsTask: false) }
                }
                Section {
                    Button(task.enabled ? "暂停任务" : "启用任务") {
                        Task {
                            do { try await center.setEnabled(!task.enabled, for: task) }
                            catch { failure = error.localizedDescription }
                        }
                    }
                    Button("删除任务", role: .destructive) { confirmingDelete = true }
                }
            } else {
                Text("这个任务已经不在账本里了。").balancedFont(size: 14).foregroundStyle(BalancedPalette.meta)
            }
        }
        .navigationTitle(task?.name ?? String(localized: "任务"))
        .navigationBarTitleDisplayMode(.inline)
        .terminalNativeChrome()
        .toolbar {
            if let task {
                ToolbarItem(placement: .topBarTrailing) { Button("编辑") { edit(task) } }
            }
        }
        .confirmationDialog("删除这个任务？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task {
                    do {
                        try await center.delete(taskID)
                        dismiss()
                    } catch { failure = error.localizedDescription }
                }
            }
        } message: {
            Text("任务文件会从账本仓库删掉，已有的运行记录和对话会留着。")
        }
        .alert("没有保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(verbatim: failure ?? "")
        }
    }
}

private struct LedgerAutomationRunRow: View {
    let run: LedgerAutomationRun
    var onOpen: (LedgerAutomationRun, Bool) -> Void
    var showsTask = true

    var body: some View {
        Button {
            onOpen(run, false)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .regular))
                    .foregroundStyle(run.status == .ok ? BalancedPalette.ink : BalancedPalette.secondary)
                    .frame(width: 22)
                    .accessibilityLabel(run.statusText)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: showsTask ? run.taskName : run.slot.formatted(date: .abbreviated, time: .shortened))
                            .balancedFont(size: 15, weight: .medium)
                            .foregroundStyle(BalancedPalette.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        if showsTask {
                            Text(run.slot.formatted(date: .abbreviated, time: .shortened))
                                .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                        }
                    }
                    if !run.summary.isEmpty {
                        Text(verbatim: run.summary).balancedFont(size: 13).foregroundStyle(BalancedPalette.secondary)
                            .lineLimit(2)
                    }
                    Text(verbatim: LedgerAutomationTaskText.caption(run)).balancedFont(size: 12)
                        .foregroundStyle(BalancedPalette.meta)
                }
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(run.status != .ok)
        .contextMenu {
            if run.status == .ok {
                Button { onOpen(run, false) } label: { Label("打开对话", systemImage: "bubble.left") }
                if run.hasDraft {
                    Button { onOpen(run, true) } label: { Label("重新载入草稿", systemImage: "arrow.down.doc") }
                }
            }
        }
        .accessibilityIdentifier("ledger-automation-run")
    }

    private var symbol: String {
        switch run.status {
        case .ok: "checkmark.circle"
        case .degraded: "clock.arrow.circlepath"
        case .failed: "exclamationmark.circle"
        }
    }
}

/// Creates or edits a task: a form over the frontmatter and the prompt.
private struct LedgerAutomationTaskEditor: View {
    @State var task: LedgerAutomationTask
    let isNew: Bool
    let takenIDs: Set<String>

    @ObservedObject private var center = LedgerAutomationCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var failure: String?
    @State private var showsAdvanced = false

    private var time: Binding<Date> {
        Binding(get: {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = task.zone
            return calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: task.schedule.hour,
                                                      minute: task.schedule.minute)) ?? Date()
        }, set: { date in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = task.zone
            task.schedule.hour = calendar.component(.hour, from: date)
            task.schedule.minute = calendar.component(.minute, from: date)
        })
    }

    private var canSave: Bool {
        !task.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (task.schedule.kind != .weekly || !task.schedule.weekdays.isEmpty)
            && LedgerAutomationTask.isValidID(task.id) && !saving
    }

    var body: some View {
        Form {
            Section {
                TextField("名称，比如：每日巡检", text: $task.name)
                Toggle("启用", isOn: $task.enabled)
            }
            Section {
                Picker("频率", selection: $task.schedule.kind) {
                    ForEach(LedgerAutomationSchedule.Kind.allCases) { Text($0.title).tag($0) }
                }
                switch task.schedule.kind {
                case .hourly:
                    Stepper(value: $task.schedule.minute, in: 0...59) {
                        Text("每小时第 \(task.schedule.minute) 分")
                    }
                case .daily:
                    DatePicker("时间", selection: time, displayedComponents: .hourAndMinute)
                case .weekly:
                    weekdayPicker
                    DatePicker("时间", selection: time, displayedComponents: .hourAndMinute)
                case .monthly:
                    Stepper(value: $task.schedule.dayOfMonth, in: 1...31) {
                        Text("每月 \(task.schedule.dayOfMonth) 日")
                    }
                    DatePicker("时间", selection: time, displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("什么时候跑")
            } footer: {
                if let next = task.schedule.nextSlot(after: Date(), in: task.zone) {
                    Text("下次：\(next.formatted(date: .abbreviated, time: .shortened))（\(task.zone.identifier)）")
                }
            }
            Section {
                TextEditor(text: $task.prompt)
                    .frame(minHeight: 160)
                    .balancedFont(size: 15)
            } header: {
                Text("要助手做什么")
            } footer: {
                Text("助手无人值守地跑完这一轮：只起草改动，不会写入账本；结果会推送到手机，打开后可以接着问，草稿确认后才写入。")
            }
            Section {
                Toggle("先跑确定性巡检", isOn: $task.audit)
                DisclosureGroup("高级", isExpanded: $showsAdvanced) {
                    TextField("模型（留空用主机默认）", text: $task.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("思考强度", selection: $task.thinking) {
                        ForEach(LedgerAutomationTask.thinkingLevels, id: \.self) { level in
                            Text(level.isEmpty ? String(localized: "主机默认") : level).tag(level)
                        }
                    }
                    if isNew {
                        TextField("文件名", text: $task.id)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            } footer: {
                Text("确定性巡检不调用模型：查重复、待处理、很久没对账和没被 include 的文件，结果交给助手核实。")
            }
        }
        .navigationTitle(isNew ? "新建任务" : "编辑任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button("保存") { save() }.disabled(!canSave) }
            }
        }
        .alert("没有保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(verbatim: failure ?? "")
        }
        .interactiveDismissDisabled(saving)
    }

    private var weekdayPicker: some View {
        HStack(spacing: 6) {
            // Monday first, as a Chinese calendar reads.
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                let on = task.schedule.weekdays.contains(day)
                Button {
                    if on { task.schedule.weekdays.remove(day) } else { task.schedule.weekdays.insert(day) }
                } label: {
                    Text(verbatim: LedgerAutomationSchedule.weekdayTitles[day - 1])
                        .balancedFont(size: 14, weight: on ? .medium : .regular)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundStyle(on ? BalancedPalette.page : BalancedPalette.ink)
                        .background(Circle().fill(on ? BalancedPalette.ink : Color.clear))
                        .overlay(Circle().stroke(BalancedPalette.meta.opacity(on ? 0 : 0.4)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("周\(LedgerAutomationSchedule.weekdayTitles[day - 1])")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func save() {
        if isNew, takenIDs.contains(task.id) {
            failure = String(localized: "已经有一个叫 \(task.id) 的任务文件了，换个文件名。")
            return
        }
        task.name = task.name.trimmingCharacters(in: .whitespaces)
        saving = true
        Task {
            defer { saving = false }
            do {
                try await center.save(task)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// The lines under a task and a run.
enum LedgerAutomationTaskText {
    static func caption(_ task: LedgerAutomationTask, state: LedgerAutomationState.Task?, runs: [LedgerAutomationRun]) -> String {
        var parts = [task.schedule.title]
        if task.enabled, let next = task.schedule.nextSlot(after: Date(), in: task.zone) {
            parts.append(String(localized: "下次 \(next.formatted(date: .abbreviated, time: .shortened))"))
        }
        if let last = runs.first {
            parts.append(String(localized: "上次\(last.statusText)"))
        } else if state?.lastRunAt == nil {
            parts.append(String(localized: "还没跑过"))
        }
        return parts.joined(separator: " · ")
    }

    static func caption(_ run: LedgerAutomationRun) -> String {
        var parts: [String] = []
        if run.status != .ok { parts.append(run.statusText) }
        if run.findings > 0 {
            parts.append(run.newFindings > 0 ? String(localized: "\(run.findings) 处问题，新 \(run.newFindings) 处")
                                             : String(localized: "\(run.findings) 处问题"))
        }
        if run.hasDraft {
            let files = run.draftFiles?.count ?? 0
            parts.append(files > 0 ? String(localized: "草稿改了 \(files) 个文件") : String(localized: "有草稿"))
        }
        if parts.isEmpty { parts.append(String(localized: "没有发现问题")) }
        return parts.joined(separator: " · ")
    }
}
#endif
