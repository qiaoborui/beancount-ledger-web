package mobileagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path"
	"slices"
	"strings"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

// attachmentPrompt is added to the system prompt of a conversation that has
// files attached.
const attachmentPrompt = `

附件与对账：
9. 用户可以上传账单附件（CSV、Excel、PDF、截图），用 list_attachments 查看结构和前几行预览；需要更多内容时用 read_attachment 按行或关键字分段读，不要整份读进来。PDF 和图片给的是设备识别出的文字，可能有错字；能查看图片时，识别不清可以用 view_attachment_image 看原图。
10. 对账用 reconcile_attachment，由它精确比对，不要自己逐笔心算：
   - accounts 填要对的账本账户（先用 get_accounts 确认），例如信用卡账单对 Liabilities 下对应的卡。
   - 表格附件传 id、表头行 headerRow（预览里的行号）和列：dateColumn、金额列（amountColumn，或分开的 inColumn/outColumn），有「收/支」列时传 directionColumn，摘要列放 descriptionColumns（商户、备注等，有助于找出金额不一致的条目）。
   - 金额按账户余额变化计：转入为正、支出为负。账单里消费记为正数时（多数信用卡账单）传 amountSign=expense_positive。结果里有 hint 说方向可能反了，就换一个再对一次。
   - PDF 或图片：自己从文字里整理出每笔的日期、金额、摘要，用 rows 参数传入（金额同样按余额变化计，或配合 amountSign），一次最多 600 行。
11. 回复先给结论：对上多少笔，账单合计、账本合计和差额；再分「账本缺失」「账本多出」「金额不一致」列出条目（日期、金额、摘要，账本条目带上文件和行号）。条目很多时列前几笔并说明总数。用户要补记或修正时，按第 4 条的方式改草稿，不要说已经写入。`

// supportsImages reports a catalog model known to accept image input.
func supportsImages(model *ai.Model) bool {
	return model != nil && (model.Capabilities.SupportsImages || slices.Contains(model.Input, "image"))
}

