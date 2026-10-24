# iOS 大账本扩展：第一阶段交付

- 任务 `20261024-ios-large-ledger-scaling`；状态 `active`（代码与验证已完成，等待评审/合入）；更新于 2026-10-24T13:20:00+08:00。
- 用户目标：按 `docs/plans/20261024-ios-large-ledger-scaling.md` 的第一阶段 6 项落地，每项独立 PR、不改变校验语义、不放宽上限、不加数据库/依赖。
- 基线：`main` @ `150b552`。计划文档、方案对比与后续阶段见该 plan。

## 交付分支

| 项 | 分支 | HEAD | 说明 |
| --- | --- | --- | --- |
| ① 基准 + 分段计时 | `codex/ios-ledger-perf-baseline` | `5c36c52` | opt-in 合成账本生成器/基准、App os_signpost + phys_footprint、Python 可选 `log_timings` |
| ② 内存核算 + GOMEMLIMIT + 内存告警 | `codex/ios-model-memory-accounting` | `cf763ca`（`891d4b6`+`cf763ca`） | estimate 3→6、`debug.SetMemoryLimit`、告警原子裁剪空闲模型 |
| ③ 预检不再重复解析 | `codex/ios-preflight-scan` | `d4f96b6` | 无策略关键字文件跳过 `parser.parse_file`（fail-closed） |
| ④ 流导出提速 | `codex/ios-export-encode-once` | `2edc7b5`（`56fccd8`+`2edc7b5`） | 预算检查直接检查原始字段，投影前拒绝保留，字节不变 |
| ⑤ 只做一次 Go 注册 | `codex/ios-single-model-registration` | `b138576`（4 commits） | `model-adopt` + `model-promote` + Swift 保留/回退 |
| ⑥ 日期范围二分定位 | `codex/ios-date-range-bisect` | `5222937` | `sort.Search` 扫描起点，游标/错误语义不变 |
| 文档（本文件 + plan 勾选） | `codex/ios-large-ledger-scaling-docs` | 本文所在提交 | 只改 `docs/` |
| 集成验证分支 | `codex/ios-large-ledger-scaling-integration` | 见 branch | 6 项合并后的冲突解决与全量验证 |

所有分支从 `origin/main` @ `150b552` 出发、已 push；各分支未改 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`，未加依赖。

## 已完成与验证

- Python（需要 beancount 3.2.3 的 3.12 解释器，解释器路径属本机环境，见本地 checkpoint）：`PYTHONPATH=. python3 -m unittest test_ledger_validator`（集成分支 32 tests OK，含新增 golden SHA-256、投影前拒绝、等价性与计时测试）。
- Go：集成分支 `go test ./...` 全绿、`go build ./cmd/...` OK；新增 commit/test 覆盖 promote/adopt 拒绝矩阵、release-idle、二分起点与翻页完整性。
- Swift：集成分支 `swift test` 745+ tests，仅 2 个本机既有环境失败（见下）；`swift build --triple arm64-apple-ios17.0 --sdk …` OK；`Package.swift` 只把新增 `LocalLedgerPerformance.swift` 加入 portable sources。
- 关键数字（宿主 macOS arm64，非真机）：预检 0.639s→0.039s；预算检查 1.58s→0.64s、隔离导出 3.66s→2.50s（字节不变）；窄区间首页扫描 100,501→501 行；100k 一次写 Go 导入 2→1 次（约 −7.8s），adopt 浅拷贝 44ms，发布后首读 12s→4.2s。

## 未完成 / 已知问题

1. 真机验收数据未采集：10k/50k/100k/200k Release 包的 signpost 分段与 `phys_footprint` 峰值、jetsam 次数；`GOMEMLIMIT` 边界、estimate 系数 6 待真机校准。
2. 打包前需重跑 `scripts/build-ledgercore-xcframework.sh`（新增 4 个 Go 操作）；`scripts/build-ios-ipa.sh` 已包含。
3. `ImportHistoryTests` 2 个用例本机因 `.completeFileProtection` 原子写 `mktemp` EPERM 失败（macOS 27 / Xcode 27 对 data-protection class 写入返回 EPERM），已在 pristine `main` 复现，会挡住任何改动 `App/` 的 PR；已由前置修复 #547（`codex/ios-macos-file-protection`）修复并合入 `main` @ `64bed5c`：macOS 测试构建省略 protection class，iOS App 行为不变；修复后 6 项 PR + docs PR 的 CI 全绿。`TestGitHubWriteValidationLargeLedgerPerformance` 对负载敏感（安静时通过），同属既有环境问题。
4. 既有 bug（超出本阶段范围）：`document` 指令 `Filename` 导出为绝对路径，规范流不满足跨目录字节一致；item ⑤ promote 只重绑 `File`，未处理 `Filename`。建议单独评估。
5. item ⑤ 在 commit 校验期保留 stage 模型，两个 Go 模型 + Python RSS 可能重叠；软上限不保证不 OOM，真机峰值是验收门。
6. 快照未跨 root 迁移（item ⑤ 只省导入、不省快照）；计划里的“省一次快照 4.2s”仍待做。
7. 待决定第 1、3、4 项（目标体量、写队列交互、关账期检查点语义）未动。

## 下一步

1. 评审/合入 6 个代码 PR（建议顺序：③④（同文件、无交互）→ ① → ② → ⑥ → ⑤；`codex/ios-large-ledger-scaling-integration` 是已验证的合并结果，可直接参考冲突解决）。
2. 合入后重建 `LedgerCore.xcframework` 并用 Release 包在真机采集第一阶段验收数据。
3. 按真机数据校准 estimate 系数与 GOMEMLIMIT，再决定是否进入第二阶段（二进制规范快照）。
