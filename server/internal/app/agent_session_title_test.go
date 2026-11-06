package app

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

type agentTitleTestModel struct {
	result   agentModelResult
	err      error
	system   string
	messages []agentModelMessage
}

func (m *agentTitleTestModel) Complete(_ context.Context, system string, messages []agentModelMessage, _ []agentToolSpec) (agentModelResult, error) {
	m.system = system
	m.messages = append([]agentModelMessage(nil), messages...)
	return m.result, m.err
}

func TestAgentSessionTitleRouteNamesConversationFromFirstExchange(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	model := &agentTitleTestModel{result: agentModelResult{Content: "**标题：本月餐饮支出**"}}
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir), limiter: NewRateLimiter(), agentModel: model}
	router := newRouter(cfg, server)
	cookies := loginCookies(t, router)

	response := requestWithCookies(router, http.MethodPost, "/api/ai/agent/session-title",
		`{"question":"这个月外食花了多少？","answer":"本月餐饮支出合计 1,280.00 元。"}`, cookies)
	if response.Code != http.StatusOK {
		t.Fatalf("title=%d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Title string `json:"title"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Title != "本月餐饮支出" {
		t.Fatalf("title=%q", payload.Title)
	}
	if !strings.Contains(model.messages[0].Content, "这个月外食花了多少？") || !strings.Contains(model.messages[0].Content, "1,280.00") {
		t.Fatalf("prompt missing exchange: %q", model.messages[0].Content)
	}
	if !strings.Contains(model.system, "标题") {
		t.Fatalf("system prompt=%q", model.system)
	}
}

func TestAgentSessionTitleRouteRequiresAuthAndAQuestion(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir), limiter: NewRateLimiter(), agentModel: &agentTitleTestModel{result: agentModelResult{Content: "标题"}}}
	router := newRouter(cfg, server)

	unauthorized := requestWithCookies(router, http.MethodPost, "/api/ai/agent/session-title", `{"question":"查一下余额"}`, nil)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}

	cookies := loginCookies(t, router)
	empty := requestWithCookies(router, http.MethodPost, "/api/ai/agent/session-title", `{"answer":"好的"}`, cookies)
	if empty.Code != http.StatusBadRequest {
		t.Fatalf("empty question=%d body=%s", empty.Code, empty.Body.String())
	}
}

func TestAgentSessionTitleReportsModelFailure(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir), limiter: NewRateLimiter(),
		agentModel: &agentTitleTestModel{err: context.DeadlineExceeded}}
	router := newRouter(cfg, server)
	cookies := loginCookies(t, router)

	response := requestWithCookies(router, http.MethodPost, "/api/ai/agent/session-title", `{"question":"查一下余额"}`, cookies)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("failed model=%d body=%s", response.Code, response.Body.String())
	}
}

func TestNormalizeAgentSessionTitle(t *testing.T) {
	cases := []struct {
		raw  string
		want string
		ok   bool
	}{
		{raw: "本月餐饮支出\n解释一下", want: "本月餐饮支出", ok: true},
		{raw: " `账单核对` ", want: "账单核对", ok: true},
		{raw: "**会话标题：修复 iOS 流水**。", want: "修复 iOS 流水", ok: true},
		{raw: "Title: Q3 budget review", want: "Q3 budget review", ok: true},
		{raw: strings.Repeat("长", 40), want: strings.Repeat("长", agentSessionTitleMaxRunes), ok: true},
		{raw: "\n\n", ok: false},
		{raw: "！", ok: false},
	}
	for _, testCase := range cases {
		got, err := normalizeAgentSessionTitle(testCase.raw)
		if testCase.ok && err != nil {
			t.Fatalf("raw=%q err=%v", testCase.raw, err)
		}
		if !testCase.ok && err == nil {
			t.Fatalf("raw=%q expected error, got %q", testCase.raw, got)
		}
		if testCase.ok && got != testCase.want {
			t.Fatalf("raw=%q got=%q want=%q", testCase.raw, got, testCase.want)
		}
	}
}
