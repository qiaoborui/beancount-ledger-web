# iOS 本地账本性能：写入并发 + 会话/UI 层

- 任务 `20261108-ios-local-perf-architecture`；状态 `completed-pending-review`（代码已提交到本地分支，未 push、未开 PR）；更新于 2026-11-08T19:30:00+08:00。
- 用户目标：减少本地账本在保存、同步、刷新时的卡顿和列表闪空，不改变写入/校验语义（preview → validate → append，bean-check/规范校验与回滚不变），不加依赖，不改版本号，部署目标 iOS 17，遵守 Reduce Motion。
- 分支 `codex/ios-local-perf-architecture`，基线 `main` @ `f58874e8`。本文覆盖的代码提交：`a3bf18ab`、`c07e3167`（第一部分）和 `55a9ac85`（第二部分）。

## 第一部分：引擎层（已提交）

- `a3bf18ab` `perf(core)`：模型 promote 时带上已预热的 stage 快照。
- `c07e3167` `perf(ios)`：新增 `LocalModelWriterLane`，规范校验只占写入 lane，读取不再被整次校验阻塞；锁顺序固定为先 lane 后 gate；阻塞的桥接调用改到并发队列执行。发布仍会等校验完成。

## 第二部分：会话 + UI 层（`55a9ac85`）

| 项 | 改动 | 主要文件 |
| --- | --- | --- |
| A 自动同步按 revision 判断 | `automaticSyncRequiresRefresh(currentRevisionID:presentedRevisionID:)`：只有工作区 revision 与正在展示的 revision 不同才刷新；只 push 时只有 baseCommit 变化，不刷新；pull/merge 会产生新 revision，照常刷新 | `App/LedgerMobile/Sources/LedgerSession.swift` |
| B 刷新时保留已显示的行 | 重置拆成 `cancelLocalTransactionReaders()`（让旧 generation 失效、把 window 置 nil，保留已累积的行）和 `clearLocalTransactionRows()`。刷新、保存观察者、新增、批量和打标签这些变更路径只取消读取；新 revision 的第一页读完后一次性替换行。改了筛选或上限、或重读失败时仍清空。刷新期间会话已在自己重载 window 时不再额外 bump reloadID（去掉了双重 bump）；并发调用会加入正在进行的第一页任务，不再重复扫描。后续任务的顺序：先可见 window，再 overview，再 prefetch/analysis | `LedgerSession.swift` |
| C 快速搜索防抖 | 交易页搜索框用本地 `searchText` 输入，停止输入 250 ms 后才写回 `filters.query`；清除按钮立即生效。`GlobalSearchView` 原本已有 180 ms 防抖，未改 | `App/LedgerMobile/Sources/TransactionViews.swift` |
| D Widget 发布防抖 | 本地路径改为 2.5 s 尾部防抖，只发布最后一次请求；App 失去活跃、进入后台或本地锁定时，在 background task 内立即 flush（不绑定 generation，`.ready`/`.locked` 且 contextURL 相同时才写入）；`invalidateSession` 取消挂起的发布。远程路径不变 | `LedgerSession.swift` |
| E 渲染开销 | `AccountsView` 每次 body 只算一次 sections/totals；`CurrencyRateText` 和筛选日期选择器复用静态缓存的 formatter；本地交易列表跳过用不到的 balanced 过滤和重复计数 | `AccountsView.swift`、`CurrencyAnalysisView.swift`、`GlobalSearchView.swift`、`TransactionViews.swift` |

### 决策

- 不迁移到 `@Observable`，`LedgerSession` 仍是 `ObservableObject`（明确不在本次范围）。
- 不改 `LedgerIsland*` 文件和 `BookkeepingPreviewView` 的灵动岛提示（由岛 PR 负责）。
- 写入、校验、回滚路径的语义不变：变更路径只改了列表重置的方式，没有改 preview/validate/append。
- 写入失败时仍会取消读取并 bump reloadID，让列表回到已提交的状态。
- 防抖时长做成可在测试中覆盖的静态值：`LedgerSession.localWidgetPublishDebounceNanoseconds`，以及 `TransactionsView.searchDebounceNanoseconds`。

## 验证（在 `55a9ac85` 的工作树内容上运行）

- `cd App/LedgerMobile && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`：899 tests，25 skipped，0 failures。
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project App/LedgerMobile/LedgerMobile.xcodeproj -scheme LedgerMobile -destination 'platform=iOS Simulator,id=<simulator>' -only-testing:LedgerMobileTests`：914 tests，7 skipped，0 failures，`TEST SUCCEEDED`。
- 新增和更新的测试：
  - `LocalLedgerAutomaticSyncSessionTests`：revision 判断表；保存后自动 push 不刷新、pull 刷新；widget 突发请求合并为一次，后台时 flush。该 suite 的 `setUp` 把防抖缩到 50 ms，避免在模拟器负载下超时。
  - `LocalTransactionWindowSessionTests`：同 revision 刷新保留行和 window；新 revision 在第一页替换前保留行，只读一页，不 bump；改筛选和重读失败会清空行。
- Go 未改动，未运行 Go 测试。

## 未测试 / 已知问题

1. 没有真机验证：没有 Instruments trace，没有大账本上的滚动、帧率实测，也没有真机上后台 flush 的实测。
2. 既有编译问题，不是本分支引入：Xcode 27.2 下 `App/LedgerMobile/Tests/LedgerAgentTests.swift` 的 `testInterruptionNotificationNamesTheCause` 在非隔离上下文里调用 main actor 隔离的 `LedgerAgentBackgroundRun.summary`，导致 app 测试 target 编译失败。为跑 xcodebuild，临时给该测试加了 `@MainActor`，跑完已还原，没有提交。需要单独修复。
3. Widget 防抖意味着前台连续操作时，widget 最多延迟约 2.5 s 更新；进入后台或锁定时会 flush。

## 后续

1. 把 `LedgerSession` 拆分迁移到 `@Observable`，缩小 SwiftUI 失效范围。
2. 把会话侧的全历史扫描（overview/analysis 的全量遍历）挪到 Go 侧。
3. 用 Release 包在真机上录一次 Instruments trace（Time Profiler、SwiftUI、Hangs），确认保存、同步、刷新和搜索时的卡顿确实下降。
4. 修复上面第 2 条的 `LedgerAgentTests` 既有编译问题。
5. 评审通过后 push 并开 PR；不需要发版（性能改动，没有新增能力）。
