package app

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"hash/crc32"
	"net/http"
	"net/http/httptest"
	"net/mail"
	"strings"
	"testing"
	"time"

	"google.golang.org/api/gmail/v1"
	"google.golang.org/api/googleapi"
	"google.golang.org/api/idtoken"
)

type fakeGmailAPI struct {
	messageIDs []string
	recentIDs  []string
	messages   map[string]*gmail.Message
	rawCalls   []string
}

func (f *fakeGmailAPI) Profile(context.Context) (*gmail.Profile, error) { return &gmail.Profile{}, nil }
func (f *fakeGmailAPI) Labels(context.Context) ([]*gmail.Label, error)  { return nil, nil }
func (f *fakeGmailAPI) Watch(context.Context, string, string) (*gmail.WatchResponse, error) {
	return &gmail.WatchResponse{}, nil
}
func (f *fakeGmailAPI) History(context.Context, uint64, string) ([]string, uint64, error) {
	return append([]string(nil), f.messageIDs...), 99, nil
}
func (f *fakeGmailAPI) RecentMessages(context.Context, string, int) ([]string, uint64, error) {
	return append([]string(nil), f.recentIDs...), 99, nil
}
func (f *fakeGmailAPI) RawMessage(_ context.Context, id string) (*gmail.Message, error) {
	f.rawCalls = append(f.rawCalls, id)
	return f.messages[id], nil
}
func (f *fakeGmailAPI) Stop(context.Context) error { return nil }

func TestGmailSecretRoundTrip(t *testing.T) {
	cfg := Config{GmailTokenEncryptionKey: base64.RawStdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))}
	encrypted, err := encryptGmailSecret(cfg, "refresh-token")
	if err != nil {
		t.Fatal(err)
	}
	if encrypted == "refresh-token" {
		t.Fatal("refresh token was stored as plaintext")
	}
	plain, err := decryptGmailSecret(cfg, encrypted)
	if err != nil {
		t.Fatal(err)
	}
	if plain != "refresh-token" {
		t.Fatalf("decrypted token = %q", plain)
	}
}

func TestValidateGmailAutomationConfig(t *testing.T) {
	cfg := Config{
		GmailClientID:             "client",
		GmailClientSecret:         "secret",
		GmailOAuthRedirectURL:     "https://ledger.example/api/integrations/gmail/callback",
		GmailPubSubTopic:          "projects/example/topics/ledger-gmail",
		GmailPubSubAudience:       "https://ledger.example/api/integrations/gmail/pubsub",
		GmailPubSubServiceAccount: "gmail-push@example.iam.gserviceaccount.com",
		GmailAllowedSenders:       []string{"bill@example.com"},
		GmailTokenEncryptionKey:   base64.RawStdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32)),
		GmailSyncLookbackDays:     30,
		GmailZipTimeoutSeconds:    20,
		CronSecret:                "cron-secret",
	}
	if err := validateGmailAutomationConfig(cfg); err != nil {
		t.Fatal(err)
	}
	cfg.GmailAllowedSenders = nil
	if err := validateGmailAutomationConfig(cfg); err == nil || !strings.Contains(err.Error(), "GMAIL_ALLOWED_SENDERS") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestValidateGmailPubSubToken(t *testing.T) {
	original := validateGmailIDToken
	t.Cleanup(func() { validateGmailIDToken = original })
	validateGmailIDToken = func(_ context.Context, token, audience string) (*idtoken.Payload, error) {
		if token != "signed-token" || audience != "https://ledger.example/api/integrations/gmail/pubsub" {
			return nil, fmt.Errorf("unexpected token input")
		}
		return &idtoken.Payload{Audience: audience, Claims: map[string]any{"email": "gmail-push@example.iam.gserviceaccount.com", "email_verified": true}}, nil
	}
	cfg := Config{GmailPubSubAudience: "https://ledger.example/api/integrations/gmail/pubsub", GmailPubSubServiceAccount: "gmail-push@example.iam.gserviceaccount.com"}
	if err := validateGmailPubSubToken(context.Background(), "Bearer signed-token", cfg); err != nil {
		t.Fatal(err)
	}
	cfg.GmailPubSubServiceAccount = "other@example.iam.gserviceaccount.com"
	if err := validateGmailPubSubToken(context.Background(), "Bearer signed-token", cfg); err == nil {
		t.Fatal("expected service account mismatch")
	}
}

