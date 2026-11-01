package mobileagent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
	"github.com/xuri/excelize/v2"
	"golang.org/x/text/encoding/simplifiedchinese"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

const reconcileLedger = `option "operating_currency" "CNY"
2026-01-01 open Liabilities:Card CNY
2026-01-01 open Expenses:Food CNY
2026-01-01 open Expenses:Transport CNY
2026-01-05 * "食堂" "午饭"
  Expenses:Food  25.00 CNY
  Liabilities:Card  -25.00 CNY
2026-01-08 * "滴滴出行" "打车"
  Expenses:Transport  30.00 CNY
  Liabilities:Card  -30.00 CNY
2026-01-12 * "便利店" "零食"
  Expenses:Food  9.90 CNY
  Liabilities:Card  -9.90 CNY
`

// A card statement as banks export it: GBK, a preamble above the header,
// spending as positive amounts and a total line underneath.
const cardStatement = `招商银行信用卡账单
账户：**** 1234
交易日,记账日,交易摘要,人民币金额
2026/01/04,2026/01/05,食堂 午饭,25.00
2026/01/07,2026/01/08,滴滴出行,32.50
2026/01/10,2026/01/10,星巴克咖啡,"1,038.00"
合计,,,"1,095.50"
`

type fakeLedger []app.LocalAgentPosting

func (f fakeLedger) Postings(start, end string, accounts []string) ([]app.LocalAgentPosting, error) {
	var out []app.LocalAgentPosting
	for _, posting := range f {
		if posting.Date >= start && posting.Date < end {
			out = append(out, posting)
		}
	}
	return out, nil
}

var cardPostings = fakeLedger{
	{Date: "2026-01-05", Payee: "食堂", Narration: "午饭", Account: "Liabilities:Card", Amount: -2500, Currency: "CNY", File: "main.bean", Line: 5},
	{Date: "2026-01-08", Payee: "滴滴出行", Narration: "打车", Account: "Liabilities:Card", Amount: -3000, Currency: "CNY", File: "main.bean", Line: 8},
	{Date: "2026-01-12", Payee: "便利店", Narration: "零食", Account: "Liabilities:Card", Amount: -990, Currency: "CNY", File: "main.bean", Line: 11},
}

