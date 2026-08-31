import Foundation

struct LedgerPrice: Codable, Equatable, Sendable {
    let date: String
    let currency: String
    let amount: Int
    let quoteCurrency: String
}

enum CurrencyRateSource: String, Equatable, Sendable {
    case base
    case direct
    case inverse
    case bridge

    var title: String {
        switch self {
        case .base: "基准货币"
        case .direct: "直接价格"
        case .inverse: "反向价格"
        case .bridge: "交叉汇率"
        }
    }
}

struct CurrencyRateInfo: Equatable, Sendable {
    let rate: Double
    let date: String?
    let source: CurrencyRateSource
}

struct CurrencyRatePoint: Equatable, Identifiable, Sendable {
    let date: String
    let rate: Double

    var id: String { date }
}

struct CurrencyRateRow: Equatable, Identifiable, Sendable {
    let currency: String
    let rate: CurrencyRateInfo?
    let history: [CurrencyRatePoint]

    var id: String { currency }

    var recentChange: Double? {
        guard history.count >= 2,
              let previous = history.dropLast().last?.rate,
              let current = history.last?.rate,
              previous != 0 else { return nil }
        return (current - previous) / previous
    }
}

struct CurrencyAnalysisInput: Equatable, Sendable {
    let commodities: [String]
    let prices: [LedgerPrice]
    let balanceCurrencies: [String]
    let accountCurrencies: [String]
    let valuationCurrency: String

    init(ledger: LedgerBootstrap) {
        commodities = ledger.commodities
        prices = ledger.prices
        balanceCurrencies = ledger.accountBalances.map(\.currency)
        accountCurrencies = ledger.accounts.map(\.currency)
        valuationCurrency = ledger.valuationCurrency
    }
}

struct CurrencyAnalysisSnapshot: Equatable, Sendable {
    let input: CurrencyAnalysisInput
    let currencies: [String]
    let rows: [CurrencyRateRow]
    let latestDate: String?
    let missingCount: Int
}

enum CurrencyAnalysis {
    static func snapshot(input: CurrencyAnalysisInput) -> CurrencyAnalysisSnapshot {
        let currencies = currencyUniverse(
            commodities: input.commodities,
            prices: input.prices,
            balanceCurrencies: input.balanceCurrencies,
            accountCurrencies: input.accountCurrencies,
            valuationCurrency: input.valuationCurrency
        )
        let rows = rows(
            currencies: currencies,
            valuationCurrency: input.valuationCurrency,
            prices: input.prices
        )
        return CurrencyAnalysisSnapshot(
            input: input,
            currencies: currencies,
            rows: rows,
            latestDate: input.prices.map(\.date).max(),
            missingCount: rows.filter {
                $0.currency != input.valuationCurrency && $0.rate == nil
            }.count
        )
    }

    static func currencyUniverse(
        commodities: [String],
        prices: [LedgerPrice],
        balances: [AccountBalance],
        accounts: [LedgerAccount],
        valuationCurrency: String
    ) -> [String] {
        currencyUniverse(
            commodities: commodities,
            prices: prices,
            balanceCurrencies: balances.map(\.currency),
            accountCurrencies: accounts.map(\.currency),
            valuationCurrency: valuationCurrency
        )
    }

