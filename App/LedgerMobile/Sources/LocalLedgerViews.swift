import SwiftUI
import UniformTypeIdentifiers

/// The library opens local workspaces, independent of their storage provider.
struct LedgerLibraryView: View {
    @EnvironmentObject private var session: LedgerSession
    @State private var showingWizard = false
    @State private var creating = false
    @State private var importing = false
    @State private var addingGit = false
    @State private var editingLedger: LocalLedgerDescriptor?
    @State private var deletingLedger: LocalLedgerDescriptor?
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                        HStack(spacing: LedgerSpacing.md) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(
                                        colors: [Color.blue.opacity(0.18), Color.indigo.opacity(0.24)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    .frame(width: 44, height: 44)
                                Image(systemName: "sparkles")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.cobalt)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("新手开账向导")
                                    .font(.headline)
                                    .foregroundStyle(LedgerPalette.ink)
                                Text("1 分钟快速建立常用账户与分类")
                                    .font(.caption)
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                        }
                        Text("无需编写代码或配置 Git，可视化勾选微信、支付宝、银行卡与日常分类，数据 100% 离线存放在本设备。")
                            .font(.footnote)
                            .foregroundStyle(LedgerPalette.secondary)
                            .lineSpacing(2)

                        Button {
                            showingWizard = true
                        } label: {
                            HStack {
                                Image(systemName: "wand.and.stars")
                                Text("开启新手向导")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(LedgerPalette.cobalt, in: RoundedRectangle(cornerRadius: LedgerRadius.sm))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("local-ledger-open-wizard")
                    }
                    .padding(.vertical, LedgerSpacing.xs)
                }

                Section("快速操作") {
                    Button { creating = true } label: { Label("新建本地账本", systemImage: "plus") }
                        .accessibilityIdentifier("local-ledger-create")
                    Button { importing = true } label: { Label("导入账本文件夹", systemImage: "folder") }
                        .accessibilityIdentifier("local-ledger-import")
                    Button { addingGit = true } label: { Label("从 Git 添加账本", systemImage: "arrow.triangle.branch") }
                        .accessibilityIdentifier("local-ledger-add-git")
                }
                if !session.localLedgers.isEmpty {
                    Section("本地账本") {
                        ForEach(session.localLedgers) { ledger in
                            HStack(spacing: LedgerSpacing.md) {
                                Button {
                                    Task { await session.openLocalLedger(ledger) }
                                } label: {
                                    HStack(spacing: LedgerSpacing.md) {
                                        Image(systemName: ledger.git != nil ? "arrow.triangle.branch" : "book.closed.fill")
                                            .font(.title3)
                                            .foregroundStyle(LedgerPalette.cobalt)
                                            .frame(width: 28)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(ledger.name)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(LedgerPalette.ink)
                                            HStack(spacing: 4) {
                                                Text(ledger.git != nil ? "Git 同步" : "本机存储")
                                                Text("·")
                                                Text(ledger.entrypoint)
                                            }
                                            .font(.caption2)
                                            .foregroundStyle(LedgerPalette.secondary)
                                        }
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)

                                Menu {
                                    Button {
                                        Task { await session.openLocalLedger(ledger) }
                                    } label: {
                                        Label("打开账本", systemImage: "arrow.right.circle")
                                    }
                                    Button {
                                        editingLedger = ledger
                                    } label: {
                                        Label("编辑信息", systemImage: "pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        deletingLedger = ledger
                                        confirmingDelete = true
                                    } label: {
                                        Label("删除账本", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.subheadline)
                                        .foregroundStyle(LedgerPalette.secondary)
                                        .frame(width: 32, height: 32)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("local-ledger-menu-\(ledger.id.uuidString)")
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deletingLedger = ledger
                                    confirmingDelete = true
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                .accessibilityIdentifier("local-ledger-swipe-delete-\(ledger.id.uuidString)")

                                Button {
                                    editingLedger = ledger
                                } label: {
                                    Label("编辑", systemImage: "pencil")
                                }
                                .tint(LedgerPalette.cobalt)
                                .accessibilityIdentifier("local-ledger-swipe-edit-\(ledger.id.uuidString)")
                            }
                            .contextMenu {
                                Button {
                                    Task { await session.openLocalLedger(ledger) }
                                } label: {
                                    Label("打开账本", systemImage: "arrow.right.circle")
                                }
                                Button {
                                    editingLedger = ledger
                                } label: {
                                    Label("编辑信息", systemImage: "pencil")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    deletingLedger = ledger
                                    confirmingDelete = true
                                } label: {
                                    Label("删除账本", systemImage: "trash")
                                }
                            }
                            .accessibilityIdentifier("local-ledger-\(ledger.id.uuidString)")
                        }
                    }
                }
                if let error = session.errorMessage {
                    Section { StatusBanner(message: error, onDismiss: session.dismissError) }
                }
                if session.isLocalOperationBusy { Section { ProgressView("正在打开账本") } }
            }
            .navigationTitle("账本")
            .disabled(session.isLocalOperationBusy)
            .task { await session.refreshLocalLedgers() }
            .sheet(isPresented: $showingWizard) { OnboardingWizardView() }
            .sheet(isPresented: $creating) { LocalLedgerSetupView(importing: false) }
            .sheet(isPresented: $importing) { LocalLedgerSetupView(importing: true) }
            .sheet(isPresented: $addingGit) { GitLedgerSetupView() }
            .sheet(item: $editingLedger) { ledger in
                EditLedgerSheet(ledger: ledger)
            }
            .confirmationDialog("确定删除账本？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("永久删除账本", role: .destructive) {
                    if let ledger = deletingLedger {
                        Task {
                            try? await session.deleteLocalLedger(ledger)
                            deletingLedger = nil
                        }
                    }
                }
                Button("取消", role: .cancel) {
                    deletingLedger = nil
                }
            } message: {
                Text("将永久删除账本“\(deletingLedger?.name ?? "")”及其所有本地文件与配置，此操作不可恢复。")
            }
        }
    }
}

