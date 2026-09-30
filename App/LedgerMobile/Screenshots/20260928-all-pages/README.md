# iOS 全页面截图覆盖清单

状态：partial。已导出 52 张真实模拟器 PNG；仍有失败测试和未触达页面。

- 任务：`20260928-ios-all-pages-screenshots`
- 源码：`main` / `94c07e6968ccc1224f8a06cdab06dbfd36bf181c`
- 数据：仅使用 Debug `--safe-preview`、`--safe-import-flow` 和隔离的 `--local-ui-testing` 虚拟账本。
- 阻塞：当前会话无法访问 CoreSimulatorService；simctl 返回 Operation not permitted / Connection refused。
- 验收：每个可达页面及独立功能弹窗均有实际模拟器 PNG；长页补充滚动截图；记录文件名、入口、数据模式、设备和系统版本；逐张检查，不以源码清单替代截图。

## 主页面（均待截图）

- [ ] 财务概览
- [ ] 流水
- [ ] 账户
- [ ] 更多
- [ ] 搜索
- [ ] 资产分析
- [ ] 收支分析
- [ ] 投资分析
- [ ] 币种分析
- [ ] BQL 查询（表格及图表）
- [ ] 导入历史
- [ ] 分类管理
- [ ] 设置

## 导航页及弹窗（源码提取，均待运行时核对与截图）

动态标题按实际页面展开；通用标题包装器不计作独立页面。

- [ ] `AccountsView.swift:557` — `.navigationTitle(detail?.label ?? account.split(separator: ":").last.map(String.init) ?? account)`
- [ ] `AddAccountView.swift:297` — `.navigationTitle("新建账户")`
- [ ] `AddCategoryView.swift:230` — `.navigationTitle("新建分类")`
- [ ] `BeanTransactionImport.swift:71` — `.navigationTitle("导入 Beancount 交易")`
- [ ] `BookkeepingPreviewView.swift:90` — `.navigationTitle("确认账本改动")`
- [ ] `BookkeepingSettingsView.swift:131` — `.navigationTitle("语义解析设置")`
- [ ] `EventTagViews.swift:71` — `.navigationTitle("事件与项目核算")`
- [ ] `EventTagViews.swift:360` — `.navigationTitle("#\(tag)")`
- [ ] `EventTagViews.swift:400` — `.navigationTitle("事件文件导出")`
- [ ] `EventTagViews.swift:842` — `.navigationTitle("事件核算单导出")`
- [ ] `GlobalSearchView.swift:143` — `.navigationTitle("#" + tag)`
- [ ] `GlobalSearchView.swift:183` — `}.navigationTitle("导入文件")`
- [ ] `GlobalSearchView.swift:196` — `.navigationTitle("搜索")`
- [ ] `GlobalSearchView.swift:543` — `.navigationTitle("#" + tag)`
- [ ] `GlobalSearchView.swift:647` — `.navigationTitle("筛选搜索结果")`
- [ ] `ImportClassificationSettingsView.swift:54` — `.navigationTitle("智能分类")`
- [ ] `InstitutionPickerSheet.swift:100` — `.navigationTitle("选择机构与银行")`
- [ ] `LocalLedgerStorageView.swift:82` — `.navigationTitle("存储与同步")`
- [ ] `LocalLedgerStorageView.swift:205` — `.navigationTitle("添加 Git 账本")`
- [ ] `LocalLedgerViews.swift:176` — `.navigationTitle("账本")`
- [ ] `LocalLedgerViews.swift:265` — `.navigationTitle(importing ? "导入本地账本" : "新建本地账本")`
- [ ] `LocalLedgerViews.swift:330` — `.navigationTitle("本地文件")`
- [ ] `LocalLedgerViews.swift:356` — `.navigationTitle(path)`
- [ ] `LocalLedgerViews.swift:463` — `.navigationTitle("编辑账本")`
- [ ] `NativeImportFlowView.swift:139` — `.navigationTitle(currentTitle)`
- [ ] `NativeImportFlowView.swift:1447` — `.navigationTitle("编辑交易")`
- [ ] `NaturalLanguageBookkeepingView.swift:103` — `.navigationTitle("用一句话记账")`
- [ ] `NaturalLanguageBookkeepingView.swift:898` — `.navigationTitle("调整日期")`
- [ ] `NaturalLanguageBookkeepingView.swift:921` — `.navigationTitle("修改交易信息")`
- [ ] `OnboardingWizardView.swift:135` — `.navigationTitle(navigationTitleForCurrentStep)`
- [ ] `OnboardingWizardView.swift:886` — `.navigationTitle("添加账户")`
- [ ] `PendingInboxView.swift:140` — `.navigationTitle("待整理账单")`
- [ ] `PendingInboxView.swift:838` — `.navigationTitle("选择分类")`
- [ ] `PendingInboxView.swift:889` — `.navigationTitle("补全商户与备注")`
- [ ] `ReconciliationView.swift:340` — `.navigationTitle("账户对账")`
- [ ] `ReconciliationView.swift:931` — `.navigationTitle("校对余额")`
- [ ] `RootView.swift:304` — `.navigationTitle("欢迎使用 Ledger")`
- [ ] `RootView.swift:372` — `.navigationTitle(authenticated ? "账本已锁定" : "登录 Ledger")`
- [ ] `RootView.swift:519` — `.navigationTitle("Ledger")`
- [ ] `SettingsView.swift:337` — `.navigationTitle("底部标签栏")`
- [ ] `TimeRangePicker.swift:158` — `.navigationTitle("时间范围")`
- [ ] `TransactionShareView.swift:586` — `.navigationTitle(sheetTitle)`
- [ ] `TransactionShareView.swift:849` — `.navigationTitle("导出流水文字")`
- [ ] `TransactionViews.swift:1315` — `.navigationTitle("\(day) 支出")`
- [ ] `TransactionViews.swift:1583` — `.navigationTitle("筛选交易")`
- [ ] `TransactionViews.swift:1872` — `.navigationTitle(selectedCount == 1 ? "添加标签" : "批量添加标签")`
- [ ] `TransactionViews.swift:1990` — `.navigationTitle("资金分录")`
- [ ] `TransactionViews.swift:2386` — `.navigationTitle("交易详情")`
- [ ] `TransactionViews.swift:2706` — `.navigationTitle("删除交易")`
- [ ] `TransactionViews.swift:3324` — `.navigationTitle(transaction == nil ? "记一笔" : "编辑交易")`
- [ ] `TransactionViews.swift:4189` — `.navigationTitle("记账日期")`
- [ ] `TransactionViews.swift:4813` — `.navigationTitle(transaction == nil ? "记一笔 (高级)" : "编辑交易 (高级)")`
- [ ] `TransactionViews.swift:4873` — `.navigationTitle("交易预览")`

