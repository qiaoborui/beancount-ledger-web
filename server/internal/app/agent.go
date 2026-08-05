package app

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"
)

type AgentMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type AgentPageContext struct {
	Page              string `json:"page,omitempty"`
	Path              string `json:"path,omitempty"`
	Start             string `json:"start,omitempty"`
	End               string `json:"end,omitempty"`
	ValuationCurrency string `json:"valuationCurrency,omitempty"`
	BQLQuery          string `json:"bqlQuery,omitempty"`
	SensitiveUnlocked bool   `json:"-"`
}

type AgentTurnRequest struct {
	SessionID      string           `json:"sessionId,omitempty"`
	Message        string           `json:"message"`
	Context        AgentPageContext `json:"context,omitempty"`
	ApprovalPolicy string           `json:"approvalPolicy,omitempty"`
}

func (r AgentTurnRequest) Validate() error {
	if strings.TrimSpace(r.Message) == "" {
		return errors.New("message is required")
	}
	if len(r.Message) > 12000 {
		return errors.New("message is too long")
	}
	if containsSensitiveAgentContent(r.Message) {
		return errors.New("请勿在 Agent 对话中输入密码、验证码、令牌或完整卡号")
	}
	if r.ApprovalPolicy != "" && r.ApprovalPolicy != "on-write" && r.ApprovalPolicy != "always" {
		return errors.New("approvalPolicy must be on-write or always")
	}
	return nil
}

type AgentArtifact struct {
	ID    string `json:"id"`
	Type  string `json:"type"`
	Title string `json:"title"`
	Data  any    `json:"data"`
}

type agentToolSpec struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Parameters  map[string]any `json:"parameters"`
}

type agentTool struct {
	agentToolSpec
	Title            string
	RequiresApproval bool
	ApprovalMessage  string
	ExecutionStatus  string
	// ReadOnly is an explicit registry declaration.  Write tools always require
	// approval; read tools can still be paused by the user's "always" policy.
	ReadOnly bool
	Execute  func(context.Context, json.RawMessage, AgentPageContext) (agentToolExecution, error)
}

type agentToolExecution struct {
	ModelOutput   any
	ClientOutput  any
	Artifacts     []AgentArtifact
	RefreshLedger bool
}

func (s *Server) previewAgentWrite(_ context.Context, toolName string, raw json.RawMessage, page AgentPageContext) (agentToolExecution, error) {
	if err := requireAgentSensitive(page); err != nil {
		return agentToolExecution{}, err
	}
	switch toolName {
	case "append_transactions":
		var input struct {
			Entries []LedgerEntry `json:"entries"`
		}
		if err := decodeAgentArgs(raw, &input); err != nil {
			return agentToolExecution{}, err
		}
		entries, err := s.validateAgentEntries(input.Entries)
		if err != nil {
			return agentToolExecution{}, err
		}
		return agentToolExecution{Artifacts: []AgentArtifact{{ID: newAgentID("artifact"), Type: "transaction_draft", Title: "待确认交易", Data: map[string]any{"entries": entries}}}}, nil
	case "update_transaction":
		var input UpdateTransactionRequest
		if err := decodeAgentArgs(raw, &input); err != nil {
			return agentToolExecution{}, err
		}
		entry, err := s.validateAgentTransactionEntry(input.Entry)
		if err != nil {
			return agentToolExecution{}, err
		}
		if err := validateAgentTransactionSource(input.Source); err != nil {
			return agentToolExecution{}, err
		}
		if err := s.validateAgentTransactionUpdateSource(input.Source); err != nil {
			return agentToolExecution{}, err
		}
		original, err := s.agentTransactionSourceText(input.Source)
		if err != nil {
			return agentToolExecution{}, err
		}
		return agentToolExecution{Artifacts: []AgentArtifact{{ID: newAgentID("artifact"), Type: "transaction_change", Title: "待确认交易更新", Data: map[string]any{"source": input.Source, "original": original, "replacement": strings.TrimRight(TransactionToBean(entry), "\n")}}}}, nil
	case "delete_transaction":
		var input DeleteTransactionRequest
		if err := decodeAgentArgs(raw, &input); err != nil {
			return agentToolExecution{}, err
		}
		if err := validateAgentTransactionSource(input.Source); err != nil {
			return agentToolExecution{}, err
		}
		original, err := s.agentTransactionSourceText(input.Source)
		if err != nil {
			return agentToolExecution{}, err
		}
		return agentToolExecution{Artifacts: []AgentArtifact{{ID: newAgentID("artifact"), Type: "transaction_change", Title: "待确认交易删除", Data: map[string]any{"source": input.Source, "original": original, "reason": strings.TrimSpace(input.Reason)}}}}, nil
	case "reverse_transaction":
		var input ReverseTransactionRequest
		if err := decodeAgentArgs(raw, &input); err != nil {
			return agentToolExecution{}, err
		}
		if err := input.Validate(); err != nil {
			return agentToolExecution{}, err
		}
		if err := validateAgentTransactionSource(input.Source); err != nil {
			return agentToolExecution{}, err
		}
		original, err := s.agentTransactionSourceText(input.Source)
		if err != nil {
			return agentToolExecution{}, err
		}
		snapshot, err := s.ledgerSnapshot(context.Background())
		if err != nil {
			return agentToolExecution{}, err
		}
		originalTransaction := FindTransaction(snapshot.Transactions, input.Source)
		if originalTransaction == nil {
			return agentToolExecution{}, errors.New("找不到原交易，账本可能已被修改，请刷新后重试")
		}
		date := firstNonEmpty(input.Date, time.Now().Format("2006-01-02"))
		reversal := ReverseTransactionEntry(*originalTransaction, date)
		return agentToolExecution{Artifacts: []AgentArtifact{{ID: newAgentID("artifact"), Type: "transaction_change", Title: "待确认交易冲销", Data: map[string]any{"source": input.Source, "original": original, "replacement": strings.TrimRight(TransactionToBean(reversal), "\n")}}}}, nil
	case "apply_account_operations":
		var input struct {
			Operations []AccountOperation `json:"operations"`
		}
		if err := decodeAgentArgs(raw, &input); err != nil {
			return agentToolExecution{}, err
		}
		accounts, err := s.accountService.List()
		if err != nil {
			return agentToolExecution{}, err
		}
		if err := validateAccountOperations(input.Operations, accounts); err != nil {
			return agentToolExecution{}, err
		}
		return agentToolExecution{Artifacts: []AgentArtifact{{ID: newAgentID("artifact"), Type: "account_draft", Title: "待确认账户操作", Data: map[string]any{"operations": input.Operations}}}}, nil
	case "upsert_memory":
		var input agentMemoryInput
		if err := decodeAgentArgs(raw, &input); err != nil {
			return agentToolExecution{}, err
		}
		if err := input.Validate(); err != nil {
			return agentToolExecution{}, err
		}
		return agentToolExecution{Artifacts: []AgentArtifact{{ID: newAgentID("artifact"), Type: "memory_draft", Title: "待确认 Agent 记忆", Data: input}}}, nil
	default:
		return agentToolExecution{}, fmt.Errorf("unsupported approval tool: %s", toolName)
	}
}

