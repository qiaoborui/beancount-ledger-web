import SwiftUI

/// The cards the setup assistant shows in place of a string of questions
/// while it builds a ledger from scratch: opening balances, categories,
/// where the ledger lives, and which bills it imports. The user fills one
/// in; the app edits the draft and sends a summary as the answer.
struct LedgerOnboardingCardView: View {
    let card: LedgerOnboardingCard
    let draft: LedgerOnboardingDraft
    /// The Git token and username for a ledger stored in Git. They stay on
    /// the page and go to the keychain when the ledger is created; neither
    /// is ever in the draft or the conversation.
    @Binding var gitToken: String
    @Binding var gitUser: String
    var disabled = false
    let onSubmit: (LedgerOnboardingCardAnswer) -> Void

    var body: some View {
        Group {
            switch card.kind {
            case .accounts: LedgerAccountsCard(draft: draft, onSubmit: onSubmit)
            case .balances: LedgerBalancesCard(draft: draft, onSubmit: onSubmit)
            case .categories: LedgerCategoriesCard(card: card, draft: draft, onSubmit: onSubmit)
            case .storage: LedgerStorageCard(draft: draft, gitToken: $gitToken, gitUser: $gitUser, onSubmit: onSubmit)
            case .imports: LedgerImportsCard(draft: draft, onSubmit: onSubmit)
            }
        }
        .disabled(disabled)
        .accessibilityIdentifier("ai-onboarding-card-\(card.kind.rawValue)")
    }
}

/// A card's title line.
private struct LedgerCardTitle: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).balancedFont(size: 15, weight: .medium).foregroundStyle(BalancedPalette.ink)
            if let detail {
                Text(detail).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta).lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

