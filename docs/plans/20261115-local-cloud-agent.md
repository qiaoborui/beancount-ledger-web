# 本地 + 云端账本助手：通用架构设计

- 状态：设计稿，待 Borui 拍板。不改 App 代码。
- 日期：2026-11-15
- 相关：`server/mobileagent`（手机端 PiG 循环）、`docs/agent-runtime.md`（旧的网页端 Bub agent）、
  `docs/ios-local-first-ledger.md`、`LedgerAgentMerge`（三方草稿合并）。

## 结论先说

1. **手机上的助手继续当 coordinator（总调度），云端只当“手和后台”。** 用户永远只跟手机上的助手说话；账本的唯一写入者仍然是手机。云端提供两样东西：
   - **云端工具**：`sandbox_exec`（bash / python 沙箱），同步调用，几秒到两分钟，像现在调模型一样在一轮里完成。
   - **云端任务**：`delegate`（把一件长任务交给云端的同一套 agent 循环去跑），异步，跑完通过“事件收件箱”回传，并推送通知。
2. **一套 agent 内核，两个宿主。** 把 `server/mobileagent` 里与 iOS 无关的部分（PiG 循环、transcript、压缩、工具注册）抽成 `agentcore`，手机（gomobile）和云端（Linux 上的 Go 服务）共用。云端不再用 Python 的 Bub。
3. **工具协议统一用 MCP（Streamable HTTP）。** 云端服务把工具以 MCP 暴露，手机在每轮开始时 `tools/list`，把云端工具包成 PiG 的 `AgentTool`。仓库里的 `internal/app/mcp.go` 已经实现过一次无状态 MCP，可以照抄。
4. **账本同步：按内容寻址上传快照，结果以“补丁”回来，由手机用现有 `LedgerAgentMerge` 三方合并。** 云端从不直接写账本、不拿 GitHub token。
5. **云端运行时：先自建一个 Go 小服务 `ledger-agentd`（SQLite 收件箱 + Docker/gVisor 沙箱），部署在现有的自托管 Docker 主机上，用 Cloudflare Tunnel 暴露。** 额外成本约等于 0；沙箱做成接口，以后可以一行配置换成 Modal / E2B。
6. **事件驱动照用户给的图做：** handler 写 inbox 表（按事件 ID 去重）→ 唤醒 worker → worker 取 pending、按会话串行启动 run → 等完成 → 标 done → 写 outbox 并推送。
7. **手机上不内置 Alpine，但加一个本地 `run_python`。** App 里已经内置了 CPython 3.14（给 Beancount 校验用），直接让助手在里面跑 python，离线、零服务器。iOS 上跑完整 Linux（iSH 式 x86 模拟、WASM 里的虚拟机）又慢又大，后台也跑不住，不值得；bash 和真正的 Linux 留给云端。详见第 7 节。
8. **最小可用版本 = 本地 `run_python`，然后才是云端 `sandbox_exec`。** 第一步不需要任何服务器；收件箱、后台任务、定时任务放在后面的阶段。

下面逐条展开。

---

## 1. 本地与云端各做什么

| | 手机（本地，coordinator） | 云端 `ledger-agentd` |
|---|---|---|
| 和用户对话 | ✅ 唯一入口 | ❌ 不直接面对用户 |
| 读账本（BQL、搜索、读文件） | ✅ 现有工具 | ✅ 只读，读的是上传的快照 |
| 改账本 | ✅ 草稿 → 变更卡 → 写入（含自动写入开关） | ❌ 只产出补丁，交回手机 |
| 三方合并、撤销 | ✅ `LedgerAgentMerge` | ❌ |
| UI 工具：`ask_user`、App 设置、技能、visual 块、图表 | ✅ | ❌（需要用户时以 `needs_input` 结束，交回手机） |
| 离线 | ✅ 云端工具自动隐藏，退回纯本地 | — |
| bash / python / 各种 `bean-*` 命令行 / pandas / 解析 PDF、Excel | ❌ | ✅ 沙箱 |
| 长任务（几十步、几十分钟）、手机锁屏后继续 | ⚠️ 靠保活，不可靠 | ✅ |
| 定时任务、外部事件（邮件、webhook） | ❌ | ✅ |
| 模型 key | 手机 Keychain（不出手机） | 云端自己的一份，存在服务器 env |

