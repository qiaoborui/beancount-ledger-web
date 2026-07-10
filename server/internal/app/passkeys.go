package app

import (
	"context"
	"encoding/base64"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
)

type StoredPasskey struct {
	ID             string   `json:"id"`
	PublicKey      string   `json:"publicKey"`
	Counter        uint32   `json:"counter"`
	Transports     []string `json:"transports,omitempty"`
	BackupEligible *bool    `json:"backupEligible,omitempty"`
	BackupState    *bool    `json:"backupState,omitempty"`
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
	store := s.readPasskeyStore()
	c.JSON(http.StatusOK, gin.H{"registered": len(store.Credentials) > 0})
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
	if err := s.savePasskey(credential); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (s *Server) passkeyLoginOptions(c *gin.Context) {
	if !s.limiter.Check(c, "passkey.login.options", 20, timeMinute()) {
		return
	}
	store := s.readPasskeyStore()
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

func (s *Server) readPasskeyStore() passkeyStore {
	var store passkeyStore
	ok, err := s.runtime().GetJSON(context.Background(), "auth", "passkeys", &store)
	if err != nil || !ok {
		return passkeyStore{Credentials: []StoredPasskey{}}
	}
	if store.Credentials == nil {
		store.Credentials = []StoredPasskey{}
	}
	store.normalizePasskeySessions(time.Now())
	return store
}

func (s *Server) writePasskeyStore(store passkeyStore) error {
	return s.runtime().PutJSON(context.Background(), "auth", "passkeys", store)
}

func (s *Server) savePasskeySession(session *webauthn.SessionData) error {
	if session == nil || strings.TrimSpace(session.Challenge) == "" {
		return errors.New("No active passkey challenge")
	}
	return s.runtime().WithLock(context.Background(), "passkeys", func() error {
		store := s.readPasskeyStore()
		now := time.Now()
		store.normalizePasskeySessions(now)
		store.Sessions[session.Challenge] = storedPasskeySession{Session: session, CreatedAt: now}
		return s.writePasskeyStore(store)
	})
}

func (s *Server) consumePasskeySession(challenge string) (*webauthn.SessionData, error) {
	if strings.TrimSpace(challenge) == "" {
		return nil, errors.New("No active passkey challenge")
	}
	var session *webauthn.SessionData
	err := s.runtime().WithLock(context.Background(), "passkeys", func() error {
		store := s.readPasskeyStore()
		store.normalizePasskeySessions(time.Now())
		stored, ok := store.Sessions[challenge]
		if !ok || stored.Session == nil {
			return errors.New("No active passkey challenge")
		}
		session = stored.Session
		delete(store.Sessions, challenge)
		return s.writePasskeyStore(store)
	})
	if err != nil {
		return nil, err
	}
	return session, nil
}

func (s *Server) hasPasskeySession() bool {
	hasSession := false
	_ = s.runtime().WithLock(context.Background(), "passkeys", func() error {
		store := s.readPasskeyStore()
		store.normalizePasskeySessions(time.Now())
		hasSession = len(store.Sessions) > 0
		return s.writePasskeyStore(store)
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

func (s *Server) savePasskey(credential *webauthn.Credential) error {
	return s.runtime().WithLock(context.Background(), "passkeys", func() error {
		store := s.readPasskeyStore()
		id := base64.RawURLEncoding.EncodeToString(credential.ID)
		transports := make([]string, 0, len(credential.Transport))
		for _, transport := range credential.Transport {
			transports = append(transports, string(transport))
		}
		stored := StoredPasskey{
			ID:             id,
			PublicKey:      base64.RawURLEncoding.EncodeToString(credential.PublicKey),
			Counter:        credential.Authenticator.SignCount,
			Transports:     transports,
			BackupEligible: boolPtr(credential.Flags.BackupEligible),
			BackupState:    boolPtr(credential.Flags.BackupState),
		}
		replaced := false
		for i := range store.Credentials {
			if store.Credentials[i].ID == id {
				store.Credentials[i] = stored
				replaced = true
				break
			}
		}
		if !replaced {
			store.Credentials = append(store.Credentials, stored)
		}
		return s.writePasskeyStore(store)
	})
}

func (s *Server) updatePasskeyCounter(id []byte, counter uint32) error {
	return s.updatePasskeyAfterLogin(id, counter, false, false)
}

func (s *Server) updatePasskeyAfterLogin(id []byte, counter uint32, backupEligible bool, backupState bool) error {
	return s.runtime().WithLock(context.Background(), "passkeys", func() error {
		store := s.readPasskeyStore()
		encoded := base64.RawURLEncoding.EncodeToString(id)
		for i := range store.Credentials {
			if store.Credentials[i].ID == encoded {
				store.Credentials[i].Counter = counter
				store.Credentials[i].BackupEligible = boolPtr(backupEligible)
				store.Credentials[i].BackupState = boolPtr(backupState)
				return s.writePasskeyStore(store)
			}
		}
		return errors.New("Unknown passkey")
	})
}

func (s *Server) passkeyUser() passkeyUser {
	store := s.readPasskeyStore()
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
	store := s.readPasskeyStore()
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
