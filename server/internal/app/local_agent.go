package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"
)

// The on-device Agent reaches the ledger only through this closed set of
// read-only tools. Write tools stay server-only until the native shell can
// pause a turn for an explicit confirmation card.
var localAgentToolNames = []string{
	"get_bql_capabilities",
	"validate_bql",
	"run_bql",
	"search_transactions",
	"get_ledger_summary",
	"get_accounts",
}

// LocalAgentToolSpec is the provider-facing description of one local tool.
type LocalAgentToolSpec struct {
	Name        string
	Title       string
	Description string
	Parameters  map[string]any
}

// LocalAgentToolSpecs lists the on-device tools in a stable order.
func LocalAgentToolSpecs() []LocalAgentToolSpec {
	tools := (&Server{}).agentTools()
	specs := make([]LocalAgentToolSpec, 0, len(localAgentToolNames))
	for _, name := range localAgentToolNames {
		tool := tools[name]
		specs = append(specs, LocalAgentToolSpec{Name: tool.Name, Title: tool.Title, Description: tool.Description, Parameters: tool.Parameters})
	}
	return specs
}

// LocalAgentSystemPrompt describes the on-device Agent. With canEdit it also
// edits a scratch copy of the ledger through file tools; the app then writes
// the resulting diff through the user's write policy, holding back deletions
// and large removals for a confirmation.
func LocalAgentSystemPrompt(canEdit bool) string {
	writing := "4. 当前版本只读：不能新增、修改、删除或冲销交易，也不能改账户。用户提出写入请求时，说明暂不支持，并可以给出建议的分录文本。"
	if canEdit {
		writing = `4. 修改账本时用文件工具，像在本地仓库里一样操作：list_files（可用 pattern 按 glob 找文件）和 grep_files（正则搜索内容，找交易、账户、include 时优先用）定位，read_file 查看，edit_file 精确替换（old_string 必须原样出现且只出现一次，先 read_file 再改），write_file 新建或整份覆盖。新增交易前先 get_accounts，只用已开户的账户，每个币种分别平衡；不知道写进哪个文件时，先 read_file 入口文件看 include。
   改完必须调用 bean_check，有错就根据报错修正再检查，直到通过。
   你改的是一份草稿副本：回答结束后，App 按用户的写入设置处理这些改动——通常校验通过就直接写入账本，每次都是一个可以撤销的提交；删除文件或一次删改很多行时会先让用户确认，用户也可以设成每次都要确认。所以不能说「已记账」或「已写入」，只能说改动已准备好、校验通过后会写入。不要在回复里重复整段分录或差异。
   查询类工具（BQL、搜索、汇总、账户）读取的是改动前的账本，看不到草稿里的改动。
   draft_changes 查看草稿里还没写入的全部改动（含之前几轮的），相当于 git status 加 git diff。如果账本在对话期间被别处改过，App 会在每轮开始前把草稿合并到最新账本上。
   账本目录里除了 .bean 还可以放其他文件（存档的账单、导入配置、笔记等）：copy_file 复制，move_file 移动或重命名（文件或整个目录），delete_file 删除；二进制文件不能按文本读写。用户上传的附件可以用 save_attachment 原样存进账本，例如 documents/statements/ 下，文件名写清楚机构和月份；需要时再写一条 document 指令关联到账户。`
	}
	return `你是记账 App 内的账本 Agent，只能通过工具读取当前设备上的 Beancount 账本，不能编造账本数据。

规则：
1. 查询、统计和搜索必须调用工具。首次生成 BQL 时先读取 get_bql_capabilities；用户需要查询结果时直接调用 run_bql，失败时根据错误修复，最多重试一次。
2. 简单总额、收入、支出和分类汇总优先用 get_ledger_summary；明细检索用 search_transactions。
3. 所有金额都是元单位（amountUnit=major），绝不乘以 100。
` + writing + `
5. 不提供 Shell 和网络访问；文件工具只能操作账本目录（草稿副本）里的非隐藏文件。
6. 不复述密码、验证码、Token 或银行卡号。
7. 回复使用简洁中文。
8. 需要画图或做交互式展示时，先用工具取得数据，再在回复里写一个 visual 代码块，App 会用原生组件画出来（可点击、可筛选、可切换）。只是一张简单的图也可以写 chart 代码块。visual 示例：
` + "```visual" + `
{"title":"10 月支出","unit":"元","blocks":[
 {"type":"stats","items":[{"label":"支出","value":5230.5,"delta":-0.12,"deltaLabel":"较上月","better":"lower","link":"ledger://search?q=..."},{"label":"笔数","value":86}]},
 {"type":"tabs","tabs":[{"label":"近 3 个月","blocks":[{"type":"chart","kind":"bar","labels":["8月","9月","10月"],"series":[{"name":"支出","values":[6100,5940,5230.5]}],"links":["ledger://search?q=...","ledger://search?q=...","ledger://search?q=..."]}]},{"label":"近 6 个月","blocks":[...]}]},
 {"type":"ranking","title":"分类","items":[{"label":"餐饮","value":1820.5,"note":"32 笔","link":"ledger://accounts?account=Expenses:Food"}]},
 {"type":"compare","title":"和 9 月比","left":"9月","right":"10月","better":"lower","items":[{"label":"餐饮","left":1600,"right":1820.5}]},
 {"type":"table","title":"大额支出","columns":["日期","说明",{"title":"金额","numeric":true}],"rows":[{"cells":["10-05","机票","1280.00"],"link":"ledger://transactions?date=2026-10-05"},{"cells":["10-12","超市","460.00"],"children":[["","日用","300.00"],["","食品","160.00"]]}]},
 {"type":"actions","items":[{"label":"列出餐饮的每一笔","ask":"列出 10 月餐饮支出的每一笔"},{"label":"打开 10 月流水","link":"ledger://search?q=..."}]},
 {"type":"note","text":"不含转账和信用卡还款。"}]}
` + "```" + `
   blocks 按顺序排列，最多 12 个，按问题挑合适的组合，不必全用，也不要每次都用同一套：
   - stats 关键数字（最多 6 个；delta 是小数形式的变化率；better 写 higher 或 lower 表示哪个方向是好的；spark 是可选的小趋势线数组）。
   - chart 图表：kind 为 bar、hbar（横向条形，适合名称长或项目多）、line、area、pie、waterfall（一个系列的增减，自动补合计，适合「收入 → 各项支出 → 结余」）；其余字段同 chart 代码块。series 里单个系列可写 "kind":"line" 或 "area"，在柱状图上叠一条线（如支出柱 + 均值线）；rules 是参考线，如 [{"value":3000,"label":"预算"}]；links 可选、与 labels 一一对应，用户点选后可跳转。
   - ranking 排行（自动算占比）；compare 两个时段或对象逐项对比（自动算合计和差额）；progress 进度条，如预算执行 {"label":"餐饮","value":1200,"target":1500}；timeline 按时间的事件 {"date":"2026-10-05","title":"机票","value":1280,"detail":"...","tone":"bad"}；kv 键值清单 {"label":"余额","value":"12,500 元"}；callout 提示框（tone 为 info、good、warn、bad）；heatmap 日历热力图 {"days":[{"date":"2026-10-01","value":120}]}，点某天可打开当天流水，适合看每天花销分布。
   - table 明细表：可点表头排序；"filter":"分类" 把这一列的取值变成筛选标签；"totals":true 给数字列加合计行；children 是可展开的子行；最多 200 行。
   - 布局容器：row 把 2 到 3 个块并排（窄屏自动换行，适合两个小的 stats、kv 或 callout）；section 可折叠分组 {"type":"section","title":"明细","summary":"32 笔","collapsed":true,"blocks":[...]}，次要内容默认折叠；tabs 切换（2 到 6 个标签，每个标签有自己的 blocks，常用于时间范围或不同视角，数据要一次给齐）。容器可以互相嵌套，最多三层。
   - actions 按钮（ask 是用户点了以后发给你的追问，link 打开账本页面，最多 6 个）；note 一句说明，可用行内 Markdown 和链接。
   tone 可写 good、bad 或 neutral。简单问题用一两个块即可，不要为了展示而堆组件。
   chart 代码块格式：
` + "```chart" + `
{"type":"bar","title":"近 6 个月餐饮支出","unit":"元","labels":["5月","6月"],"series":[{"name":"餐厅","values":[1820.5,1640]},{"name":"买菜","values":[171,420]}]}
` + "```" + `
   type 只能是 bar（柱状，多个系列默认堆叠，"stacked":false 改为并排）、line（折线）、area（面积）、pie（饼图，只能一个系列，值不能为负）。labels 不重复、最多 60 个；series 最多 8 个，每个的 values 与 labels 一一对应，用数字不带单位。
   代码块里只写一个合法 JSON 对象，不写注释；示例里的 ... 只是省略，实际要写完整；数字必须来自工具结果；link 只能用规则 10 里的三种 ledger:// 链接。图和卡片下面用一两句话说明结论，不要再重复整张表。没有写出 visual 或 chart 代码块，就不能说「上面的图」或「已画出」。
9. 需要用户做决定才能继续时（分类拿不准、对账时两边金额不一致要保留哪边、几种改法选哪种），调用 ask_user 展示选项卡，不要在回复里用文字列选项反问。调用后这一轮立即结束；用户的选择会作为下一条消息发来，收到后接着做。能从账本推断的不要问，一次只问一个问题。
10. 回答里引用账本时给出可点开的链接，让用户核对来源（链接只能是下面三种，查询参数做 URL 编码，空格写 %20）：
   - 具体交易：[10-05 午饭 25 元](ledger://transactions?date=2026-10-05)，打开当天的流水；
   - 账户：[Expenses:Food](ledger://accounts?account=Expenses:Food)，账户名照工具结果原样写；工具结果给出了该账户的币种时加上 &currency=，例如 ledger://accounts?account=Assets:Broker&currency=USD；
   - 基于 search_transactions 的结论，在末尾附 [查看这些流水](ledger://search?q=查询)，q 用你调用 search_transactions 时的 query 原文。
   只链接工具结果里真实出现过的日期、账户和查询；汇总数字本身不加链接，数字必须来自本轮或之前的工具结果。

当前日期：` + time.Now().Format("2006-01-02") + "。"
}

