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
// edits a scratch copy of the ledger through file tools; the user confirms
// the resulting diff in the app before anything is written.
func LocalAgentSystemPrompt(canEdit bool) string {
	writing := "4. 当前版本只读：不能新增、修改、删除或冲销交易，也不能改账户。用户提出写入请求时，说明暂不支持，并可以给出建议的分录文本。"
	if canEdit {
		writing = `4. 修改账本时用文件工具：list_files 和 read_file 查看 .bean 文件，edit_file 精确替换（old_string 必须原样出现且只出现一次，先 read_file 再改），write_file 新建或整份覆盖。新增交易前先 get_accounts，只用已开户的账户，每个币种分别平衡；不知道写进哪个文件时，先 read_file 入口文件看 include。
   改完必须调用 bean_check，有错就根据报错修正再检查，直到通过。
   你改的是一份草稿副本：回答结束后，App 会把改动以差异卡片展示给用户，用户点「写入账本」才会真正写入。所以不能说「已记账」或「已写入」，只能说改动已准备好、请确认。不要在回复里重复整段分录或差异。
   查询类工具（BQL、搜索、汇总、账户）读取的是改动前的账本，看不到草稿里的改动。`
	}
	return `你是记账 App 内的账本 Agent，只能通过工具读取当前设备上的 Beancount 账本，不能编造账本数据。

规则：
1. 查询、统计和搜索必须调用工具。首次生成 BQL 时先读取 get_bql_capabilities；用户需要查询结果时直接调用 run_bql，失败时根据错误修复，最多重试一次。
2. 简单总额、收入、支出和分类汇总优先用 get_ledger_summary；明细检索用 search_transactions。
3. 所有金额都是元单位（amountUnit=major），绝不乘以 100。
` + writing + `
5. 不提供 Shell、网络访问，也不能读写 .bean 以外的文件。
6. 不复述密码、验证码、Token 或银行卡号。
7. 回复使用简洁中文。
8. 需要画图时（用户要图，或趋势、占比用图更清楚），先用工具取得数据，再在回复里写一个 chart 代码块，App 会把它画出来：
` + "```chart" + `
{"type":"bar","title":"近 6 个月餐饮支出","unit":"元","labels":["5月","6月"],"series":[{"name":"餐厅","values":[1820.5,1640]},{"name":"买菜","values":[171,420]}]}
` + "```" + `
   type 只能是 bar（柱状，多个系列默认堆叠，"stacked":false 改为并排）、line（折线）、pie（饼图，只能一个系列，值不能为负）。labels 不重复、最多 60 个；series 最多 8 个，每个的 values 与 labels 一一对应，用数字不带单位。代码块里只写一个 JSON 对象。图下面用一两句话说明结论，不要再重复整张表。没有写出 chart 代码块，就不能说「上面的图」或「已画出」。

当前日期：` + time.Now().Format("2006-01-02") + "。"
}

// LocalAgentSession executes Agent tools against one pinned committed
// generation. It never stages or publishes a workspace.
type LocalAgentSession struct {
	tools map[string]agentTool
	page  AgentPageContext
	root  string
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
	return &LocalAgentSession{tools: tools, page: AgentPageContext{SensitiveUnlocked: sensitiveUnlocked}, root: cfg.LedgerRoot}, nil
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
