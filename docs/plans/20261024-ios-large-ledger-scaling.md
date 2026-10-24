# iOS 大账本扩展方案：从“按 10 万笔建”到“按改动量付费”

- 任务 `20261024-ios-large-ledger-scaling`；方案已定稿，2026-10-24。第一阶段 6 项已实现、通过集成验证并全部合入 `main`（PR #541–#546，文档 #540，前置修复 #547）；交付记录见文末。
- 基线：`main` @ `e4de9be`。
- 前置文档：`docs/plans/20260923-ios-100k-no-db.md`、`docs/handoffs/20260923-ios-100k-no-db.md`、`docs/handoffs/20261019-ios-model-gate-and-cache.md`。

## 结论

推荐路线：**先砍掉写路径里一半“不是 beancount 本身”的开销，再把每次写从“全量重算”改成“按改动量付费”**。`.bean` 始终是权威源，完整 canonical 校验和显式失败语义不动。

- 之前的容量分析大方向成立（内存和写延迟是第一约束），但有三处要纠正：深翻页不是 O(N²)；generation 走 APFS 克隆，磁盘不会“写 100 次涨 1GB”；100k 时一次写的耗时**不是** booking 主导。
- 本机按真实导出器和真实 Go 注册路径复现了 100k：一次“预览+提交”里，beancount 的 parse/booking/plugins/validate 只占约 46%，其余 54% 是我们自己的代码（预检重复解析整本账、Python 流导出、Go 注册做两遍）。这部分可以不改语义直接优化，预计写延迟减半。
- “持久化 booked 模型”只能解决冷启动和常驻内存，**解决不了写入延迟**：新内容总得重新校验。真正让写入不随账本线性变长的，是“已关账期检查点 + 尾部校验”。它可行的前提是本地插件是封闭白名单（12 个），可以逐个证明局部性。这一步改变校验语义，需要单独拍板。
- 不建议：用 Go/Swift 重写 booking 替代 Python、把 SQLite 当权威源、放宽 64MiB/256MiB 上限、跳过或延后校验。
- 前三个阶段都不引入数据库。数据库推迟而非排除：第二阶段二进制快照完成后，如果 200k 真机内存仍超标，再评估 SQLite 作为可删除、可从 `.bean` 重建的派生索引。

## 对原分析的核实

硬上限和内存判断都对得上代码；翻页、磁盘、写入瓶颈三处结论需要改。

| 原说法 | 核实结果 | 依据 |
| --- | --- | --- |
| 源码 ≤4096 文件 / 单文件 8MiB / 合计 64MiB | 成立 | `server/internal/app/local_transport.go:548-585` |
| 规范流单记录 1MiB、总 256MiB | 成立 | `App/LedgerMobile/Runtime/ledger_validator.py:165-166`、`server/internal/app/local_canonical_stream.go:13-14` |
| LRU 4 个、预算 384MiB、按“流×3”估算 | 成立，且估算确实偏低：本机 100k 流 47MB，实际活堆 237–365MB（5–8×） | `server/internal/app/local_model_handle.go:36-41,179` |
| Go 堆约 3.1KB/笔 | 成立。原生分页路径 2.4KB/笔；走旧的 `/api/ledger/transactions` 会物化编辑草稿，到 3.6KB/笔 | 本机实测 |
| 没有数据库 | 成立；架构文档把 SQLite 定义为“派生、可重建”的未来工作 | `docs/ios-local-first-ledger.md` |
| booking 全局串行，按文件切分被实测否定 | 成立 | `docs/handoffs/20261019-ios-model-gate-and-cache.md` |
| **深翻页 O(offset)，全量遍历 O(N²)** | **不成立**。cursor 的 offset 是已排序索引的下标，循环直接从 offset 开始，是 O(1) 定位。全量遍历 26 秒是 100 个窗口 × 每窗的 JSON 编解码，线性。真正的 O(前缀) 只有两处：窄日期范围的首页要跳过所有更新的行；Swift 侧从锚点回放（向回导航）从头重放 | `server/internal/app/local_transaction_page.go:155-175`、`App/LedgerMobile/Sources/LocalTransactionWindow.swift:69-71` |
| **每次提交完整拷贝工作区，写 100 次 1GB** | **不成立**。staging 用 `fclonefileat` 做 APFS 写时复制，物理增量只有被改的文件。按月分文件的布局下每次几十 KB；只有单个大文件账本才接近原说法 | `App/LedgerMobile/Sources/LocalLedgerWorkspace.swift:1245-1262` |
| **写一笔的代价约等于一次完整解析（booking 主导）** | **部分成立**。一次写 = 预览时一遍 Python + 两遍 Go 注册（stage 一次、新 generation 一次）。100k 时 beancount 内核只占 46%，见下节 | `App/LedgerMobile/Sources/LocalLedgerEngine.swift:283-380` + 本机实测 |
| “0.28ms/笔” | 与 20k=770ms（0.04ms/笔）对不上；更像是 100k 导入总时长整体除以笔数 | handoff 对比 |
| Git 同步每次推 10MB | 未核实。提交时会读取并哈希整棵树（CPU 随账本增长），但 git 推送通常只带新对象，需要实测 | `App/LedgerMobile/Sources/GitLocalStorage.swift:266-300` |
| 真机 100k 无验收数据 | 成立。另外代码里没有内存告警处理、没有 `phys_footprint` 采集、没有 increased-memory-limit entitlement、Go 侧没有设 GOMEMLIMIT | 全仓库检索 |

