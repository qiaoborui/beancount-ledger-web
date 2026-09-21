import SwiftUI

/// Intentionally separate from RootView and every LedgerSession-driven surface.
struct BoundedLedgerBrowser: View {
    @ObservedObject var model: BoundedLedgerBrowserModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("有界只读 · 实验构建", systemImage: "doc.text.magnifyingglass")
                        .font(.headline)
                    Text("仅使用这台设备上已有的本地工作区。不连接服务器，不自动构建索引。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if model.locked {
                    Section {
                        Label(model.runtimeAvailable ? "本地账本已锁定" : "有界读取运行时不可用",
                              systemImage: model.runtimeAvailable ? "lock.fill" : "exclamationmark.triangle")
                        Button("验证设备密码并选择账本") { model.unlock() }
                            .disabled(model.busy || !model.runtimeAvailable)
                    } footer: {
                        Text("锁定和进入后台会清除当前页面、详情和目录。再次查看需要重新验证。")
                    }
                } else {
                    library
                    if model.selected != nil { reader }
                }
                if model.busy {
                    Section { HStack { ProgressView(); Text("正在处理本地请求…").font(.footnote) } }
                }
                if let message = model.message {
                    Section("读取状态") { Text(message).font(.footnote) }
                }
                capabilities
            }
            .listStyle(.insetGrouped)
            .tint(LedgerPalette.cobalt)
            .navigationTitle("本地只读")
            .toolbar {
                if !model.locked || model.busy {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("锁定", systemImage: "lock") { model.lock() }
                    }
                }
            }
            .confirmationDialog("构建或重建本地只读索引？", isPresented: Binding(
                get: { model.confirmation != nil },
                set: { if !$0 { model.dismissConfirmation() } }
            ), titleVisibility: .visible) {
                Button("确认构建此版本") { model.confirmBuild() }
                Button("取消", role: .cancel) { model.dismissConfirmation() }
            } message: {
                Text("将读取已提交的本地版本，运行内嵌 Beancount 并写入派生索引；不会更改账本源文件。较大账本可能耗时，运行时加载本身尚非恒定内存。锁定将取消结果交付，但不能立即中断正在执行的 Python。")
            }
        }
        .privacySensitive()
    }

    private var library: some View {
        Section("选择已有本地账本") {
            if model.descriptors.isEmpty {
                Text("没有本地账本。本构建不提供创建、导入或远程下载。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(model.descriptors) { descriptor in
                Button { model.select(descriptor) } label: {
                    HStack {
                        Label(descriptor.name, systemImage: "book.closed")
                        Spacer()
                        if descriptor.id == model.selected?.id {
                            Image(systemName: "checkmark").accessibilityLabel("已选择")
                        }
                    }
                }
                .disabled(model.busy)
            }
        }
    }

    @ViewBuilder private var reader: some View {
        Section("只读索引") {
            Button("打开已有索引") { model.open() }
                .disabled(model.busy || model.lease != nil)
            Button("构建 / 重建索引…") { model.prepareBuild() }
                .disabled(model.busy)
            if let lease = model.lease {
                Label(lease.isStale ? "固定的旧版本：源文件已有更新" : "已固定源文件与索引版本",
                      systemImage: lease.isStale ? "clock.badge.exclamationmark" : "checkmark.shield")
                    .font(.footnote)
                Text("浏览期间固定版本，不实时跟随源文件。重建需要再次确认。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section {
            Picker("读取内容", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                Text("交易").tag(BoundedLedgerBrowserModel.Mode.transactions)
                Text("账户").tag(BoundedLedgerBrowserModel.Mode.accounts)
            }
            .pickerStyle(.segmented)
            .disabled(model.busy)
        }
        if model.mode == .accounts { accounts; accountActivity }
        if let page = model.page {
            Section {
                if page.transactions.isEmpty { Text("此版本没有交易。") }
                ForEach(page.transactions, id: \.id) { transaction in
                    Button { model.showDetail(transaction.id) } label: {
                        VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
                            if case .directive(_, let directive) = transaction.record.value {
                                Text(directive.payee ?? "交易").font(.headline).lineLimit(2)
                                if let narration = directive.narration, !narration.isEmpty {
                                    Text(narration).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                            Text(transaction.date).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                    .disabled(model.busy)
                }
            } header: { Text("当前页 · \(page.transactions.count) 条 / 最多 100 条") }
            Section {
                Button("回到第一页") { model.firstPage() }.disabled(model.busy)
                Button("下一页（替换当前页）") { model.nextPage() }
                    .disabled(model.busy || page.nextCursor == nil)
            } footer: { Text("不累计已读页面，不保留翻页历史。每次响应最多 1 MiB。") }
        }
        if let detail = model.detail {
            Section {
                ForEach(detail.records.indices, id: \.self) { index in
                    scalarRecord(detail.records[index])
                }
                if detail.records.isEmpty { Text("已到详情记录末尾。") }
                Button("详情回到第一页") { model.firstDetailPage() }.disabled(model.busy)
                Button("详情下一页（替换当前页）") { model.nextDetailPage() }
                    .disabled(model.busy || detail.nextCursor == nil)
                Button("关闭详情") { model.dismissDetail() }.disabled(model.busy)
            } header: { Text("部分指令详情 · 当前页 \(detail.records.count) 条 / 最多 100 条") } footer: { Text("只显示当前页的只读标量，续页不重复指令标题；不累计记录，不保留翻页历史。即使已到末页，也不是完整指令。不是完整交易编辑器。标签、链接、元数据值、自定义字段均省略；成本仅显示已导出的标量，不表示完整成本规格、批次或估值语义。") }
        }
    }

    @ViewBuilder private var accounts: some View {
        if let page = model.accountsPage {
            Section {
                if page.accounts.isEmpty { Text("此版本没有显式开户记录。") }
                ForEach(page.accounts, id: \.openID) { row in
                    Button { model.selectAccount(row.openID) } label: {
                        VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
                            Text(row.account).font(.headline)
                            Text("开户：\(row.openDate)").font(.caption)
                            if let close = row.closeDate { Text("最后显式关闭：\(close)").font(.caption) }
                            if case .directive(_, let value) = row.openRecord.value {
                                if let currencies = value.currencies, !currencies.isEmpty {
                                    Text("声明单位：\(currencies.joined(separator: ", "))").font(.caption)
                                }
                                if let booking = value.booking { Text("记账方式：\(booking)").font(.caption) }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .disabled(model.busy || !BoundedAccountsValidation.account(row.account))
                }
                Button("账户回到第一页") { model.firstAccountsPage() }.disabled(model.busy)
                Button("账户下一页（替换当前页）") { model.nextAccountsPage() }
                    .disabled(model.busy || page.nextCursor == nil)
            } header: { Text("显式开户 · 当前页 \(page.accounts.count) 条 / 最多 100 条") }
              footer: { Text("仅列出显式 open 指令，包含已关闭账户；不从分录推断账户，也不表示某日的有效账户。翻页会清除已选账户与余额。") }
        }
        if let selected = model.selectedAccount {
            Section {
                Text(selected.account).font(.headline).textSelection(.enabled)
                Text("原生单位净额 · 全部日期").font(.subheadline)
                if let page = model.balances {
                    if page.balances.isEmpty { Text("此账户没有原生单位分录。") }
                    ForEach(page.balances.indices, id: \.self) { index in
                        Button { model.selectCurrency(page.balances[index].currency) } label: {
                            VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
                                Text(page.balances[index].currency).font(.caption).foregroundStyle(.secondary)
                                Text(page.balances[index].quantity).font(.body.monospacedDigit())
                                Text("查看此原生单位的汇总与流水").font(.caption)
                            }
                            .foregroundStyle(.primary)
                        }
                        .disabled(model.busy || !BoundedAccountsValidation.account(page.balances[index].currency))
                    }
                    Text("当前页 \(page.balances.count) 种单位 / 最多 100 种").font(.caption)
                    Button("单位回到第一页") { model.firstBalancesPage() }.disabled(model.busy)
                    Button("单位下一页（替换当前页）") { model.nextBalancesPage() }
                        .disabled(model.busy || page.nextCursor == nil)
                }
                Button("查看开户指令与元数据类型") { model.showAccountMetadata() }.disabled(model.busy)
            } footer: {
                Text("native_nominal：按原生币种或商品单位精确求和，不换汇、不合计不同单位。这不是市值或估值，不含成本批次，也不保证与旧版金额或报表语义一致。仅保留当前页，不累计单位；每次响应最多 1 MiB。")
            }
        }
    }

    @ViewBuilder private var accountActivity: some View {
        if let currency = model.selectedCurrency {
            Section {
                Text(currency).font(.headline).textSelection(.enabled)
                if let summary = model.summary {
                    nativeScalar("当前余额（全部日期）", summary.currentBalance)
                    nativeScalar("期初余额", summary.openingBalance)
                    nativeScalar("期末余额", summary.closingBalance)
                    nativeScalar("期间变动", summary.periodChange)
                }
            } header: { Text("原生单位汇总 · 全部日期") }
              footer: { Text("native_nominal：仅按选中单位精确求和。未选日期范围时，期初为 0，期末和期间变动等于当前余额。不是市值、估值、成本批次或旧版金额兼容承诺。") }
            if let page = model.activity {
                Section {
                    if page.rows.isEmpty { Text("此账户与单位没有交易流水。") }
                    ForEach(page.rows, id: \.id) { row in
                        Button { model.showActivityDetail(row.id) } label: {
                            VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
                                Text(row.date).font(.caption.monospacedDigit())
                                if case .directive(_, let value) = row.record.value {
                                    if let payee = value.payee { Text(payee).font(.headline).lineLimit(2) }
                                    if let narration = value.narration { Text(narration).lineLimit(3) }
                                }
                                Text("变动：\(row.change)").monospacedDigit()
                                Text("逐笔余额：\(row.balance)").monospacedDigit()
                            }.foregroundStyle(.primary)
                        }.disabled(model.busy)
                    }
                    Button("流水回到第一页") { model.firstActivityPage() }.disabled(model.busy)
                    Button("流水下一页（替换当前页）") { model.nextActivityPage() }
                        .disabled(model.busy || page.nextCursor == nil)
                } header: { Text("按日期正序 · 当前页 \(page.rows.count) 条 / 最多 100 条") }
                  footer: { Text("同一交易的同账户、同单位分录合并为一行。逐笔余额包含此前交易，不从当前页重新归零；点击查看部分标量详情。不累计页面，每次响应最多 1 MiB。") }
            }
        }
    }

    private func nativeScalar(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit()).textSelection(.enabled)
        }
    }

    @ViewBuilder private func scalarRecord(_ record: BoundedIndexRecord) -> some View {
        switch record.value {
        case .directive(_, let value):
            VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
                Text("\(value.date) · \(value.kind)").font(.caption)
                if let account = value.account { Text(account).font(.headline) }
                if let payee = value.payee { Text(payee).font(.headline) }
                if let narration = value.narration { Text(narration) }
                if let flag = value.flag { Text("标记：\(flag)").font(.caption) }
                Text("\(value.file):\(value.line)").font(.caption).foregroundStyle(.secondary)
            }
        case .posting(_, _, let value):
            VStack(alignment: .leading, spacing: LedgerSpacing.xs) {
                Text(value.account).font(.subheadline)
                Text("\(value.quantity.number) \(value.quantity.currency)").monospacedDigit()
                if let cost = value.cost {
                    Text("成本标量：\(cost.number) \(cost.currency)").font(.caption)
                }
                if let price = value.price {
                    Text("价格标量：\(price.number) \(price.currency)").font(.caption)
                }
            }
        case .metadata(_, _, let key, let type):
            Text("元数据 \(key)（\(type)）：值已省略")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var capabilities: some View {
        Section("能力与限制") {
            Label("支持：设备验证、本地目录、显式索引构建、分页交易与账户、原生单位净额、汇总与逐笔流水、标量详情", systemImage: "checkmark.circle")
            Label("不支持：编辑、导入、同步、远程账本、搜索、成本批次、报表、估值、小组件和后台刷新", systemImage: "minus.circle")
            Text("只读并不代表完整语义覆盖。没有服务器或旧快照回退；无法验证时保持不可用。派生文件沿用工作区保护策略，锁定不是安全擦除或独立加密。")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
    }
}
