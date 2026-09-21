# iOS 本地内核性能优化计划

- 任务：`20260921-ios-kernel-performance`
- 状态：补充 baseline 测量完成；架构优化仍待批准，没有改变产品算法。
- 最新测量与复现方法：见 [baseline harness](../ios-performance-baseline.md) 和本文第 7 节。第 3 节保留首轮调查历史，第 5 节目标已撤回。
- 检查版本：`1e3c9aa8ae3cd4bdce61017399bfbd6611608274`
- 分支：`codex/ios-kernel-performance-plan`
- 更新时间：2026-09-21T15:59:56.449707+08:00

## 1. 建议结论与边界

保留 Swift + 内嵌 Go + canonical Beancount/CPython 架构，先减少重复序列化、重复模型处理和全量 I/O，再按真机剖析结果优化查询。不先重写解析器、不先引入 SQLite、不用减少账务校验换速度。

这里的“内核”指设备内账本的加载、booking/校验、读模型、查询、预览与原子提交、与后台同步/Widget 的竞争，不是 iOS 系统内核。生产是 local-only：无本地 HTTP listener，Go 直接分发已有 handler；Git 是可选同步，不应成为本地保存成功的前提。

初始调查只阅读代码、运行已有合成数据测试/benchmark、记录计划。后续获准补充隔离 baseline，增加 opt-in 测试与合成 fixture generator；不发布私有来源的数据或派生指标。未来范围可能超过 8 个文件，按下面独立可合并的工作包拆 PR；这不是一次大重构。没有新增服务、语言、API key 或第三方账户要求。

## 2. 现在如何工作

```text
SwiftUI / LedgerSession
  -> LocalLedgerRepository（页面读取、预览 token、确认）
      -> LocalLedgerWorkspace（revision、锁、隔离 stage、原子 current.json）
      -> EmbeddedLocalLedgerEngine actor
          -> EmbeddedBeancountValidator actor
              -> C bridge -> CPython -> Beancount（booking / 插件 / 完整校验）
          -> canonical JSON + 请求 JSON
              -> gomobile -> mobilecore -> Go local transport
                  -> LedgerCache -> ReadService / BQL / analytics / writers
      -> 可选 Git 同步、缩减后的 Widget snapshot
```

### 读取

1. Repository 取得一个固定 generation；bootstrap 有持久化展示缓存。
2. Swift engine 保存最近一个已提交 workspace/entrypoint 的 canonical JSON；mutable stage 不复用。
3. Python 首次初始化一次；未缓存加载经过安全预检及 canonical booking/validation。
4. 每次引擎请求仍将 canonical JSON 放进跨语言请求。
5. Go 检查路径/文件树，计算源码版本，再将 canonical marshal/hash 作为读模型缓存 key；命中不代表没有扫描/分配。
6. handler 聚合/过滤后返回 JSON，Swift 拆 envelope 再解码为模型。

### 写入

预览：旧 generation -> 完整复制 stage -> Go 写操作（可能多次 dispatch）-> canonical 校验 -> 文件 diff -> 保存准确预览字节。

确认：核对 token/revision -> 新 stage 完整复制 -> 应用已确认字节 -> 再次完整校验 -> 文件/目录持久化 -> 原子切换 current.json -> 通知页面/同步。

这种设计的价值是可核验、读者不见半成品和失败可回滚。优化必须保留这些不变量。

### 代码定位（以上版本）

