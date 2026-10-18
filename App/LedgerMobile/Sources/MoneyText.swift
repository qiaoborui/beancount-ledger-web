import Foundation

enum MoneyText {
    enum DisplayMode {
        case full
        case adaptive
        case compact
    }

    /// Formatters are expensive to build (locale + currency tables). Creating one
    /// per formatted amount meant ~3 allocations per visible row on every scroll
    /// pass. Cache by the four properties that actually vary.
    private struct FormatterKey: Hashable {
        let currency: String
        let showsCurrency: Bool
        let showSign: Bool
    }

    private final class FormatterBox {
        let formatter: NumberFormatter
        init(formatter: NumberFormatter) { self.formatter = formatter }
    }

    private static let formatterLock = NSLock()
    nonisolated(unsafe) private static var formatterCache: [FormatterKey: FormatterBox] = [:]

    /// `NumberFormatter` is not safe for concurrent use, and `format` is called from
    /// renders, exports and tests. The lock both guards the cache and serialises the
    /// formatting call, so a cached formatter can never be entered twice at once.
    private static func currencyFormatter(currency: String, showsCurrency: Bool, showSign: Bool) -> NumberFormatter {
        let key = FormatterKey(currency: currency, showsCurrency: showsCurrency, showSign: showSign)
        if let cached = formatterCache[key] { return cached.formatter }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.usesGroupingSeparator = true
        if !showsCurrency { formatter.currencySymbol = "" }
        if showSign {
            formatter.positivePrefix = "+" + (formatter.positivePrefix ?? "")
        }
        // Cap growth so unusual currencies cannot leak formatters.
        if formatterCache.count >= 16 { formatterCache.removeAll(keepingCapacity: true) }
        formatterCache[key] = FormatterBox(formatter: formatter)
        return formatter
    }

    static func format(minorUnits: Int, currency: String, showSign: Bool = false, showsCurrency: Bool = true) -> String {
        let code = currency.isEmpty ? "CNY" : currency
        let value = NSDecimalNumber(value: Double(minorUnits) / 100)
        formatterLock.lock()
        defer { formatterLock.unlock() }
        let formatter = currencyFormatter(currency: code, showsCurrency: showsCurrency, showSign: showSign)
        return formatter.string(from: value)?.trimmingCharacters(in: .whitespaces) ?? "\(code) \(value)"
    }

    static func formatCompact(minorUnits: Int, currency: String, showSign: Bool = false) -> String {
        let currencyCode = currency.isEmpty ? "CNY" : currency
        let value = Double(minorUnits) / 100
        let absoluteValue = abs(value)
        let unit: (divisor: Double, suffix: String)?

        if currencyCode == "CNY" {
            if absoluteValue >= 100_000_000 {
                unit = (100_000_000, "亿")
            } else if absoluteValue >= 10_000 {
                unit = (10_000, "w")
            } else {
                unit = nil
            }
        } else if absoluteValue >= 1_000_000_000 {
            unit = (1_000_000_000, "B")
        } else if absoluteValue >= 1_000_000 {
            unit = (1_000_000, "M")
        } else if absoluteValue >= 1_000 {
            unit = (1_000, "k")
        } else {
            unit = nil
        }

        guard let unit else {
            return format(minorUnits: minorUnits, currency: currencyCode, showSign: showSign)
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.roundingMode = .halfUp
        let compactValue = absoluteValue / unit.divisor
        let number = formatter.string(from: NSNumber(value: compactValue)) ?? String(format: "%.1f", compactValue)
        let sign = value < 0 ? "-" : showSign ? "+" : ""
        return "\(sign)\(currencySymbol(for: currencyCode))\(number)\(unit.suffix)"
    }

    static func formatWidget(minorUnits: Int, currency: String) -> String {
        let currencyCode = currency.isEmpty ? "CNY" : currency
        let compact = formatCompact(minorUnits: minorUnits, currency: currencyCode)
        let full = format(minorUnits: minorUnits, currency: currencyCode)
        guard compact == full else { return compact }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = abs(Double(minorUnits)) < 10_000 ? 2 : 0
        return formatter.string(from: NSDecimalNumber(value: Double(minorUnits) / 100)) ?? full
    }

    static func magnitude(_ minorUnits: Int) -> Int {
        minorUnits == .min ? .max : abs(minorUnits)
    }

    static func currencySymbol(for currency: String) -> String {
        let commonSymbols = [
            "CNY": "¥",
            "USD": "$",
            "EUR": "€",
            "GBP": "£",
            "JPY": "¥",
            "HKD": "HK$",
        ]
        if let symbol = commonSymbols[currency] { return symbol }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "zh_CN")
        let symbol = formatter.currencySymbol ?? currency
        return symbol == currency ? "\(currency) " : symbol
    }
}
