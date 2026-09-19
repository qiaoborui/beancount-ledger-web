import SwiftUI
import CryptoKit

struct BeanTransactionImportView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    let file: LedgerImportSelectedFile
    var onSaved: () -> Void = {}
    @State private var text = ""
    @State private var error: String?
    @State private var busy = false
    @State private var preview: PreparedBookkeepingChange?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: LedgerSpacing.md) {
                        Image(systemName: "doc.text.fill")
                            .font(.title2)
                            .foregroundStyle(LedgerPalette.cobalt)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LedgerPalette.ink)
                            Text("\(file.data.count) 字节 · UTF-8 编码")
                                .font(.caption2)
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 280)
                        .disabled(busy)

                    Button {
                        LedgerFeedback.light()
                        Task { await prepare() }
                    } label: {
                        HStack(spacing: 6) {
                            if busy {
                                ProgressView()
                                    .controlSize(.small)
                                Text("校验中…")
                            } else {
                                Image(systemName: "checkmark.shield.fill")
                                Text("生成并校验预览")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(busy || text.isEmpty)
                } header: {
                    Text("交易内容")
                } footer: {
                    Text("系统保留原始分录、注释、标签与自定义元数据。完整包含 accounts、options 或 plugin 的账本，请从账本管理导入完整目录。")
                        .font(.caption2)
                }

                if let error {
                    Section {
                        StatusBanner(message: error) { self.error = nil }
                    }
                }
            }
            .navigationTitle("导入 Beancount 交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        LedgerFeedback.light()
                        dismiss()
                    }
                    .disabled(busy)
                }
            }
        }
        .onAppear {
            if let decoded = String(data: file.data, encoding: .utf8) {
                text = decoded
            } else {
                error = "请选择 UTF-8 编码的 .bean 文件。"
            }
        }
        .sheet(item: $preview) { prepared in
            BookkeepingPreviewView(preview: prepared) { _ in
                onSaved()
                dismiss()
            }
        }
        .interactiveDismissDisabled(busy)
        .ledgerPrivacyProtectedSheet()
    }

    private func prepare() async {
        guard !busy, let repository = session.localRepository, session.phase == .ready, !session.privacyShielded else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result = try await repository.prepareBeanTransactions(text)
            guard session.currentLocalLedgerDescriptor?.id == repository.descriptor.id,
                  session.phase == .ready, !session.privacyShielded else {
                await repository.discardPrepared(result)
                return
            }
            preview = result
        } catch {
            self.error = error.localizedDescription
        }
    }
}