| 位置 | 已确认的事实 |
|---|---|
| `App/LedgerMobile/Sources/LocalLedgerEngine.swift:42` | 最近一个 canonical 缓存；每请求仍拼接完整 canonical |
| `App/LedgerMobile/Sources/EmbeddedBeancountValidator.swift:38` | validate 走完整 load，仍提取 canonical 后丢弃 |
| `App/LedgerMobile/Runtime/ledger_validator.py:156` | 预检 + `_uncached_load_file` + HARDCORE_VALIDATIONS + canonical 序列化 |
| `server/internal/app/local_transport.go:156` | 命中缓存前仍 ledgerVersion + canonical marshal/hash |
| `server/internal/app/cache.go:276` | 本地 ledgerVersion 读取 include 内容并哈希 |
| `App/LedgerMobile/Sources/LocalLedgerRepository.swift:204` | 预览操作逐条 stage dispatch；232 行确认时重新校验 |
| `App/LedgerMobile/Sources/LocalLedgerWorkspace.swift:264` | commit 整树复制；337 行 prepare 整树复制、全量比较 |
| `server/internal/app/ledger_read_service.go:443` | 日期过滤仍遍历交易数组；已有排序 snapshot 可复用 |
| `App/LedgerMobile/Sources/LocalLedgerWidgetPublisher.swift:30` | bootstrap + 四次 homeReport + importDocuments，最后验证 revision 一致 |
| `App/LedgerMobile/Sources/LocalLedgerWorkspace.swift:23` | 当前限制 10,000 entries、256 MiB、深度 32；预览字节上限 64 MiB |
| `App/LedgerMobile/Sources/LocalLedgerWorkspace.swift:630` | 历史 revision 完整保留，不能假设保存后磁盘自然回落 |

## 3. 本次实际测量：不是 iPhone 数据

环境：Apple M5 / Darwin arm64 / Go 1.27.1；代码无改动。现有 `BenchmarkLocalPageLoad`，1,000 笔合成交易、单 main.bean、月度查询；每项 5 次，1s benchtime。该用例不是复杂投资账本，investments 结果不能代表成本批次/价格估值压力。

| Go 页面 | 5 次 ns/op 的中位值（ms/op） | 5 次平均分配量的范围（MB/op，十进制） |
|---|---:|---:|
| bootstrap | 4.719 | 5.33–5.70 |
| dashboard | 2.905 | 3.81–3.96 |
| income-statement | 2.377 | 2.99–3.27 |
| investments | 2.230 | 2.63–2.84 |

这些是每次 benchmark 的平均耗时再取中位数，**不是请求 p95**；B/op 是累计分配/操作，**不是峰值/驻留内存**。用例直接调用 Go transport，未涵盖真实 Swift/gomobile JSON 入口、Python、复制/提交或 UI。缓存冷启动没有单独隔离。

另一次 bootstrap 的 3s pprof：4.491 ms/op、5.03 MB/op。采样 alloc_space 中 JSON struct 编码约 26.3%，bytes.Clone 约 24.8%，localLedgerSource.func1 自身约 9.3%；这是含 benchmark 校准/初始化的进程分配采样，不是 iPhone 或单请求的精确占比。足以支持先检查 JSON 与源码重复处理，不能据此断言 Python 或磁盘不是主瓶颈。CPU top 包含大量 syscall/runtime；需调用栈和真机 trace 才能进一步归因。

已通过：Go 本地缓存/配置/树安全相关测试、`internal/ledgercore` 与 `mobilecore` 测试。

**首轮发现、后续已修复的基线阻塞：**`swift test --filter LocalLedgerPresentationCacheTests` 在编译整个 test target 时失败，`CookieFastTransactionEditorTests.swift` 无法找到 `CookieKeypadCalculator`、`CookieFastTransactionEditorBody`、`CookieCategoryItem` 等符号；筛选并不能跳过其他测试的编译。原因是 portable Package.swift 不包含 UI 实现，却自动收进对应 UI 测试。现已仅从 portable target 排除该文件，Xcode app-host target 保留；portable 全套随后通过。没有删除测试。

首轮未执行真机/模拟器 app-host 压测、100k 数据、故障注入或长时间测试。后续已重建匹配源码的 frameworks，补测专用模拟器及 10k/100k 容量边界；真机/UI/长时间测试仍未执行。详见第 7 节。

## 4. 压测设计

这不是 Web QPS 竞赛。主要压力轴是交易量、include/附件数量、跨语言负载、连续写入，以及用户交互和后台任务竞争。

### 数据矩阵（全部固定 seed 合成，不用真实账本）

