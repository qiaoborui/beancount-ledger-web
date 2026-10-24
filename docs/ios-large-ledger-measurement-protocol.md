# iOS 大账本真机测量协议

- 任务 `20261024-ios-large-ledger-scaling`；配套 `docs/plans/20261024-ios-large-ledger-scaling.md`
  的「真机验收需要的数据」。第一阶段（PR #541–#549）已合入 `main`，本协议用来在进入
  第二阶段之前，把 10k / 50k / 100k 三档的真机数字**在无歧义的前提下**采出来。
- 适用对象：要回答“这次改动把 100k 的写延迟和内存峰值改善了多少”的人。协议只规定
  **怎么测、测什么、什么条件算合法**，不预设结论。
- 全部负载都是 `scripts/large_ledger_bench.py` 用固定 seed 生成的**合成账本**。本协议
  禁止把私有账本的任何派生数字（笔数、字节数、耗时、内存、截图里的金额）写进仓库文档、
  PR 描述或提交信息；这类信息按 `AGENTS.md` 只放在本地 checkpoint。

## 0. 三条硬规则

1. **同档位、同设备、同 OS、同构建配置才可比**。换任何一项就重新起一组，不要跨组比。
2. **每次测量都要能回答“测的是哪份账本”**。答案不是“100k 档位”，而是那份账本的
   `sourceTreeSha256`（`manifest.json` 里记录）。没有摘要的录制不收。
3. **只用合成账本**。`manifest.json` 的 `note` 字段是这条规则的机器可读版本；
   `record` 子命令发现录制里的摘要对不上就拒绝收录。

## 1. 链路总览

```
generate/assemble          →  device/ 目录（可导入）        →  manifest.json（工作负载身份）
  （本机，合成数据）                                          ↓
                             真机：文件 App → 我的 iPhone → App 内“导入本地账本”
                                                          ↓
                             预热轮（丢弃）→ N 轮正式测量 → 录制导出（阶段0-a）
                                                          ↓
record（校验 sourceTreeSha256）→ measurement.json（本次结论的证据包）
```

每个档位各自走一遍：10k / 50k / 100k 是**三个独立的工作负载**，不要在一台设备上
来回切同一档位的不同 seed。

## 2. 准备本机：生成并组装档位

需要一个带 **beancount 3.2.3** 的 Python 3.12 解释器（与 App 内置版本一致）。
脚本是 opt-in 的：不会从 `go test`、`swift test` 或 CI 自动运行。

```bash
# 三档一次做完，产物按 <workdir>/<tier>/{ledger,device} 摆放
for tier in 10k 50k 100k; do
  python3 scripts/large_ledger_bench.py assemble \
    --tier "$tier" --workdir /tmp/blw-tiers --seed 20261024
done
```

`assemble` 第一次在某档位没有 `ledger/` 时先生成（等于 `generate`），随后：

| 产物 | 内容 | 是否上设备 |
| --- | --- | --- |
| `/tmp/blw-tiers/<tier>/ledger/` | 生成器原始输出 + `manifest.json` | 否（留在本机做证据） |
| `/tmp/blw-tiers/<tier>/device/` | 只有账本源文件，**不含 `manifest.json`** | 是 |

预期输出形如（10k）：

```
10k: 10000 transactions, 240 month files, 244 source files, 1494462 source bytes
  directives: commodity 5, include 4, open 11, option 3, plugin 2, price 720, transaction 10000
  source tree: sha256:<64 hex>
  canonical: 11842 entries, 5591901 bytes, stream <64 hex>
  import budget: 246 entries (limit 10000), 1494462 bytes (limit 268435456), depth 32
  the device directory must not contain manifest.json
```

导入预算是按 App 的真实上限算的：`LocalLedgerWorkspace.TreeLimits` 允许
**10,000 个条目**（文件与目录都算）、**256 MiB** 文件字节、路径深度 **32**。三档都是
240 个月文件 + 4 个根文件，条目数恒定在 246 左右，远低于上限；主要增长的是字节。
`assemble` 超限会直接失败，不要绕过。

### 2.1 档位目录里允许出现什么

导入时 App 会把整个目录复制进 staging 并逐项检查，所以目录内容必须完全可控：

- **允许**：`main.bean`（入口，`--entrypoint` 可指定别的名字）和它 `include` 的
  `.bean` 文件，包括 `transactions/` 子目录。生成器只产这些。