**为什么手机当 coordinator，而不是反过来：**

- 账本在手机上、离线能用、已经很好用，这是这个 App 的立身之本（local-first）。云端当总调度，就意味着每句话都要联网、账本托管到服务器，回到了旧网页版的模式。
- 写账本需要 canonical 校验、变更卡、撤销，这些都在手机上，没必要在云端再造一遍。
- 云端是“可选加速器”：没配服务器、服务器挂了、在飞机上，助手照常工作，只是少了几样工具。

**为什么不用单独的“路由模型”：** coordinator 就是手机上的模型本身。它看到的工具清单里多了 `sandbox_exec` 和 `delegate`，再加几条提示词规则（见第 2 节），由它自己决定。多一个路由模型只会多一次延迟和一份钱。

---

## 2. Coordinator 怎么路由与委派，工具怎么注册

### 2.1 路由规则（写进系统提示词）

1. 能用账本工具（BQL、搜索、读改文件、`bean_check`）解决的，在本地做。
2. 需要“算”而 BQL 做不了的：复杂统计、pandas、画复杂图、解析 PDF / Excel / 网页、跑 `bean-price` / `bean-extract` 等命令 → `sandbox_exec`。
3. 预计超过两分钟、步骤很多、要在手机锁屏后继续、或者用户说“定时/每天/以后自动” → `delegate`，回复里告诉用户“交给云端了，完成后通知你”。
4. 云端不可达时，2 和 3 的工具根本不出现在清单里，模型自然不会用。
5. 用户可以强制：输入框加一个「云端」芯片（或 `/cloud` 前缀），这一轮直接走 `delegate`。

### 2.2 统一工具描述

两端共用一种工具描述（Go 结构，序列化为 MCP `Tool`，扩展字段放 `_meta`）：

```jsonc
{
  "name": "sandbox_exec",
  "description": "...",
  "inputSchema": { ... },          // JSON Schema，和现在 ai.ToolSchema 一致
  "_meta": {
    "ledger/where": "cloud",       // local | cloud
    "ledger/effect": "draft",      // read | draft | external
    "ledger/maxSeconds": 120,
    "ledger/needsWorkspace": true  // 调用前需要把草稿同步上去
  }
}
```

- `effect` 决定能否在只读会话、隐私锁定时出现；`draft` 表示会改草稿（会出现在变更卡里）；`external` 表示会产生外部副作用（例如以后的发邮件），一律需要确认。
- 本地工具仍然直接实现 PiG 的 `AgentTool`；云端工具由一个 `remoteTool` 适配器包装：`Execute` 时发 MCP `tools/call`。

### 2.3 注册与调用流程

```text
每一轮开始
  手机 ──GET /healthz（1.5s 超时）──▶ agentd
      不通 → 本轮只有本地工具
      通   → MCP tools/list（按 ETag 缓存）→ 合并进工具清单

模型调用 sandbox_exec
  手机：把本会话草稿的 manifest {path: sha256} 发过去
  agentd：返回缺哪些 blob → 手机上传缺的（zstd）
  agentd：在会话的沙箱里还原 /workspace，执行命令
  agentd：返回 stdout/stderr（截断）、退出码、/workspace 里改过的文件、/out 里的产物（图片、CSV）
  手机：改过的文件写进草稿 → 走现有变更卡；产物作为附件显示在回复里
```

