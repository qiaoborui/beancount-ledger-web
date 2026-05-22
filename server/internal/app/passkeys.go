package app

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
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
	CurrentChallenge string                `json:"currentChallenge,omitempty"`
	CurrentSession   *webauthn.SessionData `json:"currentSession,omitempty"`
	Credentials      []StoredPasskey       `json:"credentials"`
}

type passkeyUser struct {
	id          []byte
	credentials []webauthn.Credential
}

var passkeyMu sync.Mutex

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
	session, err := s.consumePasskeySession()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	credential, err := wa.FinishRegistration(s.passkeyUser(), *session, c.Request)
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
	session, err := s.consumePasskeySession()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	parsedResponse, err := protocol.ParseCredentialRequestResponse(c.Request)
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
	origin := configuredPublicOrigin()
	if origin == "" {
		origin = requestOrigin(c)
	}
	rpID := strings.TrimSpace(os.Getenv("WEBAUTHN_RP_ID"))
	if rpID == "" {
		rpID = rpIDFromOrigin(origin)
	}
	return webauthn.New(&webauthn.Config{
		RPID:          rpID,
		RPDisplayName: "我的账本",
		RPOrigins:     []string{origin},
	})
}

func (s *Server) passkeyPath() string {
	return filepath.Join(s.cfg.RuntimeDir, "passkeys.json")
}

func (s *Server) readPasskeyStore() passkeyStore {
	content, err := os.ReadFile(s.passkeyPath())
	if err != nil {
		return passkeyStore{Credentials: []StoredPasskey{}}
	}
	var store passkeyStore
	if err := json.Unmarshal(content, &store); err != nil {
		return passkeyStore{Credentials: []StoredPasskey{}}
	}
	if store.Credentials == nil {
		store.Credentials = []StoredPasskey{}
	}
	return store
}

func (s *Server) writePasskeyStore(store passkeyStore) error {
	if err := os.MkdirAll(s.cfg.RuntimeDir, 0o700); err != nil {
		return err
	}
	content, err := json.MarshalIndent(store, "", "  ")
	if err != nil {
		return err
	}
	content = append(content, '\n')
	return os.WriteFile(s.passkeyPath(), content, 0o600)
}

func (s *Server) savePasskeySession(session *webauthn.SessionData) error {
	passkeyMu.Lock()
	defer passkeyMu.Unlock()
	store := s.readPasskeyStore()
	store.CurrentSession = session
	if session != nil {
		store.CurrentChallenge = session.Challenge
	}
	return s.writePasskeyStore(store)
}

func (s *Server) consumePasskeySession() (*webauthn.SessionData, error) {
	passkeyMu.Lock()
	defer passkeyMu.Unlock()
	store := s.readPasskeyStore()
	if store.CurrentSession == nil {
		return nil, errors.New("No active passkey challenge")
	}
	session := store.CurrentSession
	store.CurrentSession = nil
	store.CurrentChallenge = ""
	if err := s.writePasskeyStore(store); err != nil {
		return nil, err
	}
	return session, nil
}

func (s *Server) savePasskey(credential *webauthn.Credential) error {
	passkeyMu.Lock()
	defer passkeyMu.Unlock()
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
}

func (s *Server) updatePasskeyCounter(id []byte, counter uint32) error {
	return s.updatePasskeyAfterLogin(id, counter, false, false)
}

func (s *Server) updatePasskeyAfterLogin(id []byte, counter uint32, backupEligible bool, backupState bool) error {
	passkeyMu.Lock()
	defer passkeyMu.Unlock()
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
	return strings.TrimRight(origin, "/")
}

func requestOrigin(c *gin.Context) string {
	proto := c.GetHeader("X-Forwarded-Proto")
	if proto != "" && !truthyEnv("TRUST_PROXY_HEADERS") {
		proto = ""
	}
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
