import Foundation

enum ImportClassificationContext {
    static func supports(_ entry: LedgerImportEntry) -> Bool {
        entry.postings.count == 2 && entry.categoryAccount != entry.fundingAccount
            && entry.postings.filter { $0.account == entry.categoryAccount }.count == 1
            && entry.postings.filter { $0.account == entry.fundingAccount }.count == 1
            && entry.postings.allSatisfy {
                $0.currency == entry.currency && $0.priceKind == nil && $0.priceAmount == nil
                    && $0.priceCurrency == nil && decimal($0.amount) != nil
            }
            && entry.amount.isFinite
    }

    static func fundingAmount(_ entry: LedgerImportEntry) -> Decimal? {
        entry.postings.first { $0.account == entry.fundingAccount }.flatMap { decimal($0.amount) }
    }

    static func request(for entry: LedgerImportEntry, accounts: [LedgerAccount], history: [LedgerTransaction]) -> ImportClassificationRequest? {
        guard supports(entry), LedgerDateRange.parse(entry.date) != nil else { return nil }
        let options = accounts.filter {
            ($0.active || $0.closeDate != nil)
                && ["Expenses:", "Income:", "Assets:", "Liabilities:"].contains(where: $0.account.hasPrefix)
                && $0.openDate <= entry.date && ($0.closeDate == nil || $0.closeDate! > entry.date)
                && ($0.currency.isEmpty || $0.currency == entry.currency)
        }.sorted { $0.account < $1.account }
        guard !options.isEmpty, options.count <= 254, options.contains(where: { ImportClassificationRequest.isFunding($0.account) }) else { return nil }
        let related = relatedHistory(for: entry, history: history)
        let examples = related.map { transaction in
            let roles = historyRoles(transaction)
            return ImportClassificationRequest.Example(
                date: transaction.date, payee: clipped(transaction.payee), narration: clipped(transaction.narration),
                method: clipped(transaction.metadata?["method"]?.stringValue ?? ""),
                cardLast4: lastFour(transaction.metadata?["cardLast4"]?.stringValue ?? ""),
                accounts: Array(Set(transaction.postings.map(\.account))).sorted(),
                fundingAccount: roles?.funding, categoryAccount: roles?.category, tags: safeTags(transaction.tags ?? [])
            )
        }
        let funds = options.filter { ImportClassificationRequest.isFunding($0.account) }
        return ImportClassificationRequest(
            date: entry.date, payee: clipped(entry.payee), narration: clipped(entry.narration), method: clipped(entry.method ?? ""),
            cardLast4: lastFour(entry.metadata["cardLast4"] ?? ""), provider: provider(entry.source),
            transactionType: clipped(entry.transactionType ?? entry.type ?? ""), amount: entry.amount,
            currency: entry.currency, fundingAccount: entry.fundingAccount,
            fundingAmount: entry.postings.first(where: { $0.account == entry.fundingAccount })!.amount,
            currentCategory: entry.categoryAccount,
            accounts: options.map { .init(account: $0.account, label: clipped($0.alias ?? $0.label)) },
            fundingHint: fundingHint(entry: entry, accounts: funds, history: history),
            tagCandidates: [], history: examples
        )
    }

    static func relatedHistory(for entry: LedgerImportEntry, history: [LedgerTransaction]) -> [LedgerTransaction] {
        let merchant = normalized(entry.payee)
        let words = bigrams(entry.payee + " " + entry.narration)
        return history.compactMap { transaction -> (LedgerTransaction, Double)? in
            guard transaction.date <= entry.date, transaction.postings.count == 2 else { return nil }
            let other = bigrams(transaction.payee + " " + transaction.narration)
            let similarity = Double(words.intersection(other).count) / Double(max(1, words.union(other).count))
            let exactMerchant = !merchant.isEmpty && merchant == normalized(transaction.payee)
            let payment = samePayment(entry, transaction)
            guard exactMerchant || payment || similarity >= 0.2 else { return nil }
            return (transaction, similarity + (exactMerchant ? 2 : 0) + (payment ? 1 : 0))
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.date != $1.0.date { return $0.0.date > $1.0.date }
            return $0.0.id < $1.0.id
        }.prefix(5).map(\.0)
    }