func TestDecodeGmailPush(t *testing.T) {
	payload := base64.RawStdEncoding.EncodeToString([]byte(`{"emailAddress":"owner@example.com","historyId":"12345"}`))
	data, messageID, err := decodeGmailPush([]byte(`{"message":{"data":"` + payload + `","messageId":"pubsub-1"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if data.EmailAddress != "owner@example.com" || data.HistoryID != "12345" || messageID != "pubsub-1" {
		t.Fatalf("unexpected push data: %#v", data)
	}
}

func TestGmailPushEventQueueDeduplicatesAndRetries(t *testing.T) {
	cfg := testLedger(t)
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir)}
	data := gmailPushData{EmailAddress: "owner@example.com", HistoryID: "123"}
	if err := server.enqueueGmailPushEvent(context.Background(), "event-1", data); err != nil {
		t.Fatal(err)
	}
	if err := server.enqueueGmailPushEvent(context.Background(), "event-1", data); err != nil {
		t.Fatal(err)
	}
	store, err := server.readGmailPushEvents(context.Background())
	if err != nil || len(store.Items) != 1 {
		t.Fatalf("events=%#v err=%v", store.Items, err)
	}
	event, ok, err := server.claimGmailPushEvent(context.Background())
	if err != nil || !ok || event.Attempts != 1 || event.Status != "leased" {
		t.Fatalf("event=%#v ok=%v err=%v", event, ok, err)
	}
	if err := server.finishGmailPushEvent(context.Background(), event, &googleapi.Error{Code: 500, Message: "temporary"}); err != nil {
		t.Fatal(err)
	}
	store, _ = server.readGmailPushEvents(context.Background())
	if store.Items[0].Status != "retry" || store.Items[0].LastError == "" {
		t.Fatalf("event after retry=%#v", store.Items[0])
	}
}

func TestGmailPubSubAcknowledgesAfterDurableEnqueue(t *testing.T) {
	original := validateGmailIDToken
	t.Cleanup(func() { validateGmailIDToken = original })
	validateGmailIDToken = func(context.Context, string, string) (*idtoken.Payload, error) {
		return &idtoken.Payload{Claims: map[string]any{"email": "push@example.com", "email_verified": true}}, nil
	}
	cfg := testLedger(t)
	cfg.GmailClientID = "configured"
	cfg.GmailPubSubAudience = "https://ledger.example/api/integrations/gmail/pubsub"
	cfg.GmailPubSubServiceAccount = "push@example.com"
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir)}
	if err := server.writeGmailConnection(context.Background(), gmailConnection{Email: "owner@example.com", EncryptedRefreshToken: "present"}); err != nil {
		t.Fatal(err)
	}
	router := newRouter(cfg, server)
	data := base64.RawStdEncoding.EncodeToString([]byte(`{"emailAddress":"owner@example.com","historyId":"123"}`))
	request := httptest.NewRequest(http.MethodPost, "/api/integrations/gmail/pubsub", strings.NewReader(`{"message":{"data":"`+data+`","messageId":"push-1"}}`))
	request.Header.Set("Authorization", "Bearer signed")
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	store, err := server.readGmailPushEvents(context.Background())
	if err != nil || len(store.Items) != 1 || store.Items[0].ID != "push-1" || store.Items[0].Status != "queued" {
		t.Fatalf("events=%#v err=%v", store.Items, err)
	}
}

func TestGmailDrainAcceptsCloudSchedulerSecretHeader(t *testing.T) {
	cfg := testLedger(t)
	cfg.CronSecret = "scheduler-secret"
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir)}
	router := newRouter(cfg, server)
	request := httptest.NewRequest(http.MethodPost, "/api/integrations/gmail/drain", nil)
	request.Header.Set("X-Cron-Secret", "scheduler-secret")
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"processed":0`) {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestGmailSyncRecordsPoisonMessageAndContinues(t *testing.T) {
	cfg := testLedger(t)
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir)}
	connection := gmailConnection{Version: 1, Email: "owner@example.com", EncryptedRefreshToken: "present", LabelID: "label-1", HistoryID: 10}
	if err := server.writeGmailConnection(context.Background(), connection); err != nil {
		t.Fatal(err)
	}
	api := &fakeGmailAPI{
		messageIDs: []string{"poison", "later"},
		messages: map[string]*gmail.Message{
			"poison": {Id: "poison", LabelIds: []string{"label-1"}, Raw: "%%%"},
			"later":  {Id: "later", LabelIds: []string{"other"}},
		},
	}
	if err := server.syncGmailWithAPI(context.Background(), api, connection, 100); err != nil {
		t.Fatal(err)
	}
	if strings.Join(api.rawCalls, ",") != "poison,later" {
		t.Fatalf("raw calls=%v", api.rawCalls)
	}
	pending, err := server.readGmailPending(context.Background())
	if err != nil || len(pending.Items) != 1 || pending.Items[0].Status != "failed" {
		t.Fatalf("pending=%#v err=%v", pending.Items, err)
	}
	updated, ok, err := server.gmailConnection(context.Background())
	if err != nil || !ok || updated.HistoryID != 100 {
		t.Fatalf("connection=%#v ok=%v err=%v", updated, ok, err)
	}
}

func TestGmailSyncRecordsUnsupportedMessage(t *testing.T) {
	cfg := testLedger(t)
	cfg.GmailAllowedSenders = []string{"bill@example.com"}
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir)}
	connection := gmailConnection{Version: 1, Email: "owner@example.com", EncryptedRefreshToken: "present", LabelID: "label-1", HistoryID: 10}
	if err := server.writeGmailConnection(context.Background(), connection); err != nil {
		t.Fatal(err)
	}
	raw := strings.Join([]string{
		"From: Bill <bill@example.com>",
		"To: owner@example.com",
		"Subject: Monthly statement",
		"Authentication-Results: mx.google.com; dmarc=pass header.from=example.com",
		"Content-Type: text/plain; charset=utf-8",
		"",
		"no attachment here",
	}, "\r\n")
	api := &fakeGmailAPI{
		messageIDs: []string{"unsupported"},
		messages: map[string]*gmail.Message{
			"unsupported": {Id: "unsupported", LabelIds: []string{"label-1"}, Raw: base64.RawURLEncoding.EncodeToString([]byte(raw))},
		},
	}
	if err := server.syncGmailWithAPI(context.Background(), api, connection, 100); err != nil {
		t.Fatal(err)
	}
	pending, err := server.readGmailPending(context.Background())
	if err != nil || len(pending.Items) != 1 {
		t.Fatalf("pending=%#v err=%v", pending.Items, err)
	}
	item := pending.Items[0]
	if item.Status != "failed" || item.Sender != "bill@example.com" || !strings.Contains(item.Error, "没有可识别") {
		t.Fatalf("item=%#v", item)
	}
}

