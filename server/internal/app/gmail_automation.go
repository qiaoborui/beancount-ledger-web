package app

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/http"
	"net/mail"
	"net/textproto"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
	"golang.org/x/text/encoding/simplifiedchinese"
	"google.golang.org/api/gmail/v1"
	"google.golang.org/api/googleapi"
	"google.golang.org/api/idtoken"
	"google.golang.org/api/option"
)

const (
	gmailConnectionKey = "connection"
	gmailOAuthStateKey = "oauth-state"
	gmailPendingKey    = "pending-imports"
	gmailPushEventsKey = "push-events"
	gmailSyncLeaseKey  = "sync-lease"

	maxGmailPendingItems = 500
	maxGmailPendingBytes = 100 * 1024 * 1024
	maxGmailPushEvents   = 1000

	cmbCreditGmailSender = "ccsvc@message.cmbchina.com"
)

var validateGmailIDToken = idtoken.Validate
var extractGmailImportZIP = func(server *Server, ctx context.Context, archive []byte, passwordCandidates []string) (importUpload, string, error) {
	return server.extractImportZIP(ctx, archive, passwordCandidates)
}
var errGmailSyncBusy = errors.New("Gmail 同步正在运行")

type gmailConnection struct {
	Version               int    `json:"version"`
	Email                 string `json:"email"`
	EncryptedRefreshToken string `json:"encryptedRefreshToken"`
	LabelID               string `json:"labelId"`
	LabelName             string `json:"labelName"`
	HistoryID             uint64 `json:"historyId,string"`
	WatchExpiration       int64  `json:"watchExpiration"`
	ConnectedAt           string `json:"connectedAt"`
	UpdatedAt             string `json:"updatedAt"`
	LastSyncAt            string `json:"lastSyncAt,omitempty"`
	LastError             string `json:"lastError,omitempty"`
}

type gmailOAuthState struct {
	Value     string `json:"value"`
	ExpiresAt string `json:"expiresAt"`
}

type GmailPendingImport struct {
	ID             string `json:"id"`
	ImportID       string `json:"importId,omitempty"`
	SourceKey      string `json:"sourceKey,omitempty"`
	MessageID      string `json:"messageId"`
	ThreadID       string `json:"threadId,omitempty"`
	Sender         string `json:"sender"`
	Subject        string `json:"subject"`
	ReceivedAt     string `json:"receivedAt"`
	Filename       string `json:"filename"`
	Provider       string `json:"provider,omitempty"`
	CandidateCount int    `json:"candidateCount"`
	Status         string `json:"status"`
	Error          string `json:"error,omitempty"`
	CreatedAt      string `json:"createdAt"`
	UpdatedAt      string `json:"updatedAt"`
	StoredBytes    int64  `json:"storedBytes,omitempty"`
	OutputFile     string `json:"outputFile,omitempty"`
}

type gmailPendingStore struct {
	Version int                  `json:"version"`
	Items   []GmailPendingImport `json:"items"`
}

type gmailPushEnvelope struct {
	Message struct {
		Data      string `json:"data"`
		MessageID string `json:"messageId"`
	} `json:"message"`
	Subscription string `json:"subscription"`
}

type gmailPushData struct {
	EmailAddress string `json:"emailAddress"`
	HistoryID    string `json:"historyId"`
}