func (a *attachments) tools(ledger postingSource) []agent.AgentTool {
	tools := []agent.AgentTool{
		fileTool{name: "list_attachments", title: "查看附件",
			description: "列出用户上传的附件：类型、大小、工作表、行数和前几行预览（每行以行号开头，列用制表符分隔）；PDF 和图片给出识别文字的开头。",
			parameters:  objectParameters(map[string]any{}, nil),
			run:         func(json.RawMessage) (any, error) { return a.listAttachments() }},
		fileTool{name: "read_attachment", title: "读取附件",
			description: "分段读取一个附件。表格按行读：start 是起始行号（从 1 开始），limit 默认 60、最多 200 行，返回 nextStart 表示后面还有；contains 只返回包含该文字的行。PDF 和图片读识别出的文字：start 是字符位置，limit 默认 6000；contains 返回包含该文字的行。",
			parameters: objectParameters(map[string]any{
				"id":       map[string]any{"type": "string", "description": "附件 id，例如 a1"},
				"sheet":    map[string]any{"type": "string", "description": "工作表名，默认第一个"},
				"start":    map[string]any{"type": "integer", "description": "表格的起始行号，或文字的起始字符位置"},
				"limit":    map[string]any{"type": "integer", "description": "最多返回的行数或字符数"},
				"contains": map[string]any{"type": "string", "description": "只返回包含这段文字的行"},
			}, []string{"id"}),
			run: func(raw json.RawMessage) (any, error) { return a.readAttachment(raw) }},
		fileTool{name: "reconcile_attachment", title: "对账",
			description: "把账单明细和账本里指定账户的记录逐笔比对，返回对上的笔数、合计与差额，以及账本缺失、账本多出、金额不一致的条目。金额按账户余额变化计（转入为正、支出为负）。表格附件用 id + 列映射；PDF 或图片把整理出的明细放进 rows。",
			parameters: objectParameters(map[string]any{
				"id":                 map[string]any{"type": "string", "description": "表格附件 id"},
				"sheet":              map[string]any{"type": "string", "description": "工作表名，默认第一个"},
				"headerRow":          map[string]any{"type": "integer", "description": "表头所在行号（预览里的行号）；不传时自动找"},
				"dateColumn":         map[string]any{"type": "string", "description": "日期列：表头文字、列字母（A、B）或列序号"},
				"amountColumn":       map[string]any{"type": "string", "description": "金额列"},
				"inColumn":           map[string]any{"type": "string", "description": "收入（存入）金额列，与 outColumn 一起用来代替 amountColumn"},
				"outColumn":          map[string]any{"type": "string", "description": "支出（取出）金额列"},
				"directionColumn":    map[string]any{"type": "string", "description": "收支方向列，例如「收/支」；金额按它定正负"},
				"inValues":           map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "方向列里表示收入的值，默认 收入、收、存入、转入、退款等"},
				"outValues":          map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "方向列里表示支出的值，默认 支出、支、消费、取出、转出等"},
				"descriptionColumns": map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "摘要列（商户、商品、备注），用于找出金额不一致的条目"},
				"amountSign":         map[string]any{"type": "string", "enum": []string{"balance", "expense_positive"}, "description": "没有方向列时金额的含义：balance（默认，转入为正、支出为负）或 expense_positive（消费为正，多数信用卡账单）"},
				"rows": map[string]any{"type": "array", "description": "从 PDF 或图片整理出的明细，代替 id；最多 600 行",
					"items": map[string]any{"type": "object", "additionalProperties": false, "required": []string{"date", "amount"},
						"properties": map[string]any{
							"date":        map[string]any{"type": "string", "description": "YYYY-MM-DD"},
							"amount":      map[string]any{"type": "string", "description": "金额，例如 -36.50"},
							"description": map[string]any{"type": "string"},
						}}},
				"accounts":      map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "要对账的账本账户，或它们的上级账户"},
				"start":         map[string]any{"type": "string", "description": "起始日期 YYYY-MM-DD，默认账单最早一天"},
				"end":           map[string]any{"type": "string", "description": "结束日期 YYYY-MM-DD（不含），默认账单最后一天的次日"},
				"toleranceDays": map[string]any{"type": "integer", "description": "日期允许相差的天数，默认 3，最多 10（信用卡入账日常晚几天）"},
				"currency":      map[string]any{"type": "string", "description": "只比对这个币种的账本记录，例如 CNY"},
			}, []string{"accounts"}),
			run: func(raw json.RawMessage) (any, error) { return reconcile(a, ledger, raw) }},
	}
	if a.images && slices.ContainsFunc(a.items, func(item attachmentV1) bool { return item.ImagePath != "" }) {
		tools = append(tools, imageTool{attachments: a})
	}
	return tools
}

func objectParameters(properties map[string]any, required []string) map[string]any {
	schema := map[string]any{"type": "object", "properties": properties, "additionalProperties": false}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}

// imageTool shows the model an attached picture.
type imageTool struct{ attachments *attachments }

func (imageTool) Name() string  { return "view_attachment_image" }
func (imageTool) Label() string { return "查看图片" }
func (imageTool) Schema() ai.ToolSchema {
	return ai.ToolSchema{Name: "view_attachment_image", Description: "查看用户上传的图片原图（已缩小），用于核对识别文字不清楚的地方。每张图只在需要时看一次。",
		Parameters: objectParameters(map[string]any{"id": map[string]any{"type": "string", "description": "图片附件 id"}}, []string{"id"})}
}
func (imageTool) ExecutionMode() agent.ToolExecutionMode { return agent.ToolModeSequential }

func (t imageTool) Execute(ctx context.Context, _ string, params json.RawMessage, _ agent.ToolUpdateCallback) (agent.AgentToolResult, error) {
	if err := ctx.Err(); err != nil {
		return agent.AgentToolResult{}, err
	}
	data, mime, err := t.attachments.viewImage(params)
	if err != nil {
		return agent.AgentToolResult{}, err
	}
	return agent.AgentToolResult{Content: []ai.ToolResultMessageContent{
		ai.TextContent{Text: "图片如下。"},
		ai.ImageContent{Data: string(data), MimeType: mime},
	}, Details: map[string]any{}}, nil
}

