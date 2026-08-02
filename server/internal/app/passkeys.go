package app

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
)

type StoredPasskey struct {
	ID             string     `json:"id"`
	PublicKey      string     `json:"publicKey"`
	Counter        uint32     `json:"counter"`
	Name           string     `json:"name,omitempty"`
	Transports     []string   `json:"transports,omitempty"`
	BackupEligible *bool      `json:"backupEligible,omitempty"`
	BackupState    *bool      `json:"backupState,omitempty"`
	CreatedAt      time.Time  `json:"createdAt,omitempty"`
	UpdatedAt      time.Time  `json:"updatedAt,omitempty"`
	LastUsedAt     *time.Time `json:"lastUsedAt,omitempty"`
}

type PasskeyCredentialSummary struct {
	ID             string     `json:"id"`
	Name           string     `json:"name"`
	Transports     []string   `json:"transports,omitempty"`
	BackupEligible *bool      `json:"backupEligible,omitempty"`
	BackupState    *bool      `json:"backupState,omitempty"`
	CreatedAt      *time.Time `json:"createdAt,omitempty"`
	LastUsedAt     *time.Time `json:"lastUsedAt,omitempty"`
}

type passkeyStore struct {
	CurrentChallenge string                          `json:"currentChallenge,omitempty"`
	CurrentSession   *webauthn.SessionData           `json:"currentSession,omitempty"`
	Sessions         map[string]storedPasskeySession `json:"sessions,omitempty"`
	Credentials      []StoredPasskey                 `json:"credentials"`
}

type storedPasskeySession struct {
	Session   *webauthn.SessionData `json:"session"`
	CreatedAt time.Time             `json:"createdAt"`
}

type passkeyUser struct {
	id          []byte
	credentials []webauthn.Credential
}

const passkeySessionTTL = 10 * time.Minute

var errPasskeyNotFound = errors.New("Passkey not found")

func (u passkeyUser) WebAuthnID() []byte {
	if len(u.id) > 0 {
		return u.id
	}
	return []byte("ledger-owner")
}

func (u passkeyUser) WebAuthnName() string {
	return "owner"
}

func (u passkeyUser) WebAuthnDisplayName() string {
	return "账本主人"
}

func (u passkeyUser) WebAuthnCredentials() []webauthn.Credential {
	return u.credentials
}

func (s *Server) passkeyStatus(c *gin.Context) {
	store := s.readPasskeyStore(c.Request.Context())
	c.JSON(http.StatusOK, gin.H{"registered": len(store.Credentials) > 0, "count": len(store.Credentials)})
}

func (s *Server) passkeyCredentials(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	store, err := s.readPasskeyStoreStrict(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"credentials": passkeyCredentialSummaries(store.Credentials)})
}

func (s *Server) renamePasskeyCredential(c *gin.Context) {
	if !s.limiter.Check(c, "passkey.credentials.rename", 30, 5*time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input PasskeyRenameRequest
	if !bindJSON(c, &input) {
		return
	}
	name := strings.TrimSpace(input.Name)
	if err := s.renameStoredPasskey(c.Request.Context(), c.Param("id"), name); err != nil {
		passkeyManagementError(c, err)
		return
	}
	store, err := s.readPasskeyStoreStrict(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	for _, credential := range passkeyCredentialSummaries(store.Credentials) {
		if credential.ID == c.Param("id") {
			c.JSON(http.StatusOK, credential)
			return
		}
	}
	passkeyManagementError(c, errPasskeyNotFound)
}

func (s *Server) deletePasskeyCredential(c *gin.Context) {
	if !s.limiter.Check(c, "passkey.credentials.delete", 10, 5*time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input PasskeyDeleteRequest
	if !bindJSON(c, &input) {
		return
	}
	ok, err := verifyPassword(input.Password)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "Invalid password"})
		return
	}
	remaining, err := s.deleteStoredPasskey(c.Request.Context(), c.Param("id"))
	if err != nil {
		passkeyManagementError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "remaining": remaining})
}

func (s *Server) passkeyRegisterOptions(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	wa, err := s.webAuthn(c)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	user := s.passkeyUser()
	exclusions := []protocol.CredentialDescriptor{}
	for _, credential := range user.credentials {
		exclusions = append(exclusions, credential.Descriptor())
	}
	creation, session, err := wa.BeginRegistration(user,
		webauthn.WithExclusions(exclusions),
		webauthn.WithConveyancePreference(protocol.PreferNoAttestation),
		webauthn.WithAuthenticatorSelection(protocol.AuthenticatorSelection{
			ResidentKey:      protocol.ResidentKeyRequirementPreferred,
			UserVerification: protocol.VerificationRequired,
		}),
	)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if err := s.savePasskeySession(session); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, creation.Response)
}