func writeAttachment(t *testing.T, runtime, name string, data []byte) string {
	t.Helper()
	dir := filepath.Join(runtime, "agent-attachments", "c1")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func gbk(t *testing.T, text string) []byte {
	t.Helper()
	encoded, err := simplifiedchinese.GBK.NewEncoder().Bytes([]byte(text))
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func mustOpen(t *testing.T, runtime string, items ...attachmentV1) *attachments {
	t.Helper()
	set, err := openAttachments(items, runtime, false)
	if err != nil {
		t.Fatal(err)
	}
	return set
}

func asJSON(t *testing.T, value any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	return decoded
}

func TestReconcileFindsMissingExtraAndMismatchedRows(t *testing.T) {
	runtime := t.TempDir()
	path := writeAttachment(t, runtime, "statement.csv", gbk(t, cardStatement))
	set := mustOpen(t, runtime, attachmentV1{ID: "a1", Name: "招行账单.csv", Path: path})

	listed := asJSON(t, must(set.listAttachments()))
	preview := listed["attachments"].([]any)[0].(map[string]any)["sheets"].([]any)[0].(map[string]any)["preview"].([]any)
	if !strings.HasPrefix(preview[2].(string), "3\t交易日\t记账日") {
		t.Fatalf("GBK statement not decoded or row numbers off: %v", preview)
	}

	result := asJSON(t, must(reconcile(set, cardPostings, []byte(`{"id":"a1","dateColumn":"记账日","amountColumn":"人民币金额",
		"descriptionColumns":["交易摘要"],"amountSign":"expense_positive","accounts":["Liabilities:Card"],"end":"2026-02-01"}`))))
	if result["matched"].(float64) != 1 {
		t.Fatalf("matched = %v: %v", result["matched"], result)
	}
	mismatches := result["amountMismatches"].([]any)
	if len(mismatches) != 1 || mismatches[0].(map[string]any)["delta"] != "-2.50" {
		t.Fatalf("taxi row not reported as a mismatch: %v", mismatches)
	}
	missing := result["missingInLedger"].([]any)
	if len(missing) != 1 || missing[0].(map[string]any)["amount"] != "-1038.00" || missing[0].(map[string]any)["row"].(float64) != 6 {
		t.Fatalf("coffee row not reported missing: %v", missing)
	}
	extra := result["extraInLedger"].([]any)
	if len(extra) != 1 || extra[0].(map[string]any)["source"] != "main.bean:11" {
		t.Fatalf("snack posting not reported extra: %v", extra)
	}
	if result["mapping"].(map[string]any)["headerRow"].(float64) != 3 {
		t.Fatalf("header row not detected: %v", result["mapping"])
	}
	if result["skippedRows"] != nil || result["statement"].(map[string]any)["skippedRows"].(float64) != 1 {
		t.Fatalf("the total line should be the only skipped row: %v", result["statement"])
	}
	if result["difference"] != "-1030.60" {
		t.Fatalf("difference = %v", result["difference"])
	}
}

func TestReconcileHintsAtAnInvertedSign(t *testing.T) {
	rows := `{"rows":[{"date":"2026-01-05","amount":"25"},{"date":"2026-01-08","amount":"30"},{"date":"2026-01-12","amount":"9.90"}],"accounts":["Liabilities:Card"]}`
	result := asJSON(t, must(reconcile(nil, cardPostings, []byte(rows))))
	if result["matched"].(float64) != 0 || !strings.Contains(result["hint"].(string), "方向可能反了") {
		t.Fatalf("no sign hint: %v", result)
	}
	fixed := strings.Replace(rows, `"accounts"`, `"amountSign":"expense_positive","accounts"`, 1)
	if result := asJSON(t, must(reconcile(nil, cardPostings, []byte(fixed)))); result["matched"].(float64) != 3 || result["hint"] != nil {
		t.Fatalf("inline rows with expense_positive should all match: %v", result)
	}
}

func TestReconcileReadsDirectionColumnsAndSkipsNeutralRows(t *testing.T) {
	runtime := t.TempDir()
	statement := "交易时间,交易对方,收/支,金额(元)\n2026-01-05 12:01:02,食堂,支出,¥25.00\n2026-01-06 08:00:00,余额宝,不计收支,100.00\n2026-01-08 19:30:00,滴滴出行,支出,30.00\n"
	path := writeAttachment(t, runtime, "alipay.csv", []byte(statement))
	set := mustOpen(t, runtime, attachmentV1{ID: "a1", Name: "alipay.csv", Path: path})
	result := asJSON(t, must(reconcile(set, cardPostings, []byte(`{"id":"a1","dateColumn":"交易时间","amountColumn":"金额","directionColumn":"收/支","accounts":["Liabilities"],"end":"2026-01-10"}`))))
	if result["matched"].(float64) != 2 || result["statement"].(map[string]any)["skippedRows"].(float64) != 1 {
		t.Fatalf("direction column not applied: %v", result)
	}
	if extra := result["extraInLedger"].([]any); len(extra) != 0 {
		t.Fatalf("postings after end must not be extra: %v", extra)
	}
}

func TestReadAttachmentPagesThroughAnXLSXSheet(t *testing.T) {
	runtime := t.TempDir()
	book := excelize.NewFile()
	book.SetSheetName("Sheet1", "明细")
	_ = book.SetSheetRow("明细", "A1", &[]any{"日期", "金额", "备注"})
	for row := 2; row <= 301; row++ {
		cell, _ := excelize.CoordinatesToCellName(1, row)
		note := "午饭"
		if row == 2 {
			note = strings.Repeat("长", 100)
		}
		_ = book.SetSheetRow("明细", cell, &[]any{"2026-01-05", "-1.00", note})
	}
	buffer, err := book.WriteToBuffer()
	if err != nil {
		t.Fatal(err)
	}
	path := writeAttachment(t, runtime, "book.xlsx", buffer.Bytes())
	set := mustOpen(t, runtime, attachmentV1{ID: "a1", Name: "book.xlsx", Path: path})
	result := asJSON(t, must(set.readAttachment([]byte(`{"id":"a1","limit":500}`))))
	if result["nextStart"].(float64) != 201 || result["totalRows"].(float64) != 301 {
		t.Fatalf("read was not bounded to 200 rows: next=%v total=%v", result["nextStart"], result["totalRows"])
	}
	if strings.Contains(result["rows"].(string), strings.Repeat("长", maxCellRunes+1)) {
		t.Fatal("long cells were not clipped")
	}
	if found := asJSON(t, must(set.readAttachment([]byte(`{"id":"a1","contains":"日期"}`)))); !strings.HasPrefix(found["rows"].(string), "1\t日期") {
		t.Fatalf("contains filter: %v", found["rows"])
	}
}

func TestReadAttachmentReadsShellTextInSlices(t *testing.T) {
	runtime := t.TempDir()
	pdf := writeAttachment(t, runtime, "bill.pdf", []byte("%PDF-1.7"))
	text := writeAttachment(t, runtime, "bill.pdf.txt", []byte(strings.Repeat("一", 7000)+"\n2026-01-05 食堂 25.00\n"))
	set := mustOpen(t, runtime, attachmentV1{ID: "a1", Name: "bill.pdf", Path: pdf, TextPath: text, Pages: 2})
	first := asJSON(t, must(set.readAttachment([]byte(`{"id":"a1"}`))))
	if first["nextStart"].(float64) != 6000 {
		t.Fatalf("text not sliced: %v", first["nextStart"])
	}
	hits := asJSON(t, must(set.readAttachment([]byte(`{"id":"a1","contains":"食堂"}`))))
	if hits["matches"] != "2\t2026-01-05 食堂 25.00" {
		t.Fatalf("contains on text: %v", hits)
	}
}

func TestOpenAttachmentsStaysInsideTheRuntimeDirectory(t *testing.T) {
	runtime := t.TempDir()
	outside := filepath.Join(t.TempDir(), "secret.csv")
	if err := os.WriteFile(outside, []byte("a,b\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := openAttachments([]attachmentV1{{ID: "a1", Name: "x.csv", Path: outside}}, runtime, false); err == nil {
		t.Fatal("a file outside the runtime directory was accepted")
	}
	link := filepath.Join(runtime, "link.csv")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	if _, err := openAttachments([]attachmentV1{{ID: "a1", Name: "x.csv", Path: link}}, runtime, false); err == nil {
		t.Fatal("a symlink out of the runtime directory was accepted")
	}
	inside := writeAttachment(t, runtime, "ok.csv", []byte("a\n"))
	if _, err := openAttachments([]attachmentV1{{ID: "A 1", Path: inside}}, runtime, false); err == nil {
		t.Fatal("a malformed id was accepted")
	}
}

func TestStatementValuesParse(t *testing.T) {
	for input, want := range map[string]int{"1,234.50": 123450, "¥-36.5": -3650, "(12.00)": -1200, "12.00-": -1200,
		"−8.80": -880, "100.00 DR": -10000, "5元": 500, "+3": 300} {
		if got, ok := parseStatementAmount(input); !ok || got != want {
			t.Errorf("amount %q = %d %v, want %d", input, got, ok, want)
		}
	}
	for _, input := range []string{"", "-", "/", "合计"} {
		if _, ok := parseStatementAmount(input); ok {
			t.Errorf("amount %q parsed", input)
		}
	}
	for input, want := range map[string]string{"2026/1/5": "2026-01-05", "2026年01月05日 12:00": "2026-01-05", "20260105": "2026-01-05",
		"20260105120000": "2026-01-05", "46027": "2026-01-05", "2026-01-05T08:00:00+08:00": "2026-01-05"} {
		if got, ok := parseStatementDate(input); !ok || got.Format("2006-01-02") != want {
			t.Errorf("date %q = %v %v, want %s", input, got, ok, want)
		}
	}
	if _, ok := parseStatementDate("2026-02-30"); ok {
		t.Error("an impossible date parsed")
	}
}

func TestStripImagesKeepsTheTranscriptSmall(t *testing.T) {
	messages := []agent.AgentMessage{{ToolResult: &agent.ToolResultMessage{Role: "toolResult", ToolCallID: "c1", ToolName: "view_attachment_image",
		Content: []ai.ToolResultMessageContent{ai.TextContent{Text: "图片如下。"}, ai.ImageContent{Data: strings.Repeat("A", 100000), MimeType: "image/jpeg"}}}}}
	encoded, err := encodeTranscript(messages)
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) > 2000 || !strings.Contains(encoded, "图片已省略") {
		t.Fatalf("image kept in transcript (%d bytes)", len(encoded))
	}
	if _, ok := messages[0].ToolResult.Content[1].(ai.ImageContent); !ok {
		t.Fatal("stripping changed the live messages")
	}
}

func TestRunTurnReconcilesAnAttachedStatement(t *testing.T) {
	ledger := t.TempDir()
	root := filepath.Join(ledger, "generations", "initial", "workspace")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "main.bean"), []byte(reconcileLedger), 0o600); err != nil {
		t.Fatal(err)
	}
	runtime := filepath.Join(ledger, "runtime")
	path := writeAttachment(t, runtime, "statement.csv", gbk(t, cardStatement))
	var firstQuestion, reconciled string
	var offered []string
	useFaux(t,
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			for _, message := range request.Messages() {
				if user, ok := message.(ai.UserMessage); ok {
					switch content := user.Content.(type) {
					case ai.UserText:
						firstQuestion = string(content)
					case ai.UserContentBlocks:
						for _, block := range content {
							if text, ok := block.(ai.TextContent); ok {
								firstQuestion = text.Text
							}
						}
					default:
						t.Logf("user content %T", content)
					}
				}
			}
			offered = offeredTools(request)
			return ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
				ai.FauxToolCall("reconcile_attachment", map[string]any{"id": "a1", "headerRow": 3, "dateColumn": "记账日",
					"amountColumn": "人民币金额", "descriptionColumns": []string{"交易摘要"}, "amountSign": "expense_positive",
					"accounts": []string{"Liabilities:Card"}, "end": "2026-02-01"}, &ai.FauxToolCallOptions{ID: "call_reconcile"}),
			}}.AssistantMessage(), nil
		}),
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			reconciled = lastToolResultText(request)
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("对上 1 笔。")}, StopReason: "stop"}.AssistantMessage(), nil
		}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": root, "runtimeRoot": runtime, "sensitiveUnlocked": true,
		"provider": "faux", "model": "faux-1", "apiKey": "test", "message": "帮我对账",
		"attachments": []map[string]any{{"id": "a1", "name": "招行账单.csv", "path": path, "new": true}}})
	if !response.OK {
		t.Fatalf("turn failed: %+v", response)
	}
	if !strings.HasPrefix(firstQuestion, "（用户随这条消息上传了附件：a1「招行账单.csv」") || !strings.HasSuffix(firstQuestion, "帮我对账") {
		t.Fatalf("question not announced: %q", firstQuestion)
	}
	for _, name := range []string{"list_attachments", "read_attachment", "reconcile_attachment"} {
		if !strings.Contains(strings.Join(offered, ","), name) {
			t.Fatalf("%s not offered: %v", name, offered)
		}
	}
	if strings.Contains(strings.Join(offered, ","), "view_attachment_image") {
		t.Fatal("image tool offered to a model without image input")
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(reconciled), &result); err != nil {
		t.Fatalf("reconcile output %q: %v", reconciled, err)
	}
	if result["matched"].(float64) != 1 || len(result["amountMismatches"].([]any)) != 1 || len(result["missingInLedger"].([]any)) != 1 {
		t.Fatalf("reconcile against the real ledger: %v", result)
	}
	if extra := result["extraInLedger"].([]any); len(extra) != 1 || extra[0].(map[string]any)["source"] != "main.bean:11" {
		t.Fatalf("extra posting source should be workspace-relative: %v", extra)
	}
}