func (s *Server) agentTransactionSourceText(source TransactionSource) (string, error) {
	snapshot, err := s.ledgerSnapshot(context.Background())
	if err != nil {
		return "", err
	}
	for _, entry := range snapshot.BeanEntries {
		if entry.Kind != "transaction" || !sameAgentTransactionSource(entry, source) {
			continue
		}
		return strings.Join(entry.RawLines, "\n"), nil
	}
	return "", errors.New("找不到原交易，账本可能已被修改，请刷新后重试")
}

func sameAgentTransactionSource(entry BeanEntry, source TransactionSource) bool {
	if filepath.Clean(entry.File) != filepath.Clean(source.File) {
		return false
	}
	if source.Hash != "" {
		return transactionHash(entry.RawLines) == source.Hash
	}
	return entry.Line == source.Line
}
func (s *Server) agentTools() map[string]agentTool {
	tools := []agentTool{
		{
			agentToolSpec: agentToolSpec{Name: "get_bql_capabilities", Description: "获取当前 BQL 支持的表、字段、聚合、过滤和限制。生成 BQL 前优先调用。", Parameters: objectSchema(nil, nil)},
			Title:         "读取 BQL 能力", ReadOnly: true,
			Execute: func(context.Context, json.RawMessage, AgentPageContext) (agentToolExecution, error) {
				result := bqlCapabilities()
				return agentToolExecution{ModelOutput: result, ClientOutput: result}, nil
			},
		},
		{
			agentToolSpec: agentToolSpec{Name: "validate_bql", Description: "校验一条只读 BQL SELECT 查询。不会读取账本数据。", Parameters: objectSchema(map[string]any{"query": stringSchema("要校验的 BQL SQL")}, []string{"query"})},
			Title:         "校验 BQL", ReadOnly: true,
			Execute: func(_ context.Context, raw json.RawMessage, _ AgentPageContext) (agentToolExecution, error) {
				var input struct {
					Query string `json:"query"`
				}
				if err := decodeAgentArgs(raw, &input); err != nil {
					return agentToolExecution{}, err
				}
				if _, err := parseBQL(input.Query); err != nil {
					return agentToolExecution{}, err
				}
				query := strings.TrimSpace(input.Query)
				artifact := AgentArtifact{ID: newAgentID("artifact"), Type: "bql_query", Title: "BQL 查询", Data: map[string]any{"query": query}}
				result := map[string]any{"valid": true, "query": query}
				return agentToolExecution{ModelOutput: result, ClientOutput: result, Artifacts: []AgentArtifact{artifact}}, nil
			},
		},
		{
			agentToolSpec: agentToolSpec{Name: "run_bql", Description: "运行只读 BQL，并返回可绘制为表格、柱状图、饼图或折线图的结果。统计支出应过滤 account LIKE 'Expenses:%'，不要用 type 代替账户类别。", Parameters: objectSchema(map[string]any{
				"query":             stringSchema("要运行的 BQL SQL"),
				"valuationCurrency": stringSchema("折算币种，例如 CNY"),
				"visualization":     enumSchema("auto", "table", "bar", "pie", "line"),
			}, []string{"query"})},
			Title: "运行 BQL", ReadOnly: true,
			Execute: func(ctx context.Context, raw json.RawMessage, page AgentPageContext) (agentToolExecution, error) {
				if err := requireAgentSensitive(page); err != nil {
					return agentToolExecution{}, err
				}
				var input struct {
					Query             string `json:"query"`
					ValuationCurrency string `json:"valuationCurrency"`
					Visualization     string `json:"visualization"`
				}
				if err := decodeAgentArgs(raw, &input); err != nil {
					return agentToolExecution{}, err
				}
				currency := firstNonEmpty(input.ValuationCurrency, page.ValuationCurrency)
				result, err := s.queryPort.BQL(ctx, input.Query, currency)
				if err != nil {
					return agentToolExecution{}, err
				}
				artifacts := []AgentArtifact{
					{ID: newAgentID("artifact"), Type: "bql_query", Title: "BQL 查询", Data: map[string]any{"query": strings.TrimSpace(input.Query)}},
					{ID: newAgentID("artifact"), Type: "table", Title: "BQL 结果", Data: result},
				}
				if input.Visualization != "" && input.Visualization != "table" {
					artifacts = append(artifacts, AgentArtifact{ID: newAgentID("artifact"), Type: "chart", Title: "BQL 图表", Data: map[string]any{"kind": input.Visualization, "result": result}})
				}
				modelResult := map[string]any{
					"columns":           result.Columns,
					"rows":              bqlModelRows(result.Columns, headRows(result.Rows, 40)),
					"rowCount":          result.RowCount,
					"warnings":          result.Warnings,
					"valuationCurrency": result.ValuationCurrency,
					"amountUnit":        "major",
				}
				clientResult := map[string]any{"rowCount": result.RowCount, "columns": result.Columns, "warnings": result.Warnings}
				return agentToolExecution{ModelOutput: modelResult, ClientOutput: clientResult, Artifacts: artifacts}, nil
			},
		},
		{
			agentToolSpec: agentToolSpec{Name: "search_transactions", Description: "使用看板/流水页 DSL 跨月份搜索交易，支持 AND、OR、NOT、字段和日期条件。返回的 postings.amount 是元单位字符串（amountUnit=major），可直接用于 update_transaction，不能乘以 100。", Parameters: objectSchema(map[string]any{
				"query": stringSchema("流水查询 DSL"), "start": stringSchema("默认起始日期 YYYY-MM-DD"), "end": stringSchema("默认结束日期 YYYY-MM-DD，开区间"), "limit": numberSchema("最多返回条数，1-100"),
			}, []string{"query"})},
			Title: "搜索流水", ReadOnly: true,
			Execute: func(_ context.Context, raw json.RawMessage, page AgentPageContext) (agentToolExecution, error) {
				if err := requireAgentSensitive(page); err != nil {
					return agentToolExecution{}, err
				}
				var input struct {
					Query string `json:"query"`
					Start string `json:"start"`
					End   string `json:"end"`
					Limit int    `json:"limit"`
				}
				if err := decodeAgentArgs(raw, &input); err != nil {
					return agentToolExecution{}, err
				}
				start := firstNonEmpty(input.Start, transactionQueryMinDate)
				end := firstNonEmpty(input.End, transactionQueryMaxDate)
				result, err := s.queryPort.Transactions(start, end, true, input.Query)
				if err != nil {
					return agentToolExecution{}, err
				}
				limit := input.Limit
				if limit <= 0 || limit > 100 {
					limit = 50
				}
				transactions := result.Transactions
				if len(transactions) > limit {
					transactions = transactions[:limit]
				}
				output := map[string]any{"start": result.Start, "end": result.End, "count": len(transactions), "amountUnit": "major", "transactions": agentTransactionsForModel(transactions)}
				return agentToolExecution{ModelOutput: output, ClientOutput: map[string]any{"count": len(transactions), "start": result.Start, "end": result.End}}, nil
			},
		},
		{
			agentToolSpec: agentToolSpec{Name: "get_ledger_summary", Description: "读取指定日期范围的收入、支出、净额和账户汇总。返回给你的所有金额均为元单位字符串（amountUnit=major），可直接阅读，绝不能乘以 100。", Parameters: objectSchema(map[string]any{
				"start": stringSchema("起始日期 YYYY-MM-DD"), "end": stringSchema("结束日期 YYYY-MM-DD，开区间"), "valuationCurrency": stringSchema("折算币种"),
			}, nil)},
			Title: "读取账本汇总", ReadOnly: true,
			Execute: func(_ context.Context, raw json.RawMessage, page AgentPageContext) (agentToolExecution, error) {
				if err := requireAgentSensitive(page); err != nil {
					return agentToolExecution{}, err
				}
				var input struct {
					Start             string `json:"start"`
					End               string `json:"end"`
					ValuationCurrency string `json:"valuationCurrency"`
				}
				if err := decodeAgentArgs(raw, &input); err != nil {
					return agentToolExecution{}, err
				}
				start := firstNonEmpty(input.Start, page.Start, time.Now().Format("2006-01-01"))
				end := firstNonEmpty(input.End, page.End, time.Now().AddDate(0, 1, 0).Format("2006-01-01"))
				result, err := s.queryPort.Summary(start, end, true, firstNonEmpty(input.ValuationCurrency, page.ValuationCurrency))
				if err != nil {
					return agentToolExecution{}, err
				}
				return agentToolExecution{ModelOutput: map[string]any{"start": result.Start, "end": result.End, "summary": agentSummaryForModel(result.Summary), "valuationCurrency": result.ValuationCurrency, "amountUnit": "major"}, ClientOutput: map[string]any{"start": result.Start, "end": result.End, "summary": result.Summary, "valuationCurrency": result.ValuationCurrency}}, nil
			},
		},
		{
			agentToolSpec: agentToolSpec{Name: "get_accounts", Description: "读取账户名称、别名、币种、分组和启用状态，用于生成合法分录或账户操作。", Parameters: objectSchema(map[string]any{"activeOnly": booleanSchema("是否只返回启用账户")}, nil)},
			Title:         "读取账户表", ReadOnly: true,
			Execute: func(_ context.Context, raw json.RawMessage, _ AgentPageContext) (agentToolExecution, error) {
				var input struct {
					ActiveOnly bool `json:"activeOnly"`
				}
				if err := decodeAgentArgs(raw, &input); err != nil {
					return agentToolExecution{}, err
				}
				accounts, err := s.accountService.List()
				if err != nil {
					return agentToolExecution{}, err
				}
				if input.ActiveOnly {
					filtered := accounts[:0]
					for _, account := range accounts {
						if account.Active {
							filtered = append(filtered, account)
						}
					}
					accounts = filtered
				}
				return agentToolExecution{ModelOutput: accounts, ClientOutput: map[string]any{"count": len(accounts), "accounts": accounts}}, nil
			},
		},
		{
			agentToolSpec: agentToolSpec{Name: "search_memories", Description: "检索已确认的 Agent 偏好和习惯记忆。记忆仅可作为偏好指导，不是账本事实。", Parameters: objectSchema(map[string]any{"query": stringSchema("可选关键词")}, nil)},
			Title:         "查询 Agent 记忆", ReadOnly: true,
			Execute: func(ctx context.Context, raw json.RawMessage, page AgentPageContext) (agentToolExecution, error) {
				if err := requireAgentSensitive(page); err != nil {
					return agentToolExecution{}, err
				}
				var input struct {
					Query string `json:"query"`
				}
				if err := decodeAgentArgs(raw, &input); err != nil {
					return agentToolExecution{}, err
				}
				records, err := s.searchAgentMemories(ctx, input.Query)
				if err != nil {
					return agentToolExecution{}, err
				}
				return agentToolExecution{ModelOutput: records, ClientOutput: map[string]any{"count": len(records), "records": records}}, nil
			},
		},
		{
			agentToolSpec: agentToolSpec{Name: "upsert_memory", Description: "创建或更新一条已明确确认的 Agent 习惯记忆。禁止保存密码、口令、验证码、令牌、银行卡号、导入原文或完整聊天记录。", Parameters: objectSchema(map[string]any{"id": stringSchema("已有记忆 ID，可选"), "kind": enumSchema("preference", "category_rule", "account_alias", "recurring", "response_style"), "title": stringSchema("简短标题"), "instruction": stringSchema("供 Agent 遵循的偏好或习惯")}, []string{"kind", "title", "instruction"})},
			Title:         "保存 Agent 记忆", RequiresApproval: true, ApprovalMessage: "将保存 Agent 记忆，需要你确认后执行。", ExecutionStatus: "正在保存已确认的 Agent 记忆",
			Execute: func(ctx context.Context, raw json.RawMessage, page AgentPageContext) (agentToolExecution, error) {
				if err := requireAgentSensitive(page); err != nil {
					return agentToolExecution{}, err
				}
				var input agentMemoryInput
				if err := decodeAgentArgs(raw, &input); err != nil {
					return agentToolExecution{}, err
				}
				record, err := s.upsertAgentMemory(ctx, input)
				if err != nil {
					return agentToolExecution{}, err
				}
				return agentToolExecution{ModelOutput: record, ClientOutput: record, Artifacts: []AgentArtifact{{ID: newAgentID("artifact"), Type: "memory_draft", Title: "已保存 Agent 记忆", Data: record}}}, nil
			},
		},
		newTransactionDraftTool(s, "draft_transactions", "生成并校验交易草稿，返回待确认预览但不写入账本。", "生成交易草稿", false),
		newTransactionDraftTool(s, "validate_transactions", "校验交易草稿的字段、账户和每币种平衡，不写入账本。", "校验交易草稿", false),
		newTransactionDraftTool(s, "append_transactions", "写入已经校验并展示给用户的交易草稿。每次调用都必须等待用户确认。", "写入账本", true),
		newUpdateTransactionTool(s),
		newDeleteTransactionTool(s),
		newReverseTransactionTool(s),
		newAccountOperationsTool(s, "draft_account_operations", "生成并校验账户创建、更新或关闭草稿，不写入。", "生成账户草稿", false),
		newAccountOperationsTool(s, "validate_account_operations", "校验账户操作草稿，不写入。", "校验账户草稿", false),
		newAccountOperationsTool(s, "apply_account_operations", "执行已经校验并展示给用户的账户操作。每次调用都必须等待用户确认。", "写入账户定义", true),
		{
			agentToolSpec: agentToolSpec{Name: "open_page", Description: "请求前端导航到指定账本页面。", Parameters: objectSchema(map[string]any{
				"path":  enumSchema("/", "/dashboard", "/query", "/transactions", "/accounts", "/net-worth", "/income-statement", "/investments", "/imports", "/reconcile", "/editor", "/settings"),
				"label": stringSchema("导航说明"),
			}, []string{"path"})},
			Title: "打开页面", ReadOnly: true,
			Execute: func(_ context.Context, raw json.RawMessage, _ AgentPageContext) (agentToolExecution, error) {
				var input struct {
					Path  string `json:"path"`
					Label string `json:"label"`
				}
				if err := decodeAgentArgs(raw, &input); err != nil {
					return agentToolExecution{}, err
				}
				artifact := AgentArtifact{ID: newAgentID("artifact"), Type: "navigation", Title: firstNonEmpty(input.Label, "打开页面"), Data: map[string]any{"path": input.Path}}
				return agentToolExecution{ModelOutput: map[string]any{"path": input.Path}, ClientOutput: map[string]any{"path": input.Path}, Artifacts: []AgentArtifact{artifact}}, nil
			},
		},
	}
	out := make(map[string]agentTool, len(tools))
	for _, tool := range tools {
		if !tool.ReadOnly && !tool.RequiresApproval {
			panic("Agent tool must be read-only or require approval: " + tool.Name)
		}
		out[tool.Name] = tool
	}
	return out
}

