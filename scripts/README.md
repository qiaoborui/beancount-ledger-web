# scripts

通用账本辅助脚本、部署/打包脚本，以及本目录下的性能基准工具。

## 大账本性能基准（脚本 opt-in；App 内计时默认开启）

`large_ledger_bench.py` 是 iOS 大账本扩展方案第一阶段第一项的度量工具：
合成账本生成器 + 分段计时基准。**全部数据都是合成数据**（固定 seed 的
中文 payee、metadata、tag、多币种、带 FIFO 成本批次的股票买卖、
`auto_accounts` / `implicit_prices` 插件），不读取真实账本，不写机器私有路径。

基准脚本本身是 opt-in：不会从 `go test`、`swift test` 或 CI 自动运行，必须显式调用。
App 内的 signpost 与 Python 计时是产品默认开启的（用于真机验收；可通过
`LEDGER_VALIDATION_TIMINGS=0` 关闭 Python 侧计时）。

### 前置条件

- Python 3.12（或任意 3.8+），并安装 **beancount 3.2.3**（与 App 内置版本一致）。
  如果本机有 App 运行时用的 test-venv，也可以直接用它的解释器。
- Go 工具链（只有 Go 段需要；`--no-go` 可跳过）。

### 生成指定档位

```bash
python3 scripts/large_ledger_bench.py generate --tier 100k --output /tmp/blw-ledger-100k
```

档位为 `10k` / `50k` / `100k`（`--transactions N` 可自定义）。生成 20 年、
240 个月文件、`main.bean` 及 `accounts/commodities/prices.bean`。

生成完成后，`<output>/manifest.json` 记录这一档工作负载的身份：

| 字段 | 含义 |
| --- | --- |
| `transactions` / `monthFiles` / `months` | 交易笔数、月文件数、覆盖月数 |
| `directiveCounts` | 按 kind 的指令计数（open/commodity/price/plugin/option/include/transaction） |
| `sourceFiles` | 每个源文件的相对路径、字节数、sha256 |
| `sourceFileCount` / `sourceBytes` | 源文件数与源字节总量 |
| `sourceTreeSha256` | 整棵源树的 sha256（按路径+内容，不含 mtime，也不含 manifest 自身） |
| `canonical.entries` / `canonical.streamBytes` / `canonical.streamSha256` | 用真实 `ledger_validator` 导出得到的预期规范流指标（解释器没有 beancount 时为 `null`） |
| `seed` | 生成用 seed；同 seed 重新生成应逐字节一致 |

### 真机档位：组装、复现性校验、证据包

真机测量的完整步骤见 [docs/ios-large-ledger-measurement-protocol.md](../docs/ios-large-ledger-measurement-protocol.md)，
这里只列命令：

```bash
# 组装成可以直接在 App 里导入的目录（<workdir>/<tier>/device），并检查导入预算
python3 scripts/large_ledger_bench.py assemble --tier 10k --workdir /tmp/blw-tiers --seed 20261024

# 同 seed 重新生成并与 manifest 逐项比对（源树 sha256、规范流 sha256 等）
python3 scripts/large_ledger_bench.py verify --tier 10k --workdir /tmp/blw-tiers

# 上设备前用 App 同一条导出路径验一遍，打印该目录的 sourceTreeSha256
python3 scripts/large_ledger_bench.py validate --source /tmp/blw-tiers/10k/device

# 把 App 导出的录制 JSON 收进证据包；摘要对不上会整体失败
python3 scripts/large_ledger_bench.py record --tier 10k --workdir /tmp/blw-tiers \
  --input /tmp/blw-recordings/10k
```

`assemble` 只复制账本源文件，**不把 `manifest.json` 放进 `device/`**：导入目录受
`LocalLedgerWorkspace.TreeLimits`（10,000 条目 / 256 MiB / 深度 32）约束，而且目录里
多出来的文件没有任何用途。三档都是 240 个月文件 + 4 个根文件，条目数约 246，主要增长
的是字节。`assemble` 发现符号链接、非普通文件或超限会直接失败。

### 跑完整分段基准

```bash
# 三档全部跑，每个 python 导出跑 2 次取中位数；默认先跑 1 次丢弃的 warm-up
python3 scripts/large_ledger_bench.py bench --tiers 10k,50k,100k --repeat 2

# 只跑 Python 侧（不调用 Go）
python3 scripts/large_ledger_bench.py bench --tiers 100k --no-go

# 指定工作目录（保留产物和 baseline.json，便于前后对比）
python3 scripts/large_ledger_bench.py bench --workdir /tmp/blw-scale-bench
```

