package app

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAIParseRouteUsesOpenAICompatibleChatCompletions(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	fakeAI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/chat/completions" {
			t.Fatalf("unexpected AI path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"{\"entries\":[{\"kind\":\"transaction\",\"date\":\"2026-05-02\",\"payee\":\"Shop\",\"narration\":\"Snack\",\"metadata\":{},\"tags\":[],\"postings\":[{\"account\":\"Expenses:Food\",\"amount\":\"8.00\",\"currency\":\"CNY\"},{\"account\":\"Assets:Cash\",\"amount\":\"-8.00\",\"currency\":\"CNY\"}],\"confidence\":1,\"needsReview\":false,\"questions\":[]}]}"}}]}`))
	}))
	defer fakeAI.Close()
	t.Setenv("LEDGER_AI_PROVIDER", "openai")
	t.Setenv("OPENAI_API_KEY", "test-key")
	t.Setenv("OPENAI_BASE_URL", fakeAI.URL)
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodPost, "/api/ai/parse", `{"input":"买零食 8 元"}`, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("ai parse status=%d body=%s", res.Code, res.Body.String())
	}
	var body struct {
		Entries []LedgerEntry `json:"entries"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Entries) != 1 || body.Entries[0].Payee != "Shop" {
		t.Fatalf("unexpected AI entries: %#v", body.Entries)
	}
}

func TestAIChatRouteUsesOpenAICompatibleChatCompletions(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	fakeAI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/chat/completions" {
			t.Fatalf("unexpected AI path: %s", r.URL.Path)
		}
		var body struct {
			Messages []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if len(body.Messages) == 0 || !strings.Contains(body.Messages[len(body.Messages)-1].Content, "用户最新消息") {
			t.Fatalf("chat payload missing latest message context: %#v", body.Messages)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"{\"message\":\"可以这样记。\",\"entries\":[{\"kind\":\"transaction\",\"date\":\"2026-05-04\",\"payee\":\"Cafe\",\"narration\":\"Coffee\",\"metadata\":{},\"tags\":[],\"postings\":[{\"account\":\"Expenses:Food\",\"amount\":\"18.00\",\"currency\":\"CNY\"},{\"account\":\"Assets:Cash\",\"amount\":\"-18.00\",\"currency\":\"CNY\"}],\"confidence\":1,\"needsReview\":false,\"questions\":[]}]}"}}]}`))
	}))
	defer fakeAI.Close()
	t.Setenv("LEDGER_AI_PROVIDER", "openai")
	t.Setenv("OPENAI_API_KEY", "test-key")
	t.Setenv("OPENAI_BASE_URL", fakeAI.URL)
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodPost, "/api/ai/chat", `{"message":"咖啡 18","messages":[{"role":"assistant","text":"你好"}],"draftEntries":[]}`, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("ai chat=%d body=%s", res.Code, res.Body.String())
	}
	var body struct {
		Message string        `json:"message"`
		Entries []LedgerEntry `json:"entries"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Message != "可以这样记。" || len(body.Entries) != 1 || body.Entries[0].Narration != "Coffee" {
		t.Fatalf("unexpected chat response: %#v", body)
	}
}

func TestAIAccountsChatRouteReturnsAccountOperationDrafts(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	fakeAI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/chat/completions" {
			t.Fatalf("unexpected AI path: %s", r.URL.Path)
		}
		var body struct {
			Messages []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if len(body.Messages) == 0 || !strings.Contains(body.Messages[len(body.Messages)-1].Content, "账户操作草稿") {
			t.Fatalf("account chat payload missing draft context: %#v", body.Messages)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"{\"message\":\"已准备创建差旅分类。\",\"operations\":[{\"kind\":\"create\",\"date\":\"2026-05-25\",\"account\":\"Expenses:Travel\",\"alias\":\"差旅\",\"currency\":\"CNY\",\"group\":\"expense\"}]}"}}]}`))
	}))
	defer fakeAI.Close()
	t.Setenv("LEDGER_AI_PROVIDER", "openai")
	t.Setenv("OPENAI_API_KEY", "test-key")
	t.Setenv("OPENAI_BASE_URL", fakeAI.URL)
	router := NewRouter(cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodPost, "/api/ai/accounts-chat", `{"message":"帮我加一个差旅分类","messages":[{"role":"assistant","text":"你好"}],"draftOperations":[]}`, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("ai accounts chat=%d body=%s", res.Code, res.Body.String())
	}
	var body struct {
		Message    string             `json:"message"`
		Operations []AccountOperation `json:"operations"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Message != "已准备创建差旅分类。" || len(body.Operations) != 1 || body.Operations[0].Account != "Expenses:Travel" {
		t.Fatalf("unexpected account chat response: %#v", body)
	}
}
