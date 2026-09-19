import SwiftUI

struct CategoriesManagementView: View {
    @EnvironmentObject private var session: LedgerSession
    @State private var selectedKind: CategoryKind = .expense
    @State private var showingAddCategory: Bool = false
    @State private var searchText: String = ""

    private var matchingAccounts: [LedgerAccount] {
        guard let accounts = session.ledger?.accounts else { return [] }
        let prefix = selectedKind.rawValue + ":"
        let filtered = accounts.filter { $0.account.hasPrefix(prefix) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return filtered }
        return filtered.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.account.localizedCaseInsensitiveContains(query)
                || ($0.alias?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var groupedAccounts: [(section: String, rows: [LedgerAccount])] {
        let prefix = selectedKind.rawValue + ":"
        var dict: [String: [LedgerAccount]] = [:]
        for acct in matchingAccounts {
            let remainder = acct.account.dropFirst(prefix.count)
            let topPart = String(remainder.split(separator: ":").first ?? "Other")
            dict[topPart, default: []].append(acct)
        }
        return dict.keys.sorted().map { key in
            (section: key, rows: dict[key]?.sorted(by: { $0.account < $1.account }) ?? [])
        }
    }

    var body: some View {
        List {
            Section {
                Picker("分类类型", selection: $selectedKind) {
                    ForEach(CategoryKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))

            if groupedAccounts.isEmpty {
                ContentUnavailableView(
                    "暂无分类",
                    systemImage: "tag.slash",
                    description: Text(searchText.isEmpty ? "点击右上角 + 添加新分类。" : "未找到匹配的分类。")
                )
            } else {
                ForEach(groupedAccounts, id: \.section) { group in
                    Section(header: Text(group.section)) {
                        ForEach(group.rows, id: \.account) { acct in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(acct.label)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(LedgerPalette.ink)
                                    Spacer()
                                    if !acct.active {
                                        Text("已停用")
                                            .font(.caption2)
                                            .foregroundStyle(LedgerPalette.gold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(LedgerPalette.gold.opacity(0.12), in: Capsule())
                                    }
                                }
                                Text(acct.account)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
        .ledgerReadingList()
        .ledgerNavigation("分类管理")
        .ledgerSearch(text: $searchText, prompt: "搜索分类名称或路径")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddCategory = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建分类")
            }
        }
        .sheet(isPresented: $showingAddCategory) {
            AddCategoryView(initialKind: selectedKind)
                .ledgerPrivacyProtectedSheet()
        }
    }
}
