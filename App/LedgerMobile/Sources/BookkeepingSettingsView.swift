#if os(iOS)
import SwiftUI

struct BookkeepingSettingsView: View {
    @ObservedObject private var settings = BookkeepingSettings.shared
    @State private var baseURL = ""
    @State private var model = ""
    @State private var key = ""
    @State private var error: String?
    @State private var saved = false

    private struct ProviderPreset: Identifiable {
        let id: String
        let name: String
        let baseURL: String
        let model: String
    }

    private let presets: [ProviderPreset] = [
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        .init(id: "moonshot", name: "Moonshot (Kimi)", baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k"),
        .init(id: "siliconflow", name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", model: "deepseek-ai/DeepSeek-V3")
    ]

    var body: some View {
        Form {
            Section("快速预设") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LedgerSpacing.sm) {
                        ForEach(presets) { preset in
                            Button {
                                LedgerFeedback.light()
                                baseURL = preset.baseURL
                                model = preset.model
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(LedgerPalette.ink)
                                    Text(preset.model)
                                        .font(.caption2)
                                        .foregroundStyle(LedgerPalette.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(baseURL == preset.baseURL ? LedgerPalette.cobalt.opacity(0.12) : LedgerPalette.canvas)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(baseURL == preset.baseURL ? LedgerPalette.cobalt : LedgerPalette.cardBorder, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("OpenAI 兼容接口") {
                TextField("Base URL（含 /v1）", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("模型名称", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(settings.hasKey ? "替换 API Key" : "API Key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("保存配置") {
                    LedgerFeedback.light()
                    do {
                        try settings.save(baseURL: baseURL, model: model, key: key)
                        key = ""
                        error = nil
                        saved = true
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if saved {
                    Label("配置已保存", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(LedgerPalette.success)
                }

                if settings.hasKey {
                    Button("移除 Key", role: .destructive) {
                        LedgerFeedback.light()
                        do {
                            try settings.removeKey()
                            key = ""
                            saved = false
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
            }

            Section("数据与隐私安全") {
                VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
                    Label("HTTPS 加密传输", systemImage: "lock.shield.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LedgerPalette.ink)
                    Text("每次点击「发送并解析」时，仅将输入文字、参考日期、时区与当前账本候选账户发送给配置的服务端。")
                        .font(.caption)
                        .foregroundStyle(LedgerPalette.secondary)
                }
                VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
                    Label("本机 Keychain 存储", systemImage: "key.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LedgerPalette.ink)
                    Text("API Key 安全保存在当前设备的 Keychain，不随账本导出，也不进入 Git 版本库。解析结果在本地生成并校验。")
                        .font(.caption)
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }

            if let error {
                Section {
                    StatusBanner(message: error) { self.error = nil }
                }
            }
        }
        .navigationTitle("语义解析设置")
        .onAppear {
            baseURL = settings.configuration.baseURL
            model = settings.configuration.model
        }
        .onDisappear {
            key = ""
        }
        .privacySensitive()
    }
}
#endif
