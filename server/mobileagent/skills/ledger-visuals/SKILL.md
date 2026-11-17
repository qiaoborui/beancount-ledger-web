---
name: ledger-visuals
description: 画图和做产物时的组件手册：桑基图、矩形树图、环形进度、矩阵热力表、流水列表、样式和变体的写法和示例；附带 html.md 讲高级 HTML 产物。做产物、面板或较复杂的 visual 前先读。
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

## 样式和变体

任何块都能加样式，不写就是默认样子。样式可以直接写在块上，也可以放进 `style` 对象：

- card：true 时给块加一层卡片底和细边，适合把一组关键数字或一段结论框出来。
- accent：块里图形的强调色，可选 green、red、blue、orange、purple、teal、pink、gray、ink（默认）。会传给容器里的子块，所以给 section 或 tabs 设一次就行。收入相关用 green，支出和超支用 red，其余按主题挑，一页里不要超过三种。
- footnote：块下面的一行小字，写数据口径或截至日期，可用行内 Markdown。
- variant：同一种块的另一种画法，不认识的值按默认画。
- columns：stats 和 kv 固定几列（1 到 4）。

各块的 variant：
- stats：hero 把第一个数字放大作为主角，其余在下面排成小卡；list 每个数字一行，适合窄的 row 里。
- ranking：compact 不画条，只留名称、金额和占比。
- progress：ring 把每一项画成环，适合三四个预算并排。
- heatmap：month 画成月历，每格写日期和金额，左右翻月；再加 "scale":"diverging" 时正数绿、负数红，适合看每天净收支。
- note：quote 引用样式（左边一道强调色）、lead 大一号的导语、muted 小字。
- table、timeline、transactions：compact 更紧凑，省去次要的一行。

chart 的额外参数：
- "stacked":"percent" 把每个标签的各系列堆成 100%，轴自动显示百分比，适合看构成随时间的变化。
- "showValues":true 在柱子上写数值（堆叠的多系列柱不写，避免挤在一起）。
- "height"：图的高度，120 到 480，默认 200。
- "axis"："percent" 表示数值本身是比例（0.32 显示成 32%）；默认按 1.2万 这样的写法。
- series 里每个系列可写 color（同 accent 的颜色名）、"dashed":true（虚线，适合预测或预算线）、curve（smooth 默认、linear、step）。

table 的列可写 {"title":"变化","signed":true}：正数显示 + 并标绿，负数标红。

```visual
{"title":"本月概览","subtitle":"数据截至 2026-11-16","unit":"元","blocks":[
 {"type":"stats","variant":"hero","style":{"card":true,"footnote":"不含转账和信用卡还款"},"items":[{"label":"本月结余","value":8240,"delta":0.18,"deltaLabel":"较上月","better":"higher"},{"label":"收入","value":20320},{"label":"支出","value":12080}]},
 {"type":"heatmap","variant":"month","scale":"diverging","title":"每日净收支","days":[{"date":"2026-11-01","value":-320},{"date":"2026-11-05","value":20000},{"date":"2026-11-06","value":-1280}]},
 {"type":"chart","kind":"bar","stacked":"percent","title":"支出构成的变化","labels":["9月","10月","11月"],"series":[{"name":"餐饮","values":[1600,1820.5,1400]},{"name":"居住","values":[3000,3000,3000]},{"name":"其他","values":[2100,1500,900]}]},
 {"type":"chart","kind":"line","title":"余额走势","height":240,"labels":["9月","10月","11月","12月"],"series":[{"name":"实际","values":[42000,45800,52000,52000]},{"name":"预测","values":[42000,45800,52000,57000],"dashed":true,"color":"gray"}]},
 {"type":"row","blocks":[
  {"type":"progress","variant":"ring","title":"预算","items":[{"label":"餐饮","value":1400,"target":2000},{"label":"购物","value":2600,"target":2000}]},
  {"type":"ranking","variant":"compact","accent":"blue","title":"商户","items":[{"label":"盒马","value":860},{"label":"美团","value":640}]}]},
 {"type":"table","variant":"compact","title":"各账户变化","columns":["账户",{"title":"变化","signed":true}],"rows":[["招行储蓄卡","3200"],["信用卡","-1280"]]},
 {"type":"note","variant":"quote","text":"本月比上月多存了 **1,260 元**，主要来自购物减少。"}]}
```

## 高级 HTML 产物

原生组件实在做不到时（计算器、模拟器、自定义交互或图形），可以写 artifact-html 代码块，在没有网络的沙盒里运行，只能只读查询账本。写之前读附带文件：`load_skill(name="ledger-visuals", file="html.md")`。
