import SwiftUI
import UniformTypeIdentifiers

/// Snapshot backups of the open ledger in a user-chosen folder, normally in
/// iCloud Drive. Unlike Git storage this does not exchange versions: each
/// backup is a complete, immutable copy that can be restored on any device.
struct LocalLedgerBackupView: View {
    @EnvironmentObject private var session: LedgerSession
    @State private var folder = LedgerBackupFolder.current
    @State private var backups: [LedgerBackupEntry] = []
    @State private var automatic = true
    @State private var lastBackup: Date?
    @State private var choosingFolder = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var selected: LedgerBackupEntry?

    private var ledgerID: UUID? { session.currentLocalLedgerDescriptor?.id }
    private var ownBackups: [LedgerBackupEntry] { backups.filter { $0.ledgerID == ledgerID } }
    private var otherBackups: [LedgerBackupEntry] { backups.filter { $0.ledgerID != ledgerID } }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    BackupKeyRow(label: String(localized: "账本"), value: session.localLedgerName)
                    BackupKeyRow(label: String(localized: "备份文件夹"), value: folder?.displayName ?? String(localized: "未选择"))
                    BackupKeyRow(label: String(localized: "自动备份"), value: folder == nil ? "—" : (automatic ? String(localized: "每天一次") : String(localized: "已关闭")))
                    BackupKeyRow(label: String(localized: "最近备份"), value: lastBackup?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: LedgerLocale.current)) ?? String(localized: "暂无"))
                }
                .balancedBand(lead: true)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 18, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } footer: {
                Text("备份是整个账本目录的完整快照，保存为单个 .ledgerbackup 文件。建议在“文件”中选择 iCloud 云盘里的文件夹，由 iCloud 负责上传和多设备可见。")
                    .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    .listRowBackground(BalancedPalette.page)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            if let error {
                Section { Text(error).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.expense).textSelection(.enabled) }
            } else if let notice {
                Section { Text(notice).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary) }
            }
            Section {
                Button(folder == nil ? "选择备份文件夹" : "更换备份文件夹") { choosingFolder = true }
                    .buttonStyle(.balanced(folder == nil ? .primary : .quiet))
                    .accessibilityIdentifier("local-backup-choose-folder")
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                if folder != nil {
                    Button("立即备份") { Task { await backupNow() } }
                        .buttonStyle(.balanced(.outline))
                        .accessibilityIdentifier("local-backup-now")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    Toggle("自动备份", isOn: Binding(get: { automatic }, set: { enabled in
                        automatic = enabled
                        if let ledgerID { LedgerBackupFolder.setAutomatic(enabled, for: ledgerID) }
                    }))
                    .balancedFont(size: 15)
                    .accessibilityIdentifier("local-backup-automatic")
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            } footer: {
                Text("自动备份在打开并解锁账本时运行，每天最多一次；内容未变化时不会重复写入。每个账本保留最近 30 份。")
                    .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    .listRowBackground(BalancedPalette.page)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            if folder != nil {
                backupSection(title: String(localized: "本账本的备份"), entries: ownBackups, empty: String(localized: "还没有备份"))
                if !otherBackups.isEmpty {
                    backupSection(title: String(localized: "其他账本或设备的备份"), entries: otherBackups, empty: nil)
                }
            }
            Section {
                Text("iCloud 云盘中的备份未做额外加密；开启 iCloud 高级数据保护后由 Apple 端到端加密。恢复前会先备份当前账本，恢复内容需通过完整账本校验才会生效。已连接 Git 的账本恢复后会作为一次本地修改同步到远端；若远端同时有修改，会进入现有的冲突处理。")
                    .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .toggleStyle(BalancedToggleStyle())
        .scrollContentBackground(.hidden)
        .background(BalancedPalette.page)
        .disabled(busy || session.isStorageSyncBusy || session.isLocalOperationBusy)
        .overlay {
            if busy {
                ProgressView("正在处理备份")
                    .tint(BalancedPalette.ink)
                    .balancedFont(size: 13.5)
                    .padding(16)
                    .background(BalancedPalette.page)
            }
        }
        .navigationTitle("备份与恢复")
        .terminalNativeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url):
                do {
                    folder = try LedgerBackupFolder.select(url)
                    error = nil
                    Task { await reload() }
                } catch { self.error = error.localizedDescription }
            case let .failure(error): self.error = error.localizedDescription
            }
        }
        .confirmationDialog(selected.map(dialogTitle) ?? "", isPresented: Binding(
            get: { selected != nil }, set: { if !$0 { selected = nil } }
        ), titleVisibility: .visible, presenting: selected) { entry in
            Button("恢复为新账本") { Task { await restoreAsNew(entry) } }
            Button("替换当前账本", role: .destructive) { Task { await restoreCurrent(entry) } }
        } message: { _ in
            Text("恢复为新账本不会改动当前账本。替换会先把“\(session.localLedgerName)”的当前内容备份到同一文件夹，再用所选备份替换全部文件。")
        }
        .privacySensitive()
    }

    @ViewBuilder
    private func backupSection(title: String, entries: [LedgerBackupEntry], empty: String?) -> some View {
        Section {
            if entries.isEmpty, let empty {
                Text(empty).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.meta)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(entries) { entry in
                Button { selected = entry } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: LedgerLocale.current)))
                                .balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink)
                            Text(entry.ledgerID == ledgerID ? entry.digestPrefix : "\(entry.ledgerName) · \(entry.digestPrefix)")
                                .balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                        }
                        Spacer(minLength: 8)
                        if let size = entry.size {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        }
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        } header: {
            TerminalSectionLabel(text: title).listRowBackground(BalancedPalette.page)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        }
    }

    private func dialogTitle(_ entry: LedgerBackupEntry) -> String {
        "\(entry.ledgerName) · \(entry.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: LedgerLocale.current)))"
    }

    private func reload() async {
        folder = LedgerBackupFolder.current
        if let ledgerID {
            automatic = LedgerBackupFolder.automaticEnabled(for: ledgerID)
            lastBackup = LedgerBackupFolder.lastBackup(for: ledgerID)
        }
        guard folder != nil else { backups = []; return }
        do {
            backups = try await session.listLedgerBackups()
            if let newest = ownBackups.first?.createdAt, lastBackup.map({ newest > $0 }) ?? true { lastBackup = newest }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func backupNow() async {
        busy = true
        defer { busy = false }
        do {
            switch try await session.backupCurrentLocalLedger() {
            case .created: notice = String(localized: "已备份到“\(folder?.displayName ?? "")”")
            case .unchanged: notice = String(localized: "账本内容与已有备份相同，无需重复备份")
            }
            error = nil
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    private func restoreCurrent(_ entry: LedgerBackupEntry) async {
        busy = true
        defer { busy = false }
        do {
            try await session.restoreCurrentLocalLedger(from: entry)
            notice = String(localized: "已恢复 \(dialogTitle(entry))")
            error = nil
            await reload()
        } catch { self.error = error.localizedDescription; await reload() }
    }

    private func restoreAsNew(_ entry: LedgerBackupEntry) async {
        busy = true
        defer { busy = false }
        await session.restoreLedgerBackupAsNew(entry)
        if let message = session.errorMessage { error = message }
    }
}

private struct BackupKeyRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).balancedFont(size: 14).foregroundStyle(BalancedPalette.secondary)
            Spacer()
            Text(value).balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink).lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}
