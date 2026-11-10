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

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ImportStatusEntry>) -> Void) {
        let now = Date()
        Task {
            let result = await LedgerWidgetTimelineLoader.shared.load(now: now)
            completion(
                Timeline(
                    entries: [ImportStatusEntry(date: now, snapshot: result.snapshot)],
                    policy: .after(now.addingTimeInterval(result.refreshInterval))
                )
            )
        }
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

/// A locked device keeps the rows and masks the channel names and dates.
struct ImportStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: ImportStatusEntry
    var familyOverride: WidgetFamily?
    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot)
            } else {
                LedgerWidgetUnavailableView(title: String(localized: "导入状态"))
            }
        }.widgetURL(URL(string: "ledger://imports"))
            .containerBackground(for: .widget) { LedgerWidgetColors.sunken }
    }
    private func content(_ snapshot: LedgerWidgetSnapshot) -> some View {
        let tone = LedgerWidgetTone(renderingMode)
        let large = (familyOverride ?? family) == .systemLarge
        let items = Array(snapshot.imports.prefix(4))
        return VStack(alignment: .leading, spacing: large ? 8 : 5) {
            LedgerWidgetHeader(title: String(localized: "导入状态"), detail: String(localized: "\(snapshot.imports.count)个渠道"))
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("暂无导入记录").font(LedgerWidgetFont.medium(12)).foregroundStyle(tone.ink)
                    Text("完成账单导入后显示覆盖日期").font(LedgerWidgetFont.text(10)).foregroundStyle(tone.meta)
                }.frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: large ? 12 : 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Rectangle().fill(tone.rule).frame(height: 1) }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // Large adds the archived range under the channel.
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.label).font(LedgerWidgetFont.text(large ? 13 : 11)).foregroundStyle(tone.ink)
                                if large {
                                    Text(coverageRange(item)).font(LedgerWidgetFont.text(10)).foregroundStyle(tone.meta)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(daysSince(item)).font(LedgerWidgetFont.text(large ? 12 : 11)).foregroundStyle(tone.meta)
                        }.lineLimit(1).monospacedDigit().privacySensitive()
                    }
                }
                Spacer(minLength: 0)
                if large {
                    Text("覆盖日期指账单截止日，不代表同步状态。")
                        .font(LedgerWidgetFont.text(10)).foregroundStyle(tone.meta)
                }
            }
            LedgerWidgetFooter(label: snapshot.imports.count > 4 ? String(localized: "另有\(snapshot.imports.count - 4)个渠道") : nil,
                               date: snapshot.importsUpdatedAt, now: entry.date)
        }
    }
    private func daysSince(_ item: LedgerWidgetImportSnapshot) -> String {
        guard let raw = item.latestCoverageDate, let date = LedgerWidgetDates.date(raw) else { return String(localized: "未知") }
        let now = Calendar.current.startOfDay(for: entry.date)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let civil = LedgerWidgetDates.calendar.date(from: parts) ?? now
        let days = LedgerWidgetDates.calendar.dateComponents([.day], from: date, to: civil).day ?? 0
        if days < 0 { return String(localized: "未来") }
        return days == 0 ? String(localized: "今天") : String(localized: "\(days) 天前")
    }
    private func coverageRange(_ item: LedgerWidgetImportSnapshot) -> String {
        guard let start = item.coverageStart, let end = item.coverageEnd else { return String(localized: "账期未知") }
        return "\(LedgerWidgetHeat.shortDate(start))–\(LedgerWidgetHeat.shortDate(end))"
    }
}