func newTransactionDraftTool(s *Server, name, description, title string, write bool) agentTool {
	return agentTool{
		agentToolSpec: agentToolSpec{Name: name, Description: description, Parameters: objectSchema(map[string]any{"entries": arraySchema(ledgerEntrySchema(), "交易或余额断言列表")}, []string{"entries"})},
		Title:         title, RequiresApproval: write, ReadOnly: !write,
		Execute: func(_ context.Context, raw json.RawMessage, page AgentPageContext) (agentToolExecution, error) {
			var input struct {
				Entries []LedgerEntry `json:"entries"`
			}
			if err := decodeAgentArgs(raw, &input); err != nil {
				return agentToolExecution{}, err
			}
			entries, err := s.validateAgentEntries(input.Entries)
			if err != nil {
				return agentToolExecution{}, err
			}
			if write {
				if err := requireAgentSensitive(page); err != nil {
					return agentToolExecution{}, err
				}
				texts, err := s.writer.AppendEntriesWithSource(ledgerWriteSourceAppendBatch, entries)
				if err != nil {
					return agentToolExecution{}, err
				}
				return agentToolExecution{ModelOutput: map[string]any{"count": len(texts)}, ClientOutput: map[string]any{"count": len(texts)}, RefreshLedger: true}, nil
			}
			artifact := AgentArtifact{ID: newAgentID("artifact"), Type: "transaction_draft", Title: "交易草稿", Data: map[string]any{"entries": entries}}
			result := map[string]any{"valid": true, "count": len(entries), "entries": entries}
			return agentToolExecution{ModelOutput: result, ClientOutput: map[string]any{"valid": true, "count": len(entries)}, Artifacts: []AgentArtifact{artifact}}, nil
		},
	}
}