| 档位 | 交易 | include 文件 | 账户 | 内容与用途 |
|---|---:|---:|---:|---|
| S | 1,000 | 12 | 30 | 单币种日常、复现现有基线 |
| M | 10,000 | 120 | 200 | 十年数据、CNY/USD/HKD、退款/转账/标签、余额断言 |
| L | 100,000 | 1,200 | 1,000 | 深账户树、价格历史、持仓 cost lots、允许的插件 |

另对 M 加 0/64/128 MiB 不透明合成附件，隔离“交易数”与“目录复制大小”。所有通过型数据必须含目录、元数据、Git fixture 后仍低于 256 MiB/10,000 entries/深度 32；边界用例独立测试刚好上限与超过上限。不得为了跑 L 自动提高产品上限。每套输出 manifest：seed、源码 bytes、文件数、交易/posting 数、校验结果、预期财务摘要。

用 canonical loader 验证 fixture，并核对固定余额/收支/持仓 golden；Go 轻量 parser 不能当 correctness oracle。

### 必测路径

- 冷进程 + 无展示缓存；冷进程 + 有展示缓存；热引擎 + 同 revision；新 revision 首读；A/B 账本切换。
- 首页、月/年报、交易首屏/搜索/账户过滤、账户明细、复杂投资、BQL 聚合/排序/LIMIT。
- 一笔 add/edit/delete；200 笔标签操作；1,000 行账单解析/去重/预览/确认；预览后发生其他提交。
- 1/4/8 个并发读取；连续 20 次搜索（每 100ms）、日期切换；读 + 写 + Widget 构建 + 可选 Git 测试 remote。
- 冷加载/写入期间取消、锁屏、切账本；无效语法、插件不允许、越界 include、symlink、同大小同 mtime 内容变化。
- 持久化故障点：复制、校验、fsync、generation rename、current.json publish；失败后重开，只能见完整旧版或完整新版。
- 30 分钟往返页面 + 100 次合成提交，记录内存、stage 清理、历史 generation 和逻辑/实际磁盘增长。历史保留增长不误报为内存泄漏；容量不足必须提前报错且旧版可用。
- Git 断网/凭据失败/冲突不能阻塞本地提交；只用一次性本地 fixture/测试 remote，不请求生产凭据。

### 测量方法

- Apple 官方 `OSSignposter` + XCTest clock/CPU/memory/storage/signpost metrics；Time Profiler、Allocations、File Activity 检查。Go 使用 testing.B、benchmem、pprof。不另造监控服务。
- 分段：queue wait、snapshot acquisition、Python init/preflight/booking/serialization、Swift encode、Go decode/source scan/model/query/encode、Swift decode、copy/diff/fsync/publish、Widget build。跨语言父区间和子区间不得相加重复计时。
- 日志只存匿名 fixture ID、revision、请求类别、字节/次数/时长，不存金额、内容、真实路径或凭据。
- 真机建议验收设备 iPhone 13（A15/4GB）或同档更低支持设备；快机作对照。确切可用设备由实施前确认；没有真机不能通过设备 SLO。Release 优化 app-host，固定 OS/build，热状态 nominal，低电量模式关闭；记录电池/温度、是否调试器连接。
- 冷路径每 fixture 30 次独立重启，报告 p50/p95/max；热路径预热 3 次后采集 100 次单次延迟，分三轮。冷进程不等于 OS 磁盘缓存被清空；不得把普通 relaunch 标成物理冷盘。
- Swift auth 等待从账本 kernel 指标中扣除，但冷启动外壳/解锁耗时单列。保存从用户确认到 durable publish；预览和保存分开计，另报总和。
- CPU/内存 profile 另跑，避免重型 profiler 扭曲 SLO；同机同构建配置比较优化前后。快速 Go 基准串行重复 10 次确认回归，不能从不同机器的 ns/op 算提升。

## 5. 建议验收指标（产品目标，不是已达到的结果）

> 用户反馈（2026-09-21T15:21:12.824349+08:00）：目标性能要求过低。以下预算未获批准，撤回作为推荐验收线，仅保留讨论历史。当时只有 1,000 笔 Mac Go 局部基准；后续第 7 节补测不等于真机验收，不能用主机/模拟器毫秒数外推真机体验。

