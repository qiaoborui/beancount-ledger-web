import SwiftUI
import WidgetKit

struct ImportStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: LedgerWidgetSnapshot?
}

struct ImportStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> ImportStatusEntry {
        ImportStatusEntry(date: LedgerWidgetSnapshot.placeholder.updatedAt, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (ImportStatusEntry) -> Void) {
        completion(
            ImportStatusEntry(
                date: Date(),
                snapshot: context.isPreview ? .placeholder : LedgerWidgetSnapshotStore.shared.load()
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ImportStatusEntry>) -> Void) {
        let now = Date()
        completion(
            Timeline(
                entries: [ImportStatusEntry(date: now, snapshot: LedgerWidgetSnapshotStore.shared.load())],
                policy: .after(now.addingTimeInterval(30 * 60))
            )
        )
    }
}

struct ImportStatusWidget: Widget {
    let kind = "LedgerImportStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ImportStatusProvider()) { entry in
            ImportStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("导入状态")
        .description("查看各个渠道上次导入的账单覆盖日期。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct ImportStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ImportStatusEntry
    var familyOverride: WidgetFamily?

    init(entry: ImportStatusEntry, familyOverride: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
    }

    var body: some View {
        if let snapshot = entry.snapshot {
            Group {
                if (familyOverride ?? family) == .systemLarge {
                    large(snapshot.imports, updatedAt: snapshot.importsUpdatedAt)
                } else {
                    medium(snapshot.imports, updatedAt: snapshot.importsUpdatedAt)
                }
            }
            .widgetURL(URL(string: "ledger://overview"))
            .containerBackground(for: .widget) { LedgerWidgetColors.panel }
        } else {
            LedgerWidgetUnavailableView(
                title: "等待导入记录",
                detail: "打开 Ledger 并刷新一次",
                symbol: "tray.and.arrow.down"
            )
            .widgetURL(URL(string: "ledger://overview"))
        }
    }

    private func medium(_ imports: [LedgerWidgetImportSnapshot], updatedAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader(imports: imports, updatedAt: updatedAt)
            Spacer(minLength: 8)
            if imports.isEmpty {
                emptyState
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 7
                ) {
                    ForEach(Array(imports.prefix(4))) { item in
                        compactRow(item)
                    }
                }
                if imports.count > 4 {
                    Text("另有 \(imports.count - 4) 个渠道已归档")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(LedgerWidgetColors.secondary)
                        .padding(.top, 5)
                }
            }
        }
        .privacySensitive()
    }

    private func large(_ imports: [LedgerWidgetImportSnapshot], updatedAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader(imports: imports, updatedAt: updatedAt)
            Text("覆盖日期表示已导入账单的最后一天")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(LedgerWidgetColors.secondary)
                .padding(.top, 8)
                .padding(.bottom, 7)
            if imports.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(imports) { item in
                        detailedRow(item)
                        if item.id != imports.last?.id {
                            Rectangle()
                                .fill(LedgerWidgetColors.line.opacity(0.7))
                                .frame(height: 0.5)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .privacySensitive()
    }

    private func statusHeader(imports: [LedgerWidgetImportSnapshot], updatedAt: Date?) -> some View {
        HStack(spacing: 10) {
            LedgerWidgetHeader(title: "导入状态", detail: "\(imports.count) 个已归档渠道")
            Text(updatedAt.map { LedgerWidgetText.checked($0, now: entry.date) } ?? "暂未检查")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(LedgerWidgetColors.secondary)
                .lineLimit(1)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(LedgerWidgetColors.cobalt)
            VStack(alignment: .leading, spacing: 3) {
                Text("暂无导入记录")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LedgerWidgetColors.ink)
                Text("完成一次账单导入后会显示在这里")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(LedgerWidgetColors.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func compactRow(_ item: LedgerWidgetImportSnapshot) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(freshnessColor(item))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(LedgerWidgetColors.ink)
                    .lineLimit(1)
                Text(item.latestCoverageDate.map(Self.shortDate) ?? "账期未知")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(freshnessColor(item))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(LedgerWidgetColors.raised.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func detailedRow(_ item: LedgerWidgetImportSnapshot) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(freshnessColor(item))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LedgerWidgetColors.ink)
                    .lineLimit(1)
                Text(coverageRange(item))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(LedgerWidgetColors.secondary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.latestCoverageDate.map(Self.fullDate) ?? "账期未知")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(freshnessColor(item))
                Text("账单覆盖日期")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(LedgerWidgetColors.secondary)
            }
        }
        .frame(height: 34)
    }

    private func freshnessColor(_ item: LedgerWidgetImportSnapshot) -> Color {
        guard let raw = item.latestCoverageDate,
              let coverageDate = Self.dayDate(raw) else {
            return LedgerWidgetColors.secondary
        }
        let days = Calendar.current.dateComponents([.day], from: coverageDate, to: entry.date).day ?? 0
        if days > 35 { return LedgerWidgetColors.expense }
        if days > 20 { return LedgerWidgetColors.gold }
        return LedgerWidgetColors.success
    }

    private func coverageRange(_ item: LedgerWidgetImportSnapshot) -> String {
        if let start = item.coverageStart, let end = item.coverageEnd, start != end {
            return "\(Self.shortDate(start))–\(Self.shortDate(end))"
        }
        return item.latestCoverageDate.map { "上次导入至 \(Self.shortDate($0))" } ?? "上次导入账期未知"
    }

    private static func dayDate(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func shortDate(_ raw: String) -> String {
        let parts = raw.split(separator: "-")
        guard parts.count == 3 else { return raw }
        return "\(parts[1])/\(parts[2])"
    }

    private static func fullDate(_ raw: String) -> String {
        raw.replacingOccurrences(of: "-", with: "/")
    }
}