/// A capsule that is on or off, for categories, channels and dates.
private struct LedgerToggleChip: View {
    let title: String
    let on: Bool
    var adds = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if on {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                } else if adds {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(BalancedPalette.meta)
                }
                Text(title).balancedFont(size: 13.5)
            }
            .foregroundStyle(on ? BalancedPalette.page : BalancedPalette.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Capsule().fill(on ? BalancedPalette.ink : BalancedPalette.page))
            .overlay {
                Capsule().stroke(on ? Color.clear : BalancedPalette.rule,
                                 style: StrokeStyle(lineWidth: 0.8, dash: adds && !on ? [3, 3] : []))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The footer of a card: a hint and its buttons.
private struct LedgerCardFooter<Buttons: View>: View {
    let hint: String
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        HStack(spacing: 8) {
            Text(hint).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).lineLimit(2)
            Spacer(minLength: 8)
            buttons()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

// MARK: Currency

/// A capsule that shows a currency and opens the common ones.
private struct LedgerCurrencyMenu: View {
    let currency: String
    let onPick: (String) -> Void

    var body: some View {
        Menu {
            ForEach(LedgerOnboardingDraft.currencies, id: \.self) { code in
                Button {
                    onPick(code)
                } label: {
                    if code == currency { Label(code, systemImage: "checkmark") } else { Text(code) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(currency).balancedMono(size: 12)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(BalancedPalette.secondary)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .background(Capsule().fill(BalancedPalette.sunken))
        }
        .accessibilityLabel(String(localized: "币种 \(currency)"))
    }
}

// MARK: Accounts

/// Where the money is: the ledger's currency first, then every built-in
/// bank, wallet, card and loan as chips, the picked ones with their own
/// currency, and a row for anything not built in.
private struct LedgerAccountsCard: View {
    let draft: LedgerOnboardingDraft
    let onSubmit: (LedgerOnboardingCardAnswer) -> Void

    private static let sections: [AccountTypeCategory] = [.bank, .wallet, .credit, .cash, .wealth, .loan]
    private static let collapsedCount = 8

    @State private var currency = "CNY"
    @State private var picked: [LedgerOnboardingDraft.Account] = []
    @State private var expanded: Set<AccountTypeCategory> = []
    @State private var customName = ""
    @State private var customKind = "bank_card"
    @State private var seeded = false

    private var pickedPaths: Set<String> { Set(picked.map(\.account)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerCardTitle(title: String(localized: "钱都放在哪"),
                            detail: String(localized: "点选你在用的，常见的都在这里；没有的在最下面加。信用卡、花呗这类欠款也一起选上。"))
            VStack(alignment: .leading, spacing: 6) {
                Text("主要用什么货币记账").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).padding(.horizontal, 4)
                LedgerSetupFlow(spacing: 6) {
                    ForEach(LedgerOnboardingDraft.currencies, id: \.self) { code in
                        LedgerToggleChip(title: code, on: currency == code) { currency = code }
                    }
                }
            }
            if !picked.isEmpty { pickedList }
            ForEach(Self.sections, id: \.self) { kind in presetSection(kind) }
            customRow
            LedgerCardFooter(hint: picked.contains { !$0.isLiability }
                             ? String(localized: "已选 \(picked.count) 个")
                             : String(localized: "至少选一个放钱的地方")) {
                Button("好了") { onSubmit(.accounts(currency: currency, picked)) }
                    .buttonStyle(.balanced(.primary))
                    .fixedSize()
                    .disabled(!picked.contains { !$0.isLiability })
                    .accessibilityIdentifier("ai-onboarding-card-done")
            }
        }
        .ledgerCard(padding: 12)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            currency = draft.currency.isEmpty ? LedgerOnboardingDraft.regionCurrency() : draft.currency
            picked = draft.accounts
        }
    }

    /// The accounts picked so far, each with its currency.
    private var pickedList: some View {
        VStack(spacing: 0) {
            ForEach(Array(picked.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider().overlay(BalancedPalette.rule).padding(.leading, 14) }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.name).balancedFont(size: 14.5).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                        Text(LedgerOnboardingDraft.kindTitle(account.kind)).balancedFont(size: 11).foregroundStyle(BalancedPalette.meta)
                    }
                    Spacer(minLength: 6)
                    LedgerCurrencyMenu(currency: account.currency.isEmpty ? currency : account.currency) { code in
                        picked[index].currency = code == currency ? "" : code
                    }
                    Button {
                        picked.removeAll { $0.account == account.account }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BalancedPalette.meta)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "去掉 \(account.name)"))
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .frame(minHeight: 46)
            }
        }
        .ledgerInsetWell()
    }

    private struct Choice: Identifiable {
        let preset: AccountPresetItem
        let account: LedgerOnboardingDraft.Account
        var id: String { preset.id }
    }

    /// The presets of one kind, those meant for the ledger's currency first.
    private func presets(_ section: AccountTypeCategory) -> [Choice] {
        let rank: (AccountPresetItem) -> Int = { preset in
            if preset.suggestedCurrency == currency { return 0 }
            if preset.suggestedCurrency == nil { return currency == "CNY" ? 0 : 1 }
            return 2
        }
        let items = AccountPresets.presets(for: section).enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map { $0.element }
        return items.compactMap { preset in
            LedgerOnboardingDraft.account(for: preset, ledgerCurrency: currency).map { Choice(preset: preset, account: $0) }
        }
    }

    @ViewBuilder
    private func presetSection(_ section: AccountTypeCategory) -> some View {
        let all = presets(section)
        let open = expanded.contains(section) || all.count <= Self.collapsedCount + 1
        let shown = open ? all : Array(all.prefix(Self.collapsedCount))
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(section.title).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).padding(.horizontal, 4)
                LedgerSetupFlow(spacing: 6) {
                    ForEach(shown) { item in
                        LedgerToggleChip(title: item.account.name, on: pickedPaths.contains(item.account.account)) {
                            toggle(item.account)
                        }
                    }
                    if !open {
                        LedgerToggleChip(title: String(localized: "更多 \(all.count - shown.count) 个"), on: false, adds: true) {
                            withAnimation(.easeOut(duration: 0.18)) { _ = expanded.insert(section) }
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ account: LedgerOnboardingDraft.Account) {
        if pickedPaths.contains(account.account) {
            picked.removeAll { $0.account == account.account }
        } else if !picked.contains(where: { $0.name == account.name }) {
            // Two accounts cannot share a name.
            picked.append(account)
        }
    }

    private var customRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(LedgerOnboardingDraft.customKinds, id: \.kind) { item in
                    Button(LedgerOnboardingDraft.kindTitle(item.kind)) { customKind = item.kind }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(LedgerOnboardingDraft.kindTitle(customKind)).balancedFont(size: 13)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(BalancedPalette.ink)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(Capsule().fill(BalancedPalette.sunken))
            }
            TextField("其他账户，如 工资卡", text: $customName)
                .balancedFont(size: 14)
                .submitLabel(.done)
                .onSubmit(addCustom)
            Button("添加", action: addCustom)
                .buttonStyle(.balanced(.quiet))
                .fixedSize()
                .disabled(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 6)
        .padding(.vertical, 4)
        .padding(.trailing, 4)
        .ledgerInsetWell()
    }

    private func addCustom() {
        guard let account = LedgerOnboardingDraft.customAccount(name: customName, kind: customKind, currency: "",
                                                                 taken: pickedPaths),
              !picked.contains(where: { $0.name == account.name }) else { return }
        picked.append(account)
        customName = ""
    }
}

