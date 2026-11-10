import AppIntents
import Foundation

// App target only. The recording decision lives in the portable
// `LedgerShortcutRecording.swift`; this file adapts Shortcuts parameters.

struct LedgerShortcutCategoryEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "分类")
    static let defaultQuery = LedgerShortcutCategoryQuery()
    let id: String
    let label: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)", subtitle: "\(id)") }
}

struct LedgerShortcutCategoryQuery: EntityStringQuery {
    init() {}
    @MainActor func entities(for identifiers: [String]) async throws -> [LedgerShortcutCategoryEntity] {
        LedgerShortcutEntityLookup.resolve(identifiers, among: await LedgerShortcutRecordingHost.shared.accounts(role: .category))
            .map { LedgerShortcutCategoryEntity(id: $0.id, label: $0.label) }
    }
    @MainActor func suggestedEntities() async throws -> [LedgerShortcutCategoryEntity] {
        await LedgerShortcutRecordingHost.shared.accounts(role: .category)
            .map { LedgerShortcutCategoryEntity(id: $0.account, label: $0.label) }
    }
    @MainActor func entities(matching string: String) async throws -> [LedgerShortcutCategoryEntity] {
        LedgerShortcutEntityLookup.matching(string, among: await LedgerShortcutRecordingHost.shared.accounts(role: .category))
            .map { LedgerShortcutCategoryEntity(id: $0.account, label: $0.label) }
    }
}

struct LedgerShortcutFundingEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "付款账户")
    static let defaultQuery = LedgerShortcutFundingQuery()
    let id: String
    let label: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)", subtitle: "\(id)") }
}

struct LedgerShortcutFundingQuery: EntityStringQuery {
    init() {}
    @MainActor func entities(for identifiers: [String]) async throws -> [LedgerShortcutFundingEntity] {
        LedgerShortcutEntityLookup.resolve(identifiers, among: await LedgerShortcutRecordingHost.shared.accounts(role: .funding))
            .map { LedgerShortcutFundingEntity(id: $0.id, label: $0.label) }
    }
    @MainActor func suggestedEntities() async throws -> [LedgerShortcutFundingEntity] {
        await LedgerShortcutRecordingHost.shared.accounts(role: .funding)
            .map { LedgerShortcutFundingEntity(id: $0.account, label: $0.label) }
    }
    @MainActor func entities(matching string: String) async throws -> [LedgerShortcutFundingEntity] {
        LedgerShortcutEntityLookup.matching(string, among: await LedgerShortcutRecordingHost.shared.accounts(role: .funding))
            .map { LedgerShortcutFundingEntity(id: $0.account, label: $0.label) }
    }
}

private enum LedgerShortcutEntityLookup {
    /// Saved values stay valid even when the target is gone or unreadable:
    /// the record step validates the account against the ledger.
    static func resolve(_ identifiers: [String], among accounts: [LedgerAccount]) -> [(id: String, label: String)] {
        identifiers.map { id in
            (id, accounts.first { $0.account == id }?.label ?? String(id.split(separator: ":").last ?? Substring(id)))
        }
    }

    static func matching(_ text: String, among accounts: [LedgerAccount]) -> [LedgerAccount] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return accounts }
        return accounts.filter { $0.label.localizedCaseInsensitiveContains(query) || $0.account.localizedCaseInsensitiveContains(query) }
    }
}

struct RecordLedgerTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "记一笔"
    static let description = IntentDescription("在本机 Ledger 账本中直接记一笔交易，不打开 App。记录会标记为待核对（!），出现在「待整理」中。需先在 Ledger 设置中为一个本机账本开启「快捷指令记账」。")
    static let openAppWhenRun = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    // `Decimal` is not an App Intents value type in this SDK; the record step
    // converts the number through its shortest text.
    @Parameter(title: "金额", requestValueDialog: "金额是多少？")
    var amount: Double
    @Parameter(title: "商户")
    var payee: String?
    @Parameter(title: "备注")
    var narration: String?
    @Parameter(title: "分类", description: "支出或收入分类；留空时按商户历史自动匹配，匹配不到记入待分类。")
    var category: LedgerShortcutCategoryEntity?
    @Parameter(title: "付款账户", description: "资产或负债账户；留空时使用上次记账用的账户。")
    var funding: LedgerShortcutFundingEntity?
    @Parameter(title: "日期")
    var date: Date?
    @Parameter(title: "币种", description: "币种代码，如 CNY；留空时使用账本的计价币种。")
    var currency: String?
    @Parameter(title: "标签")
    var tags: [String]?
    @Parameter(title: "去重标识", description: "同一标识只会记一次，适合自动化重试。")
    var idempotencyKey: String?

    static var parameterSummary: some ParameterSummary {
        Summary("记一笔 \(\.$amount)，商户 \(\.$payee)") {
            \.$category
            \.$funding
            \.$narration
            \.$date
            \.$currency
            \.$tags
            \.$idempotencyKey
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let value = LedgerShortcutEntryBuilder.amount(fromShortcutValue: amount) else {
            throw LedgerShortcutRecordingError.invalidAmount
        }
        let result = try await LedgerShortcutRecordingHost.shared.record(.init(
            amount: value, payee: payee, narration: narration,
            categoryAccount: category?.id, fundingAccount: funding?.id,
            date: date ?? Date(), currency: currency, tags: tags ?? [], idempotencyKey: idempotencyKey))
        let dialog: IntentDialog = result.duplicate
            ? IntentDialog("这笔已经记过了，没有重复记录。")
            : IntentDialog("已记入待核对：\(result.dialogSummary)")
        return .result(value: result.beanText, dialog: dialog)
    }
}

/// Owns the recorder for the app process. Intents and entity queries run here
/// whether iOS launched the app for them or it was already running. Never log
/// the amount, payee, note or written text.
@MainActor
final class LedgerShortcutRecordingHost {
    static let shared = LedgerShortcutRecordingHost()
    private var onCommitted: (@MainActor (UUID, LocalLedgerCatalog) async -> Void)?
    private var recorder: LedgerShortcutRecorder?
    private var catalog: LocalLedgerCatalog?

    func configure(onCommitted: @escaping @MainActor (UUID, LocalLedgerCatalog) async -> Void) {
        self.onCommitted = onCommitted
    }

    func record(_ request: LedgerShortcutRecordRequest) async throws -> LedgerShortcutRecordResult {
        let (catalog, recorder) = try prepared()
        let result = try await recorder.record(request, target: LedgerSession.shortcutTarget(),
            rememberedFunding: CookieFundingMemory.rawValue())
        if !result.duplicate { await onCommitted?(result.ledgerID, catalog) }
        return result
    }

    func accounts(role: LedgerShortcutRecorder.AccountRole) async -> [LedgerAccount] {
        guard let (_, recorder) = try? prepared() else { return [] }
        return (try? await recorder.accounts(role: role, target: LedgerSession.shortcutTarget())) ?? []
    }

    private func prepared() throws -> (LocalLedgerCatalog, LedgerShortcutRecorder) {
        if let catalog, let recorder { return (catalog, recorder) }
        do {
            let catalog = try LocalLedgerCatalog.appManaged()
            let recorder = LedgerShortcutRecorder(catalog: catalog)
            self.catalog = catalog
            self.recorder = recorder
            return (catalog, recorder)
        } catch {
            throw LedgerShortcutRecordingError.isPermissionDenied(error)
                ? LedgerShortcutRecordingError.unavailableBeforeFirstUnlock : LedgerShortcutRecordingError.noLedger
        }
    }
}
