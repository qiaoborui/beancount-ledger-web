#if os(iOS)
import Foundation
import UIKit
@preconcurrency import UserNotifications

/// What a contributing feature builds its reminders from.
struct LedgerReminderContext {
    let now: Date
    let calendar: Calendar
    let settings: LedgerReminderSettings
    let session: LedgerSession
}

/// Schedules the local reminders: 记账提醒, 导入账单提醒 and whatever other
/// features contribute (周报 / 月报). Only for a local ledger, only with local
/// notifications, nothing over the network.
///
/// `reschedule()` rebuilds the whole pending set from the settings
/// (`LedgerReminderPlanner`); it is idempotent and runs when the settings
/// change, when the app comes to the front, and when the presented ledger
/// revision moves (a write, an import, a sync). Taps arrive through
/// `LedgerNotificationDelegate` and open `ledger://` links.
///
/// Other features register a provider once, e.g. at launch:
///
///     LedgerLocalReminders.shared.register(source: "reports") { context in
///         LedgerReminderContribution(occurrences: [...], importReminderDates: [...])
///     }
///
/// and call `reschedule()` when their own settings change.
@MainActor
final class LedgerLocalReminders: ObservableObject {
    static let shared = LedgerLocalReminders()

    typealias Provider = @MainActor (LedgerReminderContext) async -> LedgerReminderContribution

    enum Permission: Equatable, Sendable {
        case notDetermined
        case allowed
        case denied
    }

    @Published private(set) var settings: LedgerReminderSettings
    @Published private(set) var permission: Permission = .notDetermined

    /// Opens a `ledger://` link; set by the app once its session exists. A
    /// tap that cold-starts the app waits here until then.
    var open: ((URL) -> Void)? {
        didSet {
            guard let url = pendingURL, let open else { return }
            pendingURL = nil
            open(url)
        }
    }