func (s *Server) passkeyRegisterVerify(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	wa, err := s.webAuthn(c)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if !s.hasPasskeySession() {
		errorJSON(c, http.StatusBadRequest, errors.New("No active passkey challenge"))
		return
	}
	body, err := io.ReadAll(c.Request.Body)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	parsedResponse, err := protocol.ParseCredentialCreationResponseBytes(body)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	session, err := s.consumePasskeySession(parsedResponse.Response.CollectedClientData.Challenge)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	credential, err := wa.CreateCredential(s.passkeyUser(), *session, parsedResponse)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	stored, err := s.savePasskey(credential)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "credential": passkeyCredentialSummary(stored)})
}

func (s *Server) passkeyLoginOptions(c *gin.Context) {
	if !s.limiter.Check(c, "passkey.login.options", 20, timeMinute()) {
		return
	}
	store := s.readPasskeyStore(context.Background())
	if len(store.Credentials) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "No passkey registered"})
		return
	}
	wa, err := s.webAuthn(c)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	descriptors := []protocol.CredentialDescriptor{}
	for _, credential := range s.passkeyUser().credentials {
		descriptors = append(descriptors, credential.Descriptor())
	}
	assertion, session, err := wa.BeginDiscoverableLogin(
		webauthn.WithAllowedCredentials(descriptors),
		webauthn.WithUserVerification(protocol.VerificationRequired),
	)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if err := s.savePasskeySession(session); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, assertion.Response)
}

func (s *Server) passkeyLoginVerify(c *gin.Context) {
	if !s.limiter.Check(c, "passkey.login.verify", 20, timeMinute()) {
		return
	}
	wa, err := s.webAuthn(c)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if !s.hasPasskeySession() {
		errorJSON(c, http.StatusBadRequest, errors.New("No active passkey challenge"))
		return
	}
	body, err := io.ReadAll(c.Request.Body)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	parsedResponse, err := protocol.ParseCredentialRequestResponseBytes(body)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	session, err := s.consumePasskeySession(parsedResponse.Response.CollectedClientData.Challenge)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	authenticatorFlags := parsedResponse.Response.AuthenticatorData.Flags
	_, credential, err := wa.ValidatePasskeyLogin(func(rawID, userHandle []byte) (webauthn.User, error) {
		return s.passkeyUserByCredential(rawID, userHandle, authenticatorFlags.HasBackupEligible(), authenticatorFlags.HasBackupState())
	}, *session, parsedResponse)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if err := s.updatePasskeyAfterLogin(credential.ID, credential.Authenticator.SignCount, credential.Flags.BackupEligible, credential.Flags.BackupState); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	token, err := createSessionToken()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	setSessionCookie(c, token)
	setSensitiveCookie(c)
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) webAuthn(c *gin.Context) (*webauthn.WebAuthn, error) {
	origins := configuredWebAuthnOrigins(c)
	rpID := strings.TrimSpace(os.Getenv("WEBAUTHN_RP_ID"))
	if rpID == "" {
		rpID = rpIDFromOrigin(origins[0])
	}
	return webauthn.New(&webauthn.Config{
		RPID:          rpID,
		RPDisplayName: "我的账本",
		RPOrigins:     origins,
	})
}

func (s *Server) webAuthnRelatedOrigins(c *gin.Context) {
	origins := relatedWebAuthnOrigins(c)
	if len(origins) == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "No related WebAuthn origins configured"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"origins": origins})
}

func (s *Server) readPasskeyStore(ctx context.Context) passkeyStore {
	store, err := s.readPasskeyStoreStrict(ctx)
	if err != nil {
		return passkeyStore{Credentials: []StoredPasskey{}}
	}
	return store
}