func TestGmailSyncScansRecentWhenHistoryIsEmpty(t *testing.T) {
	cfg := testLedger(t)
	cfg.GmailAllowedSenders = []string{"bill@example.com"}
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir)}
	connection := gmailConnection{Version: 1, Email: "owner@example.com", EncryptedRefreshToken: "present", LabelID: "label-1", HistoryID: 10}
	if err := server.writeGmailConnection(context.Background(), connection); err != nil {
		t.Fatal(err)
	}
	raw := strings.Join([]string{
		"From: Bill <bill@example.com>",
		"To: owner@example.com",
		"Subject: Existing statement",
		"Authentication-Results: mx.google.com; dmarc=pass header.from=example.com",
		"Content-Type: text/plain; charset=utf-8",
		"",
		"already labeled before the watch started",
	}, "\r\n")
	api := &fakeGmailAPI{
		recentIDs: []string{"recent"},
		messages: map[string]*gmail.Message{
			"recent": {Id: "recent", LabelIds: []string{"label-1"}, Raw: base64.RawURLEncoding.EncodeToString([]byte(raw))},
		},
	}
	if err := server.syncGmailWithAPI(context.Background(), api, connection, 100); err != nil {
		t.Fatal(err)
	}
	if strings.Join(api.rawCalls, ",") != "recent" {
		t.Fatalf("raw calls=%v", api.rawCalls)
	}
	pending, err := server.readGmailPending(context.Background())
	if err != nil || len(pending.Items) != 1 {
		t.Fatalf("pending=%#v err=%v", pending.Items, err)
	}
	if pending.Items[0].Status != "failed" || !strings.Contains(pending.Items[0].Error, "没有可识别") {
		t.Fatalf("item=%#v", pending.Items[0])
	}
}

