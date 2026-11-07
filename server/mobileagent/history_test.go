package mobileagent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/MichaelKinsy/PiG/ai"
)

// savedConversation writes one record the way the shell saves it:
// runtime/agent-history/<id>.json with ISO 8601 timestamps.
func savedConversation(t *testing.T, root, id, updated string, messages ...[2]string) {
	t.Helper()
	directory := filepath.Join(root, savedConversationDir)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	type message struct {
		Role string `json:"role"`
		Text string `json:"text"`
	}
	record := map[string]any{
		"version":   1,
		"id":        id,
		"createdAt": updated,
		"updatedAt": updated,
		"messages":  []message{},
	}
	list := make([]message, 0, len(messages))
	for _, pair := range messages {
		list = append(list, message{Role: pair[0], Text: pair[1]})
	}
	record["messages"] = list
	encoded, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, id+".json"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}
}

func runHistoryTool(t *testing.T, toolIndex int, index *historyIndex, arguments string) (any, error) {
	t.Helper()
	tools := index.tools()
	if toolIndex < 0 || toolIndex >= len(tools) {
		t.Fatalf("tool index %d out of range", toolIndex)
	}
	result, err := tools[toolIndex].Execute(context.Background(), "", json.RawMessage(arguments), nil)
	if err != nil {
		return nil, err
	}
	text, ok := result.Content[0].(ai.TextContent)
	if !ok {
		t.Fatalf("tool output is not text: %T", result.Content[0])
	}
	var decoded any
	if err := json.Unmarshal([]byte(text.Text), &decoded); err != nil {
		t.Fatalf("tool output is not JSON: %v", err)
	}
	return decoded, nil
}

func TestHistoryListSkipsCurrentConversationAndSortsNewestFirst(t *testing.T) {
	root := t.TempDir()
	savedConversation(t, root, "11111111-1111-1111-1111-111111111111", "2026-11-04T09:00:00Z",
		[2]string{"user", "这个月外食花了多少？"},
		[2]string{"assistant", "本月餐饮支出合计 1,280.00 元。"})
	savedConversation(t, root, "22222222-2222-2222-2222-222222222222", "2026-10-01T09:00:00Z",
		[2]string{"user", "上个月的预算怎么定的？"},
		[2]string{"assistant", "按 6:3:1 分配。"})
	savedConversation(t, root, "33333333-3333-3333-3333-333333333333", "2026-11-05T09:00:00Z",
		[2]string{"user", "当前这段对话"})

	index := openHistory(root, "33333333-3333-3333-3333-333333333333")
	if index == nil {
		t.Fatal("history index is nil")
	}
	output, err := runHistoryTool(t, 0, index, `{}`)
	if err != nil {
		t.Fatal(err)
	}
	listed := output.(map[string]any)
	if listed["count"].(float64) != 2 || listed["total"].(float64) != 2 {
		t.Fatalf("listed=%v", listed)
	}
	conversations := listed["conversations"].([]any)
	first := conversations[0].(map[string]any)
	second := conversations[1].(map[string]any)
	if first["conversation"] != "11111111-1111-1111-1111-111111111111" || second["conversation"] != "22222222-2222-2222-2222-222222222222" {
		t.Fatalf("order=%v", conversations)
	}
	if first["firstQuestion"] != "这个月外食花了多少？" || first["lastAnswer"] != "本月餐饮支出合计 1,280.00 元。" {
		t.Fatalf("summary=%v", first)
	}
	if first["turns"].(float64) != 1 {
		t.Fatalf("turns=%v", first["turns"])
	}
}

func TestHistoryListFiltersByKeywordAndBoundsTheLimit(t *testing.T) {
	root := t.TempDir()
	savedConversation(t, root, "11111111-1111-1111-1111-111111111111", "2026-11-04T09:00:00Z",
		[2]string{"user", "外卖报销怎么记"})
	savedConversation(t, root, "22222222-2222-2222-2222-222222222222", "2026-11-03T09:00:00Z",
		[2]string{"user", "预算复盘"})
	savedConversation(t, root, "33333333-3333-3333-3333-333333333333", "2026-11-02T09:00:00Z",
		[2]string{"user", "外卖明细"})
	index := openHistory(root, "")

	filtered, err := runHistoryTool(t, 0, index, `{"query":"外卖","limit":1}`)
	if err != nil {
		t.Fatal(err)
	}
	listed := filtered.(map[string]any)
	conversations := listed["conversations"].([]any)
	if len(conversations) != 1 || conversations[0].(map[string]any)["conversation"] != "11111111-1111-1111-1111-111111111111" {
		t.Fatalf("filtered=%v", listed)
	}
	if listed["total"].(float64) != 2 {
		t.Fatalf("total=%v", listed["total"])
	}

	all, err := runHistoryTool(t, 0, index, `{"limit":99}`)
	if err != nil {
		t.Fatal(err)
	}
	if count := len(all.(map[string]any)["conversations"].([]any)); count != 3 {
		t.Fatalf("count=%d", count)
	}
}

