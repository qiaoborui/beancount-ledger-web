#if os(iOS)
import SwiftUI

struct ImportClassificationSettingsView: View {
    @ObservedObject private var settings = ImportClassificationSettings.shared
    let ledgerID: UUID
    @State private var key = ""
    @State private var error: String?
    @State private var consentPresented = false

    var body: some View {
        Form {
            if let error { Section { StatusBanner(message: error) { self.error = nil } } }
            Section {
                Toggle("为此账本启用智能分类", isOn: Binding(
                    get: { settings.isEnabled(for: ledgerID) },
                    set: { if $0 { consentPresented = true } else { settings.setEnabled(false, for: ledgerID) } }
                ))
                .disabled(!settings.hasKey)
                .accessibilityIdentifier("classification-enabled")
            } footer: {
                Text("导入账单时自动判断；自然语言草稿中点击「补充账户建议」时，Jev 根据支付信息和相关历史判断分类和付款或收款账户。结果填入预览，经你确认后在本机校验并保存。")
            }
            Section {
                if settings.hasKey { Label("API Key 已保存在本机", systemImage: "key.fill") }
                SecureField(settings.hasKey ? "替换 TypeSafe API Key" : "TypeSafe API Key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("classification-api-key")
                Button("保存 API Key") {
                    do { try settings.saveKey(key); key = ""; error = nil }
                    catch { self.error = error.localizedDescription }
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("classification-save-key")
                if settings.hasKey {
                    Button("移除 API Key 并停用", role: .destructive) {
                        do { try settings.removeKey(); key = ""; error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                    .accessibilityIdentifier("classification-remove-key")
                }
                Link("获取 TypeSafe API Key", destination: URL(string: "https://typesafe.ai")!)
            } header: { Text("TypeSafe") } footer: {
                Text("API Key 存放在这台设备的 Keychain，随账本导出与 Git 同步的内容中均不包含它。调用费用由你的 TypeSafe 账户承担。")
            }
            Section("发送内容") {
                Text("启用后，账单导入自动判断；自然语言入口点击「补充账户建议」会发送原始描述和未确定的分录。发送内容包含日期、商家、交易描述、金额、币种、支付方式、账单渠道、卡尾号、候选账户，以及最多 5 条相关历史的日期、商家、描述、支付方式、账户和标签。")
                Text("历史检索在本机完成。原始账单、订单号、账户余额、附件和完整账本保留在本机。服务暂时不可用时，可以继续手动分类。")
                Text("日期、金额、币种和商家描述沿用账单。信息有歧义时会提示核对；复杂拆分交易保留原分录。")
            }
        }
        .font(.subheadline)
        .navigationTitle("智能分类")
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .alert("启用在线智能分类？", isPresented: $consentPresented) {
            Button("同意并启用") { settings.setEnabled(true, for: ledgerID) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此账本的导入交易，以及你主动请求账户建议的自然语言描述和草稿、支付方式和卡尾号、候选账户及最多 5 条相关历史片段将发送至 TypeSafe。费用使用你提供的 API Key结算，可随时关闭。")
        }
        .onDisappear { key = "" }
    }
}
#endif
