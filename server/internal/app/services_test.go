package app

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestRateLimitUsesRemoteAddrByDefault(t *testing.T) {
	limiter := NewRateLimiter()
	cfg := testLedger(t)
	router := testRouter(t, cfg)
	server := &Server{cfg: cfg, limiter: limiter}
	router.Handle(http.MethodGet, "/limited", func(c *gin.Context) {
		if server.limiter.Check(c, "test", 1, 60_000_000_000) {
			c.JSON(http.StatusOK, map[string]bool{"ok": true})
		}
	})

	first := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/limited", nil)
	req.RemoteAddr = "203.0.113.10:1111"
	req.Header.Set("X-Forwarded-For", "198.51.100.1")
	router.ServeHTTP(first, req)
	if first.Code != http.StatusOK {
		t.Fatalf("first status = %d", first.Code)
	}
	second := httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/limited", nil)
	req.RemoteAddr = "203.0.113.10:2222"
	req.Header.Set("X-Forwarded-For", "198.51.100.2")
	router.ServeHTTP(second, req)
	if second.Code != http.StatusTooManyRequests {
		t.Fatalf("second status = %d, want 429", second.Code)
	}
}

func TestPasskeyStatusAndOptionsPersistSession(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := testRouter(t, cfg)

	status := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/passkey/status", nil)
	router.ServeHTTP(status, req)
	if status.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", status.Code, status.Body.String())
	}
	var statusBody struct {
		Registered bool `json:"registered"`
	}
	if err := json.Unmarshal(status.Body.Bytes(), &statusBody); err != nil {
		t.Fatal(err)
	}
	if statusBody.Registered {
		t.Fatal("new runtime should not have a registered passkey")
	}

	cookies := loginCookies(t, router)
	options := httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/api/passkey/register/options", nil)
	req.Host = "ledger.test"
	for _, cookie := range cookies {
		req.AddCookie(cookie)
	}
	router.ServeHTTP(options, req)
	if options.Code != http.StatusOK {
		t.Fatalf("options=%d body=%s", options.Code, options.Body.String())
	}
	var optionBody struct {
		Challenge string `json:"challenge"`
		RP        struct {
			ID string `json:"id"`
		} `json:"rp"`
		User struct {
			Name string `json:"name"`
		} `json:"user"`
	}
	if err := json.Unmarshal(options.Body.Bytes(), &optionBody); err != nil {
		t.Fatal(err)
	}
	if optionBody.Challenge == "" || optionBody.RP.ID != "ledger.test" || optionBody.User.Name != "owner" {
		t.Fatalf("unexpected options: %#v", optionBody)
	}
	storeText := string(mustRead(t, filepath.Join(cfg.RuntimeDir, "passkeys.json")))
	if !strings.Contains(storeText, `"sessions"`) || !strings.Contains(storeText, optionBody.Challenge) {
		t.Fatalf("passkey session was not persisted:\n%s", storeText)
	}
}

func TestRequestOriginUsesForwardedProtoButNotForwardedHostByDefault(t *testing.T) {
	t.Setenv("TRUST_PROXY_HEADERS", "false")
	res := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(res)
	req := httptest.NewRequest(http.MethodPost, "/api/passkey/login/options", nil)
	req.Host = "ledger.example"
	req.Header.Set("X-Forwarded-Proto", "https")
	req.Header.Set("X-Forwarded-Host", "evil.example")
	c.Request = req

	if got := requestOrigin(c); got != "https://ledger.example" {
		t.Fatalf("request origin = %q, want https://ledger.example", got)
	}
}