func TestRunTurnWithoutAttachmentsOffersNoAttachmentTools(t *testing.T) {
	var offered []string
	useFaux(t, ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
		offered = offeredTools(request)
		return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好")}, StopReason: "stop"}.AssistantMessage(), nil
	}))
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "hi"})
	if !response.OK || strings.Contains(strings.Join(offered, ","), "attachment") {
		t.Fatalf("attachment tools offered without attachments: %v %+v", offered, response)
	}
}

// offeredTools are the tool names the transcript's system messages declare.
func offeredTools(request ai.TranscriptContext) []string {
	var names []string
	for _, message := range request.Messages() {
		system, ok := message.(ai.SystemMessage)
		if !ok {
			continue
		}
		for _, tool := range system.ToolsAdded {
			names = append(names, tool.Name)
		}
	}
	return names
}

func must(value any, err error) any {
	if err != nil {
		panic(err)
	}
	return value
}

var _ = context.Background

func TestSaveAttachmentCopiesTheOriginalIntoTheDraft(t *testing.T) {
	runtime := t.TempDir()
	original := append([]byte("%PDF-1.7\n"), 0, 1, 2, 0xff)
	path := writeAttachment(t, runtime, "a1-bill.pdf", original)
	set := mustOpen(t, runtime, attachmentV1{ID: "a1", Name: "招行10月.pdf", Path: path})
	dir := scratchCopy(t)
	files, err := openScratch(dir, "main.bean")
	if err != nil {
		t.Fatal(err)
	}
	defer files.close()
	result := asJSON(t, must(set.saveInto(files, []byte(`{"id":"a1","path":"documents/statements/2026-10-招行"}`))))
	if result["path"] != "documents/statements/2026-10-招行.pdf" {
		t.Fatalf("extension not kept: %v", result)
	}
	saved, err := os.ReadFile(filepath.Join(dir, "documents", "statements", "2026-10-招行.pdf"))
	if err != nil || string(saved) != string(original) {
		t.Fatalf("the original bytes were not saved: %v", err)
	}
	if !files.wasEdited() {
		t.Fatal("saving did not mark the draft edited")
	}
	if _, err := set.saveInto(files, []byte(`{"id":"a1","path":"documents/statements/2026-10-招行.pdf"}`)); err == nil {
		t.Fatal("an existing file was overwritten without overwrite")
	}
	for _, target := range []string{"../out.pdf", ".git/x.pdf", "main.bean"} {
		raw, _ := json.Marshal(map[string]any{"id": "a1", "path": target, "overwrite": true})
		if _, err := set.saveInto(files, raw); err == nil {
			t.Errorf("save to %q was allowed", target)
		}
	}

	// The other file tools see the saved file as a binary file.
	listed := asJSON(t, must(files.listFiles([]byte(`{"dir":"documents"}`))))
	if got := listed["files"].([]any); len(got) != 1 {
		t.Fatalf("list_files under documents: %v", got)
	}
	if _, err := files.readFile([]byte(`{"path":"documents/statements/2026-10-招行.pdf"}`)); err == nil || !strings.Contains(err.Error(), "二进制") {
		t.Fatalf("binary read: %v", err)
	}
	moved := asJSON(t, must(files.moveFile([]byte(`{"from":"documents/statements/2026-10-招行.pdf","to":"statements/cmb/2026-10.pdf"}`))))
	if moved["to"] != "statements/cmb/2026-10.pdf" {
		t.Fatalf("move: %v", moved)
	}
	if _, err := os.Stat(filepath.Join(dir, "statements", "cmb", "2026-10.pdf")); err != nil {
		t.Fatal(err)
	}
	if _, err := files.deleteFile([]byte(`{"path":"main.bean"}`)); err == nil {
		t.Fatal("the entrypoint was deleted")
	}
	must(files.deleteFile([]byte(`{"path":"statements/cmb/2026-10.pdf"}`)))
	if _, err := os.Stat(filepath.Join(dir, "statements", "cmb", "2026-10.pdf")); !os.IsNotExist(err) {
		t.Fatalf("delete left the file: %v", err)
	}
}

