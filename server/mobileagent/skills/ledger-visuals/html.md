# 高级产物：artifact-html

原生组件画不出来时才用：需要自己算的交互（还贷、储蓄、退休计算器）、拖动滑块看结果的模拟、特殊图形。能用 visual 组件表达的，一律用 artifact 代码块，它更快、更稳，也跟 App 的样式一致。

## 格式

````
```artifact-html
{"id":"emergency-fund","title":"应急金计算器","summary":"按近 6 个月平均支出算应急金够撑几个月"}
<style>…</style>
<div>…</div>
<script>…</script>
```
````

- 第一行是一个 JSON 对象：id（小写字母、数字、连字符）、title、summary，必须写在同一行。
- 后面是页面正文：直接写 <style>、HTML 和 <script>，不写 <!doctype>、<html>、<head>、<body>，App 会套上自己的外壳。
- 整个代码块不超过 200 KB。修改已有的 HTML 产物时沿用同一个 id，写出完整的新页面。

## 沙盒限制

- 没有网络：不能加载外部脚本、样式、图片、字体，不能 fetch、XHR、WebSocket，也不能跳转到别的网页。图表请用内联 SVG 或 <canvas> 自己画，不要引用任何库。
- 不能弹窗（alert 无效）、不能打开新窗口、没有 localStorage 持久化，每次打开都是全新的页面。
- 页面在产物全屏页里显示，自带滚动，宽度跟手机屏幕一样，要按窄屏排版。

## window.ledger

- `await ledger.query(bql)`：只读运行一条 SELECT、BALANCES 或 JOURNAL 查询，返回 {columns:[{name,type}], rows:[[...]], truncated}。money 类型的列已经是元单位。一次打开最多 60 条查询，每条最多 5000 行。查询失败会抛出错误，要 try/catch 并在页面上显示一句说明。
- `await ledger.rows(bql)`：同上，但每行是 {列名: 值} 的对象，更好用。
- `ledger.open("ledger://...")`：打开账本页面，只能在用户点按的处理函数里调用；页面里的 <a href="ledger://..."> 链接点了会自动打开。
- `ledger.ask("问题")`：把一个追问发给助手，同样只能在点按时调用，适合「问助手怎么调整」这类按钮。
- `ledger.today`（yyyy-mm-dd）、`ledger.currency`（估值币种）、`ledger.format(n, 小数位)`（1,820.5）、`ledger.compact(n)`（1.2万）。

查询语法和 run_bql 完全相同。写页面之前，先用 run_bql 把每条查询都跑一遍，确认列名和数值对得上，再写进页面；页面每次打开都会重新查询，所以数据总是最新的，不需要把数字写死在页面里。

## 样式

页面已经有 App 的配色，作为 CSS 变量提供，并会跟随深色模式：--page（背景）、--sunken（卡片底）、--ink（正文）、--secondary、--meta（次要文字）、--rule、--rule-strong（分隔线）、--income（绿）、--expense（红）、--blue、--orange、--purple、--teal。一律用这些变量，不要写死颜色。字体、表格、按钮已有基础样式，数字加 class="num" 用等宽数字。保持安静克制：少用阴影和渐变，圆角 8 到 12。

## 示例

```artifact-html
{"id":"emergency-fund","title":"应急金计算器","summary":"按近 6 个月平均支出，算应急金够撑几个月"}
<style>
.card{background:var(--sunken);border-radius:12px;padding:14px 16px;margin:12px 0}
.big{font-size:30px;font-weight:600}
.meta{color:var(--meta);font-size:13px}
input[type=range]{width:100%;accent-color:var(--ink)}
.bad{color:var(--expense)}.good{color:var(--income)}
</style>
<div class="card"><div class="meta">近 6 个月平均月支出</div><div class="big num" id="avg">…</div></div>
<div class="card"><div class="meta">现有现金和存款</div><div class="big num" id="cash">…</div></div>
<label class="meta">目标：撑 <b id="months-label">6</b> 个月</label>
<input type="range" id="months" min="1" max="24" value="6">
<div class="card"><div class="meta">需要的应急金</div><div class="big num" id="need">…</div><div class="meta" id="gap"></div></div>
<p class="meta" id="error"></p>
<button id="ask">问助手怎么补足缺口</button>
<script>
(async () => {
  const $ = (id) => document.getElementById(id);
  let avg = 0, cash = 0;
  const render = () => {
    const months = Number($("months").value);
    $("months-label").textContent = months;
    const need = avg * months;
    $("need").textContent = ledger.format(need, 0) + " 元";
    const gap = cash - need;
    $("gap").className = "meta " + (gap >= 0 ? "good" : "bad");
    $("gap").textContent = gap >= 0 ? "已经够了，多出 " + ledger.compact(gap) + " 元" : "还差 " + ledger.compact(-gap) + " 元";
  };
  try {
    const spend = await ledger.rows("SELECT month, sum(value) AS total FROM postings WHERE account LIKE 'Expenses:%' GROUP BY month ORDER BY month DESC LIMIT 6");
    avg = spend.reduce((sum, row) => sum + row.total, 0) / Math.max(spend.length, 1);
    const [assets] = await ledger.rows("SELECT sum(value) AS total FROM postings WHERE account LIKE 'Assets:Cash%' OR account LIKE 'Assets:Bank%'");
    cash = assets ? assets.total : 0;
    $("avg").textContent = ledger.format(avg, 0) + " 元";
    $("cash").textContent = ledger.format(cash, 0) + " 元";
    render();
  } catch (error) {
    $("error").textContent = "没能读取账本：" + error.message;
  }
  $("months").addEventListener("input", render);
  $("ask").addEventListener("click", () => ledger.ask("我的应急金目标是 " + $("months").value + " 个月，怎么补足缺口？"));
})();
</script>
```
