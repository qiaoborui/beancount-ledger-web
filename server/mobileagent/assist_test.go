package mobileagent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/MichaelKinsy/PiG/ai"
)

func assistFor(t *testing.T, call func(string) string, request map[string]any) assistResponseV1 {
	t.Helper()
	raw, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	var response assistResponseV1
	if err := json.Unmarshal([]byte(call(string(raw))), &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func TestStarterSuggestionsReadTheLedgerAndMemory(t *testing.T) {
	memory := filepath.Join(t.TempDir(), "agent-memory.md")
	if err := os.WriteFile(memory, []byte("- 每月 5 号核对招行信用卡\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var seen string
	var tools []string
	useFaux(t, ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
		seen, tools = transcriptText(t, request), offeredTools(request)
		return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("```json\n{\"suggestions\":[\"这个月午饭花了多少\",\"1. 核对招行信用卡\",\"这个月午饭花了多少？\",\"最近 10 笔餐饮\",\"把午饭归到 Food:Lunch\"]}\n```")}, StopReason: "stop"}.AssistantMessage(), nil
	}))
	workspace := committedWorkspace(t)
	day := time.Now().AddDate(0, 0, -3).Format("2006-01-02")
	recent := testLedger + day + " * \"瑞幸\" \"咖啡\"\n  Expenses:Food  18.00 CNY\n  Assets:Cash  -18.00 CNY\n"
	if err := os.WriteFile(filepath.Join(workspace, "main.bean"), []byte(recent), 0o600); err != nil {
		t.Fatal(err)
	}
	response := assistFor(t, SuggestJSON, map[string]any{"version": 1, "workspaceRoot": workspace,
		"sensitiveUnlocked": true, "provider": "faux", "model": "faux-1", "apiKey": "test", "memoryPath": memory,
		"recent": []string{"上个月收入"}, "count": 3})
	if !response.OK {
		t.Fatalf("unexpected response: %+v", response)
	}
	want := []string{"这个月午饭花了多少", "核对招行信用卡", "最近 10 笔餐饮"}
	if !reflect.DeepEqual(response.Suggestions, want) {
		t.Fatalf("suggestions = %v, want %v", response.Suggestions, want)
	}
	for _, fact := range []string{"瑞幸", "Expenses:Food", "每月 5 号核对招行信用卡", "上个月收入", "试试"} {
		if !strings.Contains(seen, fact) {
			t.Fatalf("%q did not reach the model:\n%s", fact, seen)
		}
	}
	if len(tools) != 0 {
		t.Fatalf("assist calls must not offer tools: %v", tools)
	}
}

func TestNextSuggestionFollowsTheConversation(t *testing.T) {
	var seen string
	useFaux(t, ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
		seen = transcriptText(t, request)
		return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText(`{"suggestions":["这个月餐饮多少","按周画个图"]}`)}, StopReason: "stop"}.AssistantMessage(), nil
	}))
	response := assistFor(t, SuggestJSON, map[string]any{"version": 1, "provider": "faux", "model": "faux-1", "apiKey": "test",
		"history": []map[string]string{{"role": "user", "content": "这个月餐饮多少"}, {"role": "assistant", "content": "餐饮 1820 元。"}}})
	if !response.OK || !reflect.DeepEqual(response.Suggestions, []string{"按周画个图"}) {
		t.Fatalf("unexpected response: %+v", response)
	}
	if !strings.Contains(seen, "餐饮 1820 元") || !strings.Contains(seen, "浅色") {
		t.Fatalf("conversation did not reach the model:\n%s", seen)
	}
}