- **禁止**：`manifest.json`、`README`、`.DS_Store`、`__MACOSX/`、任何符号链接、
  任何非普通文件。`assemble` 只复制白名单内的文件，并且用**普通复制**而不是链接；
  从 macOS 上手工整理目录时也一样，不要用“替身”。
- 生成器目录满足直接导入的全部条件（普通文件、无链接、深度 2、权限 0644）。唯一
  需要摘掉的就是 `manifest.json`，这件事由 `assemble` 做，**不要手工整理**。

### 2.2 复现性检查（每次换机器/换解释器后做一次）

```bash
python3 scripts/large_ledger_bench.py verify --tier 10k --workdir /tmp/blw-tiers
```

它做两件事：先确认磁盘上的 `ledger/` 仍等于 `manifest.json` 记录的
`sourceTreeSha256`（防止手工改过账本），再用记录的 seed 重新生成一遍，要求文件清单、
总字节、源树 sha256、指令计数、以及（解释器有 beancount 时）规范流条数/字节/sha256
**全部逐项相同**。通过时打印：

```
10k is reproducible: 244 files, 1494462 bytes, tree sha256:<64 hex> (seed 20261024)
  canonical stream 11842 entries, 5591901 bytes, <64 hex>
```

任一不符都以非零退出并列出差异。换解释器、升级生成器、改 `--transactions` 之后必须重跑；
不通过就不要开始测量，因为此时“同档位”已经不成立了。

实测证据（2026-10-24，seed `20261024`）：同 seed 连续生成 10k 三次，整个档位目录
（244 个源文件 + `manifest.json`）逐字节相同，`manifest.json` 自身的 sha256 都是
`c614c55f0c83daf415192c7136f216f12f9fdf8866d27c3ee9d921a75eb76119`，
源树为 `sha256:ee3941f43de8b01b11ad9fbaa46ef41e79b12bdd937f68b08dba997c9e2c481d`。
手工往 `accounts.bean` 追加一个字节后，`verify` 会以非零退出并报
`the files in ... no longer match the manifest`。

### 2.3 上设备前在本机先验一遍

```bash
python3 scripts/large_ledger_bench.py validate --source /tmp/blw-tiers/10k/device
```

用的是 App 同一条导出路径（`ledger_validator.export_canonical_json`），所以这里过的账本
在真机上也能过导入校验。它会打印设备目录的 `sourceTreeSha256`，应当与
`ledger/manifest.json` 里的一致——`device/` 只是少了 `manifest.json`，账本本身没变。

## 3. 构建并安装 Release 包

**一个二进制的身份 = 提交 + 版本 + build 号 + IPA 的 sha256。** 前后对比的两组必须
是同一个提交要么完全一致（同一份 IPA 测两遍），要么只有被测改动不同。

```bash
# 从要测的那个提交构建；输出目录必须是新建的
git rev-parse HEAD
bash scripts/build-ios-ipa.sh --private-local /tmp/blw-ipa-<label>
cat /tmp/blw-ipa-<label>/build-info.txt
```

`build-ios-ipa.sh` 的既有规则照旧适用，协议不改变它们：

- 需要精确的 `vMAJOR.MINOR.PATCH` 标签，且标签版本与 `App/LedgerMobile/project.yml` 的
  `MARKETING_VERSION` 一致，否则直接失败。测量用的包同样要走发版流程，不要绕过。
- 每次打包 `CURRENT_PROJECT_VERSION` +1；**不要复用或调低 build 号**。
- 记录 `build-info.txt` 里的 `Source:` 提交、`Xcode` 版本、`iPhoneOS SDK` 版本，以及
  IPA 的 sha256。这三行是这次测量的“构建条件”。
- 包是 ad-hoc 签名的，用 SideStore / iLoader / AltStore 重签安装。

安装后打开 App，先确认能进主界面再往下走。

## 4. 把档位放进设备

App 支持的导入入口是 catalog 的 `importLedger(from:name:entrypoint:)`，它要求传入
**一个目录**，不接受 zip。所以档位目录必须先落到设备上“文件”App 能看到的存储位置。

**推荐（A）**：macOS ↔ iPhone 用 AirDrop 传 `device/` 这个**目录**，接收后存到
“文件”App 的 **我的 iPhone**（或 iCloud Drive）里。AirDrop 传目录会保持目录结构，
不会打包成 zip。

**备选（B）**：把 `device/` 复制到 iCloud Drive（本机 Finder 里拖进 iCloud Drive），
等 iPhone 上的文件 App 出现该目录后再导入。

