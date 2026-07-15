package app

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func TestRouterAuthAndSummary(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := testRouter(t, cfg)

	unauth := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/ledger/summary?start=2026-05-01&end=2026-06-01", nil)
	router.ServeHTTP(unauth, req)
	if unauth.Code != http.StatusUnauthorized {
		t.Fatalf("unauth status = %d, want 401", unauth.Code)
	}

	login := httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/api/auth/login", bytes.NewBufferString(`{"password":"secret"}`))
	req.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(login, req)
	if login.Code != http.StatusOK {
		t.Fatalf("login status = %d body=%s", login.Code, login.Body.String())
	}
	for _, cookie := range login.Result().Cookies() {
		if cookie.SameSite != http.SameSiteLaxMode || cookie.Partitioned {
			t.Fatalf("expected same-origin cookie to remain unpartitioned, got name=%s sameSite=%v partitioned=%v", cookie.Name, cookie.SameSite, cookie.Partitioned)
		}
	}

	summary := httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/api/ledger/summary?start=2026-05-01&end=2026-06-01", nil)
	for _, cookie := range login.Result().Cookies() {
		req.AddCookie(cookie)
	}
	router.ServeHTTP(summary, req)
	if summary.Code != http.StatusOK {
		t.Fatalf("summary status = %d body=%s", summary.Code, summary.Body.String())
	}
	bootstrap := requestWithCookies(router, http.MethodGet, "/api/ledger/bootstrap?start=2026-05-01&end=2026-06-01", "", login.Result().Cookies())
	if got := bootstrap.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("ledger/bootstrap Cache-Control=%q", got)
	}
	var body struct {
		Summary struct {
			Income  int `json:"income"`
			Expense int `json:"expense"`
		} `json:"summary"`
		SensitiveUnlocked bool `json:"sensitiveUnlocked"`
	}
	if err := json.Unmarshal(summary.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if !body.SensitiveUnlocked || body.Summary.Income != 100000 || body.Summary.Expense != 1200 {
		t.Fatalf("unexpected summary: %#v", body)
	}

	registerQuick := requestWithCookies(router, http.MethodPost, "/api/quick-unlock/register", `{"deviceId":"test-device-1","name":"Phone","mode":"numeric"}`, login.Result().Cookies())
	if registerQuick.Code != http.StatusOK {
		t.Fatalf("quick unlock register status=%d body=%s", registerQuick.Code, registerQuick.Body.String())
	}
	var quickBody struct {
		DeviceID string `json:"deviceId"`
		Token    string `json:"token"`
	}
	if err := json.Unmarshal(registerQuick.Body.Bytes(), &quickBody); err != nil {
		t.Fatal(err)
	}
	if quickBody.DeviceID != "test-device-1" || quickBody.Token == "" {
		t.Fatalf("unexpected quick unlock register response: %#v", quickBody)
	}

	mergeCookies := func(groups ...[]*http.Cookie) []*http.Cookie {
		byName := map[string]*http.Cookie{}
		order := []string{}
		for _, group := range groups {
			for _, cookie := range group {
				if cookie.MaxAge < 0 {
					delete(byName, cookie.Name)
					continue
				}
				if _, ok := byName[cookie.Name]; !ok {
					order = append(order, cookie.Name)
				}
				byName[cookie.Name] = cookie
			}
		}
		out := []*http.Cookie{}
		for _, name := range order {
			if cookie := byName[name]; cookie != nil {
				out = append(out, cookie)
			}
		}
		return out
	}

	lock := httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/api/auth/lock", nil)
	for _, cookie := range login.Result().Cookies() {
		req.AddCookie(cookie)
	}
	router.ServeHTTP(lock, req)
	if lock.Code != http.StatusOK {
		t.Fatalf("lock status = %d body=%s", lock.Code, lock.Body.String())
	}

	me := httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/api/auth/me", nil)
	for _, cookie := range mergeCookies(login.Result().Cookies(), lock.Result().Cookies()) {
		req.AddCookie(cookie)
	}
	router.ServeHTTP(me, req)
	if me.Code != http.StatusOK {
		t.Fatalf("me status = %d body=%s", me.Code, me.Body.String())
	}
	var meBody struct {
		Authenticated     bool `json:"authenticated"`
		SensitiveUnlocked bool `json:"sensitiveUnlocked"`
	}
	if err := json.Unmarshal(me.Body.Bytes(), &meBody); err != nil {
		t.Fatal(err)
	}
	if !meBody.Authenticated || meBody.SensitiveUnlocked {
		t.Fatalf("lock should keep auth but clear sensitive unlock: %#v", meBody)
	}
	if got := me.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("auth/me Cache-Control=%q", got)
	}

	verifyQuick := requestWithCookies(router, http.MethodPost, "/api/quick-unlock/verify", `{"deviceId":"test-device-1","token":"`+quickBody.Token+`"}`, nil)
	if verifyQuick.Code != http.StatusOK {
		t.Fatalf("quick unlock verify status=%d body=%s", verifyQuick.Code, verifyQuick.Body.String())
	}
	quickSummary := requestWithCookies(router, http.MethodGet, "/api/ledger/summary?start=2026-05-01&end=2026-06-01", "", verifyQuick.Result().Cookies())
	if quickSummary.Code != http.StatusOK {
		t.Fatalf("quick unlock summary status=%d body=%s", quickSummary.Code, quickSummary.Body.String())
	}
	if err := json.Unmarshal(quickSummary.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if !body.SensitiveUnlocked || body.Summary.Income != 100000 {
		t.Fatalf("quick unlock should restore sensitive access: %#v", body)
	}

	for _, path := range []string{"/api/quick-unlock/status", "/api/passkey/status"} {
		status := requestWithCookies(router, http.MethodGet, path, "", login.Result().Cookies())
		if got := status.Header().Get("Cache-Control"); got != "no-store" {
			t.Fatalf("%s Cache-Control=%q", path, got)
		}
	}

	sessionOnly := []*http.Cookie{}
	for _, cookie := range verifyQuick.Result().Cookies() {
		if cookie.Name == sessionCookieName {
			sessionOnly = append(sessionOnly, cookie)
		}
	}
	revokeQuick := requestWithCookies(router, http.MethodPost, "/api/quick-unlock/revoke", `{"deviceId":"test-device-1"}`, sessionOnly)
	if revokeQuick.Code != http.StatusOK {
		t.Fatalf("quick unlock revoke status=%d body=%s", revokeQuick.Code, revokeQuick.Body.String())
	}
	verifyRevoked := requestWithCookies(router, http.MethodPost, "/api/quick-unlock/verify", `{"deviceId":"test-device-1","token":"`+quickBody.Token+`"}`, nil)
	if verifyRevoked.Code != http.StatusUnauthorized {
		t.Fatalf("revoked quick unlock status=%d body=%s", verifyRevoked.Code, verifyRevoked.Body.String())
	}

	forgedSensitive := []*http.Cookie{}
	for _, cookie := range login.Result().Cookies() {
		if cookie.Name == sessionCookieName {
			forgedSensitive = append(forgedSensitive, cookie)
		}
	}
	forgedSensitive = append(forgedSensitive, &http.Cookie{Name: sensitiveCookieName, Value: "9999999999999"})
	balances := requestWithCookies(router, http.MethodGet, "/api/ledger/balances", "", forgedSensitive)
	if balances.Code != 423 {
		t.Fatalf("forged sensitive cookie status=%d body=%s", balances.Code, balances.Body.String())
	}
}