## 本机 100k 实测：一次写入的时间花在哪

一次“预览+提交”约 40 秒（本机），其中 beancount 内核 18.6 秒，其余 21.8 秒是我们自己的开销。

做法：生成 100,591 条指令的合成账本（20 年、240 个月文件、中文 payee、metadata、tag、外汇、带 FIFO 成本批次的股票买卖、`auto_accounts` 插件），用仓库里的 `ledger_validator.py` + beancount 3.2.3 导出真实规范流（47MB），再走真实的 `RegisterLocalModel` 和原生 `/api/ledger/transactions/page`。机器是 4 核 x86 云容器，绝对值大约是 M 系芯片模拟器的 3 倍，**只看比例**。

| 环节 | 耗时 | 占比 | 是否 beancount 语义 |
| --- | --- | --- | --- |
| beancount 加载（parse 4.9 / booking 9.6 / plugins 1.7 / validate 1.8） | 18.6s | 46% | 是，权威，不动 |
| Go 导入规范流（JSON 逐行解码）× 2 次 | 7.8s | 19% | 否 |
| Python 写规范流（逐字段预算检查 + json + SHA-256） | 6.2s | 15% | 否 |
| Go 建快照（交易视图、排序、余额）× 2 次 | 4.2s | 10% | 否 |
| `_preflight` 先把每个文件完整 parse 一遍查插件/include | 3.6s | 9% | 否（安全门，但重复解析） |

另外三个数：

- booking 有超线性：20k→100k 笔数 ×5，booking ×8.3；去掉成本批次后 100k 只要 6.0s。持仓批次越多，FIFO 匹配越慢。
- 内存峰值叠加：Python 加载后 RSS 312MB；Go 活堆 237MB，但 Go 向系统要了 531MB（没设 GOMEMLIMIT，默认按 2× 活堆增长）；一次注册累计分配 2.5GB。预览时 stage 模型和已提交模型同时在堆上，再叠一个 Python 对象图，粗算 1GB 以上，这就是 jetsam 风险点。
- 这个拆分和模拟器已有数字一致：handoff 里 100k 预览 25–42s、提交 15–23s。提交阶段规范流缓存命中、不跑 Python，所以提交的 15–23 秒基本都是 Go 重新导入和建快照。

重现脚本未入仓；第一阶段第一项会把它做成可选的基准测试。

## 候选方向对比

只有“检查点 + 尾部校验”能让写入不随账本变长，其它都是常数倍或只管读。