以下是基准真机 Release 的首轮性能预算；p95 口径如上，不包括用户认证等待或网络同步。L 是大账本容量目标，M 是主要发布验收集。

| 场景 | M：10k | L：100k |
|---|---:|---:|
| 无展示缓存：已授权到正确首页可交互 | ≤2.0s | ≤6.0s |
| 有有效展示缓存：已授权到首页可交互 | ≤300ms | ≤500ms |
| 热页面/日期切换，含 Swift bridge 与解码 | ≤150ms | ≤400ms |
| 热搜索/账户过滤，输入稳定后到正确结果 | ≤150ms | ≤400ms |
| 单笔预览 | ≤1.0s | ≤3.0s |
| 单笔确认到 durable publish | ≤1.0s | ≤3.0s |
| 已解析 1,000 行导入：去重+预览 / 确认 | ≤5s / ≤3s | ≤12s / ≤8s |
| Widget 所需本地数据构建，不含系统调度等待 | ≤1.0s | ≤3.0s |
| 主进程读路径峰值 physical footprint | ≤250 MiB | ≤450 MiB |
| 主进程写入/导入峰值 physical footprint | ≤350 MiB | ≤600 MiB |

- 100ms 内提供忙碌/取消反馈；不允许账本任务导致主线程连续阻塞 >100ms。列表滚动 hitch time ratio <1%（固定 60Hz 场景），不可将后台安全保存强行塞进每帧预算。
- 预热稳定后，30 分钟场景结束静置 30s，footprint 相对起点增量 ≤max(20 MiB, 10%)，并检查对象/模型是否滞留；单纯一次 RSS 波动不判定泄漏。
- 正确性、数据隔离、失败恢复 100% 通过，损坏/丢失/半提交/锁屏泄露零容忍。崩溃/OOM 零次只是本测试集门槛，不是统计可靠性保证。
- 正式优化声称改善的目标路径须较同机基线降低 p95 至少 20% 或分配量至少 30%；其他核心路径不允许稳定回归 >10%。已满足预算且低占比路径停止优化，不凑加速百分比。
- 10× 数据增长不应无解释地超过 15× 冷模型构建时间；热、固定返回量查询目标 ≤3×。超限用 profile 判明扫描、结果规模还是 I/O，不能直接提高门槛。
- 上述内存是工程预算，不是 iOS 保证的 jetsam 上限。先记录真实峰值再评估是否需要调整范围；任何改预算必须写明证据并重新确认。

## 6. 推荐落地：独立可合并工作包

### A. 可观测性与可复现性能门禁（最小可选交付，约 2–3 工程日）

修复现有 portable test target 编译阻塞（先定位符号定义/Package.swift 边界，保持测试覆盖）；新增 fixture generator/manifest、分段计数和 app-host 性能测试。扩展现有 Go benchmark 的数据规模、冷/热状态与 mobilecore JSON 入口，不用只有 Go handler 的结果替代端到端。

文件目标：现有 `server/internal/app/local_performance_test.go`、`server/mobilecore/dispatch_test.go`、`App/LedgerMobile/Package.swift`/受影响测试、Swift engine/validator/workspace 埋点；新增 `App/LedgerMobile/Tests/LocalLedgerPerformanceTests.swift`、`App/LedgerMobile/UITests/LocalLedgerPerformanceUITests.swift` 与 `scripts/generate-ios-performance-fixtures.py`。新增路径是计划，当前不存在。

交付：S/M/L manifest、原始逐次指标和摘要、可重复命令、baseline artifact；轻量 Go correctness/benchmark smoke 可进 CI，真机 SLO 在固定设备跑，不给共享 runner 设绝对真机毫秒门槛。即使后续不做，A 本身可用且可合并。

### B. 去掉纯浪费，不改变验证语义（约 2–3 工程日）