    /// Card evidence and an unambiguous established payment mapping outrank the
    /// model. Ambiguous payment channels never become hard account mappings.
    static func fundingHint(entry: LedgerImportEntry, accounts: [LedgerAccount], history: [LedgerTransaction]) -> ImportClassificationRequest.FundingHint? {
        let tail = lastFour(entry.metadata["cardLast4"] ?? "")
        let method = normalized(entry.method ?? "")
        let methodTails = fourDigitTokens(entry.method ?? "")
        let tails = tail.isEmpty ? methodTails : [tail]
        if tails.count == 1, let card = tails.first {
            let matches = accounts.filter { fourDigitTokens($0.account + " " + ($0.alias ?? "") + " " + $0.label).contains(card) }
            if matches.count == 1, matchesPaymentIdentity(entry, account: matches[0], requireKnownMethod: true) {
                return .init(account: matches[0].account, reason: "卡尾号与支付身份唯一匹配")
            }
            // A repeated tail or a missing account needs model/user review.
            return nil
        }
        guard !method.isEmpty, !genericMethods.contains(method) else { return nil }
        let named = accounts.filter { account in
            let labels = [account.alias, account.label].compactMap { $0 }.map(normalized)
            return labels.contains { label in
                label.count >= 2 && !genericMethods.contains(label)
                    && (method == label || (label.count >= 4 && method.contains(label)))
            }
        }
        if named.count == 1, matchesPaymentIdentity(entry, account: named[0]) {
            return .init(account: named[0].account, reason: "支付方式与账户名称唯一匹配")
        }
        let matched = history.filter { $0.date <= entry.date && samePayment(entry, $0) }
        let mapped = matched.compactMap { historyRoles($0)?.funding }
        let unique = Set(mapped)
        guard mapped.count >= 3, unique.count == 1, let account = unique.first,
              let candidate = accounts.first(where: { $0.account == account }),
              matchesPaymentIdentity(entry, account: candidate) else { return nil }
        return .init(account: account, reason: "相同支付方式的已确认历史一致")
    }

    /// A suffix is only part of a card identity. Reuse the institution catalog
    /// and require affirmative issuer evidence whenever the statement has it.
    private static func matchesPaymentIdentity(_ entry: LedgerImportEntry, account: LedgerAccount,
                                               requireKnownMethod: Bool = false) -> Bool {
        let label = account.account + " " + (account.alias ?? "") + " " + account.label
        return matchesPaymentIdentity(method: entry.method ?? "", source: entry.source, account: account.account,
                                      label: label, cardLast4: entry.metadata["cardLast4"] ?? "",
                                      requireKnownMethod: requireKnownMethod)
    }

    static func fundingCompatible(_ account: String, input: ImportClassificationRequest) -> Bool {
        guard let candidate = input.fundingAccounts.first(where: { $0.account == account }) else { return false }
        return matchesPaymentIdentity(method: input.method, source: input.provider, account: account,
                                      label: account + " " + candidate.label, cardLast4: input.cardLast4)
    }

    private static func matchesPaymentIdentity(method rawMethod: String, source: String?, account: String,
                                               label: String, cardLast4: String, requireKnownMethod: Bool = false) -> Bool {
        let method = normalized(rawMethod)
        var tails = fourDigitTokens(rawMethod)
        let explicitTail = lastFour(cardLast4)
        if !explicitTail.isEmpty { tails.insert(explicitTail) }
        let accountTails = fourDigitTokens(label)
        if tails.count > 1 { return false }
        if !tails.isEmpty && !accountTails.isEmpty && tails != accountTails { return false }
        let credit = method.contains("信用卡") || method.contains("credit") || source == "ccb-credit"
        let debit = method.contains("储蓄卡") || method.contains("借记卡") || method.contains("debit")
        if credit && !account.hasPrefix("Liabilities:") { return false }
        if debit && !account.hasPrefix("Assets:") { return false }
        func codes(in text: String) -> Set<String> {
            let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let name = normalized(text)
            return Set(AccountPresets.presets.filter { $0.category == .bank }.compactMap { bank in
                let fullName = normalized(bank.name.components(separatedBy: "(")[0])
                let shortName = fullName.hasPrefix("中国") && fullName.count > 4 ? String(fullName.dropFirst(2)) : fullName
                return words.contains(bank.code.lowercased()) || name.contains(shortName) ? bank.code : nil
            })
        }
        var issuers = codes(in: rawMethod)
        if source == "ccb-credit" { issuers.insert("CCB") }
        if !issuers.isEmpty {
            return issuers.count == 1 && codes(in: label) == issuers
        }
        if requireKnownMethod {
            let withoutTail = method.filter { !$0.isNumber }
            return withoutTail.isEmpty || genericMethods.contains(withoutTail)
                || ["借记卡", "debitcard", "creditcard"].contains(withoutTail)
                || normalized(label).contains(method)
        }
        return true
    }