无论 A 还是 B，导入前先核对一件事：目录里**没有** `manifest.json`，也没有任何以 `_`
或 `.` 开头、由云端生成的副本文件。iCloud 同目录同名冲突会生成“xxx 2.bean”这类文件，
它会被当成多出来的 `include` 目标——遇到就删掉重传。

> 说明：App 的 `Info.plist` 只声明了 `LSSupportsOpeningDocumentsInPlace`，没有声明
> `UIFileSharingEnabled`，所以“我的 iPhone/<App 名>”这个本机共享目录不会出现。
> 走“文件”App 的其他位置（我的 iPhone、iCloud Drive、第三方 File Provider）都可以，
> 这就是为什么必须先有一个 Finder/共享层能看到的目录。

### 4.1 在 App 内导入

1. 进入本地账本列表 → “新建/导入本地账本”。
2. 名称填 `bench-10k`、`bench-50k`、`bench-100k`（**名称只影响显示，不影响测量**，
   但固定下来便于确认测的是哪一档）。
3. 入口文件保持 `main.bean`；切换成“选择文件夹”，挑第 4 步放进“文件”的档位目录。
4. 等待校验。导入是**校验通过后才发布**的：它先复制进 staging，跑 canonical 校验和
   读模型上限检查，再落成一个 generation。校验失败不会留下半成品，报错通常是：
   - `invalidSource` / `symbolicLink` / `unsupportedItem`：目录里有链接或非普通文件；
   - `treeLimitExceeded`：条目/字节/深度超限（本协议的档位不会触发）；
   - 校验错误（带文件名和行号）：账本本身有问题，回到第 2 步重新 `assemble`。

**注意**：导入这一步自己就跑了一次完整 Python 加载（校验会写规范流缓存）。所以导入时
花掉的时间**不是**下面任何一轮的测量对象。三档之间要各自重新导入一次；不要用“同一个
账本改名”的方式复用。

## 5. 测量前置条件（每一轮都必须成立）

| 条件 | 要求 | 怎么确认 |
| --- | --- | --- |
| 设备 | 同一台 iPhone，型号不变 | 设置 → 通用 → 关于本机 |
| OS | 同一 build（不只是同一版本号） | 同上，记录 `版本 (build)` |
| 构建 | 同一份 IPA（同一提交 + 版本 + build 号 + sha256） | `build-info.txt` |
| 低电量 | 关闭 | 设置 → 电池 |
| 充电 | 设备保持连接电源（避免降压与频率策略变化） | 直接接电源 |
| 热状态 | 每组开始前记录一次 | `thermalStateForDevice`（见下） |
| 后台 | 关闭其余 App；关闭自动同步/通知 | 设置 → 通知；App 内同步开关 |
| 屏幕/亮度 | 自动亮度关闭、亮度固定 | 设置 → 显示与亮度 |
| 网络 | 飞行模式开启（本地账本不需要网络） | 控制中心 |
| 存储 | 剩余空间 ≥ 5 GB | 设置 → 通用 → iPhone 储存空间 |
| 投放 | 每次测量前把设备静置 2 分钟 | 使热状态回落到 nominal |

热状态怎么读：用 `os_signpost` 之外的系统途径即可，推荐在 Mac 上

```bash
# 依赖 libimobiledevice（不在仓库依赖里，属于测量者本机工具）
idevicediagnostics -u <UDID> thermal
```

也可以看 Xcode → Window → Devices and Simulators → 打开控制台筛 `thermal`。**记录的是
读数，不是“感觉不热”**。`serious` / `critical` 下测出来的数字一律作废，等回落重测。

## 6. 轮次结构

每档、每组（改动前 / 改动后）都按下面的顺序跑，**首次加载单独分出来**：

| 阶段 | 轮数 | 是否计入结果 | 目的 |
| --- | --- | --- | --- |
| 导入 | 1 | 否 | 建立账本；此时不计时间 |
| 首次加载（cold） | 1 | **单独报**，不与后续平均 | 冷启首屏、首次注册；这是第二阶段的主要指标 |
| 预热（warm-up） | 2 | 否 | 让 Python 解释器、OS 页缓存、模型缓存进入稳态 |
| 正式（measured） | **N = 20** | 是 | 计划里要求的配对前后 20 轮 |

规则：