| 方向 | 冷启动 | 写延迟 | 峰值内存 | 工作量 | 对权威语义的风险 | 判断 |
| --- | --- | --- | --- | --- | --- | --- |
| 砸掉非 beancount 开销（单次解析、流导出提速、Go 只注册一次） | 小幅 | 约 −2 倍 | 小幅 | 小–中 | 低，用对照测试锁住 | **先做** |
| 内存核算改实测 + GOMEMLIMIT + 内存告警驱逐 | — | — | 明显 | 小 | 无 | **先做** |
| 二进制规范快照缓存（替代 NDJSON，可后续 mmap） | 大幅 | 小幅 | 中，mmap 后大幅 | 中 | 低，纯派生数据，校验和失效不变 | 第二步 |
| 写队列 + 批量校验 + “保存中”乐观行 | — | 体感大幅，连续记 N 笔只校验 1 次 | — | 中 | 低：未通过校验的不发布 | 第三步 |
| 已关账期检查点 + 尾部校验（增量 booking） | 大幅 | **O(改动期间)** | 大幅（Python 不再装全历史） | 大 | 中：需证明 12 个白名单插件和内置校验的局部性，用对照模糊测试门控 | 第四步，需拍板 |
| SQLite 派生索引 | 中 | 无帮助 | 中 | 大：Go 读服务、BQL 都是内存模型，要重写 | 低（只要不当权威） | 暂缓，二进制快照做完再看 |
| keyset 游标 | — | — | — | 小 | 无 | 不需要；只给日期范围加二分定位 |
| generation 保留策略 | — | — | — | 小 | 要和同步 merge base、备份引用协调 | 低优先，先实测物理占用 |
| Go/Swift 原生 booking 替代 Python | 大幅 | 大幅 | 大幅 | 很大 | **高**：FIFO/LIFO/AVERAGE/STRICT、插值、容差、插件全要等价重写，等于维护第二个 beancount | 不建议 |
| 放宽 64MiB/256MiB，或延后/跳过校验 | — | — | 变差 | 小 | **高**，破坏显式失败 | 不做 |

检查点方案为什么可行：`_preflight` 只允许 12 个内置插件（auto_accounts、check_closing、check_drained、close_tree、coherent_cost、implicit_prices、leafonly、noduplicates、nounused、onecommodity、sellgains、unique_prices），不允许 `insert_pythonpath`。每个插件依赖的全局状态都能列得出：账户集合、每个账户的币种集合、带成本日期和标签的持仓批次、条目哈希集合、已使用账户集合。把这些状态在“关账日”快照下来，就能只对关账日之后的条目跑 booking/插件/校验。任何改到关账日之前的写、改 option/插件列表、检查点和源哈希对不上，都回退到今天的全量校验。

## 分阶段路线

四个阶段，每段都有独立收益和验收门，前一段不达标不进下一段。

| 阶段 | 内容 | 预期收益（100k） | 进入下一段的门 |
| --- | --- | --- | --- |
| 1. 测量 + 去重复开销 | 下面 6 个小改动 | 写延迟约减半；内存预算不再低估；Go 峰值占用下降 | 真机拿到各阶段耗时和 phys_footprint 峰值 |
| 2. 二进制规范快照 | 用带版本和校验和的紧凑二进制格式替代 NDJSON 缓存，Go 直接还原模型；账户名/币种字符串驻留（intern） | 冷启动和提交阶段的导入从秒级降到亚秒；活堆减少 | 冷启首屏和内存达标后，再决定是否 mmap/SQLite |
| 3. 写队列 + 批量校验 | 连续录入时先显示“保存中”，多笔合并成一次 staging + 一次全量校验；失败时二分定位是哪一笔，明确报错、不发布 | 记 10 笔只付 1 次校验，交互不再被卡住 | 确认交互可接受 |
| 4. 关账期检查点 | 见上节；先做对照模糊测试：随机账本 × 随机写，检查点校验和全量校验的错误集合、booked 尾部条目必须完全一致 | 写入只和当前期间大小有关，与历史长度无关 | 模糊测试持续零差异 |

### 第一阶段候选小改动

每项一个独立 PR，都不改变校验结果，都能单独回滚。