1. Python/C/Swift 增加 validation-only 路径：仍执行同一预检、booking、插件和 HARDCORE_VALIDATIONS，仅在调用方不要读模型时不构造/传输 canonical JSON。保留现有 canonicalModel 契约；旧入口兼容。
2. Swift response envelope 直接 decode typed `result`，避免成功响应 JSONSerialization 解包再编码；保留错误状态、诊断、整数精度/Decimal 表示回归。
3. 不合并改变中间账务状态的 stage 操作，不复用 mutable stage 模型，不去掉确认时校验。

目标文件：`Runtime/ledger_validator.py`、`Runtime/BeancountRuntime.{c,h}`、`Sources/EmbeddedBeancountValidator.swift`、`LocalLedgerEngine.swift`、`LocalLedgerRepository.swift` 与相应 tests。先选 1 再选 2，可各自独立合并。要求减少不必要 canonical 输出/JSON pass 的结构计数，并满足对应预算/改善门槛。

### C. 已提交模型只跨桥注册一次（约 3–5 工程日，有条件启用）

仅当 A 显示 bridge/canonical 序列化占目标路径 ≥20% 或该路径不达标时实施。增加 process-local model handle：注册包含 workspace、entrypoint、源码版本和 canonical；后续请求携带 opaque handle，Go 复用 immutable model 和 canonical hash。原 JSON 请求协议仍支持，handle miss/淘汰时重注册，不静默返回空数据；staging 永远走原路径。限制为一个最近模型，与现有缓存规模一致；请求中持有引用，淘汰不破坏进行中请求。

关键安全选择：**第一版保留每次路径检查及源码内容校验，不把 UUID、mtime 或 generations 目录名当安全证明。** 保留同大小同 mtime 改动、缺失 include、symlink、canonical 改动失效测试。源码变化对旧 handle 返回 stale-model，Swift 清除缓存并重新 canonical load；账本切换/显式锁定清理可复用 handle。这样桥接优化不依赖“永远无人修改目录”这一脆弱前提。

修改内部 mobilecore 请求 envelope/操作类型（register/request/release），无公共服务器 API、磁盘 schema 或账本格式变化；校验未知 handle、跨 workspace 引用、退出重启后的旧 handle。保留旧路径便于直接回退。

### D. 查询范围及后台重复工作（约 2–3 工程日，profile 驱动）

复用已有排序 snapshot，对半开日期区间二分切片；保留多币种、余额/净资产所需的期初历史，不把所有报表简单截断到当期。只在测得重复聚合主导时增加同 revision+range+valuationCurrency 的有界派生缓存；优先固定 8 项/32 MiB 上限，并通过 L footprint 验证。

Widget 保留最终 revision 检查，把同批次需要的区间聚合放在一次 pinned snapshot 中，前台请求优先；不能仅用更多 async task 增加共享 actor/GIL 争用。过期搜索不发布结果，若没有可协作取消的底层入口，不承诺正在执行的 Python/C 会即时中断。

目标：`ledger_read_service.go`、`cache.go`、`LocalLedgerWidgetPublisher.swift`、必要的 transport 操作及 tests。BQL 任意大排序/聚合不承诺常数时间，单独报告与限制。

### E. 文件复制和历史容量（单独后续决策，不纳入首轮必须实现）

如果 copy/diff/fsync 占写入 ≥30% 或附件数据达不到保存预算，再提交一个窄的 APFS clone-copy 方案：只对受控 regular file 使用系统 clone API，失败退回现有 secure copy；保留 source identity、no-follow、权限/保护等级、执行位和 fsync/原子发布。不得使用 hard link 共享可变 stage。

首轮不删历史 revision、不改变保留策略、不省略 fsync、不跨预览/确认保留可被改写的 stage。历史保留的空间增长真实存在；需要 GC 时另获授权，明确读者 pin、回滚窗口和备份后单独设计。当前容量压测必须能给出可解释增长与空间不足错误。

## 7. 风险、被拒绝方案、停止条件

