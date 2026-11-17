# 账本定时任务（ledger-automation）

在一台常开、能访问模型网关的机器上（现在是 mibook）按时跑账本的定时任务。设计见
[账本自动巡检任务设计](https://claude.ai/artifact/VSRep3fk7XVhNcZNcJFxy9) 的“二次修订”一节。

- 任务是账本仓库里的 `automations/<id>.md`，手机和电脑都能改，随 Git 同步。
- systemd 定时器每 5 分钟跑一次 `ledger-automation tick`：拉账本，找出到期的任务，先跑确定性巡检（不调模型），再用和手机同一套 Go 助手核心无界面跑一轮。
- 结果写到账本仓库的 `automation-runs` 分支，`main` 永远不写。助手的改动只是一个草稿补丁，要在手机上确认。
- 跑完用 Bark 推一条通知。

## 任务文件

```markdown
---
name: 每日巡检
schedule: daily 21:00        # hourly | hourly :15 | daily HH:MM | weekly mon,thu HH:MM | monthly 1 HH:MM
timezone: Asia/Singapore     # 可选，默认取 LEDGER_AUTOMATION_TIMEZONE
enabled: true                # 可选，默认 true
model: <模型 id>              # 可选，覆盖默认模型
thinking: low                # 可选：off|minimal|low|medium|high|xhigh|max
audit: true                  # 可选，默认 true：先跑确定性巡检，把结果交给助手
---

提示词正文……
```

示例：[docs/examples/automations/daily-audit.md](examples/automations/daily-audit.md)。文件名就是任务 id（小写字母、数字、`-`）。写错的文件只影响它自己，`tick` 日志和 `check` 输出会列出原因。

调度规则：

- 每个计划时刻（slot）最多跑一次。机器停了一阵，恢复后只补跑每个任务最近的一个 slot。
- 新建的任务，如果最近的 slot 已经过去 15 分钟以上，只记下来不跑，等下一个 slot。
- 模型调不通时，一次运行内会隔 30 秒、2 分钟再试；仍失败记为 `degraded`，巡检结果照样保存并推送，之后每 20–60 分钟重试助手部分，slot 过去 2 小时还不行就记为 `failed`。
- 失败通知每个任务每天最多一条。

## 确定性巡检

`server/internal/app/local_audit.go`，不调模型：

| 检查 | 判定 |
|---|---|
| `duplicate` | 同一资产/负债账户、同金额、相隔 ≤ 3 天，且 payee 相同或来自不同文件；共享 link 的不算 |
| `unresolved` | 记在 `*:Uncategorized` / `*:Unknown`、带 `!` 标记、payee/备注里有 FIXME/TODO |
| `stale-balance` | 对过账的未关闭资产/负债账户，最近一次 `balance` 超过 45 天且之后仍有交易 |
| `unincluded` | 工作区里的 `.bean` 不在 `main.bean` 的 include 链里（`archive/`、`skills/`、`audits/`、`automations/` 除外） |

交易类检查只看最近 180 天。每条发现带内容指纹（`check:hash`），行号变了也不变，用来判断“新问题”。

## 运行记录（`automation-runs` 分支）

```
state.json                      每个任务的上次 slot、状态、重试计划、已报过的指纹
runs/<运行 id>/run.json         状态、提交号、摘要、发现数、是否有草稿、耗时
runs/<运行 id>/findings.json    确定性巡检结果（模型挂了也有）
runs/<运行 id>/conversation.json  App 历史格式（LedgerAgentSavedConversation v1）
runs/<运行 id>/transcript       助手 transcript，手机接着聊时原样带上
runs/<运行 id>/draft.patch      相对 run.json 里那个提交的补丁，git apply 可用
runs/<运行 id>/draft/base/…     草稿改到的每个文件在那个提交里的样子（新增的文件没有）
runs/<运行 id>/draft/after/…    助手改完的样子（删掉的文件没有）；run.json 的 draftFiles 列出这些路径
```

运行 id 形如 `20261117T1300Z-daily-audit`（slot 的 UTC 时间 + 任务 id，手动运行加 `-manual`）。默认只保留最近 200 次。

## 在手机上看结果、接着聊

用 Git 同步的账本会顺带拉 `automation-runs` 分支（单独的缓存，不碰账本自己的同步状态）：

- 账本助手的侧边栏多了「定时任务」，列出每次运行的状态、摘要、发现数和草稿；有新运行时旁边显示数字。下拉刷新，打开侧边栏时最多每 2 分钟自动拉一次。
- 跑成功的运行会作为对话加进侧边栏的历史（带时钟图标），每次运行只加一次；删掉就不会再回来，接着聊过的保留手机上的版本。
- 打开这个对话就能接着聊，助手拿到的是主机上那一轮的完整 transcript。第一次打开时，主机的草稿用三方合并（`draft/base` → `draft/after` 合到手机当前的草稿上）载入改动卡片，永远要手动确认才写入；账本后来改过同一处的文件保留账本内容并在卡片上说明。长按运行可以「重新载入草稿」。
- Bark 通知的链接 `ledger://automation/run?id=<运行 id>` 直接打开那次运行的对话。

## 在 mibook 上安装

二进制在别处编好再拷过去（mibook 内存紧，不在上面编译）：

```bash
cd server
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -o ledger-automation ./cmd/ledger-automation
scp ledger-automation mibook:/tmp/
```

在 mibook 上：

```bash
sudo install -m 755 /tmp/ledger-automation /usr/local/bin/ledger-automation
sudo useradd --system --home-dir /var/lib/ledger-automation --shell /usr/sbin/nologin ledger-automation
sudo install -d -m 750 -o root -g ledger-automation /etc/ledger-automation

# 账本仓库的 deploy key（GitHub 仓库 Settings → Deploy keys，勾选 Allow write access）
sudo ssh-keygen -t ed25519 -N '' -C ledger-automation@mibook -f /etc/ledger-automation/deploy-key
# mibook 连不上 GitHub 的 22 端口，走 ssh.github.com:443（仓库地址见 env）。
# 在 mibook 上 ssh-keyscan 拿不到回应，改从一次普通连接里取主机公钥，
# 再核对指纹是 GitHub 公布的 SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU：
ssh -p 443 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/gh_known_hosts -T git@ssh.github.com || true
ssh-keygen -lf /tmp/gh_known_hosts
sudo tee /etc/ledger-automation/known_hosts </tmp/gh_known_hosts >/dev/null && rm /tmp/gh_known_hosts

# 密钥文件：不用的留空文件即可（systemd 要求文件存在）
sudo install -m 640 -o root -g ledger-automation /dev/null /etc/ledger-automation/model-key
sudo install -m 640 -o root -g ledger-automation /dev/null /etc/ledger-automation/bark-key
sudo install -m 640 -o root -g ledger-automation /dev/null /etc/ledger-automation/bark-encryption-key
sudoedit /etc/ledger-automation/model-key          # 模型网关（magpie：magpie gateway-key add ledger-automation）给自动化单独发的 key
sudoedit /etc/ledger-automation/bark-key           # Bark App 里的 device key
sudoedit /etc/ledger-automation/bark-encryption-key  # 可选：Bark App 加密推送设置里的 32 位 key（AES-256-CBC）
sudo chgrp ledger-automation /etc/ledger-automation/deploy-key && sudo chmod 640 /etc/ledger-automation/deploy-key

sudo install -m 640 -o root -g ledger-automation docker/systemd/ledger-automation.env.example /etc/ledger-automation/env
sudoedit /etc/ledger-automation/env                 # 填仓库地址和模型 id
sudo install -m 644 docker/systemd/ledger-automation.service docker/systemd/ledger-automation.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

先手动验证，再开定时器：

```bash
sudo systemd-run --pipe --wait -p User=ledger-automation -p StateDirectory=ledger-automation \
  -p EnvironmentFile=/etc/ledger-automation/env \
  -p LoadCredential=model-key:/etc/ledger-automation/model-key \
  /usr/local/bin/ledger-automation check        # 只读：列出任务和下次 slot
sudo systemctl start ledger-automation.service   # 跑一次 tick
journalctl -u ledger-automation -n 50
sudo systemctl enable --now ledger-automation.timer
```

立即跑某个任务：用上面 `check` 那条 `systemd-run` 命令（加上 bark 的两个 `LoadCredential`），把最后换成 `ledger-automation run daily-audit`。手机上的“立即运行”在第三阶段接。

### 保护 main

deploy key 有写权限，所以在账本仓库加一条 ruleset：`main` 禁止直接推送（Restrict updates），deploy key 不在绕过名单里。这样它只能写 `automation-runs`。

### 资源

- systemd 单元限制 `MemoryMax=768M`、不允许用 swap、`Nice=10`、空闲 IO 优先级。
- 磁盘：`/var/lib/ledger-automation` 里是账本镜像、一份导出的工作区和一份运行记录，大约是账本仓库大小的 3 倍。