func TestPasskeyOptionsSupportConfiguredRelatedOrigins(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	t.Setenv("PUBLIC_ORIGIN", "https://ledger.example.com")
	t.Setenv("WEBAUTHN_RP_ID", "ledger.example.com")
	t.Setenv("WEBAUTHN_PUBLIC_ORIGIN", "https://ledger.example.com, https://other.example.com")
	router := testRouter(t, cfg)

	wellKnown := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/.well-known/webauthn", nil)
	router.ServeHTTP(wellKnown, req)
	if wellKnown.Code != http.StatusOK {
		t.Fatalf("well-known=%d body=%s", wellKnown.Code, wellKnown.Body.String())
	}
	var related struct {
		Origins []string `json:"origins"`
	}
	if err := json.Unmarshal(wellKnown.Body.Bytes(), &related); err != nil {
		t.Fatal(err)
	}
	if len(related.Origins) != 1 || related.Origins[0] != "https://other.example.com" {
		t.Fatalf("unexpected related origins: %#v", related)
	}

	cookies := loginCookies(t, router)
	options := httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/api/passkey/register/options", nil)
	req.Host = "ledger.example.com"
	for _, cookie := range cookies {
		req.AddCookie(cookie)
	}
	router.ServeHTTP(options, req)
	if options.Code != http.StatusOK {
		t.Fatalf("options=%d body=%s", options.Code, options.Body.String())
	}
	var body struct {
		RP struct {
			ID string `json:"id"`
		} `json:"rp"`
	}
	if err := json.Unmarshal(options.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.RP.ID != "ledger.example.com" {
		t.Fatalf("rp id = %q", body.RP.ID)
	}
}

func TestAppleAppSiteAssociation(t *testing.T) {
	cfg := testLedger(t)
	router := testRouter(t, cfg)

	res := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/.well-known/apple-app-site-association", nil)
	router.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("aasa=%d body=%s", res.Code, res.Body.String())
	}
	if contentType := res.Header().Get("Content-Type"); contentType != "application/json; charset=utf-8" {
		t.Fatalf("content type = %q", contentType)
	}
	const expected = `{"webcredentials":{"apps":["H92F889YBH.com.qiaoborui.ledger.mobile"]}}`
	if res.Body.String() != expected {
		t.Fatalf("aasa body = %q, want %q", res.Body.String(), expected)
	}
	var body struct {
		WebCredentials struct {
			Apps []string `json:"apps"`
		} `json:"webcredentials"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.WebCredentials.Apps) != 1 || body.WebCredentials.Apps[0] != ledgerMobileAppID {
		t.Fatalf("unexpected aasa body: %#v", body)
	}
}

func TestPasskeyLoginOptionsUseStoredCredentials(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	mustWrite(t, filepath.Join(cfg.RuntimeDir, "passkeys.json"), `{"credentials":[{"id":"AQID","publicKey":"BAUG","counter":7,"transports":["internal"]}]}`)
	router := testRouter(t, cfg)

	res := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/passkey/login/options", nil)
	req.Host = "ledger.test"
	router.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("login options=%d body=%s", res.Code, res.Body.String())
	}
	var body struct {
		Challenge        string `json:"challenge"`
		AllowCredentials []struct {
			ID         string   `json:"id"`
			Transports []string `json:"transports"`
		} `json:"allowCredentials"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Challenge == "" || len(body.AllowCredentials) != 1 || body.AllowCredentials[0].ID != "AQID" {
		t.Fatalf("unexpected login options: %#v", body)
	}
}

func TestPasskeyCredentialManagementLifecycle(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	mustWrite(t, filepath.Join(cfg.RuntimeDir, "passkeys.json"), `{"credentials":[{"id":"AQID","publicKey":"BAUG","counter":7,"name":"MacBook Touch ID","transports":["internal"],"backupEligible":true,"backupState":true,"createdAt":"2026-07-12T08:00:00Z"},{"id":"BAUG","publicKey":"BwgJ","counter":3,"name":"YubiKey 5 NFC","transports":["usb","nfc"],"backupEligible":false,"backupState":false,"createdAt":"2026-06-03T08:00:00Z"}]}`)
	router := testRouter(t, cfg)

	unauthorized := requestWithCookies(router, http.MethodGet, "/api/passkey/credentials", "", nil)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized list=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}

	cookies := loginCookies(t, router)
	list := requestWithCookies(router, http.MethodGet, "/api/passkey/credentials", "", cookies)
	if list.Code != http.StatusOK {
		t.Fatalf("list=%d body=%s", list.Code, list.Body.String())
	}
	if got := list.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("list Cache-Control=%q", got)
	}
	var listBody struct {
		Credentials []PasskeyCredentialSummary `json:"credentials"`
	}
	if err := json.Unmarshal(list.Body.Bytes(), &listBody); err != nil {
		t.Fatal(err)
	}
	if len(listBody.Credentials) != 2 || listBody.Credentials[0].Name != "MacBook Touch ID" {
		t.Fatalf("unexpected credentials: %#v", listBody.Credentials)
	}
	if strings.Contains(list.Body.String(), "publicKey") || strings.Contains(list.Body.String(), "counter") {
		t.Fatalf("management response exposed authentication material: %s", list.Body.String())
	}

	rename := requestWithCookies(router, http.MethodPatch, "/api/passkey/credentials/AQID", `{"name":"  iPhone Passkey  "}`, cookies)
	if rename.Code != http.StatusOK || !strings.Contains(rename.Body.String(), `"name":"iPhone Passkey"`) {
		t.Fatalf("rename=%d body=%s", rename.Code, rename.Body.String())
	}

	badDelete := requestWithCookies(router, http.MethodDelete, "/api/passkey/credentials/AQID", `{"password":"bad"}`, cookies)
	if badDelete.Code != http.StatusUnauthorized {
		t.Fatalf("bad delete=%d body=%s", badDelete.Code, badDelete.Body.String())
	}

	deleted := requestWithCookies(router, http.MethodDelete, "/api/passkey/credentials/AQID", `{"password":"secret"}`, cookies)
	if deleted.Code != http.StatusOK || !strings.Contains(deleted.Body.String(), `"remaining":1`) {
		t.Fatalf("delete=%d body=%s", deleted.Code, deleted.Body.String())
	}
	deletedLast := requestWithCookies(router, http.MethodDelete, "/api/passkey/credentials/BAUG", `{"password":"secret"}`, cookies)
	if deletedLast.Code != http.StatusOK || !strings.Contains(deletedLast.Body.String(), `"remaining":0`) {
		t.Fatalf("delete last=%d body=%s", deletedLast.Code, deletedLast.Body.String())
	}
	status := requestWithCookies(router, http.MethodGet, "/api/passkey/status", "", cookies)
	if status.Code != http.StatusOK || !strings.Contains(status.Body.String(), `"registered":false`) || !strings.Contains(status.Body.String(), `"count":0`) {
		t.Fatalf("status=%d body=%s", status.Code, status.Body.String())
	}
}