    static func autofilled(_ entry: LedgerImportEntry, suggestion: ImportClassificationSuggestion,
                           input: ImportClassificationRequest) -> LedgerImportEntry {
        let funding = suggestion.funding.isConfident && fundingCompatible(suggestion.funding.value, input: input)
            ? suggestion.funding.value : entry.fundingAccount
        let category = suggestion.category.isConfident && suggestion.nature.isConfident
            && suggestion.compatible(category: suggestion.category.value, funding: funding, entry: entry)
            ? suggestion.category.value : entry.categoryAccount
        let tags = (try? LedgerTagRules.validating((entry.tags ?? []) + suggestion.suggestedTags)) ?? entry.tags ?? []
        return applying(category: category, funding: funding, tags: tags, to: entry,
                        allowed: input.accounts.map(\.account)) ?? entry
    }

    static func applying(category: String, funding: String, tags: [String]? = nil,
                         to entry: LedgerImportEntry, allowed: [String]) -> LedgerImportEntry? {
        guard supports(entry), allowed.contains(category) || category == entry.categoryAccount,
              allowed.contains(funding) || funding == entry.fundingAccount, category != funding,
              ImportClassificationRequest.isFunding(funding) else { return nil }
        guard let checkedTags = try? LedgerTagRules.validating(tags ?? entry.tags ?? []) else { return nil }
        // Simultaneous role replacement supports transfer endpoints swapping
        // while retaining exact decimal strings, polarity and source evidence.
        return LedgerImportEntry(
            id: entry.id, date: entry.date, flag: entry.flag, payee: entry.payee, narration: entry.narration,
            source: entry.source, orderID: entry.orderID, merchantID: entry.merchantID, payTime: entry.payTime,
            method: entry.method, transactionType: entry.transactionType, status: entry.status, type: entry.type,
            categoryAccount: category, fundingAccount: funding, amount: entry.amount, currency: entry.currency,
            tags: entry.tags == nil && checkedTags.isEmpty ? nil : checkedTags, metadata: entry.metadata,
            postings: entry.postings.map {
                $0.replacing(account: $0.account == entry.categoryAccount ? category : funding)
            }
        )
    }

    private static let genericMethods: Set<String> = ["微信支付", "支付宝", "银行卡", "信用卡", "储蓄卡", "快捷支付", "其他", "未知"]
    private static func samePayment(_ entry: LedgerImportEntry, _ transaction: LedgerTransaction) -> Bool {
        let method = normalized(entry.method ?? "")
        let otherMethod = normalized(transaction.metadata?["method"]?.stringValue ?? "")
        let tail = lastFour(entry.metadata["cardLast4"] ?? "")
        let otherTail = lastFour(transaction.metadata?["cardLast4"]?.stringValue ?? "")
        guard provider(entry.source) == provider(transaction.metadata?["source"]?.stringValue),
              method == otherMethod, tail == otherTail else { return false }
        return !tail.isEmpty || (!method.isEmpty && !genericMethods.contains(method))
    }
    private static func historyRoles(_ transaction: LedgerTransaction) -> (funding: String, category: String)? {
        guard transaction.postings.count == 2,
              let category = transaction.postings.first(where: { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") }),
              let funding = transaction.postings.first(where: { ImportClassificationRequest.isFunding($0.account) }),
              category.account != funding.account else { return nil }
        return (funding.account, category.account)
    }
    private static func provider(_ value: String?) -> String {
        guard let value, LedgerImportProvider.provider(value) != nil else { return "" }
        return value
    }
    private static func safeTags(_ tags: [String]) -> [String] {
        Array(Set(tags.compactMap { (try? LedgerTagRules.validating([$0]))?.first })).sorted().prefix(24).map { $0 }
    }
    private static func fourDigitTokens(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isNumber }).filter { $0.count == 4 }.map(String.init))
    }
    private static func lastFour(_ value: String) -> String {
        value.count == 4 && value.utf8.allSatisfy { (48...57).contains($0) } ? value : ""
    }
    private static func decimal(_ raw: String) -> Decimal? {
        guard let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }
    private static func clipped(_ value: String) -> String { String(value.prefix(200)) }
    private static func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
    private static func bigrams(_ value: String) -> Set<String> {
        let characters = Array(normalized(String(value.prefix(400))))
        guard characters.count > 1 else { return Set(characters.map(String.init)) }
        return Set(zip(characters, characters.dropFirst()).map { String([$0, $1]) })
    }
}
