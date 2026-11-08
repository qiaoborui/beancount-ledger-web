# iOS 本地账本性能：写入并发 + 会话/UI 层

- 任务 `20261108-ios-local-perf-architecture`；状态 `completed-pending-review`（评审修复已提交到本地分支，未 push、未开 PR）；更新于 2026-11-08T22:30:00+08:00。
- 用户目标：减少本地账本在保存、同步、刷新时的卡顿和列表闪空，不改变写入/校验语义（preview → validate → append，bean-check/规范校验与回滚不变），不加依赖，不改版本号，部署目标 iOS 17，遵守 Reduce Motion。
- 分支 `codex/ios-local-perf-architecture`，基线 `main` @ `f58874e8`。本文覆盖的代码提交：`a3bf18ab`、`c07e3167`（第一部分）、`55a9ac85`（第二部分），以及之后的评审修复提交（见“评审修复”）。

## 第一部分：引擎层（已提交）

- `a3bf18ab` `perf(core)`：模型 promote 时带上已预热的 stage 快照。
- `c07e3167` `perf(ios)`：新增 `LocalModelWriterLane`，规范校验只占写入 lane，读取不再被整次校验阻塞；锁顺序固定为先 lane 后 gate；阻塞的桥接调用改到并发队列执行。发布仍会等校验完成。

## 第二部分：会话 + UI 层（`55a9ac85`）

| 项 | 改动 | 主要文件 |
| --- | --- | --- |
| A 自动同步按 revision 判断 | `automaticSyncRequiresRefresh(currentRevisionID:presentedRevisionID:)`：只有工作区 revision 与正在展示的 revision 不同才刷新；只 push 时只有 baseCommit 变化，不刷新；pull/merge 会产生新 revision，照常刷新 | `App/LedgerMobile/Sources/LedgerSession.swift` |
| B 刷新时保留已显示的行 | 重置拆成 `cancelLocalTransactionReaders()`（让旧 generation 失效、把 window 置 nil，保留已累积的行）和 `clearLocalTransactionRows()`。刷新和新增交易只取消读取，行保留到列表自己读到新 revision 的第一页时一次性替换；编辑/删除/打标签、外部保存观察者、改筛选或上限、重读失败仍清空。重读由列表的 `windowRequestKey` 驱动，`loadLedger` 不再等待列表读取；新增交易后不再双重 bump reloadID；并发调用会加入正在进行的第一页任务，不再重复扫描 | `LedgerSession.swift` |
| C 快速搜索防抖 | 交易页搜索框用本地 `searchText` 输入，停止输入 250 ms 后才写回 `filters.query`；清除按钮立即生效。`GlobalSearchView` 原本已有 180 ms 防抖，未改 | `App/LedgerMobile/Sources/TransactionViews.swift` |
| D Widget 发布防抖 | 本地路径改为 2.5 s 尾部防抖，只发布最后一次请求；等待期间按 contextURL + 展示 revision 校验，不按 request generation（中途失败的刷新不会丢掉上一次好的快照）。App 失去活跃、进入后台或本地锁定时，在 background task 内立即 flush（`.ready`/`.locked` 且 contextURL 相同时才写入）；不活跃时才排进来的发布直接 flush，不进防抖；`invalidateSession` 取消挂起的发布。远程路径不变 | `LedgerSession.swift` |
| E 渲染开销 | `AccountsView` 每次 body 只算一次 sections/totals；`CurrencyRateText` 和筛选日期选择器复用静态缓存的 formatter；本地交易列表跳过用不到的 balanced 过滤和重复计数 | `AccountsView.swift`、`CurrencyAnalysisView.swift`、`GlobalSearchView.swift`、`TransactionViews.swift` |

### 决策

- 不迁移到 `@Observable`，`LedgerSession` 仍是 `ObservableObject`（明确不在本次范围）。
- 不改 `LedgerIsland*` 文件和 `BookkeepingPreviewView` 的灵动岛提示（由岛 PR 负责）。
- 写入、校验、回滚路径的语义不变：变更路径只改了列表重置的方式，没有改 preview/validate/append。
- 写入失败时仍会取消读取并 bump reloadID，让列表回到已提交的状态。
- 第一部分的 promote 在没有可带过去的预热快照时不再后台构建快照（后台构建会占住 committed cache 的 mutex，让下一次编辑的 adopt 卡住所有读取），回到首次读取时构建。
- 防抖时长做成可在测试中覆盖的静态值：`LedgerSession.localWidgetPublishDebounceNanoseconds`，以及 `TransactionsView.searchDebounceNanoseconds`。