func TestTextToolsWorkOnNonBeanFiles(t *testing.T) {
	files, err := openScratch(scratchCopy(t), "main.bean")
	if err != nil {
		t.Fatal(err)
	}
	defer files.close()
	must(files.writeFile([]byte(`{"path":"notes/对账.md","content":"十月已对账"}`)))
	must(files.editFile([]byte(`{"path":"notes/对账.md","old_string":"十月","new_string":"10 月"}`)))
	read := asJSON(t, must(files.readFile([]byte(`{"path":"notes/对账.md"}`))))
	if !strings.Contains(read["content"].(string), "10 月已对账") {
		t.Fatalf("read back: %v", read)
	}
}

func TestSaveAttachmentIsOfferedOnlyWithADraft(t *testing.T) {
	ledger := t.TempDir()
	root := filepath.Join(ledger, "generations", "initial", "workspace")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "main.bean"), []byte(testLedger), 0o600); err != nil {
		t.Fatal(err)
	}
	runtime := filepath.Join(ledger, "runtime")
	path := writeAttachment(t, runtime, "bill.pdf", []byte("%PDF"))
	draft := filepath.Join(runtime, "agent", "d1", "workspace")
	if err := os.CopyFS(draft, os.DirFS(root)); err != nil {
		t.Fatal(err)
	}
	for _, withDraft := range []bool{false, true} {
		var offered []string
		useFaux(t, ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			offered = offeredTools(request)
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("好")}, StopReason: "stop"}.AssistantMessage(), nil
		}))
		request := map[string]any{"version": 1, "workspaceRoot": root, "runtimeRoot": runtime, "provider": "faux", "model": "faux-1",
			"message": "存一下", "attachments": []map[string]any{{"id": "a1", "name": "bill.pdf", "path": path}}}
		if withDraft {
			request["scratchRoot"] = draft
		}
		if response := runTurnFor(t, request); !response.OK {
			t.Fatalf("turn failed: %+v", response)
		}
		has := strings.Contains(strings.Join(offered, ","), "save_attachment")
		if has != withDraft {
			t.Fatalf("draft=%v offered=%v", withDraft, offered)
		}
	}
}