func TestPasskeyVerifyRoutesRequireActiveChallenge(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := testRouter(t, cfg)
	cookies := loginCookies(t, router)

	register := requestWithCookies(router, http.MethodPost, "/api/passkey/register/verify", `{}`, cookies)
	if register.Code != http.StatusBadRequest || !strings.Contains(register.Body.String(), "No active passkey challenge") {
		t.Fatalf("register verify=%d body=%s", register.Code, register.Body.String())
	}

	login := requestWithCookies(router, http.MethodPost, "/api/passkey/login/verify", `{}`, nil)
	if login.Code != http.StatusBadRequest || !strings.Contains(login.Body.String(), "No active passkey challenge") {
		t.Fatalf("login verify=%d body=%s", login.Code, login.Body.String())
	}
}

func TestPushSubscriptionLifecycle(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	t.Setenv("WEB_PUSH_VAPID_PUBLIC_KEY", "public-key")
	router := testRouter(t, cfg)
	cookies := loginCookies(t, router)

	subscription := `{"subscription":{"endpoint":"https://push.example/sub/1","keys":{"p256dh":"p256dh","auth":"auth"}}}`
	res := requestWithCookies(router, http.MethodPost, "/api/push/subscription", subscription, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("push save=%d body=%s", res.Code, res.Body.String())
	}
	var saved struct {
		ID    string `json:"id"`
		Count int    `json:"count"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &saved); err != nil {
		t.Fatal(err)
	}
	if saved.ID == "" || saved.Count != 1 {
		t.Fatalf("unexpected save response: %#v", saved)
	}

	res = requestWithCookies(router, http.MethodGet, "/api/push/subscription", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("push status=%d body=%s", res.Code, res.Body.String())
	}
	var status struct {
		PublicKey  string `json:"publicKey"`
		Configured bool   `json:"configured"`
		Count      int    `json:"count"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if status.PublicKey != "public-key" || status.Configured || status.Count != 1 {
		t.Fatalf("unexpected push status: %#v", status)
	}

	res = requestWithCookies(router, http.MethodDelete, "/api/push/subscription", `{"endpoint":"https://push.example/sub/1"}`, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("push delete=%d body=%s", res.Code, res.Body.String())
	}
	var deleted struct {
		Removed int `json:"removed"`
		Count   int `json:"count"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &deleted); err != nil {
		t.Fatal(err)
	}
	if deleted.Removed != 1 || deleted.Count != 0 {
		t.Fatalf("unexpected delete response: %#v", deleted)
	}
}

func TestPushNotificationRoutesValidateRequestsAndConfiguration(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := testRouter(t, cfg)
	cookies := loginCookies(t, router)

	invalidSave := requestWithCookies(router, http.MethodPost, "/api/push/subscription", `{"subscription":{"endpoint":"","keys":{"auth":"","p256dh":""}}}`, cookies)
	if invalidSave.Code != http.StatusBadRequest {
		t.Fatalf("invalid push save=%d body=%s", invalidSave.Code, invalidSave.Body.String())
	}

	testSend := requestWithCookies(router, http.MethodPut, "/api/push/subscription", "", cookies)
	if testSend.Code != http.StatusBadRequest || !strings.Contains(testSend.Body.String(), "WEB_PUSH_VAPID") {
		t.Fatalf("push test=%d body=%s", testSend.Code, testSend.Body.String())
	}

	invalidNotify := requestWithCookies(router, http.MethodPost, "/api/push/notify", `{"title":"","body":""}`, cookies)
	if invalidNotify.Code != http.StatusBadRequest {
		t.Fatalf("invalid notify=%d body=%s", invalidNotify.Code, invalidNotify.Body.String())
	}

	notify := requestWithCookies(router, http.MethodPost, "/api/push/notify", `{"title":"提醒","body":"测试"}`, cookies)
	if notify.Code != http.StatusBadRequest || !strings.Contains(notify.Body.String(), "WEB_PUSH_VAPID") {
		t.Fatalf("push notify=%d body=%s", notify.Code, notify.Body.String())
	}
}

func TestInsightsAndNotifications(t *testing.T) {
	cfg := testLedger(t)
	monthFile := filepath.Join(cfg.LedgerRoot, "transactions", "2026", "05.bean")
	existing := string(mustRead(t, monthFile))
	mustWrite(t, monthFile, existing+strings.Join([]string{
		`2026-05-10 * "Electronics" "Monitor"`,
		"  Expenses:Food 400.00 CNY",
		"  Assets:Cash -400.00 CNY",
		"",
	}, "\n"))
	t.Setenv("APP_PASSWORD", "secret")
	router := testRouter(t, cfg)
	cookies := loginCookies(t, router)

	res := requestWithCookies(router, http.MethodGet, "/api/ledger/insights?month=2026-05", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("insights=%d body=%s", res.Code, res.Body.String())
	}
	var insights struct {
		Insights []Insight `json:"insights"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &insights); err != nil {
		t.Fatal(err)
	}
	if len(insights.Insights) == 0 || insights.Insights[0].Title != "大额支出" {
		t.Fatalf("unexpected insights: %#v", insights.Insights)
	}

	res = requestWithCookies(router, http.MethodGet, "/api/ledger/notifications?start=2026-05-01&end=2026-06-01", "", cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("notifications=%d body=%s", res.Code, res.Body.String())
	}
	var notifications struct {
		Notifications []StoredNotification `json:"notifications"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &notifications); err != nil {
		t.Fatal(err)
	}
	if len(notifications.Notifications) == 0 || notifications.Notifications[0].Status != "unread" {
		t.Fatalf("unexpected notifications: %#v", notifications.Notifications)
	}
	updateBody := `{"ids":["` + notifications.Notifications[0].ID + `"],"status":"read"}`
	res = requestWithCookies(router, http.MethodPatch, "/api/ledger/notifications", updateBody, cookies)
	if res.Code != http.StatusOK {
		t.Fatalf("notification patch=%d body=%s", res.Code, res.Body.String())
	}
	var updated struct {
		Notifications []StoredNotification `json:"notifications"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &updated); err != nil {
		t.Fatal(err)
	}
	if len(updated.Notifications) != 1 || updated.Notifications[0].Status != "read" || updated.Notifications[0].ReadAt == nil {
		t.Fatalf("unexpected updated notifications: %#v", updated.Notifications)
	}
}