// imageOmitted replaces a picture in the saved transcript.
const imageOmitted = "（图片已省略；需要时再调用 view_attachment_image 查看。）"

// stripImages drops pictures from tool results, so the transcript the
// shell keeps and replays stays small.
func stripImages(messages []agent.AgentMessage) []agent.AgentMessage {
	out := make([]agent.AgentMessage, len(messages))
	for index, message := range messages {
		out[index] = message
		result := message.ToolResult
		if result == nil || !slices.ContainsFunc(result.Content, isImage) {
			continue
		}
		copied := *result
		copied.Content = make([]ai.ToolResultMessageContent, 0, len(result.Content))
		for _, block := range result.Content {
			if isImage(block) {
				block = ai.TextContent{Text: imageOmitted}
			}
			copied.Content = append(copied.Content, block)
		}
		out[index].ToolResult = &copied
	}
	return out
}

func isImage(block ai.ToolResultMessageContent) bool {
	_, ok := block.(ai.ImageContent)
	if !ok {
		_, ok = block.(*ai.ImageContent)
	}
	return ok
}

// withAttachmentNote puts the announcement of new files before the question.
func withAttachmentNote(a *attachments, message string) string {
	if note := a.announcement(); note != "" {
		return note + strings.TrimSpace(message)
	}
	return message
}

// saveTool copies an attachment's original bytes into the scratch copy, so
// the user can keep a statement next to the ledger. Like every edit it only
// reaches the ledger through the change card.
func (a *attachments) saveTool(files *scratch) agent.AgentTool {
	return fileTool{name: "save_attachment", title: "存入账本",
		description: "把用户上传的附件原文件（原样的 PDF、Excel、图片等）复制进账本草稿的指定路径，例如 documents/statements/2026-10-招行信用卡.pdf。目标已存在时需要 overwrite。和其他改动一样，用户在改动卡片确认后才写入账本。",
		parameters: objectParameters(map[string]any{
			"id":        map[string]any{"type": "string", "description": "附件 id，例如 a1"},
			"path":      map[string]any{"type": "string", "description": "相对账本根目录的目标路径，含文件名和扩展名"},
			"overwrite": map[string]any{"type": "boolean", "description": "目标已存在时覆盖"},
		}, []string{"id", "path"}),
		run: func(raw json.RawMessage) (any, error) { return a.saveInto(files, raw) }}
}

func (a *attachments) saveInto(files *scratch, raw json.RawMessage) (any, error) {
	var input struct {
		ID        string `json:"id"`
		Path      string `json:"path"`
		Overwrite bool   `json:"overwrite"`
	}
	if err := decodeStrict(raw, &input); err != nil {
		return nil, err
	}
	item, err := a.find(input.ID)
	if err != nil {
		return nil, err
	}
	clean, err := workspacePath(input.Path)
	if err != nil {
		return nil, err
	}
	if path.Ext(clean) == "" {
		clean += attachmentExt(item)
	}
	if path.Ext(clean) == ".bean" {
		return nil, errors.New("附件不能存成 .bean 文件；账本条目请用 write_file 或 edit_file 写")
	}
	if existing, err := files.root.Lstat(clean); err == nil {
		if !existing.Mode().IsRegular() {
			return nil, fmt.Errorf("%s 已存在且不是文件", clean)
		}
		if !input.Overwrite {
			return nil, fmt.Errorf("%s 已存在；要覆盖请设 overwrite", clean)
		}
	}
	info, err := os.Stat(item.Path)
	if err != nil {
		return nil, err
	}
	if info.Size() > maxAttachmentBytes {
		return nil, errors.New("附件超过 25 MB")
	}
	data, err := os.ReadFile(item.Path)
	if err != nil {
		return nil, err
	}
	if err := files.writeLimited(clean, data, maxAttachmentBytes); err != nil {
		return nil, err
	}
	return map[string]any{"id": item.ID, "path": clean, "bytes": len(data)}, nil
}
