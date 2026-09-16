import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var session: LedgerSession
    @Binding var overflowDestination: LedgerDestination?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SettingsView(isRoot: false)
                } label: {
                    HStack(spacing: LedgerSpacing.md) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.gray.opacity(0.14))
                                .frame(width: 36, height: 36)
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.gray)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("设置")
                                .font(.body.weight(.medium))
                                .foregroundStyle(LedgerPalette.ink)
                            Text("\(session.localLedgerName) · 本地")
                                .font(.footnote)
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("more-settings")
            }
            let remaining = [LedgerDestination.overview, .transactions, .accounts]
                .filter { !session.compactTabDestinations.contains($0) }
            if !remaining.isEmpty {
                Section("账本") {
                    ForEach(remaining) { destination in
                        MoreDestinationButton(destination: destination, detail: destination.title)
                    }
                }
            }
            Section("财务分析") {
                ForEach(LedgerAnalysisKind.allCases, id: \.self) { kind in
                    MoreDestinationButton(
                        destination: destination(for: kind),
                        detail: kind.detail,
                        accessibilityIdentifier: "more-analysis-\(kind.rawValue)"
                    )
                }
            }
            Section("账本工具") {
                MoreDestinationButton(destination: .imports, detail: "账单导入与归档", accessibilityIdentifier: "more-imports")
                MoreDestinationButton(destination: .currencies, detail: "估值货币与汇率", accessibilityIdentifier: "more-currencies")
                MoreDestinationButton(destination: .query, detail: "查询与历史", accessibilityIdentifier: "more-query")
            }
        }
        .ledgerReadingList()
        .font(.subheadline)
        .ledgerNavigation("更多")
        .navigationDestination(item: $overflowDestination) { destination in
            LedgerDestinationView(destination: destination)
        }
        .onChange(of: session.primaryDestinationID, initial: true) { _, _ in restoreOverflowRoute() }
        .onChange(of: overflowDestination) { _, destination in
            guard destination == nil else { return }
            let current = LedgerDestination.stored(session.primaryDestinationID)
            if current.isCompactOverflow(in: session.compactTabDestinations) {
                session.primaryDestinationID = LedgerDestination.settings.rawValue
            }
        }
    }

    private func restoreOverflowRoute() {
        let destination = LedgerDestination.stored(session.primaryDestinationID)
        guard destination.isCompactOverflow(in: session.compactTabDestinations) else { return }
        overflowDestination = destination
    }

    private func destination(for kind: LedgerAnalysisKind) -> LedgerDestination {
        switch kind {
        case .assets: .assets
        case .incomeExpense: .incomeExpense
        case .investments: .investments
        }
    }
}

private struct MoreDestinationButton: View {
    @EnvironmentObject private var session: LedgerSession

    let destination: LedgerDestination
    let detail: String
    var accessibilityIdentifier: String? = nil

    private var destinationColor: Color {
        switch destination {
        case .overview: Color(red: 0.16, green: 0.54, blue: 0.95)
        case .transactions: Color(red: 0.96, green: 0.55, blue: 0.18)
        case .accounts: Color(red: 0.12, green: 0.68, blue: 0.36)
        case .assets: Color(red: 0.16, green: 0.54, blue: 0.95)
        case .incomeExpense: Color(red: 0.10, green: 0.72, blue: 0.44)
        case .investments: Color(red: 0.65, green: 0.36, blue: 0.88)
        case .imports: Color(red: 0.96, green: 0.55, blue: 0.18)
        case .currencies: Color(red: 0.12, green: 0.66, blue: 0.72)
        case .query: Color(red: 0.35, green: 0.45, blue: 0.88)
        case .settings: Color.gray
        case .search: Color(red: 0.08, green: 0.68, blue: 0.55)
        }
    }

    var body: some View {
        Button {
            session.primaryDestinationID = destination.rawValue
        } label: {
            MoreNavigationRow(icon: destination.systemImage, color: destinationColor, title: destination.title, detail: detail)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier ?? "more-\(destination.rawValue)")
    }
}

private struct MoreNavigationRow: View {
    let icon: String
    var color: Color = LedgerPalette.cobalt
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: LedgerSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(LedgerPalette.ink)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(LedgerPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(.caption2, design: .default, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
