#if os(iOS)
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// 文件 — the built-in Linux's file system, browsed from the App. The guest's
/// root is an ordinary folder (Application Support/Linux/alpine), so this
/// lists it directly; a guest path maps to the same path under that folder.
///
/// Symbolic links are shown with their target and never followed: their
/// targets are guest paths, and on the host side they would point at the
/// App's own system files instead. /proc, /dev and /workspace exist only
/// inside the running machine and show as empty folders here.
struct LedgerLinuxFilesView: View {
    /// The guest path, "/" for the root.
    var path: String = "/root"

    @State private var entries: [Entry] = []
    @State private var error: String?
    @State private var loading = true
    @State private var preview: URL?
    @State private var importing = false
    @State private var naming = false
    @State private var newName = ""
    @State private var deleting: Entry?
    /// Handed on to the folders pushed from here, so they keep this page's bar.
    @Environment(\.ledgerBarlessPush) private var barless

    struct Entry: Identifiable, Hashable {
        enum Kind { case folder, file, link(String), other }
        let name: String
        let url: URL
        let kind: Kind
        let size: Int64
        let modified: Date?
        var id: String { name }

        static func == (a: Entry, b: Entry) -> Bool { a.name == b.name }
        func hash(into hasher: inout Hasher) { hasher.combine(name) }
    }

    private var machine: LedgerLinuxMachine { .shared }
    private var directory: URL {
        path == "/" ? machine.rootfs : machine.rootfs.appendingPathComponent(String(path.dropFirst()), isDirectory: true)
    }

    var body: some View {
        List {
            if let error {
                Section { StatusBanner(message: error) { self.error = nil } }
            }
            if !loading && entries.isEmpty && error == nil {
                Section { Text("空文件夹").foregroundStyle(BalancedPalette.meta) }
            }
            Section {
                ForEach(entries) { entry in
                    row(entry)
                        .swipeActions {
                            Button("删除", role: .destructive) { deleting = entry }
                        }
                        .contextMenu {
                            if case .file = entry.kind {
                                ShareLink(item: entry.url) { Label("分享", systemImage: "square.and.arrow.up") }
                            }
                            Button("删除", systemImage: "trash", role: .destructive) { deleting = entry }
                        }
                }
            } footer: {
                if path == "/root" {
                    Text("这是内置 Linux 里的 /root，终端打开时就在这里。导入的文件放进当前文件夹。")
                }
            }
        }
        .font(.subheadline)
        .ledgerSubpageChrome(path == "/" ? "/" : (path as NSString).lastPathComponent, actions: AnyView(
            Menu {
                Button("导入文件", systemImage: "square.and.arrow.down") { importing = true }
                Button("新建文件夹", systemImage: "folder.badge.plus") {
                    newName = ""
                    naming = true
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18))
                    .foregroundStyle(BalancedPalette.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多")
            .accessibilityIdentifier("ledger-linux-files-menu")
        ))
        .quickLookPreview($preview)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .alert("新建文件夹", isPresented: $naming) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("创建") { createFolder() }
        }
        .confirmationDialog(deleting.map { String(localized: "删除“\($0.name)”？") } ?? "", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let deleting { remove(deleting) }
                deleting = nil
            }
        } message: {
            Text("从内置 Linux 里删除，不能撤销。")
        }
        .task(id: path) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        switch entry.kind {
        case .folder:
            NavigationLink {
                LedgerLinuxFilesView(path: child(entry.name))
                    .environment(\.ledgerBarlessPush, barless)
            } label: {
                Label(entry.name, systemImage: "folder")
            }
        case .file:
            Button {
                preview = entry.url
            } label: {
                HStack {
                    Label(entry.name, systemImage: "doc")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .foregroundStyle(BalancedPalette.meta)
                }
            }
            .buttonStyle(.plain)
        case .link(let target):
            HStack {
                Label(entry.name, systemImage: "arrow.turn.down.right")
                Spacer()
                Text(target).lineLimit(1).truncationMode(.middle).foregroundStyle(BalancedPalette.meta)
            }
        case .other:
            Label(entry.name, systemImage: "questionmark.square").foregroundStyle(BalancedPalette.meta)
        }
    }

    private func child(_ name: String) -> String {
        path == "/" ? "/" + name : path + "/" + name
    }

    private func load() async {
        let directory = directory
        let installed = machine.isInstalled
        let result: Result<[Entry], Error> = await Task.detached(priority: .userInitiated) {
            do {
                if !installed { try LedgerLinuxMachine.shared.installIfNeeded() }
                return .success(try Self.list(directory))
            } catch {
                return .failure(error)
            }
        }.value
        loading = false
        switch result {
        case .success(let list):
            entries = list
        case .failure(let failure):
            entries = []
            error = failure.localizedDescription
        }
    }

    /// Lists a folder without following links: attributes are the link's own.
    private nonisolated static func list(_ directory: URL) throws -> [Entry] {
        let manager = FileManager.default
        let names = try manager.contentsOfDirectory(atPath: directory.path)
        var entries: [Entry] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { continue }
            let type = attributes[.type] as? FileAttributeType
            let kind: Entry.Kind
            switch type {
            case .typeDirectory?: kind = .folder
            case .typeRegular?: kind = .file
            case .typeSymbolicLink?: kind = .link((try? manager.destinationOfSymbolicLink(atPath: url.path)) ?? "")
            default: kind = .other
            }
            entries.append(Entry(name: name, url: url, kind: kind,
                                 size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                                 modified: attributes[.modificationDate] as? Date))
        }
        return entries.sorted { lhs, rhs in
            let lhsFolder: Bool
            if case .folder = lhs.kind { lhsFolder = true } else { lhsFolder = false }
            let rhsFolder: Bool
            if case .folder = rhs.kind { rhsFolder = true } else { rhsFolder = false }
            if lhsFolder != rhsFolder { return lhsFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func importFiles(_ urls: [URL]) {
        let manager = FileManager.default
        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var target = directory.appendingPathComponent(url.lastPathComponent)
            var counter = 2
            while manager.fileExists(atPath: target.path) {
                let base = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                target = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
                counter += 1
            }
            do { try manager.copyItem(at: url, to: target) } catch { failures.append(url.lastPathComponent) }
        }
        if !failures.isEmpty {
            error = String(localized: "没能导入：\(failures.joined(separator: "、"))")
        }
        Task { await load() }
    }

    private func createFolder() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return }
        do {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name, isDirectory: true),
                                                    withIntermediateDirectories: false)
        } catch {
            self.error = error.localizedDescription
        }
        Task { await load() }
    }

    private func remove(_ entry: Entry) {
        do { try FileManager.default.removeItem(at: entry.url) } catch { self.error = error.localizedDescription }
        Task { await load() }
    }
}
#endif