- 最脆弱前提：重复处理是用户可见慢路径的主要贡献。Mac 数据仅支持 Go 分配方面；若真机主要耗时在 canonical booking，则 C/D 不实施，优先 B 和减少不必要调用，仍不跳过最终校验。
- 不推荐此时 SQLite 持久化读模型：增加 schema、失效/迁移和双真相成本；没有证据表明现有内存读模型已到极限。未来如 L 仍不达标再单独评估。
- 不推荐重写 Python/Swift/Rust parser、任意插件增量验证、全局增加并发：账务语义/插件依赖和 GIL/锁风险大。没有官方可直接替代 canonical booking 的捷径。
- 网络故障：本地操作不依赖同步；测试基线先排除网络，竞争测试另算。
- 10× 放大：跨桥全模型、日期扫描、整树复制和历史保留会先扩大；分别记录维度，不只报总耗时。
- 回滚：A–D 不变更账本或 generation 磁盘格式，旧读写路径保留；可回退代码与匹配的三个 native frameworks，不修改用户数据。不把移除历史数据当性能回滚手段。
- Apple 原生方案已核查：OSSignposter iOS 15+ 可用，当前最低 iOS 17；XCTest 有 clock/CPU/memory/storage/signpost/hitch/launch metrics。无需新增 SaaS、API key 或 token。物理设备测试需现有本地开发签名；工具存在不代表设备授权已验证。
- 实施前唯一设备执行条件：提供/选择合成测试专用基准真机及签名访问。没有时 A 的主机/模拟器部分可交付，设备 SLO 保持未验收，而不是冒称完成。

## 8. 验证及交付

本轮实际运行命令：

```sh
(cd server && go test ./internal/app -run '^$' -bench '^BenchmarkLocalPageLoad$' -benchmem -benchtime=1s -count=5)
(cd server && go test ./internal/app -run '^(TestLocalPageCache|TestLocalConfig|TestLocalTree)' -count=1)
(cd server && go test ./internal/ledgercore ./mobilecore)
(cd App/LedgerMobile && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter LocalLedgerPresentationCacheTests)
```

实施验证：先恢复 Swift tests，再跑 `swift test`；Python validator tests 按 runtime 同版本环境运行；改 Go 后从 `server/` 跑 `go test ./...`、`go build -o /tmp/ledger-web-perf-check ./cmd/ledger-web`；修改 bridge/runtime 后重建 `scripts/build-ledgercore-xcframework.sh`、`scripts/build-beancount-ios.sh`，按 `App/LedgerMobile/README.md` 生成项目并运行 app-host integration tests、workspace/engine/cache/plugin/import 回归和新性能测试。仅文档任务不需要 Web typecheck/build。

每个实现 PR 附 baseline/after 同 fixture 同设备结果、正确性验证、峰值内存、未测试范围。独立 PR 逐个合并；确实依赖的改动按项目规则用 Graphite stacked PR，不在未检查 CLI 可用性前依赖它执行。补测测试基础设施按正常 PR/mergeability/conflict 流程交付；最新提交与 PR 状态见任务 handoff。

建议本次批准 **A+B** 为首轮，C/D 按上面的客观门槛启用，E 另行批准。预估 A+B 4–6 工程日，不含设备排队/签名问题；不要把整个后续路线当已经批准的大重构。

官方参考：
- https://developer.apple.com/documentation/xctest/performance-tests
- https://developer.apple.com/documentation/os/ossignposter


## 7. 补测 baseline（2026-09-21）：不是优化后结果

环境：Apple M5、macOS 27.0 (26A428)、Xcode 27.0 beta (27A5252f)、Go 1.27.1、Beancount 3.2.3；模拟器 Release + ENABLE_TESTABILITY=YES，内嵌 Python 3.14。源码基线 `1e3c9aa`，仅新增测试/target-membership 修正，没有产品算法改动。host Python 分解使用另一主机解释器，不能从模拟器总耗时中相减。最终测量串行执行，不与编译并行；初期并行编译中的探索样本弃用。

### 可公开的合成规模结果