## 需额外展开的状态（均待截图）

- [ ] 首次设置向导：欢迎、账户、分类、汇总，每一步分别截图。
- [ ] 导入流程：准备、解析后的候选列表、重复条目、分类选择、编辑候选、写入预览、结果。
- [ ] 交易：普通及高级新建/编辑、各交易类型、筛选、批量选择、标签、删除确认、分享与导出。
- [ ] 概览及分析长页面：顶部及下部；日期范围选择。
- [ ] 搜索：最近搜索、结果、过滤器、标签及导入文件详情。
- [ ] 本地账本：列表、新建、导入、编辑、文件浏览、文件编辑、存储同步、Git 配置。
- [ ] 设置：标签栏配置、语义解析、智能分类、隐私锁定。
- [ ] 系统选择器与分享面板：只展示虚拟数据。

## 执行方式

参考 `../../README.md` 的 Visual QA 段落及 `../../UITests/`。先验证模拟器服务可用，再用当前 revision 的 Debug 构建。既有 UI 测试含 XCTAttachment 截图，但并不保证覆盖上述全部页面。从 xcresult 导出后仍需逐项补齐及视觉检查。

尚未生成图片，也未运行截图测试。


## 本次运行

- 设备：iPhone 17 Pro / iOS 27.0。
- PNG：52 张，索引见 [INDEX.md](INDEX.md)。
- XCTest 结果保留在 `/private/tmp/ledger-ui.xcresult`。
- 失败测试：`testChartAxesPreserveTimeSpacingAndTouchShowsSelections`、`testCompactLedgerShowsCategoriesAndAlignedTitles`、`testCompactTabBarCanAddReorderAndOpenDestination`、`testMorePreservesOverflowNavigationAcrossTabs`、`testNativeImportPreviewSelectionAndCommitFlow`、`testReadOnlyNavigationAndResponsiveSurfaces`、`testTransactionDraftDismissalKeepsChangesUntilDiscarded`、`testTransactionEditingAndBulkTaggingFlow`、`testCreateOfflineLedgerAddTransactionAndRestart`。这些测试关联的部分附件仍已导出，但不视为完整验收。