每次运行会把每档的分段数字写入 `<workdir>/<tier>/baseline.json`，总表写入
`<workdir>/baseline.json`。脚本打印的数字含义：

| 数字 | 含义 |
| --- | --- |
| `preflight (standalone)` | `ledger_validator._preflight` 单独一遍的开销（安全策略扫描，目前会额外完整 parse 每个文件） |
| `loader parse/booking/plugins/validate` | beancount 3.2.3 `loader._uncached_load_file` 内部各段，来自 `LEDGER_VALIDATION_TIMINGS=1` 时 `log_timings` 的 breakdown（毫秒，四段互不重叠） |
| `loader total` | 上面四段之和 |
| `export total` | 真实 `export_canonical_json` 一次导出的墙钟时间 |
| `export non-loader` | `export total − loader total`：包含 preflight、规范流逐条编码、SHA-256 和 fsync |
| `export cpu (this process)` | 同一次导出的本进程 CPU 时间；机器被其它任务占用时，wall 会变而 CPU 相对稳定 |
| `stream N entries, X MiB` | 导出的规范流记录数/字节数，SHA-256 前缀用来确认流没变 |
| Go `source version` | Go 对整棵账本源码做内容哈希 |
| Go `canonical stream ingest` | `ReadLocalCanonicalStream` 单读一遍规范流 |
| Go `model register` | `RegisterLocalModel`（含再读一遍规范流） |
| Go `first page (snapshot)` | 冷启动第一页，包含 Go 侧快照/索引构建 |
| Go `warm page` | 已注册模型的普通分页读取 |
| Go `live heap after register` | `runtime.GC()` 后 Go 活堆；`allocated by this run` 是本次注册+读页累计分配 |

这些是**本机（macOS 模拟器宿主）数字**，只用于前后比例对比，不是真机验收数据；
真机验收需要 App 内 os_signpost + phys_footprint（见下）。跑基准时尽量让机器空闲：
壁钟时间对其它编译/测试任务很敏感，`--repeat 3` 取中位数更稳；`export cpu`
和 Go 的 stage 数字可用于判断 wall 是否被外部负载放大。

### Go 段单独跑

```bash
LOCAL_LEDGER_SCALE_BENCHMARK=1 \
LOCAL_LEDGER_SCALE_DIR=/tmp/blw-scale-bench/100k \
LOCAL_LEDGER_SCALE_RESULT=/tmp/blw-scale-bench/100k/go-stages.json \
  go test ./internal/app -run '^$' -bench '^BenchmarkLocalScaleStages$' -benchtime=1x -v
```

`LOCAL_LEDGER_SCALE_DIR` 里的目录结构由 `bench` 子命令准备：
`generations/bench/workspace`（Beancount 源）和 `runtime/canonical-stream/*.records`
（Python 导出的规范流）。

### App 内计时（Signposts / 内存峰值）

`App/LedgerMobile/Sources/LocalLedgerPerformance.swift` 用 `OSSignposter` 记录：

- `python-load` / `python-export`：Python 校验/导出总段；
- `python-parse` / `python-booking` / `python-plugins` / `python-validate`：从
  stream descriptor 的 timings 拆出的 beancount 内核四段。App 在每次导出前显式
  设置 `LEDGER_VALIDATION_TIMINGS=1`（这是 App 的默认行为，不是 opt-in；设成
  `0`/`false` 可关掉）；直接跑 `ledger_validator.py` 的脚本/基准默认静默、输出
  字节不变；
- `canonical-validate`：一次“用导出代替校验”的完整发布前校验；
- `go-register` / `go-model-register` / `go-page`：Go 注册与分页/首屏；
- `memory-peak`：最外层区间内 `phys_footprint` 的峰值；区间结束时还会带
  `footprint_mb` 和（iOS）`os_proc_available_memory` 余量。

采集方式：Xcode → Instruments → Points of Interest（或 `log stream`），按
subsystem `app.beancount.ledger.local-performance`、category `ledger` 过滤。
`phys_footprint` 来自 `task_info(TASK_VM_INFO)`；`os_proc_available_memory`
是 iOS 专属 API，macOS 便携包只记录 footprint。