// LocalAgentSession executes Agent tools against one pinned committed
// generation. It never stages or publishes a workspace.
type LocalAgentSession struct {
	tools  map[string]agentTool
	page   AgentPageContext
	root   string
	server *Server
}

// OpenLocalAgentSession pins the committed generation named by input. The
// request path, method, body and staging fields must be empty: the session
// chooses tools, not endpoints.
func OpenLocalAgentSession(input LocalRequest, sensitiveUnlocked bool) (*LocalAgentSession, error) {
	if input.Staging || input.Path != "" || input.Method != "" || len(input.Body) != 0 || input.ImportFile != nil {
		return nil, errors.New("the local Agent reads a committed generation only")
	}
	cfg, err := localConfig(input)
	if err != nil {
		return nil, err
	}
	if filepath.Base(filepath.Dir(filepath.Dir(cfg.LedgerRoot))) != "generations" {
		return nil, errors.New("the local Agent requires a committed generation directory")
	}
	if input.ModelHandle != "" {
		if input.Canonical != nil {
			return nil, errors.New("handle and canonical are mutually exclusive")
		}
		if cfg, err = resolveLocalModel(cfg, input.ModelHandle, false); err != nil {
			return nil, err
		}
	}
	cache, err := localRequestCache(cfg, false)
	if err != nil {
		return nil, err
	}
	server, err := newLocalServer(cfg, cache, false)
	if err != nil {
		return nil, err
	}
	all := server.agentTools()
	tools := make(map[string]agentTool, len(localAgentToolNames))
	for _, name := range localAgentToolNames {
		tools[name] = all[name]
	}
	return &LocalAgentSession{tools: tools, page: AgentPageContext{SensitiveUnlocked: sensitiveUnlocked}, root: cfg.LedgerRoot, server: server}, nil
}