- [x] **容量基准入仓**：把合成账本生成器和分段计时做成 opt-in 的 Go/Python 基准；App 内用 os_signpost 记录 parse/booking/导出/注册/快照各段，并记录 phys_footprint 峰值。以后每一步都用它做前后对比。风险：无。
- [x] **内存核算改实测**：`localModelEstimateFactor` 从 3 改到实测系数（先取 6，等真机数据校准）；mobilecore 启动时按可用内存设 Go 软上限 `debug.SetMemoryLimit`；收到内存告警时释放非当前账本的模型。风险：低，软上限设太紧会频繁 GC，用基准挑值。
- [x] **预检不再重复解析**：`_preflight` 现在对每个文件调 `parser.parse_file`，紧接着 loader 又解析一遍。改为只按行扫描 include/plugin/option/document 指令做策略检查，或复用一次解析结果。前提：确认 Go 侧 include 走查已经在 Python 之前做了同样的路径约束。用对照测试保证放行/拒绝结果不变。收益约 9%。风险：低到中，这是安全门，要单独评审。
- [x] **流导出提速**：`_check_export_value` 的递归 isinstance 和逐记录 `json.dumps` 占导出大头，改成一次编码后按字节数判界。输出必须逐字节不变（SHA-256 一致即可验证）。收益约 7%。风险：低。
- [x] **只做一次 Go 注册**：预览时已有的 stage 模型在发布后直接升为已提交模型，不再从同一份流重新导入。难点是模型里的源路径是 stage 的绝对路径，需要改为相对路径存储。收益约 15%，提交阶段收益最大。风险：中低，放在本阶段最后。
- [x] **日期范围二分定位**：分页时在已排序索引上二分到 end 日期，不再从头跳过更新的行；游标格式不变。风险：低。

## 风险与迁移方式

迁移原则只有一条：新加的东西全是从 `.bean` 派生、可以删掉重建的缓存，删掉后行为就是今天的行为。

- **权威源不变**：账本仍是 generation 里的 `.bean`，不引入数据库状态。二进制快照和检查点都以源版本（sourceVersion）+ 运行时版本 + 格式版本为键，任一不匹配就丢弃重算，和现有 `LocalCanonicalStreamCache` 的失效方式一致。旧版本 App 打开新数据只会看到一个不认识的缓存文件，忽略即可。
- **校验语义不变**：第 1–3 阶段每次发布前仍然是完整 `_uncached_load_file` 级别的校验。第 4 阶段只在“证明等价”的子集里走检查点，其它情况回退全量；测试和可选的空闲时后台全量复核作为第二道保险。复核发现差异就永久关闭该账本的检查点并报错，不静默修正。
- **显式失败不变**：413、不返回部分合计、上限不放宽。写队列里未通过校验的条目只显示为“未保存”，不进入任何合计。

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| 依赖 beancount 内部接口（预检复用解析、检查点） | 升级 beancount 时行为漂移 | 版本锁在 3.2.3；对照测试放进 CI，升级必须重跑 |
| GOMEMLIMIT 设置不当 | GC 颠簸、变慢 | 只设软上限，用基准和真机峰值挑值 |
| 检查点漏掉某个全局依赖 | 接受了全量校验会拒绝的写 | 插件白名单之外一律不启用；模糊对照门控；后台全量复核 |
| 批量校验里一笔出错 | 一批都未发布 | 二分定位到具体条目，其余条目重新校验后发布 |
| 真机数字和本机比例不同 | 优先级排错 | 第一项就是把分段计时做进 App，先拿真机数再调整顺序 |

## 真机验收需要的数据

决定成败的是一个数：**预览阶段的 phys_footprint 峰值**，其余用来排优先级。每项在 10k / 50k / 100k / 200k 四档、Release 包、至少两台不同内存的 iPhone 上各测，配对前后对比 20 轮。