- 同一次 App 进程内的轮次算“热”；**每次冷启必须是真正的新进程**（上滑杀掉 App 再打开），
  并且要等 Python 解释器初始化完再点第一个会触发加载的操作。
- 一档跑完再跑下一档；换档位时先冷启一次，不要带着上一档的模型继续。
- 每轮只做一个可复现的动作序列，不要“顺手滑一下”。建议的最小动作序列：
  打开 App → 进入该账本 → 打开概览 → 翻到交易列表第一页 → 打开一笔交易详情 → 返回。
- 每 5 轮记录一次热状态；中途热状态升到 `serious` 就停下、静置、重跑该组。
- 失败轮（崩溃、jetsam、明显卡死）单独记下来并计入“崩溃/jetsam 次数”，不要悄悄重跑到
  凑够 20 轮。

## 7. 取数：signpost 与录制 JSON

### 7.1 signpost（第一阶段已具备，随时可用）

- subsystem `app.beancount.ledger.local-performance`，category `ledger`。
- 区间：`python-load` / `python-export` / `python-parse` / `python-booking` /
  `python-plugins` / `python-validate` / `canonical-validate` / `go-register` /
  `go-model-register` / `go-page`；每段结束时附带 `duration_ms`、`footprint_mb`，
  iOS 上还有 `available_mb`。
- 峰值事件 `memory-peak` 在每个最外层区间结束时发出，带 `peak_footprint_mb`。
- 取法：Xcode → Instruments → Points of Interest；或接 Mac 后
  `log stream --signpost --predicate 'subsystem == "app.beancount.ledger.local-performance"'`。
- **`phys_footprint` 峰值是第一验收指标**，其余用来排优先级。注意 signpost 里的峰值是
  10 Hz 采样的近似值，真正的瞬时峰值仍建议用 Instruments 的 Allocations/VM Tracker 复核。

### 7.2 录制并导出聚合 JSON（阶段0-a）

阶段0-a 给 App 加“录制 → 导出聚合 JSON”的能力，**截至本协议写作时尚未合入 `main`**。
所以这里只约定**接口必须满足什么**，具体参数名以实际合入的 PR 为准，合入后请回来把
本节替换成准确的菜单路径/参数名。

协议要求导出文件满足（也就是说：`record` 子命令依赖它）：

1. 是 UTF-8 JSON，一个文件对应**一次测量会话**（一档、一组、一台设备）。
2. 顶层必须有 `workload` 对象，且**至少**包含：

   ```json
   {
     "workload": {
       "tier": "100k",
       "sourceTreeSha256": "sha256:<64 hex>",
       "entrypoint": "main.bean",
       "canonicalEntries": 11842,
       "streamBytes": 5591901
     }
   }
   ```

   `sourceTreeSha256` 直接从该档位的 `ledger/manifest.json` 抄，**不要手改**。
3. 需要有可区分轮次的结构（`runs` 列表，每项带 `role`: `cold` / `warmup` / `measured`、
   `round` 序号），以及 `device`（型号 + OS build）、`build`（版本 + build 号 + IPA sha256）、
   `thermal`（每组开始的热状态），以便配对时过滤。
4. 聚合值（P50/P95/最大值）必须能追溯到逐轮原始值；只给平均值的导出视为不合规。

如果阶段0-a 最终用别的字段名，改的是**协议这一小节**和 `record` 的校验键，不是测量步骤。

### 7.3 收录证据包

把每档的录制文件放进一个目录，然后：

```bash
python3 scripts/large_ledger_bench.py record \
  --tier 100k --workdir /tmp/blw-tiers --input /tmp/blw-recordings/100k
```

它逐份检查 `workload.sourceTreeSha256` 与该档位 `manifest.json` 是否一致：

- 一致 → 收进 `measurement.json`（默认落在 `<tier>/ledger/measurement.json`），
  连同 `manifest.json`、可选的热状态笔记一起；
- 不一致 → 打印 `measured a different ledger (<sha256>)` **并整体失败**。

这一步是协议的“防串味”闸门：它挡住“以为是 100k、其实是上一版生成器”的情况。
`measurement.json` 是能进仓库的（全部是合成负载 + 设备型号 + 时间），但**不要**把
设备 UDID、Apple ID、任何本机绝对路径写进去。

## 8. 配对前后对比

只有满足下面全部条件，两组数字才能相减：