func newUpdateTransactionTool(s *Server) agentTool {
	return agentTool{
		agentToolSpec: agentToolSpec{Name: "update_transaction", Description: "覆盖更新一笔已存在的交易。source 必须来自 search_transactions；entry.amount 和 entry.postings[].amount 使用元单位字符串，例如 13.80，绝不能把分金额乘以 100。每次调用都必须等待用户确认。", Parameters: objectSchema(map[string]any{"source": transactionSourceSchema(), "entry": ledgerEntrySchema()}, []string{"source", "entry"})},
		Title:         "更新交易", RequiresApproval: true,
		Execute: func(_ context.Context, raw json.RawMessage, page AgentPageContext) (agentToolExecution, error) {
			var input UpdateTransactionRequest
			if err := decodeAgentArgs(raw, &input); err != nil {
				return agentToolExecution{}, err
			}
			entry, err := s.validateAgentTransactionEntry(input.Entry)
			if err != nil {
				return agentToolExecution{}, err
			}
			if err := validateAgentTransactionSource(input.Source); err != nil {
				return agentToolExecution{}, err
			}
			if err := s.validateAgentTransactionUpdateSource(input.Source); err != nil {
				return agentToolExecution{}, err
			}
			if err := requireAgentSensitive(page); err != nil {
				return agentToolExecution{}, err
			}
			if err := s.txService.Update(input.Source, entry); err != nil {
				return agentToolExecution{}, err
			}
			return agentToolExecution{ModelOutput: map[string]any{"count": 1}, ClientOutput: map[string]any{"count": 1}, RefreshLedger: true}, nil
		},
	}
}