| 数据 | 怎么采 | 用来决定什么 |
| --- | --- | --- |
| 导入、预览、提交时的 phys_footprint 峰值和 `os_proc_available_memory` 余量 | task_info 采样 + Instruments | 100k/200k 能否长期用；是否要申请 increased-memory-limit；GOMEMLIMIT 取值 |
| 写入分段耗时：preflight / parse / booking / plugins / validate / 流导出 / Go 导入 / 快照 | os_signpost（第一阶段第一项） | 校准本文的比例，确认阶段顺序 |
| 冷启首屏（流缓存命中 / 未命中） | signpost | 第二阶段的收益 |
| 连续 100 次提交的耗时曲线和物理磁盘增量 | statfs 可用空间差（du 会把克隆算重复） | 是否需要 generation 保留策略 |
| 30 分钟混合读写的崩溃/jetsam 次数 | 设备日志 JetsamEvent | 验收本身 |
| Git 同步一次写的上传字节数 | 传输层计数 | 核实“每次推 10MB”是否存在 |
| 真实账本的笔数、文件数、持仓批次数、每年增长 | 一次性统计 | 目标体量，以及 booking 超线性是不是真问题 |

## 待决定

1. **目标体量**：真实账本现在多少笔、每年增长多少？个人账本每年通常 2k–5k 笔，100k 相当于 20 年以上。如果目标是“10 年内不超过 100k”，第 1–3 阶段就够，第 4 阶段可以不做。
2. **第一阶段开工**：已执行，6 项全部合入 `main`（见文末交付记录）。
3. **写队列的交互**（第三阶段）：是否接受“保存中”的临时行，以及批量里一笔出错时整批暂不发布。
4. **检查点方案**（第四阶段）：是否接受“在证明等价的子集内不再跑全量 beancount”这一语义变化。这是唯一会碰到“每次写都完整校验”这条规则的一步。

## 第二阶段开工门（2026-10-24 决定）

维护者决定：**先采真机数据，再开第二阶段**；第二阶段编码器由 **Go 侧自研**，Swift 只存文件、不解码。

为此先落地三项测量基础设施（各自独立 PR）：

| 项 | 内容 | 分支 |
| --- | --- | --- |
| 录制 | App 内 opt-in 录制，把 signpost 区间聚合成 JSON 并按轮写出，经系统分享导出 | `codex/ios-perf-recording` |
| 协议 | `docs/ios-large-ledger-measurement-protocol.md` + 合成档位 manifest / `verify` / `assemble` / `record` | `codex/ios-perf-protocol` |
| 设计 | `docs/plans/20261025-ios-binary-canonical-snapshot.md`（含尺寸推导与待决定项） | `codex/ios-snapshot-design` |

进入第二阶段实现的条件（缺一不可）：

1. 真机 10k/50k/100k 三档、Release 包、至少一台设备的冷启动首屏与 `phys_footprint` 峰值已采集，且录制 JSON 与档位 `sourceTreeSha256` 对得上。
2. 第一阶段的目标（100k 可用、写入约减半）在真机上未被推翻；若推翻了，先回到第一阶段继续修，不进入第二阶段。
3. 第二阶段设计文档中的待决定项（尤其"整数元数据是否还原 `int`"与"`estimate` 系数如何随格式调整"）已拍板。

实现阶段必须先处理的一条硬约束：`localModelEstimateFactor` 是按"打开的文件大小"标定的，换成二进制后同一账本的字节数会缩小约 6.8 倍；**格式切换必须同时重新标定 estimate**，否则 LRU 预算会失效。

## 第一阶段交付记录（2026-10-24）