10k fixture：10,000 笔、120 个显式 include、2 个账户、CNY、2 postings/笔；不是第 4 节尚未实施的复杂 M fixture。canonical 3,325,886 bytes。原始 wildcard fixture 读路径可用、预览失败，原因是当前 writer 的 ReadLedgerLines 不展开 glob；改为显式 include 并声明 CNY 后全流程通过，没有更改产品 parser/writer。

| 10k 模拟器路径 | n | p50 ms | 样本 p95 ms |
|---|---:|---:|---:|
| `canonical_warm_interpreter_full_load` | 10 | 634.26 | 720.12 |
| `repository_bootstrap_presentation_hit` | 30 | 25.83 | 27.23 |
| `engine_bootstrap_hot_no_presentation` | 20 | 111.98 | 120.78 |
| `repository_dashboard_hot` | 30 | 84.24 | 96.64 |
| `repository_income_statement_hot` | 30 | 82.12 | 91.31 |
| `repository_investments_hot` | 30 | 81.34 | 89.11 |
| `repository_all_transactions_hot` | 10 | 391.42 | 417.19 |
| `repository_bql_aggregate_hot` | 10 | 101.44 | 105.08 |
| `single_transaction_preview` | 10 | 2250.44 | 2921.28 |
| `single_transaction_confirm_durable` | 10 | 1203.73 | 1520.16 |
| `repository_bootstrap_after_commit` | 10 | 1362.59 | 1596.96 |

独立单样本：首次 canonical 1,016.92 ms、导入账本目录 759.87 ms、首次 repository bootstrap 1,111.18 ms，不能称为可靠 p95。1/4/8 reader dashboard 批次（各 n=5）中位耗时 88.90/303.63/607.22 ms；它们是批次总时长。最大阶段后 footprint 824.99 MiB，不是峰值、不是 iPhone 内存上限。

10k 主机 Go（n=30）：direct transport / JSON bridge 中位耗时 bootstrap 42.53/62.42 ms、dashboard 24.09/42.34 ms、income statement 22.52/40.65 ms、investments 21.39/39.53 ms、transactions 37.24/56.73 ms。JSON bridge 累积分配约 92–116 MB/op；包含响应验证，不是驻留内存。这是同机两条调用入口的差别，不能把差值解释为整个 Swift bridge 或优化收益。

100k fixture：100,000 笔、1,200 includes、canonical **33,347,008 bytes**。完整 host canonical load 中位 10,572.09 ms（n=3），但 mobilecore 实际返回 **`request.too_large`**：请求与响应分别受 16 MiB 上限约束。此结果是容量失败，不是“100k 只是慢”。未提高上限、未虚构 100k UI/写入延迟；不建议在解决传输表示与内存之前直接提高限制。

### 结论与范围

- 1k Go handler 的几毫秒不能代表用户操作。本轮全链路证明，10k 单笔 preview 已约 2.25s、confirm 约 1.20s，且确认后的首次 bootstrap 另需约 1.36s；各阶段统计不可直接加成端到端 p95。
- 热 presentation cache 有价值，但其他查询仍有全量 canonical/source/JSON 工作；JSON 分配、重复 canonical 校验、stage 复制应优先剖析。没有通过减少校验来换速度。
- 100k 的第一问题是桥接容量；后续优化方案需包含句柄/分块/按需数据边界设计及失效语义，而不是只调毫秒目标。仍需另行批准，不能把 baseline 授权解释为架构重写授权。
- 已验证十次 preview/confirm/read 周期以及无效 stage 不发布。没有跑完整 30 分钟 soak、bill import、Widget 竞争、真实 UI、真机热状态/内存或故障矩阵；第 5 节旧预算仍撤回，不宣称设备目标达成。
- 通用测试与 fixture 可公开；私有来源的原始数据、数量、timing/size 派生指标及路径不进入仓库。相关隔离数据在验证原始 source hash 未变化后清理，仅在本地 checkpoint 保留数字摘要。

复现、安全边界与样本口径：`docs/ios-performance-baseline.md`。下一步是批准基于这些瓶颈的优化工作包，并选定真机验收设备；不是继续盲目增加基准次数。