func TestUnsafeAPIRoutesRejectCrossSiteOrigin(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := testRouter(t, cfg)
	cookies := loginCookies(t, router)

	req := httptest.NewRequest(http.MethodPost, "/api/auth/lock", nil)
	req.Header.Set("Origin", "https://evil.example")
	for _, cookie := range cookies {
		req.AddCookie(cookie)
	}
	res := httptest.NewRecorder()
	router.ServeHTTP(res, req)
	if res.Code != http.StatusForbidden {
		t.Fatalf("cross-site POST status=%d body=%s", res.Code, res.Body.String())
	}

	req = httptest.NewRequest(http.MethodPost, "/api/auth/lock", nil)
	req.Header.Set("Origin", "https://example.com")
	req.Header.Set("X-Forwarded-Proto", "https")
	req.Host = "example.com"
	for _, cookie := range cookies {
		req.AddCookie(cookie)
	}
	res = httptest.NewRecorder()
	router.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("same-origin POST status=%d body=%s", res.Code, res.Body.String())
	}
}

func TestConfiguredCORSOriginCanUseCookieAuth(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	t.Setenv("LEDGER_CORS_ORIGINS", "https://frontend.example.com")
	router := testRouter(t, cfg)

	preflight := httptest.NewRequest(http.MethodOptions, "/api/auth/login", nil)
	preflight.Header.Set("Origin", "https://frontend.example.com")
	preflight.Header.Set("Access-Control-Request-Method", "POST")
	preflightRes := httptest.NewRecorder()
	router.ServeHTTP(preflightRes, preflight)
	if preflightRes.Code != http.StatusNoContent {
		t.Fatalf("preflight status=%d body=%s", preflightRes.Code, preflightRes.Body.String())
	}
	if got := preflightRes.Header().Get("Access-Control-Allow-Origin"); got != "https://frontend.example.com" {
		t.Fatalf("cors origin=%q", got)
	}
	if got := preflightRes.Header().Get("Access-Control-Allow-Credentials"); got != "true" {
		t.Fatalf("cors credentials=%q", got)
	}

	login := httptest.NewRequest(http.MethodPost, "/api/auth/login", bytes.NewBufferString(`{"password":"secret"}`))
	login.Header.Set("Origin", "https://frontend.example.com")
	login.Header.Set("Sec-Fetch-Site", "cross-site")
	login.Header.Set("Content-Type", "application/json")
	loginRes := httptest.NewRecorder()
	router.ServeHTTP(loginRes, login)
	if loginRes.Code != http.StatusOK {
		t.Fatalf("login status=%d body=%s", loginRes.Code, loginRes.Body.String())
	}
	cookies := loginRes.Result().Cookies()
	if len(cookies) == 0 {
		t.Fatal("expected auth cookies")
	}
	for _, cookie := range cookies {
		if cookie.SameSite != http.SameSiteNoneMode || !cookie.Secure || !cookie.Partitioned {
			t.Fatalf("expected cross-site partitioned secure cookie, got name=%s sameSite=%v secure=%v partitioned=%v", cookie.Name, cookie.SameSite, cookie.Secure, cookie.Partitioned)
		}
	}

	logout := httptest.NewRequest(http.MethodPost, "/api/auth/logout", nil)
	logout.Header.Set("Origin", "https://frontend.example.com")
	logout.Header.Set("Sec-Fetch-Site", "cross-site")
	for _, cookie := range cookies {
		logout.AddCookie(cookie)
	}
	logoutRes := httptest.NewRecorder()
	router.ServeHTTP(logoutRes, logout)
	if logoutRes.Code != http.StatusOK {
		t.Fatalf("logout status=%d body=%s", logoutRes.Code, logoutRes.Body.String())
	}
	clearedCookies := logoutRes.Result().Cookies()
	if len(clearedCookies) != len(cookies) {
		t.Fatalf("cleared cookie count=%d want=%d", len(clearedCookies), len(cookies))
	}
	for _, cookie := range clearedCookies {
		if cookie.MaxAge >= 0 || cookie.SameSite != http.SameSiteNoneMode || !cookie.Secure || !cookie.Partitioned {
			t.Fatalf("expected matching cross-site cookie deletion, got name=%s maxAge=%d sameSite=%v secure=%v partitioned=%v", cookie.Name, cookie.MaxAge, cookie.SameSite, cookie.Secure, cookie.Partitioned)
		}
	}
}

