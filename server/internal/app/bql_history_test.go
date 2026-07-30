package app

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

const bqlHistoryTestQuery = "SELECT month, count(*) AS tx_count FROM transactions GROUP BY month ORDER BY month DESC LIMIT 5"

type bqlHistoryTestModel struct {
	result   agentModelResult
	messages []agentModelMessage
	tools    []agentToolSpec
}

func (m *bqlHistoryTestModel) Complete(_ context.Context, _ string, messages []agentModelMessage, tools []agentToolSpec) (agentModelResult, error) {
	m.messages = append([]agentModelMessage(nil), messages...)
	m.tools = append([]agentToolSpec(nil), tools...)
	return m.result, nil
}

func TestBQLHistoryPersistsGeneratedTitleAndTouchesExistingQuery(t *testing.T) {
	cfg := testLedger(t)
	model := &bqlHistoryTestModel{result: agentModelResult{Content: "月度交易趋势"}}
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir), agentModel: model}

	record, created, err := server.touchBQLHistory(context.Background(), bqlHistoryTestQuery)
	if err != nil || !created {
		t.Fatalf("touch created=%v err=%v", created, err)
	}
	if record.Title != "交易查询" || record.TitleSource != "fallback" || record.RunCount != 1 {
		t.Fatalf("unexpected fallback record: %#v", record)
	}
	title, err := server.generateBQLHistoryTitle(context.Background(), record.Query)
	if err != nil {
		t.Fatal(err)
	}
	record, err = server.setBQLHistoryGeneratedTitle(context.Background(), record.ID, title)
	if err != nil {
		t.Fatal(err)
	}
	if record.Title != "月度交易趋势" || record.TitleSource != "ai" {
		t.Fatalf("unexpected generated record: %#v", record)
	}
	if len(model.messages) != 1 || model.messages[0].Content != bqlHistoryTestQuery || len(model.tools) != 0 {
		t.Fatalf("title request should contain only the BQL query: messages=%#v tools=%#v", model.messages, model.tools)
	}

	record, created, err = server.touchBQLHistory(context.Background(), bqlHistoryTestQuery)
	if err != nil || created {
		t.Fatalf("touch existing created=%v err=%v", created, err)
	}
	if record.Title != "月度交易趋势" || record.RunCount != 2 {
		t.Fatalf("existing record should preserve title and increment count: %#v", record)
	}
	records, err := server.listBQLHistory(context.Background())
	if err != nil || len(records) != 1 {
		t.Fatalf("records=%#v err=%v", records, err)
	}
}

func TestBQLHistoryGeneratedTitleKeepsManualRename(t *testing.T) {
	cfg := testLedger(t)
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir)}
	record, _, err := server.touchBQLHistory(context.Background(), bqlHistoryTestQuery)
	if err != nil {
		t.Fatal(err)
	}
	record, err = server.renameBQLHistoryRecord(context.Background(), record.ID, "我的交易趋势")
	if err != nil {
		t.Fatal(err)
	}
	record, err = server.setBQLHistoryGeneratedTitle(context.Background(), record.ID, "AI 交易趋势")
	if err != nil {
		t.Fatal(err)
	}
	if record.Title != "我的交易趋势" || record.TitleSource != "manual" {
		t.Fatalf("generated title overwrote manual rename: %#v", record)
	}
}

func TestBQLHistorySupportsSuccessfulMultiStatementBlocks(t *testing.T) {
	query := bqlHistoryTestQuery + ";\nSELECT account, sum(value) AS total FROM postings GROUP BY account ORDER BY total DESC LIMIT 5"
	if err := (BQLHistorySaveRequest{Query: query}).Validate(); err != nil {
		t.Fatal(err)
	}
	if got := fallbackBQLHistoryTitle(query); got != "组合查询" {
		t.Fatalf("fallback title=%q", got)
	}
}

func TestBQLHistoryRoutesRequireSensitiveAccessAndPersistFallback(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir), limiter: NewRateLimiter(), agentModel: &bqlHistoryTestModel{result: agentModelResult{Content: "月度交易趋势"}}}
	router := newRouter(cfg, server)
	cookies := loginCookies(t, router)

	saved := requestWithCookies(router, http.MethodPost, "/api/ledger/bql-history", `{"query":"`+bqlHistoryTestQuery+`"}`, cookies)
	if saved.Code != http.StatusOK {
		t.Fatalf("save=%d body=%s", saved.Code, saved.Body.String())
	}
	if !strings.Contains(saved.Body.String(), `"title":"交易查询"`) || !strings.Contains(saved.Body.String(), `"titleSource":"fallback"`) {
		t.Fatalf("unexpected fallback response: %s", saved.Body.String())
	}
	var savedRecord BQLHistoryRecord
	if err := json.Unmarshal(saved.Body.Bytes(), &savedRecord); err != nil {
		t.Fatal(err)
	}
	titled := requestWithCookies(router, http.MethodPost, "/api/ledger/bql-history/"+savedRecord.ID+"/title", "", cookies)
	if titled.Code != http.StatusOK || !strings.Contains(titled.Body.String(), `"titleSource":"ai"`) {
		t.Fatalf("title=%d body=%s", titled.Code, titled.Body.String())
	}
	renamed := requestWithCookies(router, http.MethodPatch, "/api/ledger/bql-history/"+savedRecord.ID, `{"title":"我的交易"}`, cookies)
	if renamed.Code != http.StatusOK || !strings.Contains(renamed.Body.String(), `"titleSource":"manual"`) {
		t.Fatalf("rename=%d body=%s", renamed.Code, renamed.Body.String())
	}
	deleted := requestWithCookies(router, http.MethodDelete, "/api/ledger/bql-history/"+savedRecord.ID, "", cookies)
	if deleted.Code != http.StatusNoContent {
		t.Fatalf("delete=%d body=%s", deleted.Code, deleted.Body.String())
	}

	listed := requestWithCookies(router, http.MethodGet, "/api/ledger/bql-history", "", cookies)
	if listed.Code != http.StatusOK || strings.Contains(listed.Body.String(), savedRecord.ID) {
		t.Fatalf("list=%d body=%s", listed.Code, listed.Body.String())
	}

	lockedCookies := make([]*http.Cookie, 0, len(cookies))
	for _, cookie := range cookies {
		if cookie.Name != sensitiveCookieName {
			lockedCookies = append(lockedCookies, cookie)
		}
	}
	lockedHistory := requestWithCookies(router, http.MethodGet, "/api/ledger/bql-history", "", lockedCookies)
	if lockedHistory.Code != http.StatusLocked {
		t.Fatalf("locked history=%d body=%s", lockedHistory.Code, lockedHistory.Body.String())
	}
}
