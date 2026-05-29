package app

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAgentToolsRequireToken(t *testing.T) {
	cfg := testLedger(t)
	router := NewRouter(cfg)

	res := requestWithCookies(router, http.MethodGet, "/internal/agent/accounts", "", nil)
	if res.Code != http.StatusNotFound {
		t.Fatalf("disabled agent tools status=%d body=%s", res.Code, res.Body.String())
	}

	cfg.AgentToolToken = "agent-secret"
	router = NewRouter(cfg)
	res = requestWithCookies(router, http.MethodGet, "/internal/agent/accounts", "", nil)
	if res.Code != http.StatusUnauthorized {
		t.Fatalf("missing token status=%d body=%s", res.Code, res.Body.String())
	}
}

func TestAgentToolsQueryAndSummarizeLedger(t *testing.T) {
	cfg := testLedger(t)
	cfg.AgentToolToken = "agent-secret"
	router := NewRouter(cfg)
	cookies := []*http.Cookie{{Name: "unused", Value: "unused"}}

	query := requestWithAgentToken(router, http.MethodPost, "/internal/agent/transactions/query", `{"start":"2026-05-01","end":"2026-06-01","accountPrefix":"Expenses:","limit":10}`, "agent-secret", cookies)
	if query.Code != http.StatusOK {
		t.Fatalf("query status=%d body=%s", query.Code, query.Body.String())
	}
	var queryBody struct {
		Transactions []Transaction `json:"transactions"`
		Count        int           `json:"count"`
	}
	if err := json.Unmarshal(query.Body.Bytes(), &queryBody); err != nil {
		t.Fatal(err)
	}
	if queryBody.Count != 1 || len(queryBody.Transactions) != 1 || queryBody.Transactions[0].Payee != "Cafe" {
		t.Fatalf("unexpected query result: %#v", queryBody)
	}

	summary := requestWithAgentToken(router, http.MethodPost, "/internal/agent/expenses/summary", `{"start":"2026-05-01","end":"2026-06-01","groupBy":"account"}`, "agent-secret", cookies)
	if summary.Code != http.StatusOK {
		t.Fatalf("summary status=%d body=%s", summary.Code, summary.Body.String())
	}
	var summaryBody struct {
		Rows  []AgentExpenseSummaryRow `json:"rows"`
		Total int                      `json:"total"`
	}
	if err := json.Unmarshal(summary.Body.Bytes(), &summaryBody); err != nil {
		t.Fatal(err)
	}
	if summaryBody.Total != 1200 || len(summaryBody.Rows) != 1 || summaryBody.Rows[0].Key != "Expenses:Food" {
		t.Fatalf("unexpected summary result: %#v", summaryBody)
	}
}

func TestAgentToolsValidateEntriesWithoutWriting(t *testing.T) {
	cfg := testLedger(t)
	cfg.AgentToolToken = "agent-secret"
	router := NewRouter(cfg)
	body := `{"entries":[{"date":"2026-05-03","payee":"Tea","narration":"Tea","metadata":{},"tags":[],"postings":[{"account":"Expenses:Food","amount":"9.00","currency":"CNY"},{"account":"Assets:Cash","amount":"-9.00","currency":"CNY"}]}]}`

	res := requestWithAgentToken(router, http.MethodPost, "/internal/agent/entries/validate", body, "agent-secret", nil)
	if res.Code != http.StatusOK {
		t.Fatalf("validate status=%d body=%s", res.Code, res.Body.String())
	}
	var parsed struct {
		BeanText []string `json:"beanText"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &parsed); err != nil {
		t.Fatal(err)
	}
	if len(parsed.BeanText) != 1 || parsed.BeanText[0] == "" {
		t.Fatalf("validate should return bean preview: %#v", parsed)
	}

	query := requestWithAgentToken(router, http.MethodPost, "/internal/agent/transactions/query", `{"start":"2026-05-03","end":"2026-05-04","text":"Tea"}`, "agent-secret", nil)
	var queryBody struct {
		Count int `json:"count"`
	}
	if err := json.Unmarshal(query.Body.Bytes(), &queryBody); err != nil {
		t.Fatal(err)
	}
	if queryBody.Count != 0 {
		t.Fatalf("validate tool must not write entries: %#v", queryBody)
	}
}

func requestWithAgentToken(router http.Handler, method, path, body, token string, cookies []*http.Cookie) *httptest.ResponseRecorder {
	recorder := httptest.NewRecorder()
	req := httptest.NewRequest(method, path, bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	for _, cookie := range cookies {
		req.AddCookie(cookie)
	}
	router.ServeHTTP(recorder, req)
	return recorder
}