func (s *Server) readPasskeyStoreStrict(ctx context.Context) (passkeyStore, error) {
	if s.passkeys != nil {
		credentials, err := s.passkeys.Credentials(ctx)
		if err != nil {
			return passkeyStore{}, err
		}
		return passkeyStore{Credentials: credentials}, nil
	}
	var store passkeyStore
	ok, err := s.runtime().GetJSON(ctx, "auth", "passkeys", &store)
	if err != nil {
		return passkeyStore{}, err
	}
	if !ok {
		return passkeyStore{Credentials: []StoredPasskey{}}, nil
	}
	if store.Credentials == nil {
		store.Credentials = []StoredPasskey{}
	}
	store.normalizePasskeySessions(time.Now())
	return store, nil
}

func (s *Server) writePasskeyStore(ctx context.Context, store passkeyStore) error {
	return s.runtime().PutJSON(ctx, "auth", "passkeys", store)
}

func (s *Server) savePasskeySession(session *webauthn.SessionData) error {
	if session == nil || strings.TrimSpace(session.Challenge) == "" {
		return errors.New("No active passkey challenge")
	}
	if s.passkeys != nil {
		return s.passkeys.SaveSession(context.Background(), session)
	}
	return s.runtime().WithLock(context.Background(), "passkeys", func(lockCtx context.Context) error {
		store := s.readPasskeyStore(lockCtx)
		now := time.Now()
		store.normalizePasskeySessions(now)
		store.Sessions[session.Challenge] = storedPasskeySession{Session: session, CreatedAt: now}
		return s.writePasskeyStore(lockCtx, store)
	})
}

func (s *Server) consumePasskeySession(challenge string) (*webauthn.SessionData, error) {
	if strings.TrimSpace(challenge) == "" {
		return nil, errors.New("No active passkey challenge")
	}
	if s.passkeys != nil {
		return s.passkeys.ConsumeSession(context.Background(), challenge)
	}
	var session *webauthn.SessionData
	err := s.runtime().WithLock(context.Background(), "passkeys", func(lockCtx context.Context) error {
		store := s.readPasskeyStore(lockCtx)
		store.normalizePasskeySessions(time.Now())
		stored, ok := store.Sessions[challenge]
		if !ok || stored.Session == nil {
			return errors.New("No active passkey challenge")
		}
		session = stored.Session
		delete(store.Sessions, challenge)
		return s.writePasskeyStore(lockCtx, store)
	})
	if err != nil {
		return nil, err
	}
	return session, nil
}

func (s *Server) hasPasskeySession() bool {
	if s.passkeys != nil {
		hasSession, err := s.passkeys.HasSession(context.Background())
		return err == nil && hasSession
	}
	hasSession := false
	_ = s.runtime().WithLock(context.Background(), "passkeys", func(lockCtx context.Context) error {
		store := s.readPasskeyStore(lockCtx)
		store.normalizePasskeySessions(time.Now())
		hasSession = len(store.Sessions) > 0
		return s.writePasskeyStore(lockCtx, store)
	})
	return hasSession
}

func (store *passkeyStore) normalizePasskeySessions(now time.Time) {
	if store.Sessions == nil {
		store.Sessions = map[string]storedPasskeySession{}
	}
	if store.CurrentSession != nil {
		challenge := store.CurrentChallenge
		if challenge == "" {
			challenge = store.CurrentSession.Challenge
		}
		if challenge != "" {
			store.Sessions[challenge] = storedPasskeySession{Session: store.CurrentSession, CreatedAt: now}
		}
		store.CurrentChallenge = ""
		store.CurrentSession = nil
	}
	for challenge, stored := range store.Sessions {
		if challenge == "" || stored.Session == nil {
			delete(store.Sessions, challenge)
			continue
		}
		if !stored.Session.Expires.IsZero() && stored.Session.Expires.Before(now) {
			delete(store.Sessions, challenge)
			continue
		}
		if stored.CreatedAt.IsZero() {
			stored.CreatedAt = now
			store.Sessions[challenge] = stored
			continue
		}
		if now.Sub(stored.CreatedAt) > passkeySessionTTL {
			delete(store.Sessions, challenge)
		}
	}
}

