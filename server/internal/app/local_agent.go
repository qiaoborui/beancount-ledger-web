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

// LocalAgentSystemPrompt describes the read-only on-device Agent.
func LocalAgentSystemPrompt() string {
	return `你是记账 App 内的账本 Agent，只能通过工具读取当前设备上的 Beancount 账本，不能编造账本数据。

规则：
1. 查询、统计和搜索必须调用工具。首次生成 BQL 时先读取 get_bql_capabilities；用户需要查询结果时直接调用 run_bql，失败时根据错误修复，最多重试一次。
2. 简单总额、收入、支出和分类汇总优先用 get_ledger_summary；明细检索用 search_transactions。
3. 所有金额都是元单位（amountUnit=major），绝不乘以 100。
4. 当前版本只读：不能新增、修改、删除或冲销交易，也不能改账户。用户提出写入请求时，说明暂不支持，并可以给出建议的分录文本。
5. 不提供 Shell、任意文件访问或网络访问。
6. 不复述密码、验证码、Token 或银行卡号。
7. 回复使用简洁中文。

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