func TestStaticFallbackCacheHeaders(t *testing.T) {
	cfg := testLedger(t)
	cfg.ServeStatic = true
	mustWrite(t, filepath.Join(cfg.StaticDir, "index.html"), "<!doctype html>")
	mustWrite(t, filepath.Join(cfg.StaticDir, "assets", "app.123.js"), "console.log('ok')")
	mustWrite(t, filepath.Join(cfg.StaticDir, "sw.js"), "")
	router := testRouter(t, cfg)

	index := httptest.NewRecorder()
	router.ServeHTTP(index, httptest.NewRequest(http.MethodGet, "/", nil))
	if index.Code != http.StatusOK {
		t.Fatalf("index status=%d body=%s", index.Code, index.Body.String())
	}
	if got := index.Header().Get("Cache-Control"); got != "public, max-age=0, must-revalidate" {
		t.Fatalf("index Cache-Control=%q", got)
	}

	asset := httptest.NewRecorder()
	router.ServeHTTP(asset, httptest.NewRequest(http.MethodGet, "/assets/app.123.js", nil))
	if asset.Code != http.StatusOK {
		t.Fatalf("asset status=%d body=%s", asset.Code, asset.Body.String())
	}
	if got := asset.Header().Get("Cache-Control"); got != "public, max-age=31536000, immutable" {
		t.Fatalf("asset Cache-Control=%q", got)
	}

	serviceWorker := httptest.NewRecorder()
	router.ServeHTTP(serviceWorker, httptest.NewRequest(http.MethodGet, "/sw.js", nil))
	if serviceWorker.Code != http.StatusOK {
		t.Fatalf("sw status=%d body=%s", serviceWorker.Code, serviceWorker.Body.String())
	}
	if got := serviceWorker.Header().Get("Cache-Control"); got != "public, max-age=0, must-revalidate" {
		t.Fatalf("sw Cache-Control=%q", got)
	}

	gitProbe := httptest.NewRecorder()
	router.ServeHTTP(gitProbe, httptest.NewRequest(http.MethodGet, "/.git/HEAD", nil))
	if gitProbe.Code != http.StatusNotFound {
		t.Fatalf("git probe status=%d body=%s", gitProbe.Code, gitProbe.Body.String())
	}
}