func TestHistoryReadKeepsLineBreaksAndClipsLongMessages(t *testing.T) {
	root := t.TempDir()
	long := strings.Repeat("长", savedMessageRunes+50)
	savedConversation(t, root, "11111111-1111-1111-1111-111111111111", "2026-11-04T09:00:00Z",
		[2]string{"user", "帮我把这张单子记一下"},
		[2]string{"assistant", "2026-11-04 * \"Cafe\" \"午餐\"\n  Expenses:Food 32.00 CNY\n  Assets:Cash -32.00 CNY"},
		[2]string{"tool", "ignored"},
		[2]string{"assistant", long})
	index := openHistory(root, "")

	output, err := runHistoryTool(t, 1, index, `{"conversation":"11111111-1111-1111-1111-111111111111"}`)
	if err != nil {
		t.Fatal(err)
	}
	read := output.(map[string]any)
	messages := read["messages"].([]any)
	if len(messages) != 3 {
		t.Fatalf("messages=%v", messages)
	}
	draft := messages[1].(map[string]any)["content"].(string)
	if !strings.Contains(draft, "\n") || !strings.Contains(draft, "Expenses:Food") {
		t.Fatalf("draft lost its shape: %q", draft)
	}
	clipped := messages[2].(map[string]any)["content"].(string)
	if utf8.RuneCountInString(clipped) != savedMessageRunes+1 || !strings.HasSuffix(clipped, "…") {
		t.Fatalf("clipped=%d runes", utf8.RuneCountInString(clipped))
	}
}

func TestHistoryRejectsUnknownAndOutOfDirectoryConversations(t *testing.T) {
	root := t.TempDir()
	savedConversation(t, root, "33333333-3333-3333-3333-333333333333", "2026-11-05T09:00:00Z",
		[2]string{"user", "当前这段对话"})
	index := openHistory(root, "33333333-3333-3333-3333-333333333333")

	for _, arguments := range []string{
		`{"conversation":"../../main.bean"}`,
		`{"conversation":"not-a-uuid"}`,
		`{"conversation":"11111111-1111-1111-1111-111111111111"}`,
		`{"conversation":"33333333-3333-3333-3333-333333333333"}`,
	} {
		if _, err := runHistoryTool(t, 1, index, arguments); err == nil {
			t.Fatalf("accepted %s", arguments)
		}
	}
	if _, err := runHistoryTool(t, 1, index, `{}`); err == nil {
		t.Fatal("accepted a missing conversation id")
	}
}

func TestHistorySkipsMalformedRecordsAndSurvivesAMissingDirectory(t *testing.T) {
	root := t.TempDir()
	missing := openHistory(root, "")
	output, err := runHistoryTool(t, 0, missing, `{}`)
	if err != nil {
		t.Fatal(err)
	}
	if count := output.(map[string]any)["count"].(float64); count != 0 {
		t.Fatalf("count=%v", count)
	}

	directory := filepath.Join(root, savedConversationDir)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	writeFile := func(name, content string) {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writeFile("44444444-4444-4444-4444-444444444444.json", `{"id":`)
	writeFile("55555555-5555-5555-5555-555555555555.json", `{"id":"55555555-5555-5555-5555-555555555555","messages":[]}`)
	writeFile("notes.json", `{"messages":[{"role":"user","text":"不是对话"}]}`)
	writeFile("66666666-6666-6666-6666-666666666666.json", `{"id":"66666666-6666-6666-6666-666666666666","updatedAt":"2026-11-01T09:00:00Z","messages":[{"role":"user","text":"能读到"}]}`)

	output, err = runHistoryTool(t, 0, missing, `{}`)
	if err != nil {
		t.Fatal(err)
	}
	listed := output.(map[string]any)
	if listed["count"].(float64) != 1 {
		t.Fatalf("count=%v", listed["count"])
	}
	if listed["conversations"].([]any)[0].(map[string]any)["firstQuestion"] != "能读到" {
		t.Fatalf("listed=%v", listed)
	}
}

func TestHistoryToolsAdvertiseNamesAndLabels(t *testing.T) {
	index := openHistory(t.TempDir(), "")
	tools := index.tools()
	if len(tools) != 2 {
		t.Fatalf("tools=%d", len(tools))
	}
	if tools[0].Name() != "list_saved_conversations" || tools[0].Label() != "查看历史对话" {
		t.Fatalf("tool0=%s/%s", tools[0].Name(), tools[0].Label())
	}
	if tools[1].Name() != "read_saved_conversation" || tools[1].Label() != "读取历史对话" {
		t.Fatalf("tool1=%s/%s", tools[1].Name(), tools[1].Label())
	}
	schema := tools[1].Schema()
	if schema.Parameters["required"].([]string)[0] != "conversation" {
		t.Fatalf("schema=%v", schema.Parameters)
	}
	if !strings.Contains(schema.Description, "旧草稿") {
		t.Fatalf("description=%q", schema.Description)
	}
}

func TestHistoryIsNotOfferedWithoutARuntimeDirectory(t *testing.T) {
	if index := openHistory("", ""); index != nil {
		t.Fatal("history without a runtime root")
	}
	if index := openHistory("relative/runtime", ""); index != nil {
		t.Fatal("history from a relative runtime root")
	}
}