云端的 agent 循环反过来也是同一套：它的工具清单 = 只读账本工具（作用于快照）+ 沙箱工具 + `finish`（交回结果）。它没有 `ask_user`，需要用户决定时以 `needs_input` 状态结束，问题随结果回到手机（见第 5 节）。

### 2.4 委派（`delegate`）

```jsonc
// 模型调用
{ "task": "把 2024 年所有支付宝账单重新分类，规则见 memory.md", "include": ["**/*.bean", "agent/memory.md"], "notify": true }
// 立即返回
{ "runId": "run_01J…", "status": "queued" }
```

手机在会话里显示一张「云端任务」卡：排队 / 运行中（第 N 步）/ 完成 / 需要你回答 / 失败。完成后，卡片上直接是熟悉的变更卡。

---

## 3. 账本同步、冲突与隐私边界

### 3.1 同步：内容寻址快照，不依赖存储方式

账本可能在本机、Git 或 iCloud 文件夹里，所以云端**不去 clone 仓库**，而是由手机上传：

- 手机算出当前代（generation）或草稿的 manifest：`{path → sha256, size}`。
- agentd 按 sha256 存 blob（`blobs/<sha>`，zstd），只要缺的。日常改一笔，只传一个文件。
- 一个快照 = 一个 manifest 的哈希（`base`）。run 和沙箱都记住自己的 `base`。
- 默认只传 `.bean`、`agent/memory.md`、技能文件；`documents/` 里的 PDF、图片默认不传，任务声明 `include` 时才传。
- 100k 交易级别的账本首次上传约几 MB 到二十几 MB（压缩前），之后基本是增量。

Git 存储的用户以后可以加一个优化（云端直接按 commit 拉），但不放进第一版，因为它需要把 GitHub token 交给云端。

### 3.2 结果与冲突：复用三方合并

云端从不写账本，只回一个**补丁**：`{base, files: {path → 新内容 | 删除}}`。

- **同步工具（`sandbox_exec`）**：调用期间草稿只被这一轮改，直接把改动写进草稿，没有冲突问题。
- **异步任务（`delegate`）**：结果回来时，账本和草稿可能都变了。用现成的
  `LedgerAgentMerge.plan(base: run.base, draft: run.result, current: 当前 stage)`，和撤销、`rebaseAgentDraft` 是同一条路：
  - 能合的直接合；`.bean` 同位置插入两边都保留；
  - 冲突文件以账本为准，并在会话里提示模型“这几个文件云端的改动和账本冲突，请重做”，下一轮本地重做或再委派一次。
- **来自云端的改动一律要用户点一下才写入**，即使开了「改完自动写入」。理由：后台任务和外部事件（邮件内容）有提示词注入风险，人工确认是最后一道闸。等用了一段时间再考虑放开。

### 3.3 隐私与密钥边界

| 东西 | 在哪 | 不在哪 |
|---|---|---|
| 手机上的模型 key | 手机 Keychain | 永不上传 |
| 云端的模型 key | agentd 的 env 文件 | 不进沙箱容器 |
| 设备令牌（手机 → agentd） | 手机 Keychain；服务端只存哈希，可吊销 | — |
| GitHub token | 手机 | 不给云端 |
| 账本快照 blob | agentd 磁盘（主机全盘加密），最后一次引用后 7 天回收 | 不进日志 |
| 云端 run 的 transcript | agentd 的 SQLite，可在 App 里一键删除 | — |

沙箱容器：

- gVisor（`runsc`）运行时，非 root，只读根文件系统，`/workspace` 和 `/out` 可写；CPU / 内存 / 时长上限。
- **默认断网**。需要装包时走一个只放行 PyPI 镜像的出口代理；“抓网页”这类需要外网的任务由 run 显式申请，并在手机卡片上标出来。
- 容器里没有任何密钥，没有模型 key：模型调用发生在 agentd 进程里，不在沙箱里。
- 推送通知文字在隐私保护打开时只写“云端任务完成”，不带金额、账户名。