func (s *Server) savePasskey(credential *webauthn.Credential) (StoredPasskey, error) {
	if credential == nil {
		return StoredPasskey{}, errors.New("passkey credential is required")
	}
	store := s.readPasskeyStore(context.Background())
	now := time.Now().UTC()
	stored := storedPasskeyFromCredential(credential)
	stored.Name = nextDefaultPasskeyName(store.Credentials)
	stored.CreatedAt = now
	stored.UpdatedAt = now
	if s.passkeys != nil {
		if err := s.passkeys.SaveCredential(context.Background(), stored); err != nil {
			return StoredPasskey{}, err
		}
		return stored, nil
	}
	err := s.runtime().WithLock(context.Background(), "passkeys", func(lockCtx context.Context) error {
		store := s.readPasskeyStore(lockCtx)
		replaced := false
		for i := range store.Credentials {
			if store.Credentials[i].ID == stored.ID {
				stored.Name = store.Credentials[i].Name
				stored.CreatedAt = store.Credentials[i].CreatedAt
				stored.LastUsedAt = store.Credentials[i].LastUsedAt
				if stored.Name == "" {
					stored.Name = nextDefaultPasskeyName(store.Credentials)
				}
				if stored.CreatedAt.IsZero() {
					stored.CreatedAt = now
				}
				store.Credentials[i] = stored
				replaced = true
				break
			}
		}
		if !replaced {
			stored.Name = nextDefaultPasskeyName(store.Credentials)
			store.Credentials = append(store.Credentials, stored)
		}
		return s.writePasskeyStore(lockCtx, store)
	})
	if err != nil {
		return StoredPasskey{}, err
	}
	return stored, nil
}

func (s *Server) updatePasskeyCounter(id []byte, counter uint32) error {
	return s.updatePasskeyAfterLogin(id, counter, false, false)
}

func (s *Server) updatePasskeyAfterLogin(id []byte, counter uint32, backupEligible bool, backupState bool) error {
	if s.passkeys != nil {
		return s.passkeys.UpdateCredential(context.Background(), base64.RawURLEncoding.EncodeToString(id), counter, backupEligible, backupState)
	}
	return s.runtime().WithLock(context.Background(), "passkeys", func(lockCtx context.Context) error {
		store := s.readPasskeyStore(lockCtx)
		encoded := base64.RawURLEncoding.EncodeToString(id)
		for i := range store.Credentials {
			if store.Credentials[i].ID == encoded {
				now := time.Now().UTC()
				store.Credentials[i].Counter = counter
				store.Credentials[i].BackupEligible = boolPtr(backupEligible)
				store.Credentials[i].BackupState = boolPtr(backupState)
				store.Credentials[i].LastUsedAt = &now
				store.Credentials[i].UpdatedAt = now
				return s.writePasskeyStore(lockCtx, store)
			}
		}
		return errPasskeyNotFound
	})
}

func (s *Server) renameStoredPasskey(ctx context.Context, id string, name string) error {
	if s.passkeys != nil {
		return s.passkeys.RenameCredential(ctx, id, name)
	}
	return s.runtime().WithLock(ctx, "passkeys", func(lockCtx context.Context) error {
		store, err := s.readPasskeyStoreStrict(lockCtx)
		if err != nil {
			return err
		}
		for i := range store.Credentials {
			if store.Credentials[i].ID != id {
				continue
			}
			store.Credentials[i].Name = name
			store.Credentials[i].UpdatedAt = time.Now().UTC()
			return s.writePasskeyStore(lockCtx, store)
		}
		return errPasskeyNotFound
	})
}

func (s *Server) deleteStoredPasskey(ctx context.Context, id string) (int, error) {
	if s.passkeys != nil {
		return s.passkeys.DeleteCredential(ctx, id)
	}
	remaining := 0
	err := s.runtime().WithLock(ctx, "passkeys", func(lockCtx context.Context) error {
		store, err := s.readPasskeyStoreStrict(lockCtx)
		if err != nil {
			return err
		}
		for i := range store.Credentials {
			if store.Credentials[i].ID != id {
				continue
			}
			store.Credentials = append(store.Credentials[:i], store.Credentials[i+1:]...)
			if err := s.writePasskeyStore(lockCtx, store); err != nil {
				return err
			}
			remaining = len(store.Credentials)
			return nil
		}
		return errPasskeyNotFound
	})
	return remaining, err
}

func passkeyCredentialSummaries(credentials []StoredPasskey) []PasskeyCredentialSummary {
	ordered := append([]StoredPasskey(nil), credentials...)
	sort.SliceStable(ordered, func(i, j int) bool {
		left, right := ordered[i], ordered[j]
		if left.LastUsedAt != nil || right.LastUsedAt != nil {
			if left.LastUsedAt == nil {
				return false
			}
			if right.LastUsedAt == nil {
				return true
			}
			if !left.LastUsedAt.Equal(*right.LastUsedAt) {
				return left.LastUsedAt.After(*right.LastUsedAt)
			}
		}
		if !left.CreatedAt.Equal(right.CreatedAt) {
			return left.CreatedAt.After(right.CreatedAt)
		}
		return left.ID < right.ID
	})
	out := make([]PasskeyCredentialSummary, 0, len(ordered))
	for _, credential := range ordered {
		out = append(out, passkeyCredentialSummary(credential))
	}
	return out
}

