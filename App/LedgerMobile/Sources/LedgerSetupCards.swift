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

// MARK: Balances

private struct LedgerBalancesCard: View {
    let draft: LedgerOnboardingDraft
    let onSubmit: (LedgerOnboardingCardAnswer) -> Void

    private enum Start: Hashable { case today, monthStart, custom }

    @State private var amounts: [String: String] = [:]
    @State private var start: Start = .today
    @State private var date = Date()
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
                            detail: String(localized: "填当前余额，信用卡和贷款填欠多少。不确定的先空着，以后对账时再补。"))
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
            LedgerCardFooter(hint: invalid.isEmpty ? String(localized: "金额只填数字") : String(localized: "有金额看不懂")) {
                Button("先不填") { onSubmit(.balances([:], startDate: startDate)) }
                    .buttonStyle(.balanced(.quiet))
                    .fixedSize()
                Button("好了") { onSubmit(.balances(amounts, startDate: startDate)) }
                    .buttonStyle(.balanced(.primary))
                    .fixedSize()
                    .disabled(!invalid.isEmpty)
                    .accessibilityIdentifier("ai-onboarding-card-done")
            }
        }
        .ledgerCard(padding: 12)
        .onAppear {
            guard amounts.isEmpty else { return }
            amounts = Dictionary(uniqueKeysWithValues: draft.accounts.map { ($0.account, $0.openingBalance) })
            if !draft.startDate.isEmpty, let parsed = Self.parse(draft.startDate) {
                start = .custom
                date = parsed
            }
        }
    }

    private func row(_ account: LedgerOnboardingDraft.Account) -> some View {
        let currency = account.currency.isEmpty ? draft.currency : account.currency
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                Text(LedgerOnboardingDraft.kindTitle(account.kind)).balancedFont(size: 11.5).foregroundStyle(BalancedPalette.meta)
            }
            Spacer(minLength: 8)
            if account.isLiability {
                Text("欠").balancedFont(size: 13).foregroundStyle(BalancedPalette.expense)
            }
            TextField("0", text: Binding(get: { amounts[account.account] ?? "" }, set: { amounts[account.account] = $0 }))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .balancedMono(size: 15)
                .foregroundStyle(invalid.contains(account.account) ? BalancedPalette.expense : BalancedPalette.ink)
                .focused($focused, equals: account.account)
                .frame(maxWidth: 120)
                .accessibilityLabel(account.isLiability ? String(localized: "\(account.name) 欠款") : String(localized: "\(account.name) 余额"))
            Text(currency).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
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

private struct LedgerCategoriesCard: View {
    let card: LedgerOnboardingCard
    let draft: LedgerOnboardingDraft
    let onSubmit: (LedgerOnboardingCardAnswer) -> Void

    @State private var kept: Set<String> = []
    @State private var added: Set<LedgerOnboardingCard.Suggestion> = []
    @State private var seeded = false

    private var incomeCount: Int {
        draft.incomeCategories.filter { kept.contains($0.account) }.count + added.filter(\.isIncome).count
    }

    private var expenseCount: Int {
        draft.expenseCategories.filter { kept.contains($0.account) }.count + added.filter { !$0.isIncome }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerCardTitle(title: String(localized: "分类"),
                            detail: String(localized: "点一下去掉不要的，虚线的是可以加上的。想要别的，直接在下面说。"))
            section(String(localized: "收入"), draft.incomeCategories, card.suggested.filter(\.isIncome))
            section(String(localized: "支出"), draft.expenseCategories, card.suggested.filter { !$0.isIncome })
            LedgerCardFooter(hint: incomeCount == 0 || expenseCount == 0
                             ? String(localized: "收入和支出各留至少一个")
                             : String(localized: "收入 \(incomeCount) · 支出 \(expenseCount)")) {
                Button("好了") {
                    let order = card.suggested.filter(added.contains)
                    onSubmit(.categories(kept: kept, added: order))
                }
                .buttonStyle(.balanced(.primary))
                .fixedSize()
                .disabled(incomeCount == 0 || expenseCount == 0)
                .accessibilityIdentifier("ai-onboarding-card-done")
            }
        }
        .ledgerCard(padding: 12)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            kept = Set((draft.incomeCategories + draft.expenseCategories).map(\.account))
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [LedgerOnboardingDraft.Category],
                         _ suggestions: [LedgerOnboardingCard.Suggestion]) -> some View {
        if !items.isEmpty || !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).padding(.horizontal, 4)
                LedgerSetupFlow(spacing: 6) {
                    ForEach(items) { item in
                        LedgerToggleChip(title: item.name, on: kept.contains(item.account)) {
                            if kept.contains(item.account) { kept.remove(item.account) } else { kept.insert(item.account) }
                        }
                    }
                    ForEach(suggestions) { item in
                        LedgerToggleChip(title: item.name, on: added.contains(item), adds: true) {
                            if added.contains(item) { added.remove(item) } else { added.insert(item) }
                        }
                    }
                }
            }
        }
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
                   detail: String(localized: "最简单。之后随时可以在设置里接 Git 或 iCloud 云盘。"), symbol: "iphone")
            option("git", title: String(localized: "同步到 Git 仓库"),
                   detail: String(localized: "准备一个空仓库，建好后自动推上去，电脑上也能用。"), symbol: "arrow.triangle.branch")
            if storage == "git" { gitFields }
            LedgerCardFooter(hint: storage == "git" ? String(localized: "令牌只存钥匙串，不进对话") : "") {
                Button("好了") {
                    onSubmit(storage == "git" ? .storage("git", remote: address ?? "") : .storage("device", remote: ""))
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
            }
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
