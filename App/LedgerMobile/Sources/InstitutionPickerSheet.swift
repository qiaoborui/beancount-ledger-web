import SwiftUI

/// 机构与银行选择弹窗：支持按拼音/名称快速检索，分类浏览国有行、股份制银行、电子钱包、信用卡及海外账户。
struct InstitutionPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedGroup: InstitutionGroup? = nil

    var onSelect: (AccountPresetItem) -> Void
    var onSelectCustom: (() -> Void)? = nil

    private var searchResults: [AccountPresetItem] {
        AccountPresets.search(query: searchText)
    }

    var body: some View {
        NavigationStack {
            List {
                if !searchText.isEmpty {
                    // 搜索结果列表
                    if searchResults.isEmpty {
                        Section {
                            VStack(spacing: LedgerSpacing.md) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 36))
                                    .foregroundStyle(LedgerPalette.secondary)
                                Text("未找到匹配的预设机构")
                                    .font(.subheadline)
                                    .foregroundStyle(LedgerPalette.secondary)
                                if let onSelectCustom {
                                    Button("使用自定义名称") {
                                        dismiss()
                                        onSelectCustom()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(LedgerPalette.cobalt)
                                    .padding(.top, 4)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, LedgerSpacing.xl)
                        }
                    } else {
                        Section("搜索结果 (\(searchResults.count))") {
                            ForEach(searchResults) { item in
                                itemRow(item)
                            }
                        }
                    }
                } else {
                    // 自定义入口
                    if let onSelectCustom {
                        Section {
                            Button {
                                dismiss()
                                onSelectCustom()
                            } label: {
                                HStack(spacing: LedgerSpacing.md) {
                                    ZStack {
                                        Circle()
                                            .fill(LedgerPalette.cobalt.opacity(0.12))
                                            .frame(width: 36, height: 36)
                                        Image(systemName: "pencil.and.outline")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(LedgerPalette.cobalt)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("自定义机构或名称")
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(LedgerPalette.ink)
                                        Text("输入任意机构、非标银行或特定卡号")
                                            .font(.caption2)
                                            .foregroundStyle(LedgerPalette.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(LedgerPalette.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // 分组展示
                    ForEach(InstitutionGroup.allCases) { group in
                        let items = AccountPresets.presets(for: group)
                        if !items.isEmpty {
                            Section(group.title) {
                                ForEach(items) { item in
                                    itemRow(item)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索银行、钱包、拼音或代码 (如 CMB)")
            .navigationTitle("选择机构与银行")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func itemRow(_ item: AccountPresetItem) -> some View {
        Button {
            LedgerFeedback.selection()
            onSelect(item)
            dismiss()
        } label: {
            HStack(spacing: LedgerSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(groupColor(item.group).opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: item.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(groupColor(item.group))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(LedgerPalette.ink)
                    Text(item.defaultAccount)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LedgerPalette.secondary)
                }

                Spacer()

                if let curr = item.suggestedCurrency {
                    Text(curr)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(LedgerPalette.cobalt)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(LedgerPalette.cobalt.opacity(0.1), in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func groupColor(_ group: InstitutionGroup) -> Color {
        switch group {
        case .national: .red
        case .commercial: .blue
        case .digital: .green
        case .credit: .orange
        case .crossBorder: .purple
        case .wealthAndOther: .indigo
        }
    }
}
