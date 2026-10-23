import SwiftUI
import UniformTypeIdentifiers

/// The library opens local workspaces, independent of their storage provider.
struct LedgerLibraryView: View {
    @EnvironmentObject private var session: LedgerSession
    @State private var showingWizard = false
    @State private var creating = false
    @State private var importing = false
    @State private var addingGit = false
    @State private var restoringBackup = false
    @State private var joiningFolder = false
    @State private var editingLedger: LocalLedgerDescriptor?
    @State private var deletingLedger: LocalLedgerDescriptor?
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("新手开账向导").balancedFont(size: 15, weight: .medium).foregroundStyle(BalancedPalette.ink)
                            Spacer()
                            Text("约 1 分钟").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        }
                        Text("无需编写代码或配置 Git，可视化勾选微信、支付宝、银行卡与日常分类，数据 100% 离线存放在本设备。")
                            .balancedFont(size: 13.5)
                            .foregroundStyle(BalancedPalette.secondary)
                            .lineSpacing(3)

                        Button("开启向导") { showingWizard = true }
                            .buttonStyle(.balanced(.primary))
                            .accessibilityIdentifier("local-ledger-open-wizard")
                    }
                    .balancedBand(lead: true)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 18, trailing: 20))
                    .listRowBackground(Color.clear)
                }

                Section {
                    LibraryActionRow(title: String(localized: "新建本地账本"), detail: String(localized: "从零开始，自己写账户")) { creating = true }
                        .accessibilityIdentifier("local-ledger-create")
                    LibraryActionRow(title: String(localized: "导入账本文件夹"), detail: String(localized: "已有 .bean 文件，直接接管")) { importing = true }
                        .accessibilityIdentifier("local-ledger-import")
                    LibraryActionRow(title: String(localized: "从 Git 添加账本"), detail: String(localized: "用仓库做版本交换，多设备共用")) { addingGit = true }
                        .accessibilityIdentifier("local-ledger-add-git")
                    // A second importer on the list would replace the backup one, so this row owns it.
                    LibraryActionRow(title: String(localized: "从 iCloud 云盘加入账本"), detail: String(localized: "选择另一台设备已开启同步的文件夹")) { joiningFolder = true }
                        .accessibilityIdentifier("local-ledger-join-folder")
                        .fileImporter(isPresented: $joiningFolder, allowedContentTypes: [.folder]) { result in
                            switch result {
                            case let .success(url): Task { await session.importFolderLedger(url) }
                            case let .failure(error): session.errorMessage = error.localizedDescription
                            }
                        }
                    LibraryActionRow(title: String(localized: "从备份恢复"), detail: String(localized: "选择 iCloud 云盘或“文件”中的 .ledgerbackup")) { restoringBackup = true }
                        .accessibilityIdentifier("local-ledger-restore-backup")
                } header: { TerminalSectionLabel(text: String(localized: "快速操作")).listRowBackground(BalancedPalette.page) }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if !session.localLedgers.isEmpty {
                    Section {
                        ForEach(session.localLedgers) { ledger in
                            HStack(spacing: 0) {
                                Button {
                                    Task { await session.openLocalLedger(ledger) }
                                } label: {
                                    HStack(alignment: .top, spacing: 0) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(ledger.name)
                                                .balancedFont(size: 15, weight: .text)
                                                .foregroundStyle(BalancedPalette.ink)
                                            HStack(spacing: 4) {
                                                Text(ledger.folder != nil ? "iCloud 云盘同步" : ledger.git != nil ? "Git 同步" : "仅本机")
                                                    .balancedFont(size: 12)
                                                Text("·").balancedFont(size: 12)
                                                Text(ledger.entrypoint).balancedMono(size: 11.5)
                                            }
                                            .foregroundStyle(BalancedPalette.meta)
                                        }
                                        Spacer(minLength: 8)
                                    }
                                    .frame(minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
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
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(BalancedPalette.ink)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("local-ledger-menu-\(ledger.id.uuidString)")
                            }
                            .padding(.vertical, 2)
                            .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
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
                                .tint(BalancedPalette.ink)
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
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    } header: { TerminalSectionLabel(text: String(localized: "本地账本")).listRowBackground(BalancedPalette.page) }
                }
                if let error = session.errorMessage {
                    Section { StatusBanner(message: error, onDismiss: session.dismissError) }
                }
                if session.isLocalOperationBusy { Section { ProgressView("正在打开账本") } }

                Section {
                    Text("查询、统计、校验与保存都在本机执行。存储提供方只负责版本交换。")
                        .balancedFont(size: 12.5)
                        .foregroundStyle(BalancedPalette.meta)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .scrollContentBackground(.hidden)
            .background(BalancedPalette.page)
            .listStyle(.plain)
            .listSectionSpacing(8)
            .terminalPageChrome(String(localized: "账本"), isRoot: true, showsTimeRange: false, showsSync: false)
            .disabled(session.isLocalOperationBusy)
            .task { await session.refreshLocalLedgers() }
            .sheet(isPresented: $showingWizard) { OnboardingWizardView() }
            .sheet(isPresented: $creating) { LocalLedgerSetupView(importing: false) }
            .sheet(isPresented: $importing) { LocalLedgerSetupView(importing: true) }
            .sheet(isPresented: $addingGit) { GitLedgerSetupView() }
            .fileImporter(isPresented: $restoringBackup, allowedContentTypes: [.item]) { result in
                switch result {
                case let .success(url): Task { await session.restoreLedgerBackupAsNew(fileAt: url) }
                case let .failure(error): session.errorMessage = error.localizedDescription
                }
            }
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
    @State private var name = String(localized: "我的账本")
    @State private var currency = "CNY"
    @State private var entrypoint = "main.bean"
    @State private var selectingFolder = false
    @State private var showingWizard = false

    var body: some View {
        NavigationStack {
            List {
                if !importing {
                    Section {
                        LibraryActionRow(title: String(localized: "使用新手向导开账（推荐）"), detail: String(localized: "可视化配置微信、支付宝、银行卡与日常分类")) {
                            showingWizard = true
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                Section {
                    TextField("名称", text: $name)
                        .balancedFont(size: 15)
                        .accessibilityIdentifier("local-ledger-name")
                    if importing {
                        TextField("入口文件", text: $entrypoint)
                            .balancedMono(size: 13.5)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        TextField("主要币种", text: $currency)
                            .balancedFont(size: 15)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .accessibilityIdentifier("local-ledger-currency")
                    }
                } header: { TerminalSectionLabel(text: String(localized: "账本信息")).listRowBackground(BalancedPalette.page) }
                Section {
                    Text("存储在这台设备 · 设备密码与生物识别保护")
                        .balancedFont(size: 13.5)
                        .foregroundStyle(BalancedPalette.secondary)
                } footer: {
                    Text(importing ? "选择包含入口文件及 include 文件的完整文件夹。导入时会在本机校验账本。" : "创建空账本和常用账户。之后可直接编辑 .bean 文件、记账或导入账单。")
                        .balancedFont(size: 12.5)
                        .foregroundStyle(BalancedPalette.meta)
                        .listRowBackground(BalancedPalette.page)
                }
                if let error = session.errorMessage {
                    Section { StatusBanner(message: error, onDismiss: session.dismissError) }
                }
            }
            .navigationTitle(importing ? "导入本地账本" : "新建本地账本")
            .terminalNativeChrome()
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
            .overlay {
                if session.isLocalOperationBusy {
                    ProgressView("正在校验账本")
                        .tint(BalancedPalette.ink)
                        .balancedFont(size: 13.5)
                        .foregroundStyle(BalancedPalette.ink)
                        .padding(16)
                        .background(BalancedPalette.page)
                }
            }
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
            if let error {
                Section { Text(error).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.expense) }
            }
            Section {
                ForEach(files, id: \.self) { path in
                    NavigationLink { LocalLedgerFileEditor(path: path) } label: {
                        HStack {
                            Text(path).balancedMono(size: 13).foregroundStyle(BalancedPalette.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(BalancedPalette.edge)
                        }
                        .frame(minHeight: 44)
                    }
                    .navigationLinkIndicatorVisibility(.hidden)
                    .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } header: { TerminalSectionLabel(text: String(localized: "账本文件")).listRowBackground(BalancedPalette.page) }
            Section {
                Button("准备导出账本") {
                    Task {
                        do { exportURL = try await session.localRepository?.exportLedger() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.balanced(.outline))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                if let exportURL {
                    ShareLink("导出账本文件夹", item: exportURL)
                        .buttonStyle(.balanced(.outline))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } footer: {
                Text("共 \(files.count) 个文件。改动会先校验再落盘，失败时回滚到上一个可用版本。")
                    .balancedFont(size: 12.5)
                    .foregroundStyle(BalancedPalette.meta)
                    .listRowBackground(BalancedPalette.page)
            }
        }
        .navigationTitle("本地文件")
        .terminalNativeChrome()
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
        .terminalNativeChrome()
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
            List {
                if let error {
                    Section {
                        StatusBanner(message: error) { self.error = nil }
                    }
                }

                Section {
                    TextField("账本名称", text: $name)
                        .balancedFont(size: 15)
                        .accessibilityIdentifier("edit-ledger-name")
                    TextField("入口文件", text: $entrypoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .balancedMono(size: 13.5)
                        .accessibilityIdentifier("edit-ledger-entrypoint")
                } header: {
                    TerminalSectionLabel(text: String(localized: "基本信息")).listRowBackground(BalancedPalette.page)
                } footer: {
                    Text("入口文件通常为 main.bean，需位于账本根目录下。")
                        .balancedFont(size: 12.5)
                        .foregroundStyle(BalancedPalette.meta)
                        .listRowBackground(BalancedPalette.page)
                }

                Section {
                    LabeledContent(String(localized: "存储方式"), value: ledger.folder != nil ? String(localized: "iCloud 云盘文件夹同步") : ledger.git == nil ? String(localized: "本机独立存储") : String(localized: "Git 仓库协同"))
                        .balancedFont(size: 14)
                    LabeledContent("创建时间", value: ledger.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .balancedFont(size: 14)
                    LabeledContent("账本标识", value: String(ledger.id.uuidString.prefix(8)))
                        .balancedMono(size: 12.5)
                } header: { TerminalSectionLabel(text: String(localized: "账本属性")).listRowBackground(BalancedPalette.page) }

                Section {
                    Button("删除此账本") {
                        confirmingDelete = true
                    }
                    .buttonStyle(.balanced(.risk))
                    .accessibilityIdentifier("edit-ledger-delete")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } footer: {
                    Text("删除操作将永久清空此账本在本机的所有数据文件，不可撤销。")
                        .balancedFont(size: 12.5)
                        .foregroundStyle(BalancedPalette.meta)
                        .listRowBackground(BalancedPalette.page)
                }
            }
            .navigationTitle("编辑账本")
            .terminalNativeChrome()
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
                        .tint(BalancedPalette.ink)
                        .balancedFont(size: 13.5)
                        .foregroundStyle(BalancedPalette.ink)
                        .padding(16)
                        .background(BalancedPalette.page)
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

/// `.row row--tap` used for a tappable action with a title/detail pair and an
/// `--edge` chevron — the library's "快速操作" rows (d01) and the setup sheet's
/// wizard shortcut.
private struct LibraryActionRow: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink)
                    Text(detail).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BalancedPalette.edge)
            }
            .frame(minHeight: 44)
            .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
