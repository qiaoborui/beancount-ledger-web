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

struct ImportStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons
    let entry: ImportStatusEntry
    var familyOverride: WidgetFamily?
    var body: some View {
        Group {
            if !redactionReasons.isEmpty {
                LedgerWidgetPrivacyView(title: "导入状态")
            } else if let snapshot = entry.snapshot {
                content(snapshot)
            } else {
                LedgerWidgetUnavailableView(title: "等待导入记录", detail: "打开 Ledger 并刷新一次", symbol: "tray.and.arrow.down")
            }
        }.widgetURL(URL(string: "ledger://imports"))
            .containerBackground(for: .widget) { LedgerWidgetColors.panel }
    }
    private func content(_ snapshot: LedgerWidgetSnapshot) -> some View {
        let large = (familyOverride ?? family) == .systemLarge
        let items = Array(snapshot.imports.prefix(4))
        return VStack(alignment: .leading, spacing: large ? 7 : 4) {
            LedgerWidgetHeader(title: "导入状态", detail: "\(snapshot.imports.count)个渠道")
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("暂无导入记录").font(.system(size: 13, weight: .medium))
                    Text("完成账单导入后显示覆盖日期").font(.system(size: 10))
                }.foregroundStyle(LedgerWidgetColors.secondary).frame(maxHeight: .infinity)
            } else {
                HStack {
                    Text("渠道"); Spacer()
                    Text("覆盖至").frame(width: 64, alignment: .trailing)
                    Text("距今").frame(width: 40, alignment: .trailing)
                }.font(.system(size: 9)).foregroundStyle(LedgerWidgetColors.secondary)
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Text(item.label).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.latestCoverageDate.map(LedgerWidgetHeat.shortDate) ?? "未知")
                            .font(.system(size: 10, design: .monospaced)).frame(width: 64, alignment: .trailing)
                        Text(daysSince(item)).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LedgerWidgetColors.accent).frame(width: 40, alignment: .trailing)
                    }.font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.ink)
                    if large { Rectangle().fill(LedgerWidgetColors.line).frame(height: 0.5) }
                }
                if large {
                    Text("已归档区间").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerWidgetColors.ink).padding(.top, 4)
                    ForEach(items) { item in
                        HStack(spacing: 6) {
                            Rectangle().fill(LedgerWidgetColors.accent).frame(width: 12, height: 2)
                            Text(item.label).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(coverageRange(item)).font(.system(size: 9, design: .monospaced)).lineLimit(1)
                        }.font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("覆盖日期指账单截止日，不代表同步状态。")
                        .font(.system(size: 9)).foregroundStyle(LedgerWidgetColors.secondary)
                } else { Spacer(minLength: 0) }
            }
            LedgerWidgetFooter(label: snapshot.imports.count > 4 ? "另有\(snapshot.imports.count - 4)个渠道" : "账单覆盖", date: snapshot.importsUpdatedAt, now: entry.date)
        }.privacySensitive()
    }
    private func daysSince(_ item: LedgerWidgetImportSnapshot) -> String {
        guard let raw = item.latestCoverageDate, let date = LedgerWidgetDates.date(raw) else { return "未知" }
        let now = Calendar.current.startOfDay(for: entry.date)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let civil = LedgerWidgetDates.calendar.date(from: parts) ?? now
        let days = LedgerWidgetDates.calendar.dateComponents([.day], from: date, to: civil).day ?? 0
        return days < 0 ? "未来" : "\(days)天"
    }
    private func coverageRange(_ item: LedgerWidgetImportSnapshot) -> String {
        guard let start = item.coverageStart, let end = item.coverageEnd else { return "账期未知" }
        return "\(LedgerWidgetHeat.shortDate(start))–\(LedgerWidgetHeat.shortDate(end))"
    }
}