func passkeyCredentialSummary(credential StoredPasskey) PasskeyCredentialSummary {
	name := strings.TrimSpace(credential.Name)
	if name == "" {
		name = "未命名 Passkey"
	}
	var createdAt *time.Time
	if !credential.CreatedAt.IsZero() {
		value := credential.CreatedAt.UTC()
		createdAt = &value
	}
	var lastUsedAt *time.Time
	if credential.LastUsedAt != nil && !credential.LastUsedAt.IsZero() {
		value := credential.LastUsedAt.UTC()
		lastUsedAt = &value
	}
	return PasskeyCredentialSummary{
		ID:             credential.ID,
		Name:           name,
		Transports:     append([]string(nil), credential.Transports...),
		BackupEligible: credential.BackupEligible,
		BackupState:    credential.BackupState,
		CreatedAt:      createdAt,
		LastUsedAt:     lastUsedAt,
	}
}

func nextDefaultPasskeyName(credentials []StoredPasskey) string {
	used := make(map[string]struct{}, len(credentials))
	for _, credential := range credentials {
		used[strings.TrimSpace(credential.Name)] = struct{}{}
	}
	for position := 1; ; position++ {
		name := fmt.Sprintf("Passkey %d", position)
		if _, exists := used[name]; !exists {
			return name
		}
	}
}

func passkeyManagementError(c *gin.Context, err error) {
	if errors.Is(err, errPasskeyNotFound) {
		errorJSON(c, http.StatusNotFound, err)
		return
	}
	errorJSON(c, http.StatusInternalServerError, err)
}

func storedPasskeyFromCredential(credential *webauthn.Credential) StoredPasskey {
	transports := make([]string, 0, len(credential.Transport))
	for _, transport := range credential.Transport {
		transports = append(transports, string(transport))
	}
	return StoredPasskey{ID: base64.RawURLEncoding.EncodeToString(credential.ID), PublicKey: base64.RawURLEncoding.EncodeToString(credential.PublicKey), Counter: credential.Authenticator.SignCount, Transports: transports, BackupEligible: boolPtr(credential.Flags.BackupEligible), BackupState: boolPtr(credential.Flags.BackupState)}
}

func (s *Server) passkeyUser() passkeyUser {
	store := s.readPasskeyStore(context.Background())
	credentials := []webauthn.Credential{}
	for _, stored := range store.Credentials {
		id, err := decodeBase64URL(stored.ID)
		if err != nil {
			continue
		}
		publicKey, err := decodeBase64URL(stored.PublicKey)
		if err != nil {
			continue
		}
		transports := make([]protocol.AuthenticatorTransport, 0, len(stored.Transports))
		for _, transport := range stored.Transports {
			transports = append(transports, protocol.AuthenticatorTransport(transport))
		}
		credentials = append(credentials, webauthn.Credential{
			ID:        id,
			PublicKey: publicKey,
			Transport: transports,
			Flags: webauthn.CredentialFlags{
				BackupEligible: stored.BackupEligible != nil && *stored.BackupEligible,
				BackupState:    stored.BackupState != nil && *stored.BackupState,
			},
			Authenticator: webauthn.Authenticator{
				SignCount: stored.Counter,
			},
		})
	}
	return passkeyUser{credentials: credentials}
}

func (s *Server) passkeyUserByCredential(rawID, userHandle []byte, backupEligible bool, backupState bool) (webauthn.User, error) {
	encoded := base64.RawURLEncoding.EncodeToString(rawID)
	store := s.readPasskeyStore(context.Background())
	for _, credential := range store.Credentials {
		if credential.ID == encoded {
			user := s.passkeyUser()
			user.id = userHandle
			for i := range user.credentials {
				if base64.RawURLEncoding.EncodeToString(user.credentials[i].ID) == encoded {
					if credential.BackupEligible == nil {
						user.credentials[i].Flags.BackupEligible = backupEligible
					}
					if credential.BackupState == nil {
						user.credentials[i].Flags.BackupState = backupState
					}
				}
			}
			return user, nil
		}
	}
	return nil, errors.New("Unknown passkey")
}

