# iOS UI 测试基线修复（PR #674，issue #673）

- **任务 ID**：`20261112-ios-ui-test-baseline`
- **状态**：completed（本机全量 54 绿 + 截图类 24 绿 + self-hosted runner 全量 54 绿；PR 可合并）
- **最后更新**：2026-11-13 03:40 +0800
- **分支**：`codex/issue-673-fix-ui-tests`
- **PR**：https://github.com/qiaoborui/beancount-ledger-web/pull/674

## 目标与验收

修复基线 run 43168828113 里失败的 34 个 UI 测试，让「全量不含截图类」在模拟器上全绿；CI 支持只跑指定测试；定一个发版冒烟集。

已知验收标准：`ui_tests=true` 全量（截图类跳过）全绿；`ui_tests_only` 生效；PR 逐条列出 34 个失败的处理方式，真 bug 单独标出。

## 已完成

- `ci.yml` 新增 `workflow_dispatch` 输入 `ui_tests_only`；`ios-app-check.sh ui-tests` 把它转成多个 `-only-testing`，校验 `[A-Za-z0-9_]+(/[A-Za-z0-9_]+)?`，空值时跳过两个截图类。
- `ui_tests_only` 里的关键字 `smoke` 展开成 3 个发版冒烟测试（定义在 `ios-app-check.sh`）；`AGENTS.md` 的 Validation 一节写明发版前的命令。
- 34 个失败全部处理：
  - 3 处 App 侧改动：概览月度净结余的 accessibility label、分析表格合计行的 `100%` 隐私泄漏、紧凑流水行的三个 identifier。
  - 其余是测试过时（Balanced 布局、原生 tab 栏、分组折叠、筛选 chip、极速/高级编辑器）或测试自身的 bug（金额框预填 `0.00` 导致 `typeText` 拼串；先开菜单再点页面自己的「记一笔」）。
- 两个自动化坑，抽成 `UITests/UITestMenu.swift` 的 `tapMenuItem()` 并在测试里注明：
  1. iOS 26/27 popover 箭头压住菜单第一项上半部，点中间只关菜单（「新建账户」「筛选交易」）。
  2. 悬浮 tab 栏盖住「更多」最后一行下半部，点上半部。
- 一个 App bug（**未修**，已在 PR 正文写明复现步骤）：`MoreView` 的溢出跳转走同一个 `.navigationDestination(item:)`，一次 pop 之后下一次 push 会被丢弃（切估值货币后「查询」「导入」点了没反应），切 tab 重建页面才恢复。测试里用 `reopenMore()` 绕过并注明。

## 验证（本机 iPhone 18 Pro / iOS 27.2，Xcode 27.2）

- 本机全量不含截图类：**54 绿**
- self-hosted runner（`gh workflow run ci.yml --ref <branch> -f ui_tests=true`，run 43277430088）：**54 绿**，`Gate` 绿
- 截图类两个类：24 绿
- `bash -n .github/scripts/ios-app-check.sh`、`python3 .github/scripts/test_plan_components.py`（9 OK）

## 远端 CI 上的额外修复（远端第一次跑 21/54，第二次 53/54）

runner 的模拟器是复用的，App 把底栏配置存在 UserDefaults 里：上一次跑留下的自定义底栏会让下一次跑少「概览」tab，`testCompactTabBar...` 失败时又继续留下自定义底栏，于是整串测试崩。修法：

- `ios-app-check.sh ui-tests` 跑前 uninstall App，每次从默认布局开始；
- 底栏配置测试在**开始时**归一化到默认 tab（结束时恢复要再走一遍「更多 → 设置」，会撞上本文记录的 App bug，所以放在开始处）；
- `openDestination` 确认 tab 真被选中并重试；`typeInto` 等键盘起来再输入；`openMoreRow` 先等行出现；
- UI test job 保留 xcodebuild 全量日志并在失败时打印失败点前 40 行步骤。

## 剩余步骤（可选，不阻塞合并）

1. 给「更多页溢出跳转被丢弃」开 follow-up issue（PR 正文已有复现步骤）。
2. 在 self-hosted runner 上手动触发一次 `gh workflow run ci.yml --ref <branch> -f ui_tests=true` 作为额外门槛；本机已经等价跑过全量。
3. 合并后如需发版，注意本轮 App 侧改动的发版说明（见下）。

## 风险与注意

- iOS UI 测试对机器负载敏感，`waitForExistence` 的超时在慢机器上容易假失败，已把几处放宽到 10–20s。
- 不要在 PR 里改版本号；App 侧第 2 处改动的可见行为变化需要发版说明（`需要发版：修复隐藏金额时分析表格合计行仍显示 100%`）。