func newDeleteTransactionTool(s *Server) agentTool {
	return agentTool{
		agentToolSpec: agentToolSpec{Name: "delete_transaction", Description: "删除（注释保留）一笔已存在的交易，而不是追加冲销或重复交易。source 必须来自 search_transactions；可填写 reason 说明原因。每次调用都必须等待用户确认。", Parameters: objectSchema(map[string]any{"source": transactionSourceSchema(), "reason": stringSchema("删除原因，可选")}, []string{"source"})},
		Title:         "删除交易", RequiresApproval: true,
		Execute: func(_ context.Context, raw json.RawMessage, page AgentPageContext) (agentToolExecution, error) {
			var input DeleteTransactionRequest
			if err := decodeAgentArgs(raw, &input); err != nil {
				return agentToolExecution{}, err
			}
			if err := validateAgentTransactionSource(input.Source); err != nil {
				return agentToolExecution{}, err
			}
			if err := requireAgentSensitive(page); err != nil {
				return agentToolExecution{}, err
			}
			if err := s.txService.Delete(input.Source, input.Reason); err != nil {
				return agentToolExecution{}, err
			}
			return agentToolExecution{ModelOutput: map[string]any{"count": 1}, ClientOutput: map[string]any{"count": 1}, RefreshLedger: true}, nil
		},
	}
}

func newReverseTransactionTool(s *Server) agentTool {
	return agentTool{
		agentToolSpec: agentToolSpec{Name: "reverse_transaction", Description: "为一笔已存在的交易追加金额相反的冲销交易；仅当用户明确要求冲销而非更新或删除时使用。source 必须来自 search_transactions，date 必须明确指定。每次调用都必须等待用户确认。", Parameters: objectSchema(map[string]any{"source": transactionSourceSchema(), "date": stringSchema("冲销日期 YYYY-MM-DD")}, []string{"source", "date"})},
		Title:         "冲销交易", RequiresApproval: true,
		Execute: func(_ context.Context, raw json.RawMessage, page AgentPageContext) (agentToolExecution, error) {
			var input ReverseTransactionRequest
			if err := decodeAgentArgs(raw, &input); err != nil {
				return agentToolExecution{}, err
			}
			if err := input.Validate(); err != nil {
				return agentToolExecution{}, err
			}
			if err := validateAgentTransactionSource(input.Source); err != nil {
				return agentToolExecution{}, err
			}
			if input.Date == "" {
				return agentToolExecution{}, errors.New("date is required for reverse_transaction")
			}
			if err := requireAgentSensitive(page); err != nil {
				return agentToolExecution{}, err
			}
			entry, err := s.txService.Reverse(input)
			if err != nil {
				return agentToolExecution{}, err
			}
			return agentToolExecution{ModelOutput: map[string]any{"count": 1, "entry": entry}, ClientOutput: map[string]any{"count": 1}, RefreshLedger: true}, nil
		},
	}
}

func (s *Server) validateAgentTransactionEntry(entry LedgerEntry) (LedgerEntry, error) {
	if entry.Kind != "transaction" {
		return LedgerEntry{}, errors.New("entry.kind must be transaction when updating a transaction")
	}
	entries, err := s.validateAgentEntries([]LedgerEntry{entry})
	if err != nil {
		return LedgerEntry{}, err
	}
	return entries[0], nil
}

func validateAgentTransactionSource(source TransactionSource) error {
	if err := source.Validate(); err != nil {
		return err
	}
	if strings.TrimSpace(source.Hash) == "" {
		return errors.New("source.hash is required; use the complete source returned by search_transactions")
	}
	return nil
}

func (s *Server) validateAgentTransactionUpdateSource(source TransactionSource) error {
	snapshot, err := s.ledgerSnapshot(context.Background())
	if err != nil {
		return err
	}
	for _, entry := range snapshot.BeanEntries {
		if entry.Kind != "transaction" || !sameAgentTransactionSource(entry, source) {
			continue
		}
		if entry.Flag != "*" || len(entry.Links) > 0 {
			return errors.New("该交易包含当前更新工具无法无损保留的标记或链接，请使用编辑器修改")
		}
		for _, posting := range entry.Postings {
			if posting.Flag != "" || posting.PriceCurrency != "" || posting.CostCurrency != "" {
				return errors.New("该交易包含当前更新工具无法无损保留的分录标记、价格或成本，请使用编辑器修改")
			}
		}
		return nil
	}
	return errors.New("找不到原交易，账本可能已被修改，请刷新后重试")
}

func newAccountOperationsTool(s *Server, name, description, title string, write bool) agentTool {
	return agentTool{
		agentToolSpec: agentToolSpec{Name: name, Description: description, Parameters: objectSchema(map[string]any{"operations": arraySchema(accountOperationSchema(), "账户操作列表")}, []string{"operations"})},
		Title:         title, RequiresApproval: write, ReadOnly: !write,
		Execute: func(_ context.Context, raw json.RawMessage, page AgentPageContext) (agentToolExecution, error) {
			var input struct {
				Operations []AccountOperation `json:"operations"`
			}
			if err := decodeAgentArgs(raw, &input); err != nil {
				return agentToolExecution{}, err
			}
			accounts, err := s.accountService.List()
			if err != nil {
				return agentToolExecution{}, err
			}
			if err := validateAccountOperations(input.Operations, accounts); err != nil {
				return agentToolExecution{}, err
			}
			if write {
				if err := requireAgentSensitive(page); err != nil {
					return agentToolExecution{}, err
				}
				texts, err := s.accountService.ApplyOperations(input.Operations)
				if err != nil {
					return agentToolExecution{}, err
				}
				return agentToolExecution{ModelOutput: map[string]any{"count": len(texts)}, ClientOutput: map[string]any{"count": len(texts)}, RefreshLedger: true}, nil
			}
			artifact := AgentArtifact{ID: newAgentID("artifact"), Type: "account_draft", Title: "账户操作草稿", Data: map[string]any{"operations": input.Operations}}
			result := map[string]any{"valid": true, "count": len(input.Operations), "operations": input.Operations}
			return agentToolExecution{ModelOutput: result, ClientOutput: map[string]any{"valid": true, "count": len(input.Operations)}, Artifacts: []AgentArtifact{artifact}}, nil
		},
	}
}