1. **同设备、同 OS build、同构建配置（Release）、同 IPA 安装方式。**
2. **同一份负载**：两组的 `sourceTreeSha256` 相同（`record` 已保证）。执行顺序建议
   交错（前→后→前→后）以减少时间漂移，但两组各自仍需满足第 5 节的条件。
3. **同一轮次结构**：两组都是“1 次冷启 + 2 次预热 + 20 次正式”，首次加载单独报。
4. **热状态同为 `nominal`**；任何一组出现 `serious`/`critical` 就整组作废。
5. **报告统计量的中位数和 P95，外加极差**，不要只报平均。

推荐的对照表（每档一张）：

| 指标 | 前 | 后 | 变化 |
| --- | --- | --- | --- |
| 首次加载：`go-page`（冷启首屏） | | | |
| 首次加载：`go-register` | | | |
| 正式轮：`python-load` P50 / P95 | | | |
| 正式轮：`canonical-validate` P50 / P95 | | | |
| 正式轮：`go-page` P50 / P95 | | | |
| `memory-peak` 峰值 | | | |
| 崩溃 / jetsam 次数（30 分钟混合读写） | | | |

“写延迟”在真机上对应一次提交的 `canonical-validate` + `go-register`（+ 已发布的
`go-page`），三段分开报，不要合成一个数。

## 9. 哪些数字不能进仓库

以下一律**不入仓**（文档、PR、提交信息、截图、日志都不行），按 `AGENTS.md` 放本地
checkpoint（`$GIT_COMMON_DIR/agent-handoffs/<task-id>.md`）：

- 私有账本的笔数、文件数、字节数、持仓批次数、每年增长量；
- 用私有账本跑出来的任何耗时、内存、崩溃次数；
- 任何绝对路径（本机解释器、workdir、IPA 输出目录、设备 UDID）；
- 设备截图里出现的金额、商户名。

可以进仓库的只有：合成档位（seed 固定）、`manifest.json` 的摘要、`measurement.json`
里的合成负载数字，以及设备型号/OS build/热状态这类非隐私环境信息。

## 10. 一页流程（可直接对照执行）

```bash
# 1) 本机：组装 + 自检
python3 scripts/large_ledger_bench.py assemble --tier 10k --workdir /tmp/blw-tiers --seed 20261024
python3 scripts/large_ledger_bench.py verify   --tier 10k --workdir /tmp/blw-tiers
python3 scripts/large_ledger_bench.py validate --source /tmp/blw-tiers/10k/device

# 2) 本机：构建 Release IPA（需要发版标签）
bash scripts/build-ios-ipa.sh --private-local /tmp/blw-ipa-before
cat /tmp/blw-ipa-before/build-info.txt      # 记录提交/Xcode/SDK/IPA sha256

# 3) 设备：AirDrop device/ → 文件 App → 我的 iPhone → App 内导入
# 4) 设备：关低电量、接电源、飞行模式、静置 2 分钟、记录热状态
# 5) 设备：1 次冷启 + 2 次预热 + 20 次正式；每 5 轮记录热状态
# 6) 设备：阶段0-a 录制导出 → 拿到 Mac
python3 scripts/large_ledger_bench.py record --tier 10k --workdir /tmp/blw-tiers \
  --input /tmp/blw-recordings/10k

# 7) 改动后重复 2)–6)，用同一台设备、同一 OS、同样 20 轮；再按第 8 节做表
```

10k 先跑通再上 50k / 100k：100k 一档在真机上最可能先撞内存和热限制，把流程在 10k 上
验证过再花那一次时间。

## 11. 未覆盖项与已知限制

- **阶段0-a 未合入**：第 7.2 节的接口是约定，不是现状；合入后回来对齐字段名。
- **导入即一次完整加载**：导入时那次 Python 校验不在测量范围内，但也意味着“导入耗时”
  不能直接拿来当“首次加载耗时”。
- **热状态读数依赖本机工具**：`idevicediagnostics` 属于测量者环境，不是仓库依赖。
- **200k 档位不在生成器里**：`--transactions 200000` 可以生成，但它不会带上
  `tier` 字段，`manifest.json` 的 `tier` 为 `null`，需要单独命名并同样走 `verify`。
- **iCloud 副本文件**：同步层可能生成“同名 2.bean”，导入前必须确认目录干净；这是
  协议里唯一需要人工看目录结构的地方。
- **`document` 指令绝对路径问题**（既有 bug，#548）：生成器不产 `document` 指令，
  所以合成负载不受影响；真机测量也不应改用真实账本来绕开它。