// MARK: Balances

private struct LedgerBalancesCard: View {
    let draft: LedgerOnboardingDraft
    let onSubmit: (LedgerOnboardingCardAnswer) -> Void

    private enum Start: Hashable { case today, monthStart, custom }

    @State private var amounts: [String: String] = [:]
    @State private var currencies: [String: String] = [:]
    @State private var start: Start = .today
    @State private var date = Date()
    @State private var seeded = false
    @FocusState private var focused: String?

    private var invalid: Set<String> {
        Set(amounts.filter { LedgerOnboardingCardAnswer.normalizedAmount($0.value) == nil }.keys)
    }

    private var startDate: String {
        switch start {
        case .today: ""
        case .monthStart:
            LedgerOnboardingConversation.localDay(Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date())
        case .custom: LedgerOnboardingConversation.localDay(date)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LedgerCardTitle(title: String(localized: "现在各有多少"),
                            detail: String(localized: "填当前余额，可以带小数；信用卡和贷款填欠多少。币种不对点一下就能改。不确定的先空着，以后对账再补。"))
            VStack(spacing: 0) {
                ForEach(Array(draft.accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider().overlay(BalancedPalette.rule).padding(.leading, 14) }
                    row(account)
                }
            }
            .ledgerInsetWell()
            VStack(alignment: .leading, spacing: 6) {
                Text("从哪天开始记").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).padding(.horizontal, 4)
                LedgerSetupFlow(spacing: 6) {
                    LedgerToggleChip(title: String(localized: "今天"), on: start == .today) { start = .today }
                    LedgerToggleChip(title: String(localized: "本月 1 日"), on: start == .monthStart) { start = .monthStart }
                    LedgerToggleChip(title: String(localized: "选一天"), on: start == .custom) { start = .custom }
                }
                if start == .custom {
                    DatePicker("期初日期", selection: $date, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .balancedFont(size: 14)
                        .padding(.horizontal, 4)
                }
            }
            LedgerCardFooter(hint: invalid.isEmpty ? String(localized: "最多两位小数") : String(localized: "有金额看不懂，标红的再看看")) {
                Button("先不填") { onSubmit(.balances([:], startDate: startDate, currencies: currencies)) }
                    .buttonStyle(.balanced(.quiet))
                    .fixedSize()
                Button("好了") { onSubmit(.balances(amounts, startDate: startDate, currencies: currencies)) }
                    .buttonStyle(.balanced(.primary))
                    .fixedSize()
                    .disabled(!invalid.isEmpty)
                    .accessibilityIdentifier("ai-onboarding-card-done")
            }
        }
        .ledgerCard(padding: 12)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            amounts = Dictionary(draft.accounts.map { ($0.account, $0.openingBalance) }, uniquingKeysWith: { first, _ in first })
            if !draft.startDate.isEmpty, let parsed = Self.parse(draft.startDate) {
                start = .custom
                date = parsed
            }
        }
    }

    private func currency(of account: LedgerOnboardingDraft.Account) -> String {
        if let picked = currencies[account.account] { return picked }
        return account.currency.isEmpty ? draft.currency : account.currency
    }

    private func row(_ account: LedgerOnboardingDraft.Account) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                Text(account.isLiability ? String(localized: "\(LedgerOnboardingDraft.kindTitle(account.kind)) · 欠多少")
                                         : LedgerOnboardingDraft.kindTitle(account.kind))
                    .balancedFont(size: 11.5)
                    .foregroundStyle(account.isLiability ? BalancedPalette.expense : BalancedPalette.meta)
            }
            Spacer(minLength: 6)
            TextField("0.00", text: Binding(get: { amounts[account.account] ?? "" }, set: { amounts[account.account] = $0 }))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .balancedMono(size: 15)
                .foregroundStyle(invalid.contains(account.account) ? BalancedPalette.expense : BalancedPalette.ink)
                .focused($focused, equals: account.account)
                .frame(maxWidth: 130)
                .accessibilityLabel(account.isLiability ? String(localized: "\(account.name) 欠款") : String(localized: "\(account.name) 余额"))
            LedgerCurrencyMenu(currency: currency(of: account)) { code in currencies[account.account] = code }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .onTapGesture { focused = account.account }
    }

    private static func parse(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }
}

