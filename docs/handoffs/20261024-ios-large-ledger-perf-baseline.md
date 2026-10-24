# 20261024-ios-large-ledger-perf-baseline

- Status: completed (branch `codex/ios-ledger-perf-baseline`, no PR yet)
- Last updated: 2026-10-24 13:12 +0800
- Base: `main` @ `150b552`
- Plan item: `docs/plans/20261024-ios-large-ledger-scaling.md` 第一阶段候选小改动第 1 项

## Goal

给后面每一项优化建立统一的度量工具：opt-in 的合成大账本生成器 + 分段计时，
App 内用 `os_signpost` 记录 parse/booking/plugins/validate/导出/注册/快照各段，
并采集 `phys_footprint` 峰值与 iOS `os_proc_available_memory` 余量。所有工具
默认不跑（`go test` / `swift test` / CI 不受影响），校验语义和默认输出字节不变。

## What was added

- `scripts/large_ledger_bench.py`：opt-in 合成账本生成器（240 个月文件、20 年、
  中文 payee、metadata/tag/link、CNY+USD+HKD、带 FIFO 成本批次的股票买卖、
  `auto_accounts` + `implicit_prices`）与分段基准；`generate` / `bench` 两个子命令。
- `scripts/README.md`：怎么开基准、每个数字是什么意思、App signpost 采集方式。
- `server/internal/app/local_scale_benchmark_test.go`：`BenchmarkLocalScaleStages`，
  只在 `LOCAL_LEDGER_SCALE_BENCHMARK=1` + `LOCAL_LEDGER_SCALE_DIR=<tier>` 时运行，
  测 Go 源码版本哈希、规范流导入、模型注册、首屏（含快照）、热分页和堆占用。
- `App/LedgerMobile/Runtime/ledger_validator.py`：`LEDGER_VALIDATION_TIMINGS`
  显式开启时才给 `loader._uncached_load_file` 传计时 sink，并把
  parse/booking/plugins/validate 毫秒数加进导出 stream descriptor 的 `timings`
  键。默认路径不传 sink、descriptor 无新键、导出流逐字节不变。
- `App/LedgerMobile/Runtime/test_ledger_validator.py`：新增两个测试——默认
  descriptor 没有 `timings` 且开/关计时的导出流逐字节相同；开启计时后
  `validate_json` / `validate_only_json` payload 不变。
- `App/LedgerMobile/Sources/LocalLedgerPerformance.swift`：OSSignposter 分段 +
  `task_info(TASK_VM_INFO).phys_footprint` 采样（10 Hz，取区间峰值）+
  iOS `os_proc_available_memory`。macOS 便携包只记录 footprint，接口一致。
- `App/LedgerMobile/Sources/EmbeddedBeancountValidator.swift`：解析 descriptor
  `timings` 并 emit `python-parse/booking/plugins/validate`；导出/校验加 interval。
- `App/LedgerMobile/Sources/LocalLedgerEngine.swift`：只加 `canonical-validate`、
  `go-register`、`go-model-register`、`go-page` 四处埋点，未改注册生命周期。
- `App/LedgerMobile/Package.swift`：portable target 的 sources 列表机械加入
  `"LocalLedgerPerformance.swift"`，未改平台/版本/依赖。

## How to run

```bash
# 需要装 beancount 3.2.3 的 python 和 go 工具链
python3 scripts/large_ledger_bench.py bench --tiers 10k,50k,100k --repeat 2
# 只重生成某一档
python3 scripts/large_ledger_bench.py generate --tier 100k --output /tmp/blw-ledger-100k
# 只跑 Go 段
LOCAL_LEDGER_SCALE_BENCHMARK=1 LOCAL_LEDGER_SCALE_DIR=/tmp/blw-scale-bench/100k \
  go test ./internal/app -run '^$' -bench '^BenchmarkLocalScaleStages$' -benchtime=1x -v
```

详细参数和数字含义见 `scripts/README.md`。`bench` 会在工作目录留下每档
`baseline.json`（含每轮原始数据），前后对比用同一 `--seed` 和同一档位。

## Baseline (macOS arm64, local machine)

机器：MacBook（10 CPU，arm64），Python 3.12.13 + beancount 3.2.3，Go 1.27.1。
**这是模拟器宿主机的本机数据，不是真机验收数据。** 采集方式：每档先跑一次丢弃的
warm-up，再跑 2 次取中位数（同一 `--seed`，`--repeat 2`）；两次测量的 wall 差异
在 1% 以内。采集窗口 load average ≈ 6（团队其它 worktree 仍有任务在跑；更早一次
负载 7–13 时的同类测量 wall 会放大 2–3 倍，所以对比时务必记录负载并取中位数）。

账本规模（合成）：

| 档位 | 交易数 | 月文件 | 源码文件 | 规范流条目 | 规范流大小 |
| --- | --- | --- | --- | --- | --- |
| 10k | 10,000 | 240 | 244 | 11,842 | 5.3 MiB |
| 50k | 50,000 | 240 | 244 | 56,097 | 26 MiB |
| 100k | 100,000 | 240 | 244 | 110,563 | 52 MiB |