func TestRegisteredAPIRoutesHaveIntegrationCoverage(t *testing.T) {
	cfg := testLedger(t)
	router := testRouter(t, cfg)
	actual := map[string]bool{}
	for _, route := range router.Routes() {
		if strings.HasPrefix(route.Path, "/api/") {
			actual[route.Method+" "+route.Path] = true
		}
	}
	covered := map[string]bool{
		"GET /api/health":                        true,
		"POST /api/auth/login":                   true,
		"POST /api/auth/lock":                    true,
		"POST /api/auth/logout":                  true,
		"GET /api/auth/me":                       true,
		"GET /api/quick-unlock/status":           true,
		"POST /api/quick-unlock/register":        true,
		"POST /api/quick-unlock/verify":          true,
		"POST /api/quick-unlock/revoke":          true,
		"GET /api/passkey/status":                true,
		"POST /api/passkey/login/options":        true,
		"POST /api/passkey/login/verify":         true,
		"POST /api/passkey/register/options":     true,
		"POST /api/passkey/register/verify":      true,
		"GET /api/ledger/bootstrap":              true,
		"GET /api/ledger/version":                true,
		"GET /api/ledger/index-info":             true,
		"GET /api/ledger/entries":                true,
		"GET /api/ledger/summary":                true,
		"GET /api/ledger/transactions":           true,
		"POST /api/ledger/transactions":          true,
		"PUT /api/ledger/transactions":           true,
		"DELETE /api/ledger/transactions":        true,
		"GET /api/ledger/balances":               true,
		"GET /api/ledger/income-statement":       true,
		"GET /api/ledger/dashboard":              true,
		"GET /api/ledger/investments":            true,
		"GET /api/ledger/accounts":               true,
		"POST /api/ledger/accounts":              true,
		"POST /api/ledger/accounts/operations":   true,
		"GET /api/ledger/accounts/detail":        true,
		"GET /api/ledger/account-status":         true,
		"GET /api/ledger/reconciliation":         true,
		"POST /api/ledger/reconciliation":        true,
		"POST /api/ledger/append":                true,
		"POST /api/ledger/append-batch":          true,
		"GET /api/ledger/insights":               true,
		"GET /api/ledger/notifications":          true,
		"PATCH /api/ledger/notifications":        true,
		"GET /api/ledger/imports/providers":      true,
		"GET /api/ledger/imports/documents":      true,
		"GET /api/ledger/imports/documents/file": true,
		"POST /api/ledger/imports/preview":       true,
		"POST /api/ledger/imports/commit":        true,
		"GET /api/ledger/editor/files":           true,
		"GET /api/ledger/editor/file":            true,
		"PUT /api/ledger/editor/file":            true,
		"POST /api/ai/parse":                     true,
		"POST /api/ai/chat":                      true,
		"POST /api/ai/accounts-chat":             true,
		"GET /api/push/subscription":             true,
		"POST /api/push/subscription":            true,
		"DELETE /api/push/subscription":          true,
		"PUT /api/push/subscription":             true,
		"POST /api/push/notify":                  true,
	}
	missing := []string{}
	for route := range actual {
		if !covered[route] {
			missing = append(missing, route)
		}
	}
	extra := []string{}
	for route := range covered {
		if !actual[route] {
			extra = append(extra, route)
		}
	}
	sort.Strings(missing)
	sort.Strings(extra)
	if len(missing) > 0 || len(extra) > 0 {
		t.Fatalf("API coverage inventory mismatch\nmissing coverage: %v\nstale coverage: %v", missing, extra)
	}
}