## 评审修复

- 本地 widget 发布：排期时 App 已不活跃或在后台则立即 flush；等待中的请求按 ledger + revision 校验，不再因 generation 变化被静默丢弃。
- 编辑/删除/打标签开始时恢复清空列表行（列表直接渲染原始 window 行，不做 projection，保留会显示删除前或编辑前的内容）。
- `loadLedger` 不再在 overview/widget 之前等待列表第一页；由列表自己的请求 key 触发重读。
- 外部保存观察者（Share/Agent/导入提交新 revision）恢复清空列表行，避免旧 revision 的行继续可交互。
- Go：`PromoteLocalModel` 去掉无预热快照时的后台构建；测试改为确认 promote 后 cache mutex 空闲、首次读取构建结果与冷构建一致。
- 未修：在 `swift test` 下覆盖引擎 lane 的可移植测试（需要给 `EmbeddedLocalLedgerEngine` 加 native dispatch 注入点，超出本次修复范围），以及 `LedgerAgentTests` 既有编译问题（单独修复）。

## 验证（在评审修复后的工作树内容上运行）

- `cd server && go test ./... && go build ./cmd/ledger-web`：全部通过。
- `scripts/build-ledgercore-xcframework.sh`：重新构建成功。
- `cd App/LedgerMobile && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`：899 tests，25 skipped，0 failures。
- `xcodegen generate` 后 `xcodebuild test -scheme LedgerMobile -destination 'platform=iOS Simulator,id=<iPhone 17 Pro Max>' -only-testing:LedgerMobileTests`（临时给 `LedgerAgentTests` 加 `@MainActor` 以通过编译，跑完已还原）：914 tests，7 skipped，0 failures，`TEST SUCCEEDED`。
- 新增和更新的测试：
  - `LocalLedgerAutomaticSyncSessionTests`：revision 判断表；保存后自动 push 不刷新、pull 刷新；widget 突发请求合并为一次，后台时 flush，后台中排进的发布立即执行。该 suite 的 `setUp` 把防抖缩到 50 ms，避免在模拟器负载下超时。
  - `LocalTransactionWindowSessionTests`：同 revision 刷新保留行、window 置 nil 并 bump 一次；新 revision 刷新不读列表页、overview 照常刷新，行保留到列表第一页替换，加入的调用不重复读；改筛选和重读失败清空行；删除开始和外部保存清空行。
  - `local_model_promote_test.go`：无预热快照时 promote 不占用 cache mutex，首次读取构建与冷构建一致。

## 未测试 / 已知问题

1. 没有真机验证：没有 Instruments trace，没有大账本上的滚动、帧率实测，也没有真机上后台 flush 的实测。
2. 既有编译问题，不是本分支引入：当前 Xcode 下 `App/LedgerMobile/Tests/LedgerAgentTests.swift` 的 `testInterruptionNotificationNamesTheCause` 在非隔离上下文里调用 main actor 隔离的 `LedgerAgentBackgroundRun.summary`，导致 app 测试 target 编译失败。为跑 xcodebuild，临时给该测试加了 `@MainActor`，跑完已还原，没有提交。需要单独修复；修复前，`#if os(iOS)` 下的引擎 lane 测试在 CI 中不运行。
3. Widget 防抖意味着前台连续操作时，widget 最多延迟约 2.5 s 更新；进入后台或锁定时会 flush。

## 后续

1. 把 `LedgerSession` 拆分迁移到 `@Observable`，缩小 SwiftUI 失效范围。
2. 把会话侧的全历史扫描（overview/analysis 的全量遍历）挪到 Go 侧。
3. 用 Release 包在真机上录一次 Instruments trace（Time Profiler、SwiftUI、Hangs），确认保存、同步、刷新和搜索时的卡顿确实下降。
4. 修复上面第 2 条的 `LedgerAgentTests` 既有编译问题。
5. 评审通过后 push 并开 PR；不需要发版（性能改动，没有新增能力）。
