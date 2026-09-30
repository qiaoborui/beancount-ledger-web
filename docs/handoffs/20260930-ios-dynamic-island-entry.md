# Handoff: iOS 动态岛灵动入账动画 (Apple Wallet / Pay Style)

- **Task ID**: `20260930-ios-dynamic-island-entry`
- **Status**: `completed`
- **Last Updated**: `2026-09-30 13:45:00 +08:00`
- **Branch**: `codex/ios-dynamic-island-entry`
- **PR**: https://github.com/qiaoborui/beancount-ledger-web/pull/501 (MERGEABLE, OPEN)

## 需求与实现总结

1. **核心诉求**:
   - 摆脱全宽通知条和生硬文字弹窗，打造类似 Apple Wallet / Apple Pay 的沉浸式灵动岛入账动效。
   - 非全宽（224pt × 68pt 紧凑胶囊）、纵向层次适中、微动效细腻、字数精简，杜绝无意义假银行卡堆砌。
   - 完整支持四种业务形态：支出（Expense）、收入（Income）、转账（Transfer，带双向对流图标）、批量账单导入（Batch Import）。

2. **设计与原型**:
   - 原型演示：[dynamic_island_entry_demo.html](file:///Users/qiaoborui/Developer/beancount/beancount-ledger-web/docs/design/dynamic_island_entry_demo.html)（Canvas 高拟真交互动画）。

3. **代码变更**:
   - [`App/LedgerMobile/Sources/LedgerModels.swift`](file:///Users/qiaoborui/Developer/beancount/beancount-ledger-web/App/LedgerMobile/Sources/LedgerModels.swift): 新增 `LedgerIslandNotice` 及 `LedgerIslandNoticeType`，支持自动从 Beancount Entry 提取分类、图标、金额与账户。
   - [`App/LedgerMobile/Sources/LedgerIslandEntryView.swift`](file:///Users/qiaoborui/Developer/beancount/beancount-ledger-web/App/LedgerMobile/Sources/LedgerIslandEntryView.swift): 编写 SwiftUI 灵动岛弹窗组件，包含 Apple Pay 式环形对勾描边、图标微弹（Spring 物理回弹）、触觉反馈（UINotificationFeedbackGenerator）及 2.3s 自动平滑收缩撤回。
   - [`App/LedgerMobile/Sources/RootView.swift`](file:///Users/qiaoborui/Developer/beancount/beancount-ledger-web/App/LedgerMobile/Sources/RootView.swift): 全局挂载 `LedgerIslandOverlayContainer`，顶层悬浮，不遮挡下层手势。
   - [`App/LedgerMobile/Sources/LedgerSession.swift`](file:///Users/qiaoborui/Developer/beancount/beancount-ledger-web/App/LedgerMobile/Sources/LedgerSession.swift): 在新建记账 `addLocalTransaction`、对账账单提交 `commitImport` 时自动触发灵动岛。
   - [`App/LedgerMobile/Sources/BookkeepingPreviewView.swift`](file:///Users/qiaoborui/Developer/beancount/beancount-ledger-web/App/LedgerMobile/Sources/BookkeepingPreviewView.swift): 确认记账方案后即时弹出灵动岛动效。
   - [`App/LedgerMobile/Tests/LedgerIslandNoticeTests.swift`](file:///Users/qiaoborui/Developer/beancount/beancount-ledger-web/App/LedgerMobile/Tests/LedgerIslandNoticeTests.swift): 单元测试覆盖各类事务的灵动岛通知解析。

## 验证与测试
- `swift test`: 87/87 core tests passed.
- Xcode Scheme 测试: 669/669 app tests passed (0 failures).
- Xcode 编译测试: `LedgerMobile` iOS Simulator target build 正常通过。
- PR 状态: 501 MERGEABLE。