func TestAPIRouteSmokeCoverage(t *testing.T) {
	cfg := testLedger(t)
	beanCheck := filepath.Join(t.TempDir(), "bean-check")
	mustWrite(t, beanCheck, "#!/bin/sh\nexit 0\n")
	if err := os.Chmod(beanCheck, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEAN_CHECK_BIN", beanCheck)
	t.Setenv("APP_PASSWORD", "secret")
	runGit(t, cfg, "init")
	runGit(t, cfg, "config", "user.email", "ledger@example.test")
	runGit(t, cfg, "config", "user.name", "Ledger Test")
	router := testRouter(t, cfg)
	cookies := loginCookies(t, router)

	health := requestWithCookies(router, http.MethodGet, "/api/health", "", nil)
	if health.Code != http.StatusOK {
		t.Fatalf("health=%d body=%s", health.Code, health.Body.String())
	}
	var healthBody struct {
		OK           bool     `json:"ok"`
		APIVersion   int      `json:"apiVersion"`
		ClusterID    string   `json:"clusterId"`
		Capabilities []string `json:"capabilities"`
		Modules      []string `json:"modules"`
	}
	if err := json.Unmarshal(health.Body.Bytes(), &healthBody); err != nil {
		t.Fatal(err)
	}
	if !healthBody.OK {
		t.Fatalf("health should be ok: %#v", healthBody)
	}
	if healthBody.APIVersion != 1 || healthBody.ClusterID == "" || len(healthBody.Capabilities) == 0 || len(healthBody.Modules) == 0 {
		t.Fatalf("health identity missing: %#v", healthBody)
	}

	badLogin := requestWithCookies(router, http.MethodPost, "/api/auth/login", `{"password":"bad"}`, nil)
	if badLogin.Code != http.StatusUnauthorized {
		t.Fatalf("bad login=%d body=%s", badLogin.Code, badLogin.Body.String())
	}

	for _, route := range []struct {
		method string
		path   string
		body   string
	}{
		{http.MethodGet, "/api/ledger/version", ""},
		{http.MethodGet, "/api/ledger/entries", ""},
		{http.MethodGet, "/api/ledger/bootstrap?start=2026-05-01&end=2026-06-01", ""},
		{http.MethodGet, "/api/ledger/transactions?start=2026-05-01&end=2026-06-01", ""},
		{http.MethodGet, "/api/ledger/balances", ""},
		{http.MethodGet, "/api/ledger/dashboard?start=2026-05-01&end=2026-06-01", ""},
		{http.MethodGet, "/api/ledger/accounts", ""},
		{http.MethodGet, "/api/ledger/account-status", ""},
		{http.MethodGet, "/api/ledger/reconciliation?start=2026-05-01&end=2026-06-01", ""},
		{http.MethodGet, "/api/ledger/editor/files", ""},
		{http.MethodGet, "/api/ledger/editor/file?path=main.bean", ""},
	} {
		res := requestWithCookies(router, route.method, route.path, route.body, cookies)
		if res.Code != http.StatusOK {
			t.Fatalf("%s %s=%d body=%s", route.method, route.path, res.Code, res.Body.String())
		}
	}
	account := requestWithCookies(router, http.MethodPost, "/api/ledger/accounts", `{"date":"2026-01-01","account":"Expenses:Travel","alias":"差旅","currency":"CNY"}`, cookies)
	if account.Code != http.StatusOK {
		t.Fatalf("append account=%d body=%s", account.Code, account.Body.String())
	}
	if text := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"))); !strings.Contains(text, "open Expenses:Travel CNY") || !strings.Contains(text, `alias: "差旅"`) {
		t.Fatalf("account was not appended:\n%s", text)
	}

	accountOpsBody := `{"operations":[{"kind":"update","date":"2026-01-02","account":"Expenses:Travel","alias":"差旅交通","group":"expense"},{"kind":"disable","date":"2026-12-31","account":"Expenses:Travel"}]}`
	accountOps := requestWithCookies(router, http.MethodPost, "/api/ledger/accounts/operations", accountOpsBody, cookies)
	if accountOps.Code != http.StatusOK {
		t.Fatalf("account operations=%d body=%s", accountOps.Code, accountOps.Body.String())
	}
	if text := string(mustRead(t, filepath.Join(cfg.LedgerRoot, "accounts.bean"))); !strings.Contains(text, `alias: "差旅交通"`) || !strings.Contains(text, `group: "expense"`) || !strings.Contains(text, "2026-12-31 close Expenses:Travel") {
		t.Fatalf("account operations were not applied:\n%s", text)
	}

	batchBody := `{"entries":[{"kind":"transaction","date":"2026-05-03","payee":"Bakery","narration":"Bread","metadata":{},"tags":[],"postings":[{"account":"Expenses:Food","amount":"9.00","currency":"CNY"},{"account":"Assets:Cash","amount":"-9.00","currency":"CNY"}],"confidence":1,"needsReview":false,"questions":[]},{"kind":"balance","date":"2026-05-31","account":"Assets:Cash","amount":"979.00","currency":"CNY"}]}`
	batch := requestWithCookies(router, http.MethodPost, "/api/ledger/append-batch", batchBody, cookies)
	if batch.Code != http.StatusOK {
		t.Fatalf("append batch=%d body=%s", batch.Code, batch.Body.String())
	}
	var batchResp struct {
		Count int `json:"count"`
	}
	if err := json.Unmarshal(batch.Body.Bytes(), &batchResp); err != nil {
		t.Fatal(err)
	}
	if batchResp.Count != 2 {
		t.Fatalf("append batch count=%d", batchResp.Count)
	}

	logout := requestWithCookies(router, http.MethodPost, "/api/auth/logout", "", cookies)
	if logout.Code != http.StatusOK {
		t.Fatalf("logout=%d body=%s", logout.Code, logout.Body.String())
	}
	me := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/auth/me", nil)
	for _, cookie := range logout.Result().Cookies() {
		req.AddCookie(cookie)
	}
	router.ServeHTTP(me, req)
	if me.Code != http.StatusOK {
		t.Fatalf("me after logout=%d body=%s", me.Code, me.Body.String())
	}
	var meBody struct {
		Authenticated bool `json:"authenticated"`
	}
	if err := json.Unmarshal(me.Body.Bytes(), &meBody); err != nil {
		t.Fatal(err)
	}
	if meBody.Authenticated {
		t.Fatalf("logout should clear auth: %#v", meBody)
	}
}