Python 侧（真实 `ledger_validator.py` 导出，单位 ms，2 次中位数）：

| 段 | 10k | 50k | 100k |
| --- | ---: | ---: | ---: |
| preflight（单独一遍） | 104.8 | 371.2 | 801.4 |
| loader parse | 86.5 | 417.0 | 996.5 |
| loader booking | 134.0 | 1,286.0 | 4,407.5 |
| loader plugins | 42.0 | 220.0 | 503.0 |
| loader validate | 48.0 | 309.5 | 944.0 |
| **loader total** | **310.5** | **2,232.5** | **6,851.0** |
| export total（wall） | 567.2 | 3,321.4 | 9,335.2 |
| export non-loader | 256.8 | 1,088.9 | 2,484.2 |
| export cpu（本进程） | 566.0 | 3,316.8 | 9,276.9 |

100k 时 beancount 内核占导出的 73%（其中 booking 64%），preflight 约 8.6%，
其余约 18% 是规范流编码 + SHA-256 + fsync。注意这个合成账本约 8% 是股票买卖，
FIFO 持仓批次多，booking 占比比计划里 x86 容器的 100k 分解更高（计划是 20k→100k
booking ×8.3 的超线性），**不要拿它和计划文档里的绝对秒数直接对比**，只用于同一
命令的前后对比。

Go 侧（`BenchmarkLocalScaleStages`，单次）：

| 段 | 10k | 50k | 100k |
| --- | ---: | ---: | ---: |
| source version | 8.1 | 16.1 | 57.2 |
| canonical stream ingest | 68.5 | 301.3 | 723.4 |
| model register（含再读一遍流） | 59.2 | 295.5 | 705.0 |
| first page（含快照构建） | 129.4 | 663.1 | 1,646.6 |
| warm page | 1.5 | 2.0 | 2.9 |
| live heap after register | 39 MiB | 183 MiB | 361 MiB |
| allocated by this run | 272 MiB | 1,363 MiB | 2,718 MiB |

这些 Go 数字和计划里 x86 容器的“100k 规范流导入 7.8 s（×2）/ 快照 4.2 s（×2）”
比例一致（本机约快 2–3 倍），可以互相印证。

## App instrumentation

- subsystem `app.beancount.ledger.local-performance`，category `ledger`；
  Instruments → Points of Interest，或 `log stream` 过滤。
- interval：`python-load`、`python-export`、`canonical-validate`、`go-register`、
  `go-model-register`、`go-page`。
- event：`python-parse/booking/plugins/validate`（duration 来自 Python 端；
  App 在每次导出前显式设置 `LEDGER_VALIDATION_TIMINGS=1`，Python 自身默认静默）、
  `memory-peak`（最外层区间内 `phys_footprint` 峰值）。
- 区间结束的 event 带 `duration_ms`、`footprint_mb`，iOS 上还有 `available_mb`。
- macOS 便携包：`os_proc_available_memory` 是 iOS 专属 API，macOS 返回 nil，
  只记录 footprint；其余接口和 iOS 一致，`swift test` 可编译通过。

## Validation

| 命令 | 结果 |
| --- | --- |
| `cd App/LedgerMobile/Runtime && PYTHONPATH=. <py312> -m unittest test_ledger_validator -v` | 23 tests OK |
| `cd server && go build ./cmd/...` | OK |
| `cd server && go test ./...` | 仅 `TestGitHubWriteValidationLargeLedgerPerformance` 失败：本机 `bean-check` 单次 2.5 s 超过测试的 2 s warm 预算；在 `origin/main` @ `150b552` 的干净拷贝上复现同样失败（2.18 s > 2 s），与本次改动无关，其余包通过 |
| `cd App/LedgerMobile && swift build` | Build complete |
| `cd App/LedgerMobile && swift build --triple arm64-apple-ios17.0 --sdk <iphoneos>` | Build complete |
| `cd App/LedgerMobile && swift test` | exit 0（portable 包 XCTest + swift-testing 全过） |
| opt-in Go benchmark | 不带 `LOCAL_LEDGER_SCALE_BENCHMARK=1` 时 skip；正常 `go test ./...` 不跑 |

## Uncovered / next steps

- **没有真机数据**：本项只负责把度量做进 App；真机 10k/50k/100k/200k 的
  signpost 各段耗时和 `phys_footprint` 峰值（计划“真机验收需要的数据”）仍需
  在 Release 包上采集。
- Go 的 `first page (snapshot)` 是“快照构建 + 该页响应”的合计；要再细分需要
  改 Go 分页代码，本项未动。
- Python 计时只覆盖导出路径；`BRValidate` 的 `python-load` 有总时长但没有
  parse/booking 拆分（该路径不产出 stream descriptor）。
- 本机 wall 数字受同机其它任务影响；后续对比请用空闲窗口 + `--repeat` +
  `export cpu` 列，并记录 `baseline.json` 里的原始数据。
- 未加入 CI：基准和 App 计时都是显式 opt-in，符合“不拖慢 CI”的要求。
