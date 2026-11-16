---
name: ledger-visuals
description: 画图和做产物时的组件手册：桑基图、矩形树图、环形进度、矩阵热力表、流水列表的写法和示例。做产物、面板或较复杂的 visual 前先读。
---

# 图表和产物组件手册

系统提示里的规则 8 列了基础组件（stats、chart、ranking、compare、progress、timeline、kv、callout、heatmap、table、actions、note 和 row、section、tabs 容器）。这里补充更多组件的完整写法。下面每个示例都是能直接画出来的 visual，数字只是示意，实际一律来自工具结果。

挑组件的思路：
- 钱从哪来、到哪去（工资进了哪些账户、又花到哪些分类）→ sankey。
- 一个整体由哪些部分组成，而且部分很多（几十个商户、两层分类）→ treemap；部分少于 8 个时用 ranking 或 pie 更清楚。
- 一个比例对着目标（储蓄率、预算用掉多少、还款进度）→ gauge；多条预算并列时 progress 更省地方。
- 两个维度交叉（分类 × 月份、账户 × 季度）→ matrix。
- 要让用户看到具体是哪几笔 → transactions，比 table 更像 App 里的流水。

## sankey 资金流向

`flows` 里每一条是一段流动：from、to、value（正数），可选 link。节点按流向自动分列：没有来源的在最左边，每个节点排在它最远来源的右边一列。形成环的那一条会被丢掉，所以不要把转账写成来回两条。节点最多 30 个，flows 最多 60 条。点一个节点会列出它的流入和流出。

```visual
{"title":"10 月资金流向","unit":"元","blocks":[
 {"type":"sankey","flows":[
  {"from":"工资","to":"招行储蓄卡","value":20000},
  {"from":"理财收益","to":"余额宝","value":320},
  {"from":"招行储蓄卡","to":"信用卡还款","value":6200},
  {"from":"招行储蓄卡","to":"余额宝","value":8000},
  {"from":"信用卡还款","to":"餐饮","value":1820.5,"link":"ledger://accounts?account=Expenses:Food"},
  {"from":"信用卡还款","to":"交通","value":640},
  {"from":"信用卡还款","to":"购物","value":3739.5}]}]}
```

节点名写人能看懂的名字（「招行储蓄卡」而不是完整账户名），同一个节点在所有 flow 里写法要一致。

## treemap 矩形树图

items 和 ranking 一样（label、value、note、link），value 必须为正。可带一层 children：点开父块后显示它的子块，上方有返回。最多 40 项。

```visual
{"title":"今年支出构成","unit":"元","blocks":[
 {"type":"treemap","items":[
  {"label":"餐饮","value":21840,"note":"412 笔","children":[{"label":"外卖","value":9300},{"label":"餐厅","value":8400},{"label":"买菜","value":4140}]},
  {"label":"居住","value":36000,"link":"ledger://accounts?account=Expenses:Housing"},
  {"label":"交通","value":5120},
  {"label":"购物","value":12800}]}]}
```

## gauge 环形进度

每项 label、value；有 max 时按 value/max 画，没有 max 时 value 本身就是 0 到 1 的比例。target 在环上画一个刻度（和 value 同一个单位），better 决定超过目标是好是坏（higher 或 lower）。最多 6 个，自动排成网格。

```visual
{"blocks":[
 {"type":"gauge","title":"今年目标","better":"higher","items":[
  {"label":"储蓄率","value":0.34,"target":0.3},
  {"label":"应急金","value":42000,"max":60000,"note":"目标 6 个月开支"},
  {"label":"房贷已还","value":318000,"max":1200000}]}]}
```

## matrix 矩阵热力表

columns 是列名数组；rows 每行有 label、values（与 columns 一一对应，没有数据写 null），可选 link。格子按数值大小深浅着色，点格子显示行、列和占该行的比例。"totals":true 加合计行和合计列。最多 40 行、24 列，列多时可横向滑动。

```visual
{"title":"分类 × 月份","unit":"元","blocks":[
 {"type":"matrix","totals":true,"columns":["7月","8月","9月","10月"],"rows":[
  {"label":"餐饮","values":[1700,1950,1600,1820.5],"link":"ledger://accounts?account=Expenses:Food"},
  {"label":"交通","values":[420,610,380,640]},
  {"label":"旅行","values":[null,5200,null,1280]}]}]}
```

## transactions 流水列表

items 每笔：date（yyyy-mm-dd）、payee 和 narration 至少一个、amount（钱流出写负数，流入写正数）、可选 account、currency、tags（最多 4 个）、link。同一天的排在同一个日期下面，按给出的顺序。默认显示 10 笔，其余折叠。点一行打开当天流水，写了 link 就打开 link。最多 100 笔。

```visual
{"title":"10 月大额支出","unit":"元","blocks":[
 {"type":"transactions","items":[
  {"date":"2026-10-12","payee":"盒马","narration":"日用和食品","account":"Expenses:Food:Groceries","amount":-460},
  {"date":"2026-10-05","payee":"东航","narration":"上海—成都机票","account":"Expenses:Travel","amount":-1280,"tags":["国庆"]},
  {"date":"2026-10-05","payee":"公司","narration":"差旅报销","account":"Income:Reimbursement","amount":1280}]}]}
```
