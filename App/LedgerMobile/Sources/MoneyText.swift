import Foundation

/// Money formatting for every visible amount.
///
/// `NumberFormatter` construction is roughly 18× more expensive than a format
/// call, and these helpers sit on the transaction-list and analysis hot paths.
/// Every formatter is therefore built once per configuration and reused. The
/// caches are bounded and guarded because SwiftUI may format from more than one
/// thread during layout and snapshot work.
enum MoneyText {
    enum DisplayMode {
        case full
        case adaptive
        case compact
    }

    /// Formatter caches. `FormatterStore` owns the mutable state so the Swift 6
    /// concurrency checker sees a single immutable reference.
    private static let store = FormatterStore()

    private final class FormatterStore: @unchecked Sendable {
        private let lock = NSLock()
        private var currencyFormatters: [CurrencyFormatterKey: NumberFormatter] = [:]
        private var compactFormatters: [CompactFormatterKey: NumberFormatter] = [:]
        private var symbolFormatters: [String: String] = [:]

        func currency(for key: CurrencyFormatterKey, build: () -> NumberFormatter) -> NumberFormatter {
            lock.lock()
            if let cached = currencyFormatters[key] { lock.unlock(); return cached }
            lock.unlock()

            let formatter = build()

            lock.lock()
            defer { lock.unlock() }
            if let existing = currencyFormatters[key] { return existing }
            if currencyFormatters.count >= MoneyText.capacity { currencyFormatters.removeAll(keepingCapacity: true) }
            currencyFormatters[key] = formatter
            return formatter
        }

        func compact(maximumFractionDigits: Int, build: () -> NumberFormatter) -> NumberFormatter {
            let key = CompactFormatterKey(maximumFractionDigits: maximumFractionDigits)
            lock.lock()
            if let cached = compactFormatters[key] { lock.unlock(); return cached }
            lock.unlock()

            let formatter = build()

            lock.lock()
            defer { lock.unlock() }
            if let existing = compactFormatters[key] { return existing }
            if compactFormatters.count >= MoneyText.capacity { compactFormatters.removeAll(keepingCapacity: true) }
            compactFormatters[key] = formatter
            return formatter
        }

        func symbol(for currency: String, build: () -> String) -> String {
            lock.lock()
            if let cached = symbolFormatters[currency] { lock.unlock(); return cached }
            lock.unlock()

            let resolved = build()

            lock.lock()
            defer { lock.unlock() }
            if symbolFormatters.count >= MoneyText.capacity { symbolFormatters.removeAll(keepingCapacity: true) }
            symbolFormatters[currency] = resolved
            return resolved
        }
    }

    /// Currency formatting configuration. Every field that changes the
    /// formatter's output must appear here, otherwise a cached formatter would
    /// be reused for a different rendering.
    private struct CurrencyFormatterKey: Hashable {
        let currencyCode: String
        let showsCurrency: Bool
        let showSign: Bool
        let maximumFractionDigits: Int?
    }

    private struct CompactFormatterKey: Hashable {
        let maximumFractionDigits: Int
    }

    /// Keeps the caches small. A ledger has a handful of currencies, so this is
    /// only a guard against pathological input.
    private static let capacity = 64

    static func format(minorUnits: Int, currency: String, showSign: Bool = false, showsCurrency: Bool = true) -> String {
        let currencyCode = currency.isEmpty ? "CNY" : currency
        let key = CurrencyFormatterKey(
            currencyCode: currencyCode,
            showsCurrency: showsCurrency,
            showSign: showSign,
            maximumFractionDigits: nil
        )
        let formatter = currencyFormatter(for: key)
        let value = NSDecimalNumber(value: Double(minorUnits) / 100)
        return formatter.string(from: value)?.trimmingCharacters(in: .whitespaces) ?? "\(currency) \(value)"
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

        let formatter = compactFormatter(maximumFractionDigits: 1)
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

        let maximumFractionDigits = abs(Double(minorUnits)) < 10_000 ? 2 : 0
        let key = CurrencyFormatterKey(
            currencyCode: currencyCode,
            showsCurrency: true,
            showSign: false,
            maximumFractionDigits: maximumFractionDigits
        )
        let formatter = currencyFormatter(for: key)
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

        return store.symbol(for: currency) {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency
            formatter.locale = Locale(identifier: "zh_CN")
            let symbol = formatter.currencySymbol ?? currency
            return symbol == currency ? "\(currency) " : symbol
        }
    }

    // MARK: - Formatter caches

    private static func currencyFormatter(for key: CurrencyFormatterKey) -> NumberFormatter {
        store.currency(for: key) {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = key.currencyCode
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.usesGroupingSeparator = true
            if !key.showsCurrency { formatter.currencySymbol = "" }
            if key.showSign {
                formatter.positivePrefix = "+" + (formatter.positivePrefix ?? "")
            }
            if let maximumFractionDigits = key.maximumFractionDigits {
                formatter.minimumFractionDigits = 0
                formatter.maximumFractionDigits = maximumFractionDigits
            }
            return formatter
        }
    }

    private static func compactFormatter(maximumFractionDigits: Int) -> NumberFormatter {
        store.compact(maximumFractionDigits: maximumFractionDigits) {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = maximumFractionDigits
            formatter.roundingMode = .halfUp
            return formatter
        }
    }
}