    private static func currencyUniverse(
        commodities: [String],
        prices: [LedgerPrice],
        balanceCurrencies: [String],
        accountCurrencies: [String],
        valuationCurrency: String
    ) -> [String] {
        let monetary = monetaryCommoditySet(prices: prices, valuationCurrency: valuationCurrency)
        var seen = Set([valuationCurrency, "CNY"])
        for commodity in commodities where monetary.contains(commodity) {
            seen.insert(commodity)
        }
        for price in prices {
            if monetary.contains(price.currency) { seen.insert(price.currency) }
            if monetary.contains(price.quoteCurrency) { seen.insert(price.quoteCurrency) }
        }
        for currency in balanceCurrencies where monetary.contains(currency) {
            seen.insert(currency)
        }
        for currency in accountCurrencies where monetary.contains(currency) {
            seen.insert(currency)
        }
        return seen.sorted { lhs, rhs in
            if lhs == rhs { return false }
            if lhs == valuationCurrency { return true }
            if rhs == valuationCurrency { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    static func rows(
        currencies: [String],
        valuationCurrency: String,
        prices: [LedgerPrice]
    ) -> [CurrencyRateRow] {
        let index = PriceIndex(prices: prices)
        return currencies.map { currency in
            CurrencyRateRow(
                currency: currency,
                rate: latestRate(currency: currency, targetCurrency: valuationCurrency, index: index),
                history: rateHistory(currency: currency, targetCurrency: valuationCurrency, index: index)
            )
        }
    }

    static func latestRate(
        currency: String,
        targetCurrency: String,
        prices: [LedgerPrice]
    ) -> CurrencyRateInfo? {
        latestRate(
            currency: currency,
            targetCurrency: targetCurrency,
            index: PriceIndex(prices: prices)
        )
    }

    private static func latestRate(
        currency: String,
        targetCurrency: String,
        index: PriceIndex
    ) -> CurrencyRateInfo? {
        if currency == targetCurrency {
            return CurrencyRateInfo(rate: 1, date: nil, source: .base)
        }
        if let pair = pairRate(currency: currency, targetCurrency: targetCurrency, index: index) {
            return pair
        }
        guard currency != "CNY", targetCurrency != "CNY",
              let currencyToCNY = pairRate(currency: currency, targetCurrency: "CNY", index: index),
              let targetToCNY = pairRate(currency: targetCurrency, targetCurrency: "CNY", index: index),
              targetToCNY.rate != 0 else { return nil }
        return CurrencyRateInfo(
            rate: currencyToCNY.rate / targetToCNY.rate,
            date: latestDate(currencyToCNY.date, targetToCNY.date),
            source: .bridge
        )
    }

    static func rateHistory(
        currency: String,
        targetCurrency: String,
        prices: [LedgerPrice]
    ) -> [CurrencyRatePoint] {
        rateHistory(
            currency: currency,
            targetCurrency: targetCurrency,
            index: PriceIndex(prices: prices)
        )
    }

    private static func rateHistory(
        currency: String,
        targetCurrency: String,
        index: PriceIndex
    ) -> [CurrencyRatePoint] {
        if currency == targetCurrency {
            let dates = Array(index.allDates.suffix(90))
            return (dates.isEmpty ? ["当前"] : dates).map { CurrencyRatePoint(date: $0, rate: 1) }
        }
        let dates = Array(index.allDates.suffix(90))
        return dates.compactMap { date in
            rateAtDate(currency: currency, targetCurrency: targetCurrency, index: index, date: date)
                .map { CurrencyRatePoint(date: date, rate: $0.rate) }
        }
    }

    private static func monetaryCommoditySet(prices: [LedgerPrice], valuationCurrency: String) -> Set<String> {
        var seen = Set(["CNY", "USD", "HKD", "GBP", "EUR", "JPY", valuationCurrency])
        for price in prices {
            if !price.quoteCurrency.isEmpty { seen.insert(price.quoteCurrency) }
            if price.quoteCurrency == "CNY" || price.currency == "CNY" {
                seen.insert(price.currency)
            }
        }
        return seen
    }

    private static func rateAtDate(
        currency: String,
        targetCurrency: String,
        index: PriceIndex,
        date: String
    ) -> CurrencyRateInfo? {
        if let pair = pairRateAtDate(currency: currency, targetCurrency: targetCurrency, index: index, date: date) {
            return pair
        }
        guard currency != "CNY", targetCurrency != "CNY",
              let currencyToCNY = pairRateAtDate(currency: currency, targetCurrency: "CNY", index: index, date: date),
              let targetToCNY = pairRateAtDate(currency: targetCurrency, targetCurrency: "CNY", index: index, date: date),
              targetToCNY.rate != 0 else { return nil }
        return CurrencyRateInfo(
            rate: currencyToCNY.rate / targetToCNY.rate,
            date: latestDate(currencyToCNY.date, targetToCNY.date),
            source: .bridge
        )
    }

    private static func pairRate(
        currency: String,
        targetCurrency: String,
        index: PriceIndex
    ) -> CurrencyRateInfo? {
        if let direct = index.latest(currency: currency, quoteCurrency: targetCurrency) {
            return CurrencyRateInfo(rate: Double(direct.amount) / 100, date: direct.date, source: .direct)
        }
        guard let inverse = index.latest(currency: targetCurrency, quoteCurrency: currency),
              inverse.amount != 0 else { return nil }
        return CurrencyRateInfo(rate: 100 / Double(inverse.amount), date: inverse.date, source: .inverse)
    }

    private static func pairRateAtDate(
        currency: String,
        targetCurrency: String,
        index: PriceIndex,
        date: String
    ) -> CurrencyRateInfo? {
        if let direct = index.latestAtOrBefore(
            currency: currency,
            quoteCurrency: targetCurrency,
            date: date
        ) {
            return CurrencyRateInfo(rate: Double(direct.amount) / 100, date: direct.date, source: .direct)
        }
        guard let inverse = index.latestAtOrBefore(
            currency: targetCurrency,
            quoteCurrency: currency,
            date: date
        ), inverse.amount != 0 else { return nil }
        return CurrencyRateInfo(rate: 100 / Double(inverse.amount), date: inverse.date, source: .inverse)
    }

    private struct PairKey: Hashable, Sendable {
        let currency: String
        let quoteCurrency: String
    }

    private struct PriceIndex: Sendable {
        let series: [PairKey: [LedgerPrice]]
        let allDates: [String]

        init(prices: [LedgerPrice]) {
            var byPairAndDate: [PairKey: [String: LedgerPrice]] = [:]
            for price in prices {
                let pair = PairKey(currency: price.currency, quoteCurrency: price.quoteCurrency)
                byPairAndDate[pair, default: [:]][price.date] = price
            }
            series = byPairAndDate.mapValues { pricesByDate in
                pricesByDate.values.sorted { $0.date < $1.date }
            }
            allDates = Array(Set(prices.map(\.date))).sorted()
        }

        func latest(currency: String, quoteCurrency: String) -> LedgerPrice? {
            series[PairKey(currency: currency, quoteCurrency: quoteCurrency)]?.last
        }

        func latestAtOrBefore(
            currency: String,
            quoteCurrency: String,
            date: String
        ) -> LedgerPrice? {
            guard let prices = series[PairKey(currency: currency, quoteCurrency: quoteCurrency)] else {
                return nil
            }
            var lowerBound = 0
            var upperBound = prices.count
            while lowerBound < upperBound {
                let middle = (lowerBound + upperBound) / 2
                if prices[middle].date <= date {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }
            guard lowerBound > 0 else { return nil }
            return prices[lowerBound - 1]
        }
    }

    private static func latestDate(_ lhs: String?, _ rhs: String?) -> String? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return max(lhs, rhs)
    }
}