func decodeBase64URL(value string) ([]byte, error) {
	if decoded, err := base64.RawURLEncoding.DecodeString(value); err == nil {
		return decoded, nil
	}
	return base64.URLEncoding.DecodeString(value)
}

func boolPtr(value bool) *bool {
	return &value
}

func configuredPublicOrigin() string {
	origin := strings.TrimSpace(os.Getenv("PUBLIC_ORIGIN"))
	if origin == "" {
		origin = strings.TrimSpace(os.Getenv("LEDGER_PUBLIC_ORIGIN"))
	}
	return normalizeWebOrigin(origin)
}

func configuredWebAuthnOrigins(c *gin.Context) []string {
	origins := []string{}
	origins = appendWebAuthnOrigin(origins, configuredPublicOrigin())
	origins = appendConfiguredWebAuthnOrigins(origins, os.Getenv("WEBAUTHN_PUBLIC_ORIGIN"))
	origins = appendConfiguredWebAuthnOrigins(origins, os.Getenv("WEBAUTHN_RP_ORIGINS"))
	origins = appendConfiguredWebAuthnOrigins(origins, os.Getenv("PUBLIC_ORIGINS"))
	if len(origins) == 0 {
		origins = appendWebAuthnOrigin(origins, requestOrigin(c))
	}
	return origins
}

func relatedWebAuthnOrigins(c *gin.Context) []string {
	origins := configuredWebAuthnOrigins(c)
	rpID := strings.TrimSpace(os.Getenv("WEBAUTHN_RP_ID"))
	if rpID == "" {
		rpID = rpIDFromOrigin(origins[0])
	}
	related := []string{}
	for _, origin := range origins {
		if webAuthnOriginMatchesRPID(origin, rpID) {
			continue
		}
		related = appendWebAuthnOrigin(related, origin)
	}
	return related
}

func appendConfiguredWebAuthnOrigins(origins []string, value string) []string {
	for _, origin := range strings.FieldsFunc(value, func(r rune) bool {
		return r == ',' || r == '\n' || r == '\t' || r == ' '
	}) {
		origins = appendWebAuthnOrigin(origins, origin)
	}
	return origins
}

func appendWebAuthnOrigin(origins []string, origin string) []string {
	origin = normalizeWebOrigin(origin)
	if origin == "" {
		return origins
	}
	for _, existing := range origins {
		if existing == origin {
			return origins
		}
	}
	return append(origins, origin)
}

func normalizeWebOrigin(origin string) string {
	origin = strings.TrimRight(strings.TrimSpace(origin), "/")
	if origin == "" {
		return ""
	}
	parsed, err := url.Parse(origin)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return ""
	}
	return strings.ToLower(parsed.Scheme) + "://" + strings.ToLower(parsed.Host)
}

func webAuthnOriginMatchesRPID(origin string, rpID string) bool {
	parsed, err := url.Parse(origin)
	if err != nil || parsed.Host == "" {
		return false
	}
	host := strings.ToLower(strings.Split(parsed.Host, ":")[0])
	rpID = strings.ToLower(strings.TrimSpace(rpID))
	return host == rpID || strings.HasSuffix(host, "."+rpID)
}

func requestOrigin(c *gin.Context) string {
	proto := forwardedProto(c)
	if proto == "" {
		if c.Request.TLS != nil {
			proto = "https"
		} else {
			proto = "http"
		}
	}
	host := ""
	if truthyEnv("TRUST_PROXY_HEADERS") {
		host = c.GetHeader("X-Forwarded-Host")
	}
	if host == "" {
		host = c.Request.Host
	}
	if host == "" {
		host = c.Request.URL.Host
	}
	return proto + "://" + host
}

func forwardedProto(c *gin.Context) string {
	proto := strings.ToLower(strings.TrimSpace(strings.Split(c.GetHeader("X-Forwarded-Proto"), ",")[0]))
	switch proto {
	case "http", "https":
		return proto
	default:
		return ""
	}
}

func rpIDFromOrigin(origin string) string {
	parsed, err := url.Parse(origin)
	if err != nil || parsed.Host == "" {
		return strings.Split(strings.TrimPrefix(strings.TrimPrefix(origin, "https://"), "http://"), ":")[0]
	}
	return strings.Split(parsed.Host, ":")[0]
}

func timeMinute() time.Duration {
	return time.Minute
}