    private var pendingURL: URL?
    private var providers: [String: Provider] = [:]
    private var extraCategories: [String: UNNotificationCategory] = [:]
    private weak var session: LedgerSession?
    private var running: Task<Void, Never>?
    private var rerun = false
    private let defaults: UserDefaults
    private static let lastRecordedDayKey = "ledger.reminders.last-recorded-day"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = LedgerReminderSettings.load(from: defaults)
    }

    // MARK: Integration points

    func attach(_ session: LedgerSession) {
        self.session = session
        reschedule()
    }

    /// Adds a feature's reminders to every reschedule. Registering the same
    /// source again replaces its provider.
    func register(source: String, provider: @escaping Provider) {
        providers[source] = provider
        reschedule()
    }

    func unregister(source: String) {
        guard providers.removeValue(forKey: source) != nil else { return }
        reschedule()
    }

    /// A notification category with buttons of a contributing feature. Its
    /// identifier must start with `LedgerReminderNotification.identifierPrefix`
    /// so taps are routed here; action buttons open the notification's link.
    func register(category: UNNotificationCategory) {
        extraCategories[category.identifier] = category
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    var categories: Set<UNNotificationCategory> {
        typealias N = LedgerReminderNotification
        let record = UNNotificationAction(identifier: N.recordAction, title: String(localized: "记一笔"), options: [.foreground])
        let sentence = UNNotificationAction(identifier: N.sentenceAction, title: String(localized: "一句话记账"), options: [.foreground])
        let imports = UNNotificationAction(identifier: N.importAction, title: String(localized: "导入账单"), options: [.foreground])
        var all: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: N.bookkeepingCategory, actions: [record, sentence], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: N.importCategory, actions: [imports], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: N.plainCategory, actions: [], intentIdentifiers: [], options: []),
        ]
        all.formUnion(extraCategories.values)
        return all
    }

    /// A tap on a reminder or one of its buttons.
    func route(_ url: URL) {
        if let open { open(url) } else { pendingURL = url }
    }

    // MARK: Settings

    /// Changes the settings. Turning a reminder on asks for notification
    /// permission the first time.
    func update(_ change: (inout LedgerReminderSettings) -> Void) {
        let before = settings
        var next = settings
        change(&next)
        guard next != before else { return }
        settings = next
        next.save(to: defaults)
        let switchedOn = (next.bookkeeping.isEnabled && !before.bookkeeping.isEnabled)
            || (next.imports.isEnabled && !before.imports.isEnabled)
        Task {
            if switchedOn { await requestPermissionIfNeeded() }
            reschedule()
        }
    }

    func refreshPermission() async {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<UNAuthorizationStatus, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
        let next: Permission
        switch status {
        case .notDetermined: next = .notDetermined
        case .denied: next = .denied
        default: next = .allowed
        }
        if permission != next { permission = next }
    }

    private func requestPermissionIfNeeded() async {
        await refreshPermission()
        guard permission == .notDetermined else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                continuation.resume()
            }
        }
        await refreshPermission()
    }

    // MARK: Scheduling

    /// Rebuilds the pending reminders. Calls while one runs coalesce into one
    /// more run after it.
    func reschedule() {
        guard running == nil else {
            rerun = true
            return
        }
        running = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.rerun = false
                await self.apply()
            } while self.rerun
            self.running = nil
        }
    }

    private func apply() async {
        // Before the session knows its ledger, leave what is pending alone.
        guard let session, let location = session.location else { return }
        await refreshPermission()
        let ours = await pendingIdentifiers()
        guard case .local = location, permission == .allowed else {
            remove(ours)
            return
        }
        let now = Date()
        let calendar = Calendar.current
        let current = settings
        var recordedToday = false
        if current.bookkeeping.isEnabled, current.bookkeeping.skipsRecordedDays {
            let today = LedgerDateRange.today(now: now)
            // A locked ledger cannot be read: fall back to the last day a read
            // found recorded, so a reschedule before unlocking does not bring
            // back a reminder that was already skipped.
            if let found = await session.localHasTransactions(on: today) {
                recordedToday = found
                if found { defaults.set(today, forKey: Self.lastRecordedDayKey) }
            } else {
                recordedToday = defaults.string(forKey: Self.lastRecordedDayKey) == today
            }
        }
        let context = LedgerReminderContext(now: now, calendar: calendar, settings: current, session: session)
        var contributions: [LedgerReminderContribution] = []
        for source in providers.keys.sorted() {
            guard let provider = providers[source] else { continue }
            contributions.append(await provider(context))
        }
        // The ledger may have changed under the reads above.
        guard self.session === session, session.location == location else { return }
        let plan = LedgerReminderPlanner.plan(settings: current, now: now, calendar: calendar,
            recordedToday: recordedToday, contributions: contributions)
        submit(plan, replacing: ours, calendar: calendar)
        if recordedToday { clearDeliveredBookkeeping() }
    }

    private func pendingIdentifiers() async -> [String] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map(\.identifier)
                    .filter { $0.hasPrefix(LedgerReminderNotification.identifierPrefix) })
            }
        }
    }

    private func remove(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func submit(_ plan: [LedgerReminderOccurrence], replacing pending: [String], calendar: Calendar) {
        let center = UNUserNotificationCenter.current()
        let planned = Set(plan.map(\.id))
        remove(pending.filter { !planned.contains($0) })
        for occurrence in plan {
            let content = UNMutableNotificationContent()
            content.title = occurrence.title
            content.body = occurrence.body
            content.sound = .default
            content.threadIdentifier = LedgerReminderNotification.thread
            content.categoryIdentifier = occurrence.categoryIdentifier
            content.userInfo = [LedgerReminderNotification.urlKey: occurrence.url.absoluteString]
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: occurrence.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            // The same identifier replaces the pending request, so a reschedule
            // also refreshes wording that changed.
            center.add(UNNotificationRequest(identifier: occurrence.id, content: content, trigger: trigger),
                       withCompletionHandler: nil)
        }
    }

    /// Once today has a transaction, a 记账提醒 still in the list is old news.
    private func clearDeliveredBookkeeping() {
        let prefix = LedgerReminderNotification.identifierPrefix + LedgerReminderKind.bookkeeping.rawValue + "."
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}

/// The app's one notification center delegate. 账本助手 notifications are
/// recognized by their thread and open the Agent screen as before; reminders
/// by their category, and open the link of the button or notification tapped.
@MainActor
final class LedgerNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LedgerNotificationDelegate()

    /// At launch, before it ends, so a tap that started the app is delivered.
    static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.setNotificationCategories(LedgerLocalReminders.shared.categories)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        if content.threadIdentifier == LedgerAgentNotifications.thread {
            await MainActor.run {
                LedgerCrashLog.shared.record("收到账本助手通知")
                LedgerAgentNotifications.shared.route()
            }
            return
        }
        guard LedgerReminderNotification.isReminder(categoryIdentifier: content.categoryIdentifier),
              let url = LedgerReminderNotification.url(forAction: response.actionIdentifier,
                                                       userInfo: content.userInfo) else { return }
        await MainActor.run { LedgerLocalReminders.shared.route(url) }
    }

    /// In the app, the banner still shows: away from the Agent screen for the
    /// assistant, and anywhere for a reminder.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
#endif