---

## 4. 云端运行时选型与成本

使用量估算（单人）：每天 30 次沙箱调用，平均 2 分钟 ≈ 每月 30 小时沙箱时间；后台任务每天几次。成本大头仍然是模型 token，和现在一样。

| 方案 | 做法 | 每月成本（估） | 优点 | 缺点 |
|---|---|---|---|---|
| **A. 自建 Go 小服务 + Docker/gVisor（推荐）** | `ledger-agentd` 单二进制 + SQLite + 本机 Docker 起沙箱 | 用现有自托管主机：≈ 0；新开一台小 VPS：约 5 美元级 | 账本不出自己的机器；和仓库同语言；agent 内核与手机共用；没有新供应商 | 要自己维护主机、沙箱隔离；家里主机断电就没了 |
| B. 自建服务 + 托管沙箱（Modal / E2B） | agentd 同上，沙箱调 Modal / E2B | 30 小时 × 约 0.07–0.12 美元/小时 ≈ 2–4 美元，Modal 每月有 30 美元免费额度，E2B 有一次性 100 美元额度 | 沙箱零运维、隔离更强 | 账本内容交给第三方（美国）；多一跳延迟；国内访问不稳定 |
| C. Cloudflare（Worker + Durable Objects + Containers/Sandbox） | 收件箱用 DO/D1，定时用 Cron Triggers，沙箱用 Containers | Workers 付费版 5 美元/月起，用量很小 | 全球可达，收件箱/定时/串行天然契合 | 收件箱要用 TS 重写，Go 内核只能跑在容器里；两种语言两套部署 |
| E. 自托管的“开源 Managed Agents”：[Omnara](https://github.com/omnara-ai/omnara)（Go，Apache-2.0） | 在主机上用 compose 跑 Omnara（API、worker、Postgres、Redis、blob），代码跑在 gVisor 容器里的 `omnarad`；云端改账本只能调一个由手机执行的自定义工具 `propose_ledger_change`，调用会停住等手机合并、你确认后交回结果 | 自有主机 ≈ 0 | 收件箱、worker、cron、SSE、webhook 都现成；“改账本必须你点头”由它的自定义工具机制天然保证 | 主机上多一整套服务要维护；云端循环和手机上的 PiG 是两套；项目年轻，API 可能变；要自己写 Swift 客户端（只有 TS SDK） |
| D. 托管 agent 服务（Claude Managed Agents、OpenAI 托管等） | 整个 agent 交给厂商 | 按量 | 最省事 | 锁死单一模型厂商，和“多 provider”的选择冲突；账本和 transcript 都在厂商那里 |

价格来源：Modal 官方定价页（沙箱按 3 倍非抢占价计费）、Cloudflare Containers 定价页、以及 Fly.io 2026-09 的沙箱价格对比文章（E2B、Daytona 等的数字来自这篇第三方文章，未逐个核对官网）。

**推荐 A，并保留 B 作为备胎：** 沙箱做成接口 `Sandbox{Prepare, Exec, Collect, Destroy}`，第一版实现 `dockerSandbox`，以后要省运维时加一个 `modalSandbox` 适配器即可，其余不动。

部署要点：

- 优先放在已有的自托管 Docker 主机上（`docs/headscale-local-cicd.md` 里那台），和现有 compose 并排。**前提是那台机器还在常开**；如果不是，换一台小 VPS，设计不变。
- **对外暴露用 Cloudflare Tunnel，不要求手机连 Headscale。** iOS 同一时间只能开一个 VPN，手机若在用代理访问模型服务，就连不上 tailnet。
- 如果主机在国内，agentd 访问模型厂商要配 `HTTPS_PROXY`。
- agentd 作为 `server/cmd/ledger-agentd`，和 `ledger-web` 同一个 Go module，复用 MCP、令牌、日志等代码。

---

## 5. 事件驱动与推送回传

完全按用户给的图来：

```text
事件 ──▶ Handler（HTTP） ──1. 写入（按 ID 去重）──▶ inbox 表
            └──2. 唤醒（进程内 channel）──▶ Worker
Worker ──3. 取 pending（按会话串行）──▶ 4. 启动 run（agent 循环）──▶ 5. 等完成
       ──6. 标 done，写 outbox ──▶ 推送（Bark）──▶ 手机拉 outbox、合并、展示
```

### 5.1 事件来源与 ID（去重的关键）

| 事件 | 来源 | 事件 ID（幂等键） | 会话 |
|---|---|---|---|
| 手机委派一个任务 | `POST /v1/events` | 手机生成的消息 UUID | 会话 ID |
| 用户回答了 `needs_input` | `POST /v1/events` | 手机生成的消息 UUID | 会话 ID |
| 定时任务到点 | agentd 内置调度器 | `cron:<scheduleId>:<计划时刻>` | 定时任务自己的会话 |
| 新邮件（以后） | Gmail 推送 / 轮询 | `gmail:<messageId>` | 按规则 |
| 后台作业完成（沙箱长命令） | agentd 自己 | `job:<jobId>:done` | 发起它的会话 |

手机网络断了重发、调度器重启补跑、邮件推送重复投递，ID 都一样，`INSERT … ON CONFLICT(id) DO NOTHING` 直接丢掉，对应图里的 dropped。

### 5.2 表结构（SQLite）

```sql
CREATE TABLE inbox (
  id          TEXT PRIMARY KEY,         -- 幂等键
  kind        TEXT NOT NULL,            -- delegate | user_reply | cron | email | job_done
  session_id  TEXT,                     -- 同一会话串行
  payload     TEXT NOT NULL,            -- JSON
  status      TEXT NOT NULL,            -- pending | running | done | failed
  run_id      TEXT,
  attempts    INTEGER NOT NULL DEFAULT 0,
  lease_until INTEGER,                  -- worker 租约，崩溃后可回收
  created_at  INTEGER NOT NULL,
  done_at     INTEGER
);
CREATE TABLE outbox (                   -- 给手机拉取的结果
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT, run_id TEXT,
  kind       TEXT,                      -- progress | done | needs_input | failed
  payload    TEXT,                      -- 摘要、补丁 manifest、问题
  acked_at   INTEGER
);
```

### 5.3 Worker 规则

- **按会话串行**：一个会话同时只有一个 run；同一会话里积压的多条 pending 合并进同一个 run（图里两条同 Chat ID 的 pending 就是这个意思）。不同会话可以并行，上限 2。
- **租约**：取任务时设 `lease_until = now + 5min`，run 每步续约；进程崩溃后租约过期，事件回到 pending，`attempts+1`，3 次后 failed 并通知。
- **双保险唤醒**：handler 写完立即通过进程内 channel 唤醒 worker；另有 30 秒一次的扫表兜底。
- **run 的结果**写入 outbox：`done`（摘要 + 补丁）、`needs_input`（问题 + 选项，手机用 `ask_user` 卡片呈现，回答作为新事件回来，run 从 transcript 续跑）、`failed`。

### 5.4 推送回传

App 是 SideStore 个人团队签名，**拿不到 APNs**，所以：

- **推送用 Bark**（App Store 上的推送 App，支持自建服务端和加密推送）。agentd 完成后调 Bark，`url` 参数带 `ledger://agent?run=<runId>`，点通知直接跳回我们的 App。不装 Bark 也行，只是没有即时提醒。现有 Telegram 机器人可以作为另一个渠道。
- **手机拉取**：回到前台、`BGAppRefreshTask`、点了推送，都调 `GET /v1/outbox?after=<seq>`，处理完 ack。outbox 是唯一可靠来源，推送只是“快来拉”的提醒，丢了也不影响正确性。

---

## 6. 分阶段落地

### 第 0 阶段：本地 `run_python`（不需要服务器）

目标：离线也能用 python 算账。做法见第 7.3 节。验收：问“按月算一下近两年餐饮支出的趋势和同比”，助手写 python 在手机上算出来；断网也能用。

### 第 1 阶段：云端沙箱工具

目标：手机上的助手能跑 bash，以及装任意包的 python。

- 抽 `agentcore`：先只抽工具描述和 `remoteTool` 适配器，循环暂不动。
- `ledger-agentd`：设备令牌鉴权、blob 存储、`/mcp` 暴露 `sandbox_exec`、Docker + gVisor 沙箱（每会话一个，空闲 10 分钟销毁），镜像内置 Python 3、beancount 3、beanquery、pandas、matplotlib、openpyxl、pdfplumber。
- 手机：设置里加「云端」（地址 + 令牌 + 连通性测试）；每轮健康检查，不通就隐藏云端工具；`sandbox_exec` 改动进草稿、`/out` 产物显示为附件。
- 部署：自托管主机 + Cloudflare Tunnel。
- 不做：收件箱、推送、委派、定时。

验收：问“按月算一下近两年餐饮支出的趋势并做季节性分解”，助手用 python 算出来并出图；断网时同一问题退回 BQL 版本。

### 第 2 阶段：委派与收件箱

- 抽出完整 `agentcore` 循环，agentd 跑云端 agent。
- inbox / outbox 表、worker、租约、去重；`delegate` 工具和「云端任务」卡片；结果走 `LedgerAgentMerge`。
- Bark 推送 + 前台/后台拉取。
- `needs_input` 往返。

### 第 3 阶段：定时与外部事件

- 定时任务表 + 调度器（App 里一个列表，助手也能用工具创建），例如“每月 1 号对账并生成月报”“每天拉一次汇率写 price”。
- 接入邮件等外部事件，复用旧服务里的 Gmail 代码。
- 可选：整段会话“固定在云端”（每条消息都成为该会话的 inbox 事件）。

### 以后再看

- 沙箱换托管（Modal / E2B）适配器。
- Git 存储用户直接按 commit 同步。
- 放开云端改动的自动写入。

## 7. 手机本地沙箱：能不能像 ServerBox 那样内置一个 Alpine

Borui 看到 [ServerBox](https://github.com/madeye/ServerBox) 想到能不能在 App 里内置 Alpine。调研结论：**ServerBox 的做法搬不到 iOS 上，内置完整 Linux 也不推荐；推荐用 App 已有的 CPython 做一个本地 `run_python`。**

### 7.1 ServerBox 是怎么做的

- 它是 **Android** App（GPL-3.0，UserLAnd 的分叉），用 **PRoot** 在用户态跑 Alpine / Debian 等发行版：PRoot 靠 `ptrace` 截获系统调用、改写路径，跑的是原生 arm64 二进制。另有一条走 Android 虚拟化框架（AVF）的真虚拟机路线。
- iOS 上这两条都走不通：App 沙箱里**没有 `fork` / `exec` / `ptrace`**，不能启动任何子进程；第三方 App 也拿不到 Hypervisor 能力。

### 7.2 iOS 上真正可行的几条路

| 方案 | 原理 | 能做什么 | 体积（估） | 速度 | 问题 |
|---|---|---|---|---|---|
| **A. 内置 CPython 跑 `run_python`（推荐）** | 复用已内置的 BeeWare CPython 3.14，在进程内执行模型写的代码 | python 标准库、beancount、beanquery；纯 python 包；numpy/pandas 需要 iOS 版的二进制包（BeeWare 有 iOS wheel 的构建链，具体可用版本待核实） | 已有，几乎不增加；加 numpy/pandas 约多几十 MB | 原生速度 | 没有 bash、不能 `subprocess`；进程内执行，隔离靠审计钩子，属于“尽力而为” |
| B. iSH 式 x86 模拟 + Alpine | [iSH](https://github.com/ish-app/ish)：用户态 x86 模拟 + 系统调用翻译，线程化解释器，不需要 JIT，已上架 App Store | 真正的 Alpine（i386）：`apk add`、bash、python3 | rootfs 几 MB，装上 python 后几十 MB | 解释执行，明显比原生慢（经验上大约一个数量级，未实测）；`pip install` 很慢 | iSH 是完整 App，不是可嵌入库，要抽它的内核和模拟器；32 位 x86，很多现代包没有 i386 版本；后台被挂起就停 |
| C. WKWebView 里跑 WASM（Pyodide，或 WASM 里的 x86 虚拟机跑 Alpine） | WebKit 的 WebContent 进程有 JIT，第三方 App 自己的进程没有 | Pyodide 带 numpy/pandas；虚拟机路线有真 Linux | Pyodide 加科学计算包约几十 MB；虚拟机镜像更大 | Pyodide 尚可；WASM 里再模拟 x86 很慢 | 要在网页和原生之间搬文件；App 进后台后 WebContent 进程会被节流或挂起，和助手的后台运行冲突 |
| D. a-Shell 式 `ios_system` | [a-Shell](https://github.com/holzschu/a-shell)（BSD-3）把 ls/grep/sed/awk/curl/python 等编成进程内函数，C 程序编成 WASM 跑 | 一个“像 shell”的环境 | 中等 | 原生 | 不是真 bash；python 只能装纯 python 包；集成工作量不小 |
| E. QEMU 解释模式跑完整 VM（UTM SE 那种） | 不用 JIT 的 TCG 解释器 | 完整 aarch64 Alpine | 上百 MB | 非常慢 | 不实用 |
| F. 开 JIT（SideStore + StikDebug） | 调试器附加后允许 JIT，配合 QEMU/UTM | 接近能用的 VM | 上百 MB | 尚可 | 每次启动都要手动开 JIT，iOS 一升级就可能失效，不能当默认依赖 |

### 7.3 推荐：本地 `run_python`

- **执行**：在已有的嵌入解释器里，开一个独立命名空间运行模型写的代码；工作目录是本会话的草稿副本（`runtime/agent/<id>/workspace`），改动自然进草稿、走变更卡。
- **限制**：
  - 超时（例如 30 秒）后用异步异常打断；输出截断。
  - `sys.addaudithook` 拦截 `socket`、`subprocess`、`os.system`，`open` 只允许草稿目录和一个临时输出目录。这只是尽力而为的隔离（代码是你自己的模型写的，草稿本来就是副本），**不当安全边界**，真要隔离的任务交给云端。
  - 与 Beancount 校验共用一把 GIL：执行时串行，校验优先。
- **产物**：写到输出目录的 PNG/CSV 作为附件显示在回复里（matplotlib 能用的前提是有 iOS 版的包）。
- **路由**：本地 `run_python` 优先；需要 bash、任意 `pip install`、联网、长时间运行、后台或定时，才走云端。
- **先核实**：BeeWare 生态目前能拿到哪些 iOS 版 numpy / pandas / matplotlib，以及加进 IPA 后的体积。拿不到就先只提供标准库 + beancount，这已经覆盖大部分“BQL 算不了”的统计。

## 不做什么

- 不用单独的路由模型。
- 云端不直接写账本、不拿 GitHub token。
- 不复用旧的 Bub（Python）agent，也不用托管 agent 服务，以免锁定单一模型厂商。
- 第一版不做多设备、多用户。
- 不在 App 里内置完整 Linux（iSH 式模拟、WASM 虚拟机、QEMU）。

## 需要 Borui 确认的

1. 那台自托管主机是否还常开、在国内还是海外（决定部署位置和是否要代理）。
2. 推送用 Bark 可以吗（还是只靠回到 App 时拉取）。