// MARK: Categories

/// Every built-in income and expense category, grouped and folded; the
/// ones the assistant picked for the user start ticked, and anything not
/// built in can be typed in.
private struct LedgerCategoriesCard: View {
    let card: LedgerOnboardingCard
    let draft: LedgerOnboardingDraft
    let onSubmit: (LedgerOnboardingCardAnswer) -> Void

    typealias Item = LedgerOnboardingCard.Suggestion

    @State private var chosen: [Item] = []
    @State private var expanded: Set<String> = []
    @State private var customName = ""
    @State private var customIncome = false
    @State private var seeded = false

    private var chosenPaths: Set<String> { Set(chosen.map(\.account)) }
    private var incomeCount: Int { chosen.filter(\.isIncome).count }
    private var expenseCount: Int { chosen.count - incomeCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerCardTitle(title: String(localized: "收支分类"),
                            detail: String(localized: "已经按你的情况勾了一组。展开分组可以多选，点掉不要的；没有的在最下面加。"))
            side(income: false)
            side(income: true)
            customRow
            LedgerCardFooter(hint: incomeCount == 0 || expenseCount == 0
                             ? String(localized: "收入和支出各选至少一个")
                             : String(localized: "收入 \(incomeCount) · 支出 \(expenseCount)")) {
                Button("好了") {
                    let inDraft = Set((draft.incomeCategories + draft.expenseCategories).map(\.account))
                    onSubmit(.categories(kept: chosenPaths.intersection(inDraft),
                                         added: chosen.filter { !inDraft.contains($0.account) }))
                }
                .buttonStyle(.balanced(.primary))
                .fixedSize()
                .disabled(incomeCount == 0 || expenseCount == 0)
                .accessibilityIdentifier("ai-onboarding-card-done")
            }
        }
        .ledgerCard(padding: 12)
        .onAppear(perform: seed)
    }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        let fromDraft = draft.expenseCategories.map { Item(kind: "expense", name: $0.name, account: $0.account) }
            + draft.incomeCategories.map { Item(kind: "income", name: $0.name, account: $0.account) }
        chosen = fromDraft.isEmpty ? LedgerOnboardingCard.defaultCategories : fromDraft
        let paths = Set(chosen.map(\.account))
        expanded = Set(CategoryPresets.sections.filter { section in
            section.items.contains { paths.contains(LedgerOnboardingCard.path(section, $0)) }
        }.map(\.id))
    }

    @ViewBuilder
    private func side(income: Bool) -> some View {
        let kind: CategoryKind = income ? .income : .expense
        let presetPaths = Set(CategoryPresets.sections(for: kind).flatMap { section in
            section.items.map { LedgerOnboardingCard.path(section, $0) }
        })
        // Picked or suggested ones that are not built in: the assistant's
        // own or typed by the user.
        let own = chosen.filter { $0.isIncome == income && !presetPaths.contains($0.account) }
        let suggested = card.suggested.filter { $0.isIncome == income && !chosenPaths.contains($0.account) && !presetPaths.contains($0.account) }
        VStack(alignment: .leading, spacing: 8) {
            Text(income ? String(localized: "收入 \(incomeCount)") : String(localized: "支出 \(expenseCount)"))
                .balancedFont(size: 13, weight: .medium).foregroundStyle(BalancedPalette.ink).padding(.horizontal, 4)
            if !own.isEmpty || !suggested.isEmpty {
                LedgerSetupFlow(spacing: 6) {
                    ForEach(own) { item in
                        LedgerToggleChip(title: item.name, on: true) { toggle(item) }
                    }
                    ForEach(suggested) { item in
                        LedgerToggleChip(title: item.name, on: false, adds: true) { toggle(item) }
                    }
                }
            }
            VStack(spacing: 0) {
                let sections = CategoryPresets.sections(for: kind)
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 { Divider().overlay(BalancedPalette.rule).padding(.leading, 14) }
                    group(section, income: income)
                }
            }
            .ledgerInsetWell()
        }
    }

    private func group(_ section: CategorySectionPreset, income: Bool) -> some View {
        let items = section.items.map { Item(kind: income ? "income" : "expense", name: $0.name,
                                             account: LedgerOnboardingCard.path(section, $0)) }
        let count = items.filter { chosenPaths.contains($0.account) }.count
        let open = expanded.contains(section.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    if open { expanded.remove(section.id) } else { expanded.insert(section.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: section.icon).font(.system(size: 13)).foregroundStyle(BalancedPalette.secondary)
                        .frame(width: 20)
                    Text(section.name).balancedFont(size: 14.5).foregroundStyle(BalancedPalette.ink)
                    Spacer(minLength: 6)
                    if count > 0 {
                        Text("\(count)/\(items.count)").balancedMono(size: 12).foregroundStyle(BalancedPalette.ink)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(BalancedPalette.meta)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .frame(minHeight: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                LedgerSetupFlow(spacing: 6) {
                    ForEach(items) { item in
                        LedgerToggleChip(title: item.name, on: chosenPaths.contains(item.account)) { toggle(item) }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 14)
    }

    private func toggle(_ item: Item) {
        if chosenPaths.contains(item.account) {
            chosen.removeAll { $0.account == item.account }
        } else if !chosen.contains(where: { $0.isIncome == item.isIncome && $0.name == item.name }) {
            // Two categories on one side cannot share a name.
            chosen.append(item)
        }
    }

    private var customRow: some View {
        HStack(spacing: 8) {
            Menu {
                Button(String(localized: "支出")) { customIncome = false }
                Button(String(localized: "收入")) { customIncome = true }
            } label: {
                HStack(spacing: 3) {
                    Text(customIncome ? String(localized: "收入") : String(localized: "支出")).balancedFont(size: 13)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(BalancedPalette.ink)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(Capsule().fill(BalancedPalette.sunken))
            }
            TextField("其他分类，如 猫粮", text: $customName)
                .balancedFont(size: 14)
                .submitLabel(.done)
                .onSubmit(addCustom)
            Button("添加", action: addCustom)
                .buttonStyle(.balanced(.quiet))
                .fixedSize()
                .disabled(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 6)
        .padding(.vertical, 4)
        .padding(.trailing, 4)
        .ledgerInsetWell()
    }

    private func addCustom() {
        let taken = chosenPaths.union((draft.incomeCategories + draft.expenseCategories).map(\.account))
        guard let category = LedgerOnboardingDraft.customCategory(name: customName, income: customIncome, taken: taken),
              !chosen.contains(where: { $0.name == category.name }) else { return }
        chosen.append(Item(kind: customIncome ? "income" : "expense", name: category.name, account: category.account))
        customName = ""
    }
}

// MARK: Storage

private struct LedgerStorageCard: View {
    let draft: LedgerOnboardingDraft
    @Binding var gitToken: String
    @Binding var gitUser: String
    let onSubmit: (LedgerOnboardingCardAnswer) -> Void

    @State private var storage = "device"
    @State private var remote = ""
    @State private var seeded = false
    /// Shown only on builds and devices that can reach the app's iCloud.
    @State private var iCloudAvailable = false

    /// The address as it will be stored: HTTPS, no credentials.
    private var address: String? {
        let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("@"), let found = LedgerSetupScript.gitRepository(in: text) else { return nil }
        return found
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LedgerCardTitle(title: String(localized: "账本放在哪"))
            option("device", title: String(localized: "只存在这台设备上"),
                   detail: String(localized: "最简单。之后随时可以在设置里接 Git 或 iCloud。"), symbol: "iphone")
            if iCloudAvailable {
                option("icloud", title: String(localized: "存进 iCloud"),
                       detail: String(localized: "同一个 Apple 账户的 iPhone、iPad 自动同步，不用准备什么。"), symbol: "icloud")
            }
            option("git", title: String(localized: "同步到 Git 仓库"),
                   detail: String(localized: "准备一个空仓库，建好后自动推上去，电脑上也能用。"), symbol: "arrow.triangle.branch")
            if storage == "git" { gitFields }
            LedgerCardFooter(hint: storage == "git" ? String(localized: "令牌只存钥匙串，不进对话") : "") {
                Button("好了") {
                    onSubmit(storage == "git" ? .storage("git", remote: address ?? "") : .storage(storage, remote: ""))
                }
                .buttonStyle(.balanced(.primary))
                .fixedSize()
                .disabled(storage == "git" && address == nil)
                .accessibilityIdentifier("ai-onboarding-card-done")
            }
        }
        .ledgerCard(padding: 12)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            if draft.storage == "git" {
                storage = "git"
                remote = draft.remote
            } else if draft.storage == "icloud" {
                storage = "icloud"
            }
        }
        .task {
            iCloudAvailable = await LedgerICloud.available()
            if !iCloudAvailable, storage == "icloud" { storage = "device" }
        }
    }

    private func option(_ value: String, title: String, detail: String, symbol: String) -> some View {
        let on = storage == value
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { storage = value }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BalancedPalette.ink)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                    Text(detail).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta).lineSpacing(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                LedgerRoundTick(on: on)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(BalancedPalette.page, in: RoundedRectangle(cornerRadius: LedgerRound.inset, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LedgerRound.inset, style: .continuous)
                    .stroke(on ? BalancedPalette.ink : BalancedPalette.rule, lineWidth: on ? 1.2 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: LedgerRound.inset, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("ai-onboarding-storage-\(value)")
    }

    private var gitFields: some View {
        VStack(spacing: 0) {
            field(String(localized: "地址")) {
                TextField("https://github.com/你/账本", text: $remote)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("ai-onboarding-storage-remote")
            }
            Divider().overlay(BalancedPalette.rule).padding(.leading, 14)
            field(String(localized: "令牌")) {
                SecureField("有写入权限的访问令牌", text: $gitToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Divider().overlay(BalancedPalette.rule).padding(.leading, 14)
            field(String(localized: "用户名")) {
                TextField("可不填", text: $gitUser)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .balancedFont(size: 14.5)
        .ledgerInsetWell()
    }

    private func field<Field: View>(_ label: String, @ViewBuilder content: () -> Field) -> some View {
        HStack(spacing: 10) {
            Text(label).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta).frame(width: 52, alignment: .leading)
            content()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
    }
}

// MARK: Imports

private struct LedgerImportsCard: View {
    let draft: LedgerOnboardingDraft
    let onSubmit: (LedgerOnboardingCardAnswer) -> Void

    @State private var channels: Set<String> = []
    @State private var seeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LedgerCardTitle(title: String(localized: "平时导入哪些账单"),
                            detail: String(localized: "选了的会先备好导入规则，到时把账单文件发给助手就行。"))
            LedgerSetupFlow(spacing: 6) {
                ForEach(LedgerOnboardingDraft.channels, id: \.self) { channel in
                    LedgerToggleChip(title: LedgerOnboardingDraft.channelTitle(channel), on: channels.contains(channel)) {
                        if channels.contains(channel) { channels.remove(channel) } else { channels.insert(channel) }
                    }
                }
            }
            LedgerCardFooter(hint: channels.isEmpty ? String(localized: "不选就是都手动记") : String(localized: "已选 \(channels.count) 项")) {
                Button("好了") { onSubmit(.imports(LedgerOnboardingDraft.channels.filter(channels.contains))) }
                    .buttonStyle(.balanced(.primary))
                    .fixedSize()
                    .accessibilityIdentifier("ai-onboarding-card-done")
            }
        }
        .ledgerCard(padding: 12)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            channels = Set(draft.importChannels)
        }
    }
}