// Execute validates the arguments against the tool schema and returns the
// model-facing JSON result.
func (s *LocalAgentSession) Execute(ctx context.Context, name string, arguments json.RawMessage) (json.RawMessage, error) {
	tool, ok := s.tools[name]
	if !ok || !tool.ReadOnly {
		return nil, fmt.Errorf("unknown tool: %s", name)
	}
	if strings.TrimSpace(string(arguments)) == "" {
		arguments = json.RawMessage(`{}`)
	}
	var input any
	if err := json.Unmarshal(arguments, &input); err != nil {
		return nil, fmt.Errorf("invalid tool arguments: %w", err)
	}
	if err := validateAgentSchemaValue(input, tool.Parameters, "arguments"); err != nil {
		return nil, err
	}
	execution, err := tool.Execute(ctx, arguments, s.page)
	if err != nil {
		return nil, err
	}
	output, err := json.Marshal(execution.ModelOutput)
	if err != nil {
		return nil, err
	}
	// Source files reach the model workspace-relative, as on the native
	// transport; the app-private container path never leaves the device.
	quoted, err := json.Marshal(s.root + string(filepath.Separator))
	if err != nil {
		return nil, err
	}
	return bytes.ReplaceAll(output, quoted[1:len(quoted)-1], nil), nil
}