6 项各自一个独立分支/PR，基线 `main` @ `150b552`；每项都未改 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`，未加依赖，未改校验结果、错误文案或 64MiB/256MiB/1MiB 上限。

| 项 | 分支 / HEAD | 主要改动 | 本机验证数字（宿主，非真机） |
| --- | --- | --- | --- |
| ① 基准与分段计时 | `codex/ios-ledger-perf-baseline` @ `5c36c52` | opt-in 生成器/基准（`scripts/large_ledger_bench.py`、`BenchmarkLocalScaleStages`）、App signpost + phys_footprint、Python 可选 `log_timings` | 100k 导出 9.34s（loader 6.85s，booking 4.41s）；Go 导入 723ms、注册 705ms、首屏 1.65s、活堆 361MiB |
| ② 内存核算 | `codex/ios-model-memory-accounting` @ `cf763ca` | estimate 3→6、`debug.SetMemoryLimit`（可用内存一半，clamp 512MiB–1GiB）、内存告警原子裁剪空闲模型 | 单 100k 模型 ~282MiB 仍驻留、第二个被预算挤出；告警不动 staged/在途模型 |
| ③ 预检去重 | `codex/ios-preflight-scan` @ `d4f96b6` | 无策略关键字文件跳过 `parser.parse_file`，loader 成为唯一解析方；命中关键字仍走原检查（fail-closed） | `_preflight` 0.639s→0.039s/100k；流 SHA-256 不变 |
| ④ 流导出提速 | `codex/ios-export-encode-once` @ `2edc7b5` | 预算检查改为直接检查原始 entry/posting 字段，保留投影前拒绝与编码长度兜底 | 预算检查 1.58s→0.64s（−59%）；隔离导出 3.66s→2.50s；字节不变 |
| ⑤ 只注册一次 | `codex/ios-single-model-registration` @ `b138576` | 新增 `model-adopt`（committed→一次性 stage 浅拷贝）与 `model-promote`（发布后 stage→generation，含摘要/布局/路径重绑），Swift 保留/提升/回退矩阵 | 100k 一次写 2 次 Go 导入→1 次（省约 7.8s）；adopt 浅拷贝 44ms；发布后首读 12s→4.2s；快照仍重建 |
| ⑥ 日期二分 | `codex/ios-date-range-bisect` @ `5222937` | `sort.Search` 定位首个 `Date < effectiveEnd`，`scanStart=max(cursor, first)`，越界即 break | 窄区间首页扫描 100,501→501 行；本地 4.3–6.5ms→1.3ms |

合入与集成验证：6 项按 #541→#542→#543→#544→#545→#546 顺序合入（#546 以 rebase 方式重放到 #545 之后），文档 #540 最后合入，`main` @ `ecbebb5`。每个 PR 的 CI 都通过；合入后复核 Python 32 tests、`go test ./...`、`go build ./cmd/...`、`swift test`（0 failures）、`swift build --triple arm64-apple-ios17.0`，以及带基线 `LedgerCore.xcframework` 的 `canImport(LedgerCore)` 分支编译，全部通过。冲突解决集中在 `LocalLedgerEngine.swift`（handles/signpost）与 `dispatch_test.go`（两组控制操作测试）。

### 第一阶段已知问题与未覆盖项

- **CI 前置修复已合入**：本机 macOS 27 / Xcode 27 对 `.completeFileProtection` 写入返回 EPERM，导致 `ImportHistoryTests` 两个用例在 pristine `main` 上就失败，会挡住任何改动 `App/` 的 PR。#547（`codex/ios-macos-file-protection`）已合入 `main` @ `64bed5c`：macOS 测试构建省略 protection class，iOS App 行为不变。`TestGitHubWriteValidationLargeLedgerPerformance` 对机器负载敏感（安静时通过），属既有环境问题。
- **既有 bug（未修，超出范围）**：`document` 指令的 `Filename` 以绝对路径导出，规范流因此不满足“不同目录拷贝字节相同”；会影响规范流缓存跨 stage/generation 复用。建议单独评估（item ⑤ 的 promote 只重绑 `File`，不重绑 `Filename`）。
- **item ⑤ 峰值内存**：发布校验会保留 stage 模型，commit 期间两个 Go 模型与 Python RSS 可能重叠；GOMEMLIMIT 是软上限。真机 `phys_footprint` 峰值仍是第一阶段验收门。
- **打包**：新增 Go 操作（`model-adopt`/`model-promote`/`model-release-idle`/`memory-limit`）需要重跑 `scripts/build-ledgercore-xcframework.sh` 生成新的 `LedgerCore.xcframework`（`scripts/build-ios-ipa.sh` 已包含该步骤）；CI 的 `swift test`/iOS SDK 交叉编译不编译 `canImport(LedgerCore)` 分支。
- **真机数据**：10k/50k/100k/200k Release 包的 signpost 与 phys_footprint 峰值尚未采集；GOMEMLIMIT 边界与 estimate 系数待真机校准。
- 待决定第 2 项（第一阶段开工）已执行；第 1、3、4 项（目标体量、写队列交互、检查点语义）仍未决。