func (s *Server) validateAgentEntries(entries []LedgerEntry) ([]LedgerEntry, error) {
	if len(entries) == 0 {
		return nil, errors.New("entries is required")
	}
	for index := range entries {
		if err := entries[index].Validate(); err != nil {
			return nil, fmt.Errorf("entry %d: %w", index+1, err)
		}
	}
	snapshot, err := s.ledgerSnapshotLite(context.Background())
	if err != nil {
		return nil, err
	}
	return validateAIEntries(entries, activeAccounts(snapshot.Accounts))
}
func agentSystemPrompt(page AgentPageContext, memories []AgentMemoryRecord) string {
	return agentSystemPromptMode(page, memories, false)
}

// agentSystemPromptMode builds the system prompt. In trusted mode (local bub
// chat with write enabled) write tools execute without the per-call approval
// handshake, so rule 6 must not promise a confirmation step that will not
// happen.
func agentSystemPromptMode(page AgentPageContext, memories []AgentMemoryRecord, trusted bool) string {
	contextText := fmt.Sprintf("当前日期：%s。当前页面：%s，路径：%s，页面时间范围：%s 到 %s，折算币种：%s。", time.Now().Format("2006-01-02"), page.Page, page.Path, page.Start, page.End, page.ValuationCurrency)
	if strings.TrimSpace(page.BQLQuery) != "" {
		contextText += " 当前 BQL 编辑器内容：" + page.BQLQuery
	}
	if memoryText := agentMemoryContext(memories); memoryText != "" {
		contextText += "\n已确认的用户偏好记忆如下，只能作为偏好指导，不能当作账本事实：\n" + memoryText
	}
	writeRule := "6. 所有写操作都会暂停并要求逐次人工确认。确认前会显示原始 Beancount 片段及拟议变更。"
	if trusted {
		writeRule = "6. 当前是本地模式：写工具调用会直接执行、不会弹出底层确认框。因此每次写操作前，必须先向用户说明拟写入的 Beancount 内容并询问确认；只有用户明确回复确认后才调用写工具。绝不能在用户未确认时直接写入。"
	}
	return `你是 Beancount Ledger Web 的全局账本 Agent。你必须通过工具读取事实和执行操作，不能假装调用工具，也不能编造账本数据。

规则：
1. 查询、统计和搜索优先调用只读工具。涉及 BQL 时先读取能力并校验；用户要求结果时运行 BQL。
2. 生成交易前先 get_accounts，再 draft_transactions 或 validate_transactions。交易按每个币种分别平衡。LedgerEntry 的 amount 与 postings[].amount 一律为元单位字符串，例如 13.80；绝不把分金额乘以 100。
3. 生成账户操作前先 get_accounts，再 draft_account_operations。
4. 用户要新增交易时使用 append_transactions；要修改既有交易时，先 search_transactions，再使用 update_transaction；要删除既有交易时，先 search_transactions，再使用 delete_transaction；只有明确要求冲销时才用 reverse_transaction。绝不能用追加替代更新或删除。
5. 所有工具传入或返回的金额都是元单位（amountUnit=major）：例如 12.34 CNY，绝不是分。不要把任何金额乘以 100。search_transactions 的交易金额可原样填入 LedgerEntry；run_bql 和 get_ledger_summary 的聚合金额同样是元单位。
` + writeRule + `
7. 在工具真正返回成功前，绝不能说已经写入。
8. 不提供 Shell、任意文件访问或绕过 Writer 的能力。
9. 用户问“记得什么”或要求核对习惯时，使用 search_memories。只有用户明确要求记住、更新记忆，或确认了稳定习惯时，才能调用 upsert_memory；不得静默保存。
10. 不保存或复述密码、解锁口令、验证码、Token、银行卡号、导入原文或完整聊天记录。
11. 回复使用简洁中文。工具结果已通过结构化卡片展示，不要重复大段表格或 JSON。

` + contextText
}

// agentTelegramSystemPrompt builds the system prompt for the Telegram channel.
// Telegram replies must be short and mobile-friendly; casual chat must not
// trigger tool calls. Writes still go through the per-call approval handshake.
func agentTelegramSystemPrompt(page AgentPageContext, memories []AgentMemoryRecord) string {
	contextText := fmt.Sprintf("当前日期：%s。", time.Now().Format("2006-01-02"))
	if memoryText := agentMemoryContext(memories); memoryText != "" {
		contextText += "\n已确认的用户偏好记忆如下，只能作为偏好指导，不能当作账本事实：\n" + memoryText
	}
	return `你是用户通过 Telegram 使用的个人 Beancount 记账助手。回复必须简短、适合手机屏幕，通常 3-8 条要点即可；用户用中文就回中文。

回复规则：
1. 问候、闲聊或不明确的请求：直接简短回复，不要调用任何工具。
2. 只有用户明确要求查询、统计或记账时才调用工具；查询、统计优先调用只读工具。
3. 生成交易前先 get_accounts，再 draft_transactions 或 validate_transactions。交易按每个币种分别平衡。LedgerEntry 的 amount 与 postings[].amount 一律为元单位字符串，例如 13.80；绝不把分金额乘以 100。
4. 只有用户明确要求写入时才调用写工具。写工具调用后，系统会自动展示包含日期、金额、账户和摘要的 Beancount 预览并暂停；只有用户明确回复“确认写入”后才会真正执行。
5. 工具传入或返回的金额都是元单位（amountUnit=major）：例如 12.34 CNY，绝不是分。
6. 在工具真正返回成功前，绝不能说已经写入。
7. 不保存或复述密码、解锁口令、验证码、Token、银行卡号、导入原文或完整聊天记录。
8. 不显示完整账本或原始导入文件，默认只给最小有用结果集。

` + contextText
}