func (data *gmailPushData) UnmarshalJSON(raw []byte) error {
	var payload struct {
		EmailAddress string          `json:"emailAddress"`
		HistoryID    json.RawMessage `json:"historyId"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return err
	}
	data.EmailAddress = payload.EmailAddress
	data.HistoryID = ""
	if len(payload.HistoryID) == 0 || string(payload.HistoryID) == "null" {
		return nil
	}
	if err := json.Unmarshal(payload.HistoryID, &data.HistoryID); err == nil {
		return nil
	}
	var numericHistoryID json.Number
	if err := json.Unmarshal(payload.HistoryID, &numericHistoryID); err != nil {
		return fmt.Errorf("decode Gmail historyId: %w", err)
	}
	data.HistoryID = numericHistoryID.String()
	return nil
}

type gmailPushEvent struct {
	ID          string `json:"id"`
	Email       string `json:"email"`
	HistoryID   uint64 `json:"historyId,string"`
	Status      string `json:"status"`
	Attempts    int    `json:"attempts"`
	AvailableAt string `json:"availableAt"`
	LeaseUntil  string `json:"leaseUntil,omitempty"`
	LastError   string `json:"lastError,omitempty"`
	CreatedAt   string `json:"createdAt"`
	UpdatedAt   string `json:"updatedAt"`
}

type gmailPushEventStore struct {
	Version int              `json:"version"`
	Items   []gmailPushEvent `json:"items"`
}

type gmailSyncLease struct {
	Owner     string `json:"owner"`
	ExpiresAt string `json:"expiresAt"`
}

type gmailMessageEnvelope struct {
	Sender        string
	Subject       string
	ReceivedAt    string
	Authenticated bool
	Attachments   []importUpload
}

type gmailImportCandidate struct {
	Upload           importUpload
	ProviderOverride string
	Error            error
}

type gmailAPI interface {
	Profile(context.Context) (*gmail.Profile, error)
	Labels(context.Context) ([]*gmail.Label, error)
	Watch(context.Context, string, string) (*gmail.WatchResponse, error)
	History(context.Context, uint64, string) ([]string, uint64, error)
	RecentMessages(context.Context, string, int) ([]string, uint64, error)
	RawMessage(context.Context, string) (*gmail.Message, error)
	Stop(context.Context) error
}

type googleGmailAPI struct {
	service *gmail.Service
}

func newGoogleGmailAPI(ctx context.Context, cfg Config, refreshToken string) (gmailAPI, error) {
	config := gmailOAuthConfig(cfg)
	token := &oauth2.Token{RefreshToken: refreshToken, TokenType: "Bearer", Expiry: time.Unix(0, 0)}
	service, err := gmail.NewService(ctx, option.WithTokenSource(config.TokenSource(ctx, token)))
	if err != nil {
		return nil, err
	}
	return &googleGmailAPI{service: service}, nil
}

func (api *googleGmailAPI) Profile(ctx context.Context) (*gmail.Profile, error) {
	return api.service.Users.GetProfile("me").Context(ctx).Do()
}

func (api *googleGmailAPI) Labels(ctx context.Context) ([]*gmail.Label, error) {
	response, err := api.service.Users.Labels.List("me").Context(ctx).Do()
	if err != nil {
		return nil, err
	}
	return response.Labels, nil
}

func (api *googleGmailAPI) Watch(ctx context.Context, topic, labelID string) (*gmail.WatchResponse, error) {
	return api.service.Users.Watch("me", &gmail.WatchRequest{TopicName: topic, LabelIds: []string{labelID}, LabelFilterBehavior: "include"}).Context(ctx).Do()
}

func (api *googleGmailAPI) History(ctx context.Context, startHistoryID uint64, labelID string) ([]string, uint64, error) {
	ids := map[string]bool{}
	latest := startHistoryID
	call := api.service.Users.History.List("me").StartHistoryId(startHistoryID).HistoryTypes("messageAdded", "labelAdded").LabelId(labelID)
	err := call.Pages(ctx, func(response *gmail.ListHistoryResponse) error {
		if response.HistoryId > latest {
			latest = response.HistoryId
		}
		for _, history := range response.History {
			for _, added := range history.MessagesAdded {
				if added.Message != nil && added.Message.Id != "" {
					ids[added.Message.Id] = true
				}
			}
			for _, added := range history.LabelsAdded {
				if added.Message != nil && added.Message.Id != "" && stringIn(labelID, added.LabelIds) {
					ids[added.Message.Id] = true
				}
			}
		}
		return nil
	})
	return sortedKeys(ids), latest, err
}

func (api *googleGmailAPI) RecentMessages(ctx context.Context, labelID string, lookbackDays int) ([]string, uint64, error) {
	ids := map[string]bool{}
	call := api.service.Users.Messages.List("me").LabelIds(labelID).Q(fmt.Sprintf("newer_than:%dd", lookbackDays)).MaxResults(500)
	if err := call.Pages(ctx, func(response *gmail.ListMessagesResponse) error {
		for _, message := range response.Messages {
			if message.Id != "" {
				ids[message.Id] = true
			}
		}
		return nil
	}); err != nil {
		return nil, 0, err
	}
	profile, err := api.Profile(ctx)
	if err != nil {
		return nil, 0, err
	}
	return sortedKeys(ids), profile.HistoryId, nil
}

func (api *googleGmailAPI) RawMessage(ctx context.Context, messageID string) (*gmail.Message, error) {
	return api.service.Users.Messages.Get("me", messageID).Format("raw").Context(ctx).Do()
}

func (api *googleGmailAPI) Stop(ctx context.Context) error {
	return api.service.Users.Stop("me").Context(ctx).Do()
}

func sortedKeys(values map[string]bool) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func gmailOAuthConfig(cfg Config) *oauth2.Config {
	return &oauth2.Config{
		ClientID:     cfg.GmailClientID,
		ClientSecret: cfg.GmailClientSecret,
		RedirectURL:  cfg.GmailOAuthRedirectURL,
		Endpoint:     google.Endpoint,
		Scopes:       []string{gmail.GmailReadonlyScope},
	}
}

func (s *Server) gmailConnection(ctx context.Context) (gmailConnection, bool, error) {
	var connection gmailConnection
	ok, err := s.runtime().GetJSON(ctx, "gmail", gmailConnectionKey, &connection)
	if err != nil || !ok || connection.EncryptedRefreshToken == "" {
		return gmailConnection{}, false, err
	}
	return connection, true, nil
}

func (s *Server) writeGmailConnection(ctx context.Context, connection gmailConnection) error {
	connection.Version = 1
	connection.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	return s.runtime().PutJSON(ctx, "gmail", gmailConnectionKey, connection)
}

func (s *Server) connectedGmailAPI(ctx context.Context) (gmailAPI, gmailConnection, error) {
	connection, ok, err := s.gmailConnection(ctx)
	if err != nil {
		return nil, gmailConnection{}, err
	}
	if !ok {
		return nil, gmailConnection{}, errors.New("Gmail 尚未连接")
	}
	refreshToken, err := decryptGmailSecret(s.cfg, connection.EncryptedRefreshToken)
	if err != nil {
		return nil, gmailConnection{}, err
	}
	api, err := newGoogleGmailAPI(ctx, s.cfg, refreshToken)
	return api, connection, err
}

func encryptGmailSecret(cfg Config, value string) (string, error) {
	key, err := gmailEncryptionKey(cfg)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return "", err
	}
	sealed := gcm.Seal(nonce, nonce, []byte(value), []byte("gmail-refresh-token-v1"))
	return base64.RawURLEncoding.EncodeToString(sealed), nil
}

func decryptGmailSecret(cfg Config, value string) (string, error) {
	key, err := gmailEncryptionKey(cfg)
	if err != nil {
		return "", err
	}
	raw, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return "", errors.New("Gmail 凭据格式无效")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	if len(raw) < gcm.NonceSize() {
		return "", errors.New("Gmail 凭据不完整")
	}
	plain, err := gcm.Open(nil, raw[:gcm.NonceSize()], raw[gcm.NonceSize():], []byte("gmail-refresh-token-v1"))
	if err != nil {
		return "", errors.New("Gmail 凭据解密失败")
	}
	return string(plain), nil
}

func gmailEncryptionKey(cfg Config) ([]byte, error) {
	key, err := base64.RawStdEncoding.DecodeString(cfg.GmailTokenEncryptionKey)
	if err != nil {
		key, err = base64.StdEncoding.DecodeString(cfg.GmailTokenEncryptionKey)
	}
	if err != nil || len(key) != 32 {
		return nil, errors.New("Gmail 加密密钥无效")
	}
	return key, nil
}

func findGmailLabel(labels []*gmail.Label, name string) (string, bool) {
	for _, label := range labels {
		if label != nil && strings.EqualFold(strings.TrimSpace(label.Name), strings.TrimSpace(name)) {
			return label.Id, true
		}
	}
	return "", false
}

func (s *Server) renewGmailWatch(ctx context.Context) (gmailConnection, error) {
	api, connection, err := s.connectedGmailAPI(ctx)
	if err != nil {
		return gmailConnection{}, err
	}
	watch, err := api.Watch(ctx, s.cfg.GmailPubSubTopic, connection.LabelID)
	if err != nil {
		_ = s.updateGmailConnectionError(ctx, err)
		return gmailConnection{}, err
	}
	var renewed gmailConnection
	err = s.runtime().WithLock(ctx, "gmail-state", func(lockCtx context.Context) error {
		latest, ok, err := s.gmailConnection(lockCtx)
		if err != nil || !ok {
			return err
		}
		latest.WatchExpiration = watch.Expiration
		latest.HistoryID = max(latest.HistoryID, connection.HistoryID)
		latest.LastError = ""
		renewed = latest
		return s.writeGmailConnection(lockCtx, latest)
	})
	return renewed, err
}

func validateGmailPubSubToken(ctx context.Context, authorization string, cfg Config) error {
	return validateGoogleServiceAccountToken(ctx, authorization, cfg.GmailPubSubAudience, cfg.GmailPubSubServiceAccount, "Pub/Sub")
}

func validateGoogleServiceAccountToken(ctx context.Context, authorization, audience, serviceAccount, purpose string) error {
	const prefix = "Bearer "
	if !strings.HasPrefix(authorization, prefix) {
		return fmt.Errorf("%s Authorization header is required", purpose)
	}
	payload, err := validateGmailIDToken(ctx, strings.TrimSpace(strings.TrimPrefix(authorization, prefix)), audience)
	if err != nil {
		return fmt.Errorf("validate %s token: %w", purpose, err)
	}
	email, _ := payload.Claims["email"].(string)
	verified, _ := payload.Claims["email_verified"].(bool)
	if !verified || !strings.EqualFold(email, serviceAccount) {
		return fmt.Errorf("%s service account does not match", purpose)
	}
	return nil
}

func decodeGmailPush(body []byte) (gmailPushData, string, error) {
	var envelope gmailPushEnvelope
	if err := json.Unmarshal(body, &envelope); err != nil {
		return gmailPushData{}, "", err
	}
	if envelope.Message.Data == "" || strings.TrimSpace(envelope.Message.MessageID) == "" {
		return gmailPushData{}, "", errors.New("Pub/Sub message data and messageId are required")
	}
	raw, err := decodeGmailPushData(envelope.Message.Data)
	if err != nil {
		return gmailPushData{}, "", err
	}
	var data gmailPushData
	if err := json.Unmarshal(raw, &data); err != nil {
		return gmailPushData{}, "", err
	}
	if data.EmailAddress == "" || data.HistoryID == "" {
		return gmailPushData{}, "", errors.New("Gmail push payload is incomplete")
	}
	return data, strings.TrimSpace(envelope.Message.MessageID), nil
}

func decodeGmailPushData(value string) ([]byte, error) {
	if raw, err := base64.RawURLEncoding.DecodeString(value); err == nil {
		return raw, nil
	}
	if raw, err := base64.URLEncoding.DecodeString(value); err == nil {
		return raw, nil
	}
	if raw, err := base64.RawStdEncoding.DecodeString(value); err == nil {
		return raw, nil
	}
	return base64.StdEncoding.DecodeString(value)
}

func (s *Server) enqueueGmailPushEvent(ctx context.Context, messageID string, data gmailPushData) error {
	historyID, err := parseHistoryID(data.HistoryID)
	if err != nil {
		return err
	}
	return s.runtime().WithLock(ctx, "gmail-push-events", func(lockCtx context.Context) error {
		store, err := s.readGmailPushEvents(lockCtx)
		if err != nil {
			return err
		}
		for _, item := range store.Items {
			if item.ID == messageID {
				return nil
			}
		}
		active := 0
		for _, item := range store.Items {
			if item.Status == "queued" || item.Status == "retry" || item.Status == "leased" {
				active++
			}
		}
		if active >= maxGmailPushEvents {
			return errors.New("Gmail push 事件队列已满")
		}
		now := time.Now().UTC().Format(time.RFC3339Nano)
		store.Items = append(store.Items, gmailPushEvent{ID: messageID, Email: strings.ToLower(data.EmailAddress), HistoryID: historyID, Status: "queued", AvailableAt: now, CreatedAt: now, UpdatedAt: now})
		return s.writeGmailPushEvents(lockCtx, store)
	})
}

func (s *Server) readGmailPushEvents(ctx context.Context) (gmailPushEventStore, error) {
	var store gmailPushEventStore
	ok, err := s.runtime().GetJSON(ctx, "gmail", gmailPushEventsKey, &store)
	if err != nil {
		return gmailPushEventStore{}, err
	}
	if !ok {
		return gmailPushEventStore{Version: 1, Items: []gmailPushEvent{}}, nil
	}
	return store, nil
}

func (s *Server) writeGmailPushEvents(ctx context.Context, store gmailPushEventStore) error {
	store.Version = 1
	if len(store.Items) > maxGmailPushEvents {
		store.Items = store.Items[len(store.Items)-maxGmailPushEvents:]
	}
	return s.runtime().PutJSON(ctx, "gmail", gmailPushEventsKey, store)
}

func (s *Server) claimGmailPushEvent(ctx context.Context) (gmailPushEvent, bool, error) {
	var claimed gmailPushEvent
	found := false
	err := s.runtime().WithLock(ctx, "gmail-push-events", func(lockCtx context.Context) error {
		store, err := s.readGmailPushEvents(lockCtx)
		if err != nil {
			return err
		}
		now := time.Now().UTC()
		for index := range store.Items {
			item := &store.Items[index]
			leaseUntil, _ := time.Parse(time.RFC3339Nano, item.LeaseUntil)
			if item.Status == "leased" && now.After(leaseUntil) {
				item.Status = "retry"
				item.AvailableAt = now.Format(time.RFC3339Nano)
			}
			availableAt, _ := time.Parse(time.RFC3339Nano, item.AvailableAt)
			if found || (item.Status != "queued" && item.Status != "retry") || now.Before(availableAt) {
				continue
			}
			item.Status = "leased"
			item.Attempts++
			item.LeaseUntil = now.Add(5 * time.Minute).Format(time.RFC3339Nano)
			item.UpdatedAt = now.Format(time.RFC3339Nano)
			claimed = *item
			found = true
		}
		if !found {
			return nil
		}
		return s.writeGmailPushEvents(lockCtx, store)
	})
	return claimed, found, err
}

func (s *Server) finishGmailPushEvent(ctx context.Context, event gmailPushEvent, processErr error) error {
	return s.runtime().WithLock(ctx, "gmail-push-events", func(lockCtx context.Context) error {
		store, err := s.readGmailPushEvents(lockCtx)
		if err != nil {
			return err
		}
		now := time.Now().UTC()
		for index := range store.Items {
			item := &store.Items[index]
			if item.ID != event.ID {
				continue
			}
			item.LeaseUntil = ""
			item.UpdatedAt = now.Format(time.RFC3339Nano)
			if processErr == nil {
				item.Status = "done"
				item.LastError = ""
			} else if event.Attempts >= 8 || !gmailErrorTransient(processErr) {
				item.Status = "dead"
				item.LastError = processErr.Error()
			} else {
				item.Status = "retry"
				item.LastError = processErr.Error()
				delay := time.Duration(1<<min(event.Attempts, 6)) * time.Minute
				item.AvailableAt = now.Add(delay).Format(time.RFC3339Nano)
			}
		}
		terminal := make([]gmailPushEvent, 0, len(store.Items))
		active := make([]gmailPushEvent, 0, len(store.Items))
		for _, item := range store.Items {
			if item.Status == "done" || item.Status == "dead" {
				terminal = append(terminal, item)
			} else {
				active = append(active, item)
			}
		}
		if len(terminal) > 200 {
			terminal = terminal[len(terminal)-200:]
		}
		store.Items = append(terminal, active...)
		return s.writeGmailPushEvents(lockCtx, store)
	})
}

func (s *Server) drainGmailPushEvents(ctx context.Context, limit int) (int, error) {
	processed := 0
	for processed < limit {
		event, ok, err := s.claimGmailPushEvent(ctx)
		if err != nil || !ok {
			return processed, err
		}
		connection, connected, err := s.gmailConnection(ctx)
		if err == nil && (!connected || !strings.EqualFold(connection.Email, event.Email)) {
			err = nil
		} else if err == nil {
			err = s.syncGmail(ctx, event.HistoryID)
		}
		if finishErr := s.finishGmailPushEvent(ctx, event, err); finishErr != nil {
			return processed, finishErr
		}
		processed++
		if err != nil && gmailErrorTransient(err) {
			return processed, err
		}
	}
	return processed, nil
}

func (s *Server) syncGmail(ctx context.Context, notifiedHistoryID uint64) error {
	owner := randomID()
	claimed, err := s.claimGmailSyncLease(ctx, owner)
	if err != nil {
		return err
	}
	if !claimed {
		return errGmailSyncBusy
	}
	defer s.releaseGmailSyncLease(context.Background(), owner)
	api, connection, err := s.connectedGmailAPI(ctx)
	if err != nil {
		return err
	}
	return s.syncGmailWithAPI(ctx, api, connection, notifiedHistoryID)
}

func (s *Server) syncGmailWithAPI(ctx context.Context, api gmailAPI, connection gmailConnection, notifiedHistoryID uint64) error {
	messageIDs, latestHistoryID, err := api.History(ctx, connection.HistoryID, connection.LabelID)
	if isGoogleNotFound(err) || (err == nil && len(messageIDs) == 0 && connection.LastSyncAt == "") {
		messageIDs, latestHistoryID, err = api.RecentMessages(ctx, connection.LabelID, s.cfg.GmailSyncLookbackDays)
	}
	if err != nil {
		_ = s.updateGmailConnectionError(ctx, err)
		return err
	}
	for _, messageID := range messageIDs {
		if err := s.processGmailMessage(ctx, api, messageID, connection.LabelID); err != nil {
			if gmailErrorTransient(err) {
				_ = s.updateGmailConnectionError(ctx, err)
				return err
			}
			if recordErr := s.recordGmailMessageFailure(ctx, messageID, err); recordErr != nil {
				return recordErr
			}
		}
	}
	return s.runtime().WithLock(ctx, "gmail-state", func(lockCtx context.Context) error {
		latest, ok, err := s.gmailConnection(lockCtx)
		if err != nil || !ok {
			return err
		}
		latest.HistoryID = max(latest.HistoryID, latestHistoryID, notifiedHistoryID)
		latest.LastSyncAt = time.Now().UTC().Format(time.RFC3339Nano)
		latest.LastError = ""
		return s.writeGmailConnection(lockCtx, latest)
	})
}

func gmailErrorTransient(err error) bool {
	if errors.Is(err, errGmailSyncBusy) {
		return true
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var apiError *googleapi.Error
	return errors.As(err, &apiError) && (apiError.Code == http.StatusTooManyRequests || apiError.Code >= 500)
}

func (s *Server) updateGmailConnectionError(ctx context.Context, syncErr error) error {
	return s.runtime().WithLock(ctx, "gmail-state", func(lockCtx context.Context) error {
		connection, ok, err := s.gmailConnection(lockCtx)
		if err != nil || !ok {
			return err
		}
		connection.LastError = syncErr.Error()
		return s.writeGmailConnection(lockCtx, connection)
	})
}

func (s *Server) claimGmailSyncLease(ctx context.Context, owner string) (bool, error) {
	claimed := false
	err := s.runtime().WithLock(ctx, "gmail-sync-lease", func(lockCtx context.Context) error {
		var lease gmailSyncLease
		ok, err := s.runtime().GetJSON(lockCtx, "gmail", gmailSyncLeaseKey, &lease)
		if err != nil {
			return err
		}
		expiresAt, _ := time.Parse(time.RFC3339Nano, lease.ExpiresAt)
		if ok && lease.Owner != "" && time.Now().UTC().Before(expiresAt) {
			return nil
		}
		claimed = true
		return s.runtime().PutJSON(lockCtx, "gmail", gmailSyncLeaseKey, gmailSyncLease{Owner: owner, ExpiresAt: time.Now().UTC().Add(5 * time.Minute).Format(time.RFC3339Nano)})
	})
	return claimed, err
}

func (s *Server) releaseGmailSyncLease(ctx context.Context, owner string) {
	_ = s.runtime().WithLock(ctx, "gmail-sync-lease", func(lockCtx context.Context) error {
		var lease gmailSyncLease
		ok, err := s.runtime().GetJSON(lockCtx, "gmail", gmailSyncLeaseKey, &lease)
		if err != nil || !ok || lease.Owner != owner {
			return err
		}
		return s.runtime().DeleteJSON(lockCtx, "gmail", gmailSyncLeaseKey)
	})
}

func isGoogleNotFound(err error) bool {
	var apiError *googleapi.Error
	return errors.As(err, &apiError) && apiError.Code == http.StatusNotFound
}

func (s *Server) processGmailMessage(ctx context.Context, api gmailAPI, messageID, labelID string) error {
	message, err := api.RawMessage(ctx, messageID)
	if err != nil {
		return err
	}
	if !stringIn(labelID, message.LabelIds) {
		return nil
	}
	raw, err := decodeGmailRaw(message.Raw)
	if err != nil {
		return err
	}
	envelope, err := parseGmailMessage(raw, message.InternalDate)
	if err != nil {
		return err
	}
	if !envelope.Authenticated {
		return s.recordGmailEnvelopeFailure(ctx, messageID, raw, envelope, "auth", "邮件未通过 Gmail DMARC 验证")
	}
	if !gmailSenderAllowed(envelope.Sender, s.cfg.GmailAllowedSenders) {
		return s.recordGmailEnvelopeFailure(ctx, messageID, raw, envelope, "sender", "发件人不在 Gmail 自动账单 allowlist: "+envelope.Sender)
	}
	existingSourceKeys, err := s.gmailPendingSourceKeys(ctx)
	if err != nil {
		return err
	}
	candidates, duplicateSkipped := s.gmailImportCandidates(ctx, envelope, raw, messageID, existingSourceKeys)
	if len(candidates) == 0 {
		if duplicateSkipped {
			return nil
		}
		return s.recordGmailEnvelopeFailure(ctx, messageID, raw, envelope, "unsupported", "邮件没有可识别的账单附件: "+gmailAttachmentSummary(envelope.Attachments))
	}
	ready := 0
	for _, candidate := range candidates {
		sourceKey := messageID + ":" + sha256Hex(candidate.Upload.Content)
		now := time.Now().UTC().Format(time.RFC3339Nano)
		item := GmailPendingImport{ID: randomID(), ImportID: randomID(), SourceKey: sourceKey, MessageID: messageID, ThreadID: message.ThreadId, Sender: envelope.Sender, Subject: envelope.Subject, ReceivedAt: envelope.ReceivedAt, Filename: candidate.Upload.Filename, Status: "processing", StoredBytes: int64(len(candidate.Upload.Content) + len(raw)), CreatedAt: now, UpdatedAt: now}
		reserved, err := s.reserveGmailPending(ctx, item)
		if err != nil {
			return err
		}
		if !reserved {
			continue
		}
		original := &importUpload{Filename: "gmail-" + safeSuffix(messageID) + ".eml", Content: raw}
		if strings.EqualFold(filepath.Ext(candidate.Upload.Filename), ".eml") && bytes.Equal(candidate.Upload.Content, raw) {
			original = nil
		}
		preview, previewErr := ginH(nil), candidate.Error
		if previewErr == nil {
			preview, previewErr = s.createImportPreviewFromUploadsWithID(ctx, item.ImportID, candidate.ProviderOverride, false, candidate.Upload, original)
		}
		if previewErr != nil {
			item.Status = "failed"
			item.Error = previewErr.Error()
		} else {
			item.Provider, _ = preview["provider"].(string)
			item.CandidateCount = anyInt(preview["candidateCount"])
			item.Status = "ready"
			ready++
		}
		if err := s.finalizeGmailPending(ctx, item); err != nil {
			_ = s.cleanupImportRuntime(context.Background(), item.ImportID)
			return err
		}
	}
	if ready > 0 && s.notificationService != nil {
		_, _ = s.notificationService.Publish(ctx, NotificationMessage{Title: "收到新账单", Body: fmt.Sprintf("%s：%d 份账单等待 Review", valueOr(envelope.Subject, envelope.Sender), ready), URL: "/import", Tag: "gmail-import-" + messageID})
	}
	return nil
}

func (s *Server) recordGmailEnvelopeFailure(ctx context.Context, messageID string, raw []byte, envelope gmailMessageEnvelope, reason, message string) error {
	sourceKey := messageID + ":message-" + reason
	now := time.Now().UTC().Format(time.RFC3339Nano)
	item := GmailPendingImport{ID: randomID(), SourceKey: sourceKey, MessageID: messageID, Sender: envelope.Sender, Subject: envelope.Subject, ReceivedAt: envelope.ReceivedAt, Filename: "gmail-" + safeSuffix(messageID) + ".eml", Status: "failed", Error: message, CreatedAt: now, UpdatedAt: now, StoredBytes: int64(len(raw))}
	reserved, err := s.reserveGmailPending(ctx, item)
	if err != nil || !reserved {
		return err
	}
	return s.finalizeGmailPending(ctx, item)
}

func (s *Server) recordGmailMessageFailure(ctx context.Context, messageID string, processErr error) error {
	sourceKey := messageID + ":message-error"
	now := time.Now().UTC().Format(time.RFC3339Nano)
	item := GmailPendingImport{ID: randomID(), SourceKey: sourceKey, MessageID: messageID, Filename: "gmail-" + safeSuffix(messageID) + ".eml", Status: "failed", Error: processErr.Error(), CreatedAt: now, UpdatedAt: now}
	reserved, err := s.reserveGmailPending(ctx, item)
	if err != nil || !reserved {
		return err
	}
	return s.finalizeGmailPending(ctx, item)
}

func decodeGmailRaw(value string) ([]byte, error) {
	raw, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		raw, err = base64.URLEncoding.DecodeString(value)
	}
	return raw, err
}

func (s *Server) gmailImportCandidates(ctx context.Context, envelope gmailMessageEnvelope, raw []byte, messageID string, existingSourceKeys map[string]struct{}) ([]gmailImportCandidate, bool) {
	candidates := make([]gmailImportCandidate, 0, len(envelope.Attachments)+1)
	usable := 0
	duplicateSkipped := false
	for _, attachment := range envelope.Attachments {
		sourceKey := messageID + ":" + sha256Hex(attachment.Content)
		if _, exists := existingSourceKeys[sourceKey]; exists {
			duplicateSkipped = true
			continue
		}
		ext := strings.ToLower(filepath.Ext(attachment.Filename))
		if ext == ".zip" {
			zipContext, cancel := context.WithTimeout(ctx, time.Duration(s.cfg.GmailZipTimeoutSeconds)*time.Second)
			extracted, _, err := extractGmailImportZIP(s, zipContext, attachment.Content, s.cfg.GmailZipPasswords)
			cancel()
			if err != nil {
				candidates = append(candidates, gmailImportCandidate{Upload: attachment, Error: err})
			} else if s.importFilenameSupported(extracted.Filename) {
				candidates = append(candidates, gmailImportCandidate{Upload: extracted, ProviderOverride: gmailAttachmentProviderOverride(envelope.Sender, extracted.Filename)})
				usable++
			}
			continue
		}
		if s.importFilenameSupported(attachment.Filename) {
			candidates = append(candidates, gmailImportCandidate{Upload: attachment, ProviderOverride: gmailAttachmentProviderOverride(envelope.Sender, attachment.Filename)})
			usable++
		}
	}
	if usable == 0 && !duplicateSkipped {
		filename := "gmail-" + safeSuffix(messageID) + ".eml"
		if _, err := s.importerRegistry().Detect(filename, raw, ""); err == nil {
			candidates = append(candidates, gmailImportCandidate{Upload: importUpload{Filename: filename, Content: raw}})
		}
	}
	return candidates, duplicateSkipped
}

func gmailAttachmentProviderOverride(sender, filename string) string {
	if strings.EqualFold(strings.TrimSpace(sender), cmbCreditGmailSender) && strings.EqualFold(filepath.Ext(filename), ".pdf") {
		return "cmb"
	}
	return ""
}

func gmailAttachmentSummary(attachments []importUpload) string {
	if len(attachments) == 0 {
		return "无附件"
	}
	names := make([]string, 0, len(attachments))
	for _, attachment := range attachments {
		names = append(names, attachment.Filename)
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}

func (s *Server) importFilenameSupported(filename string) bool {
	ext := strings.ToLower(filepath.Ext(filename))
	for _, option := range s.importerRegistry().Options() {
		if stringIn(ext, option.Extensions) {
			return true
		}
	}
	return false
}

func anyInt(value any) int {
	switch typed := value.(type) {
	case int:
		return typed
	case int64:
		return int(typed)
	case float64:
		return int(typed)
	default:
		return 0
	}
}

func parseGmailMessage(raw []byte, internalDate int64) (gmailMessageEnvelope, error) {
	message, err := mail.ReadMessage(bytes.NewReader(raw))
	if err != nil {
		return gmailMessageEnvelope{}, err
	}
	decoder := gmailMIMEWordDecoder()
	subject, _ := decoder.DecodeHeader(message.Header.Get("Subject"))
	sender := canonicalEmailAddress(message.Header.Get("From"))
	receivedAt := ""
	if internalDate > 0 {
		receivedAt = time.UnixMilli(internalDate).UTC().Format(time.RFC3339Nano)
	} else if parsed, err := mail.ParseDate(message.Header.Get("Date")); err == nil {
		receivedAt = parsed.UTC().Format(time.RFC3339Nano)
	}
	attachments := []importUpload{}
	if err := collectMIMEAttachments(textprotoMIMEHeader(message.Header), message.Body, decoder, &attachments, 0); err != nil {
		return gmailMessageEnvelope{}, err
	}
	return gmailMessageEnvelope{Sender: sender, Subject: strings.TrimSpace(subject), ReceivedAt: receivedAt, Authenticated: gmailDMARCPassed(message.Header), Attachments: attachments}, nil
}

func gmailMIMEWordDecoder() *mime.WordDecoder {
	return &mime.WordDecoder{CharsetReader: func(charset string, input io.Reader) (io.Reader, error) {
		switch strings.ToLower(strings.TrimSpace(charset)) {
		case "gb18030", "gbk", "gb2312":
			return simplifiedchinese.GB18030.NewDecoder().Reader(input), nil
		default:
			return nil, fmt.Errorf("unsupported charset %q", charset)
		}
	}}
}

func gmailDMARCPassed(header mail.Header) bool {
	for key, values := range header {
		if !strings.EqualFold(key, "Authentication-Results") {
			continue
		}
		if len(values) == 0 {
			return false
		}
		lower := strings.ToLower(strings.TrimSpace(values[0]))
		return strings.HasPrefix(lower, "mx.google.com;") && strings.Contains(lower, "dmarc=pass")
	}
	return false
}

func textprotoMIMEHeader(header mail.Header) textproto.MIMEHeader {
	converted := make(textproto.MIMEHeader, len(header))
	for key, values := range header {
		converted[key] = append([]string(nil), values...)
	}
	return converted
}

func collectMIMEAttachments(header textproto.MIMEHeader, body io.Reader, decoder *mime.WordDecoder, attachments *[]importUpload, depth int) error {
	if depth > 8 {
		return errors.New("邮件 MIME 嵌套过深")
	}
	if len(*attachments) >= maxImportArchiveEntries {
		return fmt.Errorf("邮件附件数量超过 %d", maxImportArchiveEntries)
	}
	mediaType, params, _ := mime.ParseMediaType(header.Get("Content-Type"))
	if strings.HasPrefix(strings.ToLower(mediaType), "multipart/") {
		boundary := params["boundary"]
		if boundary == "" {
			return nil
		}
		reader := multipart.NewReader(body, boundary)
		for {
			part, err := reader.NextPart()
			if errors.Is(err, io.EOF) {
				return nil
			}
			if err != nil {
				return err
			}
			if err := collectMIMEAttachments(part.Header, part, decoder, attachments, depth+1); err != nil {
				_ = part.Close()
				return err
			}
			_ = part.Close()
		}
	}
	disposition, dispositionParams, _ := mime.ParseMediaType(header.Get("Content-Disposition"))
	filename := dispositionParams["filename"]
	if filename == "" {
		filename = params["name"]
	}
	if filename == "" && !strings.EqualFold(disposition, "attachment") {
		return nil
	}
	if decoded, err := decoder.DecodeHeader(filename); err == nil {
		filename = decoded
	}
	content, err := readMIMEBody(header.Get("Content-Transfer-Encoding"), body)
	if err != nil {
		return err
	}
	if len(content) > maxImportFileBytes {
		return errors.New("邮件附件超过 10MB")
	}
	filename = safeArchiveFilename(filename)
	if filepath.Ext(filename) == "" && (strings.EqualFold(mediaType, "application/pdf") || bytes.HasPrefix(content, []byte("%PDF-"))) {
		filename += ".pdf"
	}
	*attachments = append(*attachments, importUpload{Filename: filename, Content: content})
	return nil
}

func readMIMEBody(encoding string, body io.Reader) ([]byte, error) {
	switch strings.ToLower(strings.TrimSpace(encoding)) {
	case "base64":
		body = base64.NewDecoder(base64.StdEncoding, body)
	case "quoted-printable":
		body = quotedprintable.NewReader(body)
	}
	return io.ReadAll(io.LimitReader(body, maxImportFileBytes+1))
}

func canonicalEmailAddress(value string) string {
	address, err := mail.ParseAddress(value)
	if err != nil {
		start := strings.LastIndex(value, "<")
		end := strings.LastIndex(value, ">")
		if start >= 0 && end > start {
			if address, fallbackErr := mail.ParseAddress(strings.TrimSpace(value[start+1 : end])); fallbackErr == nil {
				return strings.ToLower(strings.TrimSpace(address.Address))
			}
		}
		return strings.ToLower(strings.TrimSpace(value))
	}
	return strings.ToLower(strings.TrimSpace(address.Address))
}

func gmailSenderAllowed(sender string, allowed []string) bool {
	sender = strings.ToLower(strings.TrimSpace(sender))
	for _, candidate := range allowed {
		if sender == strings.ToLower(strings.TrimSpace(candidate)) {
			return true
		}
	}
	return false
}

func (s *Server) readGmailPending(ctx context.Context) (gmailPendingStore, error) {
	var store gmailPendingStore
	ok, err := s.runtime().GetJSON(ctx, "gmail", gmailPendingKey, &store)
	if err != nil {
		return gmailPendingStore{}, err
	}
	if !ok {
		return gmailPendingStore{Version: 1, Items: []GmailPendingImport{}}, nil
	}
	if store.Version == 0 {
		store.Version = 1
	}
	if store.Items == nil {
		store.Items = []GmailPendingImport{}
	}
	return store, nil
}

func (s *Server) writeGmailPending(ctx context.Context, store gmailPendingStore) error {
	store.Version = 1
	return s.runtime().PutJSON(ctx, "gmail", gmailPendingKey, store)
}

func (s *Server) gmailPendingSourceKeys(ctx context.Context) (map[string]struct{}, error) {
	store, err := s.readGmailPending(ctx)
	if err != nil {
		return nil, err
	}
	keys := make(map[string]struct{}, len(store.Items))
	for _, item := range store.Items {
		if item.SourceKey != "" {
			keys[item.SourceKey] = struct{}{}
		}
	}
	return keys, nil
}

func (s *Server) gmailPendingSnapshot(ctx context.Context) (gmailPendingStore, error) {
	store, err := s.readGmailPending(ctx)
	if err != nil {
		return gmailPendingStore{}, err
	}
	originalUpdatedAt := map[string]string{}
	for _, item := range store.Items {
		originalUpdatedAt[item.ID] = item.UpdatedAt
	}
	changed, err := s.recoverStaleGmailPendingUnlocked(ctx, &store)
	if err != nil || !changed {
		return store, err
	}
	var snapshot gmailPendingStore
	err = s.runtime().WithLock(ctx, "gmail-pending", func(lockCtx context.Context) error {
		latest, err := s.readGmailPending(lockCtx)
		if err != nil {
			return err
		}
		for _, recovered := range store.Items {
			for index := range latest.Items {
				if latest.Items[index].ID == recovered.ID && latest.Items[index].UpdatedAt == originalUpdatedAt[recovered.ID] {
					latest.Items[index] = recovered
				}
			}
		}
		if err := s.writeGmailPending(lockCtx, latest); err != nil {
			return err
		}
		snapshot = latest
		return nil
	})
	return snapshot, err
}

func (s *Server) recoverStaleGmailPendingUnlocked(ctx context.Context, store *gmailPendingStore) (bool, error) {
	changed := false
	for index := range store.Items {
		item := &store.Items[index]
		if item.Status != "committing" && item.Status != "processing" {
			continue
		}
		updatedAt, _ := time.Parse(time.RFC3339Nano, item.UpdatedAt)
		if !updatedAt.IsZero() && time.Since(updatedAt) < 10*time.Minute {
			continue
		}
		if item.Status == "committing" && item.OutputFile != "" {
			committed, err := s.importCommitExists(ctx, item.OutputFile, item.ImportID)
			if err != nil {
				return false, err
			}
			if committed {
				item.Status = "committed"
				item.Error = ""
				item.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
				_ = s.cleanupImportRuntime(ctx, item.ImportID)
				changed = true
				continue
			}
		}
		var preview ginH
		exists, err := s.runtime().GetJSON(ctx, "imports", importFileKey(item.ImportID, "preview"), &preview)
		if err != nil {
			return false, err
		}
		if exists {
			item.Status = "ready"
			item.Provider, _ = preview["provider"].(string)
			item.CandidateCount = anyInt(preview["candidateCount"])
			item.Error = "上次处理未完成，请重新确认"
		} else {
			item.Status = "failed"
			item.Error = "上次处理在完成预览前中断，请重新发送账单"
			_ = s.cleanupImportRuntime(ctx, item.ImportID)
		}
		item.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
		changed = true
	}
	return changed, nil
}

func (s *Server) importCommitExists(ctx context.Context, outputFile, importID string) (bool, error) {
	relative, err := filepath.Rel(s.cfg.LedgerRoot, outputFile)
	if err != nil {
		return false, err
	}
	content, err := s.readLedgerFileContent(ctx, filepath.ToSlash(relative))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return strings.Contains(string(content), "; import-id: "+importID), nil
}

func (s *Server) reserveGmailPending(ctx context.Context, item GmailPendingImport) (bool, error) {
	reserved := false
	err := s.runtime().WithLock(ctx, "gmail-pending", func(lockCtx context.Context) error {
		store, err := s.readGmailPending(lockCtx)
		if err != nil {
			return err
		}
		active, bytesUsed := 0, int64(0)
		for _, existing := range store.Items {
			if existing.SourceKey == item.SourceKey {
				return nil
			}
			if existing.Status != "committed" && existing.Status != "dismissed" {
				active++
				bytesUsed += existing.StoredBytes
			}
		}
		if active >= maxGmailPendingItems || bytesUsed+item.StoredBytes > maxGmailPendingBytes {
			return errors.New("Gmail 待 Review 队列已达到容量上限")
		}
		store.Items = append(store.Items, item)
		store.Items = pruneGmailPending(store.Items, maxGmailPendingItems)
		reserved = true
		return s.writeGmailPending(lockCtx, store)
	})
	return reserved, err
}

func (s *Server) finalizeGmailPending(ctx context.Context, item GmailPendingImport) error {
	return s.runtime().WithLock(ctx, "gmail-pending", func(lockCtx context.Context) error {
		store, err := s.readGmailPending(lockCtx)
		if err != nil {
			return err
		}
		for index := range store.Items {
			if store.Items[index].ID == item.ID {
				item.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
				store.Items[index] = item
				return s.writeGmailPending(lockCtx, store)
			}
		}
		return os.ErrNotExist
	})
}

func pruneGmailPending(items []GmailPendingImport, limit int) []GmailPendingImport {
	if len(items) <= limit {
		return items
	}
	active := make([]GmailPendingImport, 0, len(items))
	terminal := make([]GmailPendingImport, 0, len(items))
	for _, item := range items {
		if item.Status == "committed" || item.Status == "dismissed" {
			terminal = append(terminal, item)
		} else {
			active = append(active, item)
		}
	}
	keepTerminal := max(0, limit-len(active))
	if keepTerminal < len(terminal) {
		terminal = terminal[len(terminal)-keepTerminal:]
	}
	return append(terminal, active...)
}

func (s *Server) updateGmailPendingStatus(ctx context.Context, id, status, message string) error {
	return s.runtime().WithLock(ctx, "gmail-pending", func(lockCtx context.Context) error {
		return s.updateGmailPendingStatusUnlocked(lockCtx, id, status, message)
	})
}

func (s *Server) updateGmailPendingStatusUnlocked(ctx context.Context, id, status, message string) error {
	store, err := s.readGmailPending(ctx)
	if err != nil {
		return err
	}
	for index := range store.Items {
		item := &store.Items[index]
		if item.ID != id && item.ImportID != id {
			continue
		}
		item.Status = status
		item.Error = message
		item.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	}
	return s.writeGmailPending(ctx, store)
}

func (s *Server) claimGmailPendingImport(ctx context.Context, importID string) (bool, error) {
	if _, err := s.gmailPendingSnapshot(ctx); err != nil {
		return false, err
	}
	claimed := false
	err := s.runtime().WithLock(ctx, "gmail-pending", func(lockCtx context.Context) error {
		store, err := s.readGmailPending(lockCtx)
		if err != nil {
			return err
		}
		for index := range store.Items {
			item := &store.Items[index]
			if item.ImportID != importID {
				continue
			}
			if item.Status != "ready" {
				return fmt.Errorf("自动账单状态为 %s，无法提交", item.Status)
			}
			meta, err := s.readImportMeta(lockCtx, item.ImportID)
			if err != nil {
				return err
			}
			item.OutputFile = importOutputPath(s.cfg, meta.DateStart, meta.DateEnd, meta.Provider, item.ImportID)
			item.Status = "committing"
			item.Error = ""
			item.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
			claimed = true
			return s.writeGmailPending(lockCtx, store)
		}
		return nil
	})
	return claimed, err
}

func (s *Server) dismissGmailPendingImport(ctx context.Context, id string) error {
	if _, err := s.gmailPendingSnapshot(ctx); err != nil {
		return err
	}
	return s.runtime().WithLock(ctx, "gmail-pending", func(lockCtx context.Context) error {
		store, err := s.readGmailPending(lockCtx)
		if err != nil {
			return err
		}
		item, ok := pendingImportByID(store, id)
		if !ok {
			return os.ErrNotExist
		}
		if item.Status == "committing" || item.Status == "committed" {
			return fmt.Errorf("自动账单状态为 %s，无法忽略", item.Status)
		}
		if item.ImportID != "" {
			if err := s.cleanupImportRuntime(lockCtx, item.ImportID); err != nil {
				return err
			}
		}
		return s.updateGmailPendingStatusUnlocked(lockCtx, id, "dismissed", "")
	})
}

func pendingImportByID(store gmailPendingStore, id string) (GmailPendingImport, bool) {
	for _, item := range store.Items {
		if item.ID == id || item.ImportID == id {
			return item, true
		}
	}
	return GmailPendingImport{}, false
}

func (s *Server) isGmailPendingImport(ctx context.Context, importID string) (bool, error) {
	store, err := s.readGmailPending(ctx)
	if err != nil {
		return false, err
	}
	_, ok := pendingImportByID(store, importID)
	return ok, nil
}

func parseHistoryID(value string) (uint64, error) {
	return strconv.ParseUint(strings.TrimSpace(value), 10, 64)
}
