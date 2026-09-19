import SwiftUI

struct BookkeepingPreviewView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    let preview: PreparedBookkeepingChange
    let onSaved: (LedgerImportCommitResult?) -> Void
    @State private var saving = false
    @State private var error: String?

    private var visibleFiles: [LocalLedgerWorkspace.PreparedFiles.File] {
        // Writer receipts remain bound to the token; financial review presents
        // transaction text first and attachments afterward.
        preview.files.files.filter { !$0.path.hasPrefix(".ledger-write-receipts/") }.sorted { left, right in
            if left.path.hasSuffix(".bean") != right.path.hasSuffix(".bean") { return left.path.hasSuffix(".bean") }
            let leftDiff = Self.diff(before: left.before, after: left.after)
            let rightDiff = Self.diff(before: right.before, after: right.after)
            let leftIncludeOnly = Self.isIncludeOnlyDiff(leftDiff)
            let rightIncludeOnly = Self.isIncludeOnlyDiff(rightDiff)
            if leftIncludeOnly != rightIncludeOnly {
                return !leftIncludeOnly
            }
            if (left.before == nil) != (right.before == nil) { return left.before == nil }
            return left.path < right.path
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
                        HStack(spacing: LedgerSpacing.sm) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(LedgerPalette.success)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("完整账本校验通过")
                                    .font(.headline)
                                    .foregroundStyle(LedgerPalette.ink)
                                Text("本地 Beancount 引擎已验证复式记账平衡与语法规范。")
                                    .font(.caption)
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if let error {
                    Section {
                        StatusBanner(message: error) { self.error = nil }
                    }
                }

                ForEach(visibleFiles) { file in
                    let diffString = file.path.hasSuffix(".bean") ? Self.diff(before: file.before, after: file.after) : ""
                    let isIncludeOnly = file.path.hasSuffix(".bean") && Self.isIncludeOnlyDiff(diffString)
                    Section {
                        if file.path.hasSuffix(".bean") {
                            DiffCodeBlock(diffString: diffString)
                                .accessibilityIdentifier("bookkeeping-file-diff")
                        } else {
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(LedgerPalette.cobalt)
                                Text("附件变更")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(file.before?.count ?? 0) → \(file.after?.count ?? 0) 字节")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: file.path.hasSuffix(".bean") ? (isIncludeOnly ? "link" : "doc.text.fill") : "paperclip")
                                .foregroundStyle(LedgerPalette.cobalt)
                            Text(file.path)
                                .font(.caption.weight(.semibold).monospaced())
                            if isIncludeOnly {
                                Text("（入口关联引用）")
                                    .font(.caption2)
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("确认账本改动")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回编辑") {
                        LedgerFeedback.light()
                        dismiss()
                    }
                    .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        LedgerFeedback.selection()
                        Task { await save() }
                    } label: {
                        if saving {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("保存中…")
                            }
                        } else {
                            Text("确认保存")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(saving || error != nil || session.privacyShielded || session.phase != .ready)
                    .accessibilityIdentifier("bookkeeping-confirm-save")
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .ledgerPrivacyProtectedSheet()
        .onDisappear {
            if let repository = session.localRepository { Task { await repository.discardPrepared(preview) } }
        }
    }

    static func diff(before: Data?, after: Data?) -> String {
        let old = String(decoding: before ?? Data(), as: UTF8.self).components(separatedBy: "\n")
        let new = String(decoding: after ?? Data(), as: UTF8.self).components(separatedBy: "\n")
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        return old[max(0, prefix - 2)..<prefix].map { "  " + $0 }.joined(separator: "\n")
            + "\n" + old[prefix..<(old.count - suffix)].map { "- " + $0 }.joined(separator: "\n")
            + "\n" + new[prefix..<(new.count - suffix)].map { "+ " + $0 }.joined(separator: "\n")
            + "\n" + new[(new.count - suffix)..<min(new.count, new.count - suffix + 2)].map { "  " + $0 }.joined(separator: "\n")
    }

    static func isIncludeOnlyDiff(_ diff: String) -> Bool {
        let added = diff.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("+") }
            .map { $0.dropFirst().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !added.isEmpty else { return false }
        return added.allSatisfy { $0.hasPrefix("include ") || $0.hasPrefix(";") }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        do {
            guard session.phase == .ready, !session.privacyShielded,
                  let repository = session.localRepository, repository.descriptor.id == preview.ledgerID else {
                throw BookkeepingError.expiredPreview
            }
            let result = try await repository.commitPrepared(preview)
            await session.refresh()
            onSaved(result)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}

private struct DiffCodeBlock: View {
    let diffString: String

    private var lines: [String] {
        diffString.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    diffLineView(line)
                }
            }
            .padding(.vertical, 6)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func diffLineView(_ line: String) -> some View {
        let isAdded = line.hasPrefix("+")
        let isRemoved = line.hasPrefix("-")

        HStack(alignment: .top, spacing: 6) {
            Text(isAdded ? "+" : (isRemoved ? "-" : " "))
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(isAdded ? LedgerPalette.income : (isRemoved ? LedgerPalette.expense : LedgerPalette.secondary))
                .frame(width: 12)

            Text(line.count >= 2 ? String(line.dropFirst(2)) : line)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isAdded ? LedgerPalette.income : (isRemoved ? LedgerPalette.expense : LedgerPalette.ink))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isAdded ? LedgerPalette.income.opacity(0.08) :
            (isRemoved ? LedgerPalette.expense.opacity(0.08) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
