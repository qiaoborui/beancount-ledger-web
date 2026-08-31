import Foundation

enum MoneyText {
    enum DisplayMode {
        case full
        case adaptive
        case compact
    }

    static func format(minorUnits: Int, currency: String, showSign: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.isEmpty ? "CNY" : currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.usesGroupingSeparator = true
        if showSign {
            formatter.positivePrefix = "+" + (formatter.positivePrefix ?? "")
        }
        let value = NSDecimalNumber(value: Double(minorUnits) / 100)
        return formatter.string(from: value) ?? "\(currency) \(value)"
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

    private static func currencySymbol(for currency: String) -> String {
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