func TestRecoverStaleProcessingImport(t *testing.T) {
	cfg := testLedger(t)
	server := &Server{cfg: cfg, runtimeStore: newFilesystemRuntimeStore(cfg.RuntimeDir)}
	old := time.Now().UTC().Add(-20 * time.Minute).Format(time.RFC3339Nano)
	store := gmailPendingStore{Version: 1, Items: []GmailPendingImport{{ID: "pending-1", ImportID: "import-1", SourceKey: "source-1", Status: "processing", CreatedAt: old, UpdatedAt: old}}}
	if err := server.writeGmailPending(context.Background(), store); err != nil {
		t.Fatal(err)
	}
	recovered, err := server.gmailPendingSnapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if recovered.Items[0].Status != "failed" || !strings.Contains(recovered.Items[0].Error, "中断") {
		t.Fatalf("recovered=%#v", recovered.Items[0])
	}
}

func TestParseGmailMessageAttachments(t *testing.T) {
	attachment := base64.StdEncoding.EncodeToString([]byte("date,amount\n2026-07-01,12.34\n"))
	raw := strings.Join([]string{
		"From: Example Bank <bill@example.com>",
		"Subject: =?UTF-8?B?5pyI5bqm6LSm5Y2V?=",
		"Authentication-Results: mx.google.com; dmarc=pass header.from=example.com",
		"Content-Type: multipart/mixed; boundary=bank-boundary",
		"",
		"--bank-boundary",
		"Content-Type: text/plain; charset=utf-8",
		"",
		"statement attached",
		"--bank-boundary",
		"Content-Type: text/csv; name=statement.csv",
		"Content-Disposition: attachment; filename=statement.csv",
		"Content-Transfer-Encoding: base64",
		"",
		attachment,
		"--bank-boundary--",
		"",
	}, "\r\n")
	message, err := parseGmailMessage([]byte(raw), time.Date(2026, 7, 2, 3, 4, 5, 0, time.UTC).UnixMilli())
	if err != nil {
		t.Fatal(err)
	}
	if message.Sender != "bill@example.com" || message.Subject != "月度账单" || !message.Authenticated {
		t.Fatalf("unexpected envelope: %#v", message)
	}
	if len(message.Attachments) != 1 || message.Attachments[0].Filename != "statement.csv" || !bytes.Contains(message.Attachments[0].Content, []byte("12.34")) {
		t.Fatalf("unexpected attachments: %#v", message.Attachments)
	}
}

func TestParseGmailMessageDecodesGB18030AttachmentFilename(t *testing.T) {
	attachment := base64.StdEncoding.EncodeToString([]byte("date,amount\n2026-07-01,12.34\n"))
	encodedFilename := "=?GB18030?Q?=D6=A7=B8=B6=B1=A6=BD=BB=D2=D7=C3=F7=CF=B8=2Ecsv?="
	raw := strings.Join([]string{
		"From: Alipay <service@mail.alipay.com>",
		"Subject: =?GB18030?Q?=D6=A7=B8=B6=B1=A6=CC=E1=D0=D1?=",
		"Authentication-Results: mx.google.com; dmarc=pass header.from=mail.alipay.com",
		"Content-Type: multipart/mixed; boundary=alipay-boundary",
		"",
		"--alipay-boundary",
		"Content-Type: text/plain; charset=utf-8",
		"",
		"statement attached",
		"--alipay-boundary",
		"Content-Type: text/csv; name=\"" + encodedFilename + "\"",
		"Content-Disposition: attachment; filename=\"" + encodedFilename + "\"",
		"Content-Transfer-Encoding: base64",
		"",
		attachment,
		"--alipay-boundary--",
		"",
	}, "\r\n")
	message, err := parseGmailMessage([]byte(raw), 0)
	if err != nil {
		t.Fatal(err)
	}
	if message.Subject != "支付宝提醒" {
		t.Fatalf("subject = %q", message.Subject)
	}
	if len(message.Attachments) != 1 || message.Attachments[0].Filename != "支付宝交易明细.csv" {
		t.Fatalf("unexpected attachments: %#v", message.Attachments)
	}
}

