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
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(BalancedPalette.meta)
                    TextField("搜索分类名称或路径", text: $searchText)
                        .balancedFont(size: 15)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("category-search")
                }
                .frame(minHeight: 40)
                .padding(.horizontal, 12)
                .background(BalancedPalette.sunken)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 2, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section {
                CategoryKindSeg(selected: $selectedKind)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 0, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section {
                Text(searchText.isEmpty
                    ? "共 \(matchingAccounts.count) 个\(selectedKind.title)分类，按一级科目分组。加号新增，左滑可停用。"
                    : "未找到匹配的分类。")
                    .balancedFont(size: 12.5)
                    .foregroundStyle(BalancedPalette.meta)
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 0, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if groupedAccounts.isEmpty {
                Section {
                    VStack(spacing: 6) {
                        Image(systemName: "tag.slash").font(.system(size: 22)).foregroundStyle(BalancedPalette.meta)
                        Text("暂无分类").balancedFont(size: 16, weight: .medium).foregroundStyle(BalancedPalette.ink)
                        Text(searchText.isEmpty ? "点击右上角 + 添加新分类。" : "未找到匹配的分类。")
                            .balancedFont(size: 13.5)
                            .foregroundStyle(BalancedPalette.meta)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 56)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(groupedAccounts, id: \.section) { group in
                    Section {
                        // A row, not a `header:` closure: native section headers
                        // in a plain list keep their own system inset instead of
                        // the 20pt column every row uses, so the label would sit
                        // a few points left of the rows beneath it. Rendering it
                        // as a row with the same `listRowInsets` guarantees the
                        // same left edge by construction.
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(group.section)
                                .balancedFont(size: 12.5, weight: .medium)
                                .tracking(0.375)
                                .foregroundStyle(BalancedPalette.meta)
                            Spacer()
                            Text("\(group.rows.count)")
                                .balancedFont(size: 12.5)
                                .foregroundStyle(BalancedPalette.meta)
                        }
                        .frame(minHeight: 28, alignment: .bottom)
                        .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 6, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                        ForEach(group.rows, id: \.account) { acct in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(acct.label)
                                        .balancedFont(size: 15, weight: .text)
                                        .foregroundStyle(acct.active ? BalancedPalette.ink : BalancedPalette.meta)
                                    Text(acct.account).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                                }
                                Spacer(minLength: 8)
                                if !acct.active {
                                    BalancedTag(text: "已停用", kind: .neutral)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(BalancedPalette.edge)
                                }
                            }
                            .frame(minHeight: 44)
                            .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }
        }
        .ledgerReadingList()
        .scrollContentBackground(.hidden)
        .background(BalancedPalette.page)
        .terminalPageChrome("分类管理", isRoot: false, actions: AnyView(
            Button { showingAddCategory = true } label: {
                Image(systemName: "plus").font(.system(size: 16)).frame(width: 44, height: 44)
                    .foregroundStyle(BalancedPalette.ink)
            }.accessibilityLabel("新建分类")
        ))
        .sheet(isPresented: $showingAddCategory) {
            AddCategoryView(initialKind: selectedKind)
                .ledgerPrivacyProtectedSheet()
        }
    }
}

/// `.seg` — a full-width two-item mark with a shared `--rule` baseline.
struct CategoryKindSeg: View {
    @Binding var selected: CategoryKind

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CategoryKind.allCases) { kind in
                Button {
                    LedgerFeedback.selection()
                    selected = kind
                } label: {
                    BalancedMark(title: kind.title, selected: selected == kind, size: 14)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == kind ? .isSelected : [])
            }
        }
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
    }
}