func TestTitleNamesTheOpeningExchange(t *testing.T) {
	var seen string
	var tools []string
	useFaux(t, ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
		seen, tools = transcriptText(t, request), offeredTools(request)
		return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("**标题：本月外卖支出**。\n解释一下")}, StopReason: "stop"}.AssistantMessage(), nil
	}))
	response := assistFor(t, TitleJSON, map[string]any{"version": 1, "provider": "faux", "model": "faux-1", "apiKey": "test",
		"history": []map[string]string{{"role": "user", "content": "帮我看下这个月的外卖"}, {"role": "assistant", "content": "本月餐饮支出合计 1,280.00 元。"}}})
	if !response.OK || response.Title != "本月外卖支出" {
		t.Fatalf("unexpected response: %+v", response)
	}
	for _, fact := range []string{"帮我看下这个月的外卖", "1,280.00"} {
		if !strings.Contains(seen, fact) {
			t.Fatalf("%q did not reach the model:\n%s", fact, seen)
		}
	}
	if len(tools) != 0 {
		t.Fatalf("assist calls must not offer tools: %v", tools)
	}
}

func TestTitleNeedsAnAnswerAndAUselessReplyIsRejected(t *testing.T) {
	useFaux(t, ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("。")}, StopReason: "stop"}))
	unanswered := assistFor(t, TitleJSON, map[string]any{"version": 1, "provider": "faux", "model": "faux-1", "apiKey": "test",
		"history": []map[string]string{{"role": "user", "content": "这个月餐饮多少"}}})
	if unanswered.OK || unanswered.Error == "" {
		t.Fatalf("a question without an answer was named: %+v", unanswered)
	}
	useless := assistFor(t, TitleJSON, map[string]any{"version": 1, "provider": "faux", "model": "faux-1", "apiKey": "test",
		"history": []map[string]string{{"role": "user", "content": "这个月餐饮多少"}, {"role": "assistant", "content": "1820 元"}}})
	if useless.OK || useless.Error == "" {
		t.Fatalf("an empty reply was accepted: %+v", useless)
	}
}

func TestCleanTitleTakesOneLineAndDropsLabels(t *testing.T) {
	cases := map[string]string{
		"**会话标题：修复 iOS 流水**。\n说明": "修复 iOS 流水",
		"Title: Q3 budget review": "Q3 budget review",
		"`账单核对`":                  "账单核对",
		"本月外卖支出。":                 "本月外卖支出",
		"  \n\n":                  "",
		"！":                       "",
	}
	for reply, want := range cases {
		if got := cleanTitle(reply); got != want {
			t.Fatalf("cleanTitle(%q) = %q, want %q", reply, got, want)
		}
	}
	if got := cleanTitle(strings.Repeat("长", 80)); utf8.RuneCountInString(got) != maxTitleRunes+1 {
		t.Fatalf("long title clipped to %d runes", utf8.RuneCountInString(got))
	}
}

func TestRecapSummarisesTheConversation(t *testing.T) {
	useFaux(t, ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("## 回顾\n- 查了本月餐饮：1820 元\n2. 打车已归到交通，已写入")}, StopReason: "stop"}))
	response := assistFor(t, RecapJSON, map[string]any{"version": 1, "provider": "faux", "model": "faux-1", "apiKey": "test",
		"history": []map[string]string{{"role": "user", "content": "这个月餐饮多少"}, {"role": "assistant", "content": "1820 元"}}})
	if !response.OK || response.Recap != "- 查了本月餐饮：1820 元\n- 打车已归到交通，已写入" {
		t.Fatalf("unexpected response: %+v", response)
	}
	empty := assistFor(t, RecapJSON, map[string]any{"version": 1, "provider": "faux", "model": "faux-1", "apiKey": "test"})
	if empty.OK || empty.Error == "" {
		t.Fatalf("an empty conversation was recapped: %+v", empty)
	}
}

func TestRecapMessageKeepsTheFirstQuestionAndTheLatest(t *testing.T) {
	history := []historyMessageV1{{Role: "user", Content: "第一个问题"}}
	for range 40 {
		history = append(history, historyMessageV1{Role: "assistant", Content: strings.Repeat("长", 1500)})
	}
	history = append(history, historyMessageV1{Role: "user", Content: "最后的问题"})
	message := recapMessage(history)
	if !strings.Contains(message, "第一个问题") || !strings.Contains(message, "最后的问题") || !strings.Contains(message, "中间省略") {
		t.Fatalf("recap message lost an end: %d bytes", len(message))
	}
	if len(message) > maxRecapBytes+maxAssistMessage*4 {
		t.Fatalf("recap message too large: %d", len(message))
	}
}