func decodeAgentArgs(raw json.RawMessage, dest any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	if err := decoder.Decode(dest); err != nil {
		return fmt.Errorf("invalid tool arguments: %w", err)
	}
	return nil
}

// validateAgentToolCall is the runtime counterpart of the provider-facing JSON
// schema.  Providers do not universally enforce schemas, so malformed calls
// must be turned into tool errors rather than reaching an executor.
func validateAgentToolCall(tools map[string]agentTool, call agentModelToolCall, seenIDs map[string]struct{}) (agentTool, json.RawMessage, any, error) {
	if strings.TrimSpace(call.ID) == "" {
		return agentTool{}, nil, nil, errors.New("tool call id is required")
	}
	if _, exists := seenIDs[call.ID]; exists {
		return agentTool{}, nil, nil, fmt.Errorf("duplicate tool call id: %s", call.ID)
	}
	seenIDs[call.ID] = struct{}{}
	if call.Type != "" && call.Type != "function" {
		return agentTool{}, nil, nil, fmt.Errorf("unsupported tool call type: %s", call.Type)
	}
	tool, ok := tools[call.Function.Name]
	if !ok {
		return agentTool{}, nil, nil, fmt.Errorf("unknown tool: %s", call.Function.Name)
	}
	arguments := json.RawMessage(call.Function.Arguments)
	if !json.Valid(arguments) {
		return agentTool{}, nil, nil, errors.New("invalid tool arguments: malformed JSON")
	}
	var input any
	if err := json.Unmarshal(arguments, &input); err != nil {
		return agentTool{}, nil, nil, fmt.Errorf("invalid tool arguments: %w", err)
	}
	if err := validateAgentSchemaValue(input, tool.Parameters, "arguments"); err != nil {
		return agentTool{}, nil, nil, err
	}
	return tool, arguments, input, nil
}

func validateAgentSchemaValue(value any, schema map[string]any, path string) error {
	want, _ := schema["type"].(string)
	switch want {
	case "object":
		object, ok := value.(map[string]any)
		if !ok {
			return fmt.Errorf("%s must be an object", path)
		}
		properties, _ := schema["properties"].(map[string]any)
		if additional, ok := schema["additionalProperties"].(bool); ok && !additional {
			for key := range object {
				if _, exists := properties[key]; !exists {
					return fmt.Errorf("%s.%s is not allowed", path, key)
				}
			}
		}
		if required, ok := schema["required"].([]string); ok {
			for _, key := range required {
				if _, exists := object[key]; !exists {
					return fmt.Errorf("%s.%s is required", path, key)
				}
			}
		} else if required, ok := schema["required"].([]any); ok {
			for _, item := range required {
				if key, ok := item.(string); ok {
					if _, exists := object[key]; !exists {
						return fmt.Errorf("%s.%s is required", path, key)
					}
				}
			}
		}
		for key, nested := range properties {
			child, exists := object[key]
			if !exists {
				continue
			}
			nestedSchema, ok := nested.(map[string]any)
			if !ok {
				continue
			}
			if err := validateAgentSchemaValue(child, nestedSchema, path+"."+key); err != nil {
				return err
			}
		}
	case "array":
		items, ok := value.([]any)
		if !ok {
			return fmt.Errorf("%s must be an array", path)
		}
		if nested, ok := schema["items"].(map[string]any); ok {
			for index, item := range items {
				if err := validateAgentSchemaValue(item, nested, fmt.Sprintf("%s[%d]", path, index)); err != nil {
					return err
				}
			}
		}
	case "string":
		if _, ok := value.(string); !ok {
			return fmt.Errorf("%s must be a string", path)
		}
	case "boolean":
		if _, ok := value.(bool); !ok {
			return fmt.Errorf("%s must be a boolean", path)
		}
	case "integer":
		number, ok := value.(float64)
		if !ok || number != float64(int64(number)) {
			return fmt.Errorf("%s must be an integer", path)
		}
	}
	if values, ok := schema["enum"].([]string); ok {
		valueString, _ := value.(string)
		for _, candidate := range values {
			if valueString == candidate {
				return nil
			}
		}
		return fmt.Errorf("%s must be one of %s", path, strings.Join(values, ", "))
	}
	if values, ok := schema["enum"].([]any); ok {
		valueString, _ := value.(string)
		for _, candidate := range values {
			if stringValue, ok := candidate.(string); ok && valueString == stringValue {
				return nil
			}
		}
		return fmt.Errorf("%s has an unsupported value", path)
	}
	return nil
}

func normalizeAgentSessionID(value string) string {
	value = strings.TrimSpace(value)
	if len(value) >= 8 && len(value) <= 96 {
		valid := true
		for _, ch := range value {
			if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_') {
				valid = false
				break
			}
		}
		if valid {
			return value
		}
	}
	return newAgentID("session")
}

func normalizeAgentApprovalPolicy(value string) string {
	if strings.TrimSpace(value) == "always" {
		return "always"
	}
	return "on-write"
}

func newAgentID(prefix string) string {
	raw := make([]byte, 12)
	if _, err := rand.Read(raw); err != nil {
		return fmt.Sprintf("%s-%d", prefix, time.Now().UnixNano())
	}
	return prefix + "-" + hex.EncodeToString(raw)
}