private struct LocalLedgerSetupView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    let importing: Bool
    @State private var name = "我的账本"
    @State private var currency = "CNY"
    @State private var entrypoint = "main.bean"
    @State private var selectingFolder = false
    @State private var showingWizard = false

    var body: some View {
        NavigationStack {
            Form {
                if !importing {
                    Section {
                        Button {
                            showingWizard = true
                        } label: {
                            HStack(spacing: LedgerSpacing.md) {
                                Image(systemName: "wand.and.stars")
                                    .font(.title3)
                                    .foregroundStyle(LedgerPalette.cobalt)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("使用新手向导开账（推荐）")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(LedgerPalette.ink)
                                    Text("可视化配置微信、支付宝、银行卡与日常分类")
                                        .font(.caption)
                                        .foregroundStyle(LedgerPalette.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                Section("账本信息") {
                    TextField("名称", text: $name).accessibilityIdentifier("local-ledger-name")
                    if importing {
                        TextField("入口文件", text: $entrypoint)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        TextField("主要币种", text: $currency)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .accessibilityIdentifier("local-ledger-currency")
                    }
                }
                Section {
                    Label("存储在这台设备", systemImage: "iphone")
                    Label("设备密码与生物识别保护", systemImage: "lock.shield")
                } footer: {
                    Text(importing ? "选择包含入口文件及 include 文件的完整文件夹。导入时会在本机校验账本。" : "创建空账本和常用账户。之后可直接编辑 .bean 文件、记账或导入账单。")
                }
                if let error = session.errorMessage {
                    Section { StatusBanner(message: error, onDismiss: session.dismissError) }
                }
            }
            .navigationTitle(importing ? "导入本地账本" : "新建本地账本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(session.isLocalOperationBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(importing ? "选择文件夹" : "创建") {
                        if importing { selectingFolder = true }
                        else {
                            Task {
                                await session.createLocalLedger(name: name, currency: currency)
                                if session.phase == .ready { dismiss() }
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isLocalOperationBusy)
                    .accessibilityIdentifier("local-ledger-confirm-create")
                }
            }
            .overlay { if session.isLocalOperationBusy { ProgressView("正在校验账本").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .interactiveDismissDisabled(session.isLocalOperationBusy)
            .fileImporter(isPresented: $selectingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case let .success(url):
                    Task {
                        await session.importLocalLedger(from: url, name: name, entrypoint: entrypoint)
                        if session.phase == .ready { dismiss() }
                    }
                case let .failure(error): session.errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showingWizard) {
                OnboardingWizardView()
            }
            .onChange(of: session.phase) { _, newPhase in
                if newPhase == .ready { dismiss() }
            }
        }
    }
}

struct LocalLedgerFilesView: View {
    @EnvironmentObject private var session: LedgerSession
    @State private var files: [String] = []
    @State private var exportURL: URL?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section("账本文件") {
                ForEach(files, id: \.self) { path in
                    NavigationLink(path) { LocalLedgerFileEditor(path: path) }
                        .font(.subheadline.monospaced())
                }
            }
            Section {
                Button("准备导出账本") {
                    Task {
                        do { exportURL = try await session.localRepository?.exportLedger() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                if let exportURL { ShareLink("导出账本文件夹", item: exportURL) }
            } footer: { Text("导出当前已保存的完整文件夹，可存入 Files、iCloud Drive 或交给其他工具管理。") }
        }
        .navigationTitle("本地文件")
        .task {
            do { files = try await session.localRepository?.files() ?? [] }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct LocalLedgerFileEditor: View {
    @EnvironmentObject private var session: LedgerSession
    let path: String
    @State private var draft: LocalLedgerFileDraft?
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            if let error { StatusBanner(message: error) { self.error = nil }.padding() }
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("local-ledger-file-editor")
                .disabled(draft == nil || saving)
        }
        .navigationTitle(path)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "正在校验" : "保存") { confirming = true }
                    .disabled(draft == nil || saving || text == draft?.text)
                    .accessibilityIdentifier("local-ledger-file-save")
            }
        }
        .confirmationDialog("保存当前编辑内容？", isPresented: $confirming, titleVisibility: .visible) {
            Button("校验并保存") { Task { await save() } }
            Button("继续编辑", role: .cancel) { }
        } message: { Text("将校验完整账本后保存新的本地版本。校验失败会保留上一版本及当前编辑内容。") }
        .task {
            do {
                draft = try await session.localRepository?.readFile(path: path)
                text = draft?.text ?? ""
            } catch { self.error = error.localizedDescription }
        }
        .privacySensitive()
    }

    private func save() async {
        guard let draft, let repository = session.localRepository else { return }
        saving = true
        defer { saving = false }
        do {
            try await repository.saveFile(draft, text: text)
            self.draft = try await repository.readFile(path: path)
            await session.refresh()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct EditLedgerSheet: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss

    let ledger: LocalLedgerDescriptor
    var onDeleted: (() -> Void)? = nil

    @State private var name: String
    @State private var entrypoint: String
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var error: String?

    init(ledger: LocalLedgerDescriptor, onDeleted: (() -> Void)? = nil) {
        self.ledger = ledger
        self.onDeleted = onDeleted
        _name = State(initialValue: ledger.name)
        _entrypoint = State(initialValue: ledger.entrypoint)
    }

    private var hasChanges: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEntry = entrypoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!trimmedName.isEmpty && trimmedName != ledger.name) ||
               (!trimmedEntry.isEmpty && trimmedEntry != ledger.entrypoint)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section {
                        StatusBanner(message: error) { self.error = nil }
                    }
                }

                Section {
                    TextField("账本名称", text: $name)
                        .accessibilityIdentifier("edit-ledger-name")
                    TextField("入口文件", text: $entrypoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("edit-ledger-entrypoint")
                } header: {
                    Text("基本信息")
                } footer: {
                    Text("入口文件通常为 main.bean，需位于账本根目录下。")
                }

                Section("账本属性") {
                    LabeledContent("存储方式", value: ledger.git == nil ? "本机独立存储" : "Git 仓库协同")
                    LabeledContent("创建时间", value: ledger.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("账本标识", value: String(ledger.id.uuidString.prefix(8))).font(.caption.monospaced())
                }

                Section {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("删除此账本", systemImage: "trash")
                                .foregroundStyle(LedgerPalette.risk)
                            Spacer()
                        }
                    }
                    .accessibilityIdentifier("edit-ledger-delete")
                } footer: {
                    Text("删除操作将永久清空此账本在本机的所有数据文件，不可撤销。")
                }
            }
            .navigationTitle("编辑账本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { await save() }
                    }
                    .disabled(!hasChanges || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                    .accessibilityIdentifier("edit-ledger-save")
                }
            }
            .confirmationDialog("确定删除账本“\(ledger.name)”？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("永久删除账本", role: .destructive) {
                    Task { await deleteLedger() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作将永久删除该账本在本机存储的所有数据文件与配置，无法恢复。")
            }
            .overlay {
                if saving {
                    ProgressView("正在保存修改")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await session.updateLocalLedger(ledger, name: name, entrypoint: entrypoint)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteLedger() async {
        saving = true
        defer { saving = false }
        do {
            try await session.deleteLocalLedger(ledger)
            onDeleted?()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
