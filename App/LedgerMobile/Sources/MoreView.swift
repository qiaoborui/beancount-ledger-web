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
                    Label("设置", systemImage: "gearshape")
                }
                .accessibilityIdentifier("more-settings")
            } footer: {
                Text(session.serverURL?.host ?? "Ledger")
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
        .listStyle(.insetGrouped)
        .ledgerNavigation("更多")
        .navigationDestination(item: $overflowDestination) { destination in
            LedgerDestinationView(destination: destination)
        }
        .onChange(of: session.primaryDestinationID, initial: true) { _, _ in restoreOverflowRoute() }
        .onChange(of: overflowDestination) { _, destination in
            guard destination == nil else { return }
            let current = LedgerDestination.stored(session.primaryDestinationID)
            if current != .settings, !session.compactTabDestinations.contains(current) {
                session.primaryDestinationID = LedgerDestination.settings.rawValue
            }
        }
    }

    private func restoreOverflowRoute() {
        let destination = LedgerDestination.stored(session.primaryDestinationID)
        guard destination != .settings, !session.compactTabDestinations.contains(destination) else { return }
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

    var body: some View {
        Button {
            session.primaryDestinationID = destination.rawValue
        } label: {
            MoreNavigationRow(icon: destination.systemImage, title: destination.title, detail: detail)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier ?? "more-\(destination.rawValue)")
    }
}

private struct MoreNavigationRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: LedgerSpacing.md) {
            Image(systemName: icon)
                .font(.system(.subheadline, design: .default, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
                .frame(width: 36, height: 36)
                .background(LedgerPalette.tag)
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
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