func TestGmailDMARCRequiresGoogleAuthenticationResult(t *testing.T) {
	header := mail.Header{"Authentication-Results": {"attacker.example; dmarc=pass header.from=example.com"}}
	if gmailDMARCPassed(header) {
		t.Fatal("non-Google Authentication-Results header was trusted")
	}
	header = mail.Header{"Authentication-Results": {"mx.google.com; dmarc=fail header.from=example.com", "mx.google.com; dmarc=pass header.from=example.com"}}
	if gmailDMARCPassed(header) {
		t.Fatal("a later untrusted Authentication-Results header overrode Google's result")
	}
}

func TestNumericZipPasswordSearch(t *testing.T) {
	plain := []byte("transactionDate,amount\n2026-07-01,88.00\n")
	crc := crc32.ChecksumIEEE(plain)
	entry := &encryptedZipEntry{method: 0, crc: crc, uncompressedSize: uint64(len(plain)), checkByte: byte(crc >> 24)}
	password := []byte("000042")
	keys := initializeZipKeys(password)
	header := append(bytes.Repeat([]byte{0}, 11), entry.checkByte)
	for _, value := range append(header, plain...) {
		temporary := uint16(keys.key2 | 2)
		encrypted := value ^ byte((uint32(temporary)*uint32(temporary^1))>>8)
		keys.update(value)
		entry.encrypted = append(entry.encrypted, encrypted)
	}
	foundPassword, foundPlain, found := searchNumericZipPasswords(context.Background(), entry, 2)
	if !found || foundPassword != 42 || !bytes.Equal(foundPlain, plain) {
		t.Fatalf("found=%v password=%d plain=%q", found, foundPassword, foundPlain)
	}
}

func TestGmailSenderAllowedUsesExactAddress(t *testing.T) {
	allowed := []string{"bill@example.com"}
	if !gmailSenderAllowed("bill@example.com", allowed) {
		t.Fatal("expected exact sender to be allowed")
	}
	if gmailSenderAllowed("attacker@example.com", allowed) {
		t.Fatal("unexpected sender was allowed")
	}
}

func TestCanonicalEmailAddressExtractsAddressFromEncodedDisplayName(t *testing.T) {
	from := "=?gbk?b?1qe4trgmzohq0q==?= <service@mail.alipay.com>"
	if got := canonicalEmailAddress(from); got != "service@mail.alipay.com" {
		t.Fatalf("canonical email = %q", got)
	}
}

func TestPruneGmailPendingKeepsUnreviewedItems(t *testing.T) {
	items := []GmailPendingImport{
		{ID: "old-committed", Status: "committed"},
		{ID: "ready", Status: "ready"},
		{ID: "failed", Status: "failed"},
		{ID: "new-committed", Status: "committed"},
	}
	pruned := pruneGmailPending(items, 3)
	ids := []string{}
	for _, item := range pruned {
		ids = append(ids, item.ID)
	}
	if strings.Join(ids, ",") != "new-committed,ready,failed" {
		t.Fatalf("pruned ids = %v", ids)
	}
}

func TestGmailRoutesStayAuthenticatedWhenDisabled(t *testing.T) {
	cfg := testLedger(t)
	t.Setenv("APP_PASSWORD", "secret")
	router := testRouter(t, cfg)
	unauthenticated := requestWithCookies(router, http.MethodGet, "/api/integrations/gmail/status", "", nil)
	if unauthenticated.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status = %d", unauthenticated.Code)
	}
	cookies := loginCookies(t, router)
	sessionOnly := make([]*http.Cookie, 0, len(cookies))
	for _, cookie := range cookies {
		if cookie.Name != sensitiveCookieName {
			sessionOnly = append(sessionOnly, cookie)
		}
	}
	lockedPending := requestWithCookies(router, http.MethodGet, "/api/ledger/imports/pending", "", sessionOnly)
	if lockedPending.Code != 423 {
		t.Fatalf("locked pending=%d body=%s", lockedPending.Code, lockedPending.Body.String())
	}
	status := requestWithCookies(router, http.MethodGet, "/api/integrations/gmail/status", "", cookies)
	if status.Code != http.StatusOK || !strings.Contains(status.Body.String(), `"configured":false`) {
		t.Fatalf("status=%d body=%s", status.Code, status.Body.String())
	}
	pending := requestWithCookies(router, http.MethodGet, "/api/ledger/imports/pending", "", cookies)
	if pending.Code != http.StatusOK || !strings.Contains(pending.Body.String(), `"items":[]`) {
		t.Fatalf("pending=%d body=%s", pending.Code, pending.Body.String())
	}
}