func requireAgentSensitive(page AgentPageContext) error {
	if !page.SensitiveUnlocked {
		return errors.New("请先解锁敏感数据后再使用这个工具")
	}
	return nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func headRows(rows [][]any, limit int) [][]any {
	if len(rows) <= limit {
		return rows
	}
	return rows[:limit]
}
func bqlCapabilities() map[string]any {
	return map[string]any{
		"tables": map[string]any{
			"postings":     []string{"date", "month", "account", "payee", "narration", "currency", "amount", "value", "type"},
			"transactions": []string{"date", "month", "payee", "narration", "type", "account", "currency", "amount", "value"},
		},
		"aggregates": []string{"count(*)", "sum(amount)", "sum(value)"},
		"clauses":    []string{"WHERE with AND", "GROUP BY", "ORDER BY", "LIMIT"},
		"operators":  []string{"=", "!=", ">", ">=", "<", "<=", "LIKE"},
		"limits":     map[string]any{"default": bqlDefaultLimit, "max": bqlMaxLimit},
		"fieldNotes": map[string]any{
			"type":    "交易分类，值为 expense, income, transfer；postings 表的每条分录继承所属交易分类，不能用它代替账户类别",
			"account": "账户路径；统计支出使用 account LIKE 'Expenses:%'，统计收入使用 account LIKE 'Income:%'",
			"amount":  "原币金额",
			"value":   "按 valuationCurrency 折算后的金额",
		},
		"examples": []string{
			"SELECT month, sum(value) AS total_expense FROM postings WHERE account LIKE 'Expenses:%' GROUP BY month ORDER BY month",
			"SELECT account, sum(value) AS total FROM postings WHERE account LIKE 'Expenses:%' GROUP BY account ORDER BY total DESC LIMIT 20",
		},
	}
}

func bqlModelRows(columns []BQLColumn, rows [][]any) []map[string]any {
	out := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		item := make(map[string]any, len(columns))
		for index, column := range columns {
			if index >= len(row) {
				continue
			}
			value := row[index]
			if column.Type == "money" {
				value = bqlMoneyForModel(value)
			}
			item[column.Name] = value
		}
		out = append(out, item)
	}
	return out
}

func bqlMoneyForModel(value any) any {
	switch amount := value.(type) {
	case int:
		return fromCents(amount)
	case int64:
		return fmt.Sprintf("%.2f", float64(amount)/100)
	case float64:
		return fmt.Sprintf("%.2f", amount/100)
	default:
		return value
	}
}

// The public summary API uses integer cents for browser rendering. The model
// boundary is intentionally different: every money value is a decimal major
// unit string, with an explicit amountUnit marker on its enclosing response.
func agentSummaryForModel(summary Summary) map[string]any {
	days := make(map[string]map[string]string, len(summary.Days))
	for day, values := range summary.Days {
		converted := make(map[string]string, len(values))
		for currency, amount := range values {
			converted[currency] = fromCents(amount)
		}
		days[day] = converted
	}
	categories := make(map[string]string, len(summary.Categories))
	for category, amount := range summary.Categories {
		categories[category] = fromCents(amount)
	}
	return map[string]any{
		"currency": summary.Currency, "income": fromCents(summary.Income), "expense": fromCents(summary.Expense), "net": fromCents(summary.Net),
		"days": days, "categories": categories, "amountUnit": "major",
	}
}

func agentTransactionsForModel(transactions []Transaction) []map[string]any {
	result := make([]map[string]any, 0, len(transactions))
	for _, transaction := range transactions {
		postings := make([]map[string]any, 0, len(transaction.Postings))
		for _, posting := range transaction.Postings {
			postings = append(postings, map[string]any{"account": posting.Account, "amount": fromCents(posting.Amount), "currency": posting.Currency, "flag": posting.Flag})
		}
		result = append(result, map[string]any{
			"date": transaction.Date, "payee": transaction.Payee, "narration": transaction.Narration, "metadata": transaction.Metadata,
			"tags": transaction.Tags, "links": transaction.Links, "postings": postings, "source": transaction.Source,
		})
	}
	return result
}

func objectSchema(properties map[string]any, required []string) map[string]any {
	if properties == nil {
		properties = map[string]any{}
	}
	schema := map[string]any{"type": "object", "properties": properties, "additionalProperties": false}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}

func stringSchema(description string) map[string]any {
	return map[string]any{"type": "string", "description": description}
}
func numberSchema(description string) map[string]any {
	return map[string]any{"type": "integer", "description": description}
}
func booleanSchema(description string) map[string]any {
	return map[string]any{"type": "boolean", "description": description}
}
func enumSchema(values ...string) map[string]any {
	return map[string]any{"type": "string", "enum": values}
}
func arraySchema(items map[string]any, description string) map[string]any {
	return map[string]any{"type": "array", "items": items, "description": description}
}

func ledgerEntrySchema() map[string]any {
	return map[string]any{
		"type": "object", "additionalProperties": true,
		"properties": map[string]any{
			"kind": enumSchema("transaction", "balance"), "date": stringSchema("YYYY-MM-DD"), "payee": stringSchema("商户或对方"), "narration": stringSchema("说明"),
			"account": stringSchema("余额断言账户"), "amount": stringSchema("金额"), "currency": stringSchema("币种"),
			"metadata": map[string]any{"type": "object", "additionalProperties": true}, "tags": map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
			"postings":   map[string]any{"type": "array", "items": map[string]any{"type": "object", "additionalProperties": true, "properties": map[string]any{"account": stringSchema("账户"), "amount": stringSchema("带符号金额"), "currency": stringSchema("币种")}}},
			"confidence": map[string]any{"type": "number"}, "needsReview": booleanSchema("是否需要人工复核"), "questions": map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
		},
		"required": []string{"kind", "date"},
	}
}

func transactionSourceSchema() map[string]any {
	return map[string]any{
		"type": "object", "additionalProperties": false,
		"properties": map[string]any{
			"file":   stringSchema("交易来源文件，由 search_transactions 返回"),
			"line":   numberSchema("交易起始行，由 search_transactions 返回"),
			"hash":   stringSchema("交易内容哈希，由 search_transactions 返回"),
			"gitSha": stringSchema("账本版本 Git SHA，由 search_transactions 返回"),
		},
		"required": []string{"file", "hash"},
	}
}

func accountOperationSchema() map[string]any {
	return map[string]any{
		"type": "object", "additionalProperties": false,
		"properties": map[string]any{"kind": enumSchema("create", "update", "disable"), "date": stringSchema("YYYY-MM-DD"), "account": stringSchema("Beancount 账户路径"), "alias": stringSchema("显示名"), "currency": stringSchema("币种"), "group": enumSchema("cash", "wealth", "credit", "liability", "receivable", "expense", "income", "equity", "other")},
		"required":   []string{"kind", "date", "account"},
	}
}
