package app

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base32"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
	"golang.org/x/crypto/hkdf"
)

const (
	runtimeConfigSettingKey = "runtime_config"
	adminPasswordKey        = "admin_password"
	installCodeKey          = "install_code"
	githubWriteTokenKey     = "github_write_token"
	githubIndexTokenKey     = "github_index_token"
	aiAPIKeySecretKey       = "ai_api_key"
)

var (
	githubOwnerPattern = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$`)
	githubRepoPattern  = regexp.MustCompile(`^[A-Za-z0-9._-]{1,100}$`)
)

type runtimeConfigSettings struct {
	Version                 int    `json:"version"`
	SetupComplete           bool   `json:"setupComplete"`
	ConfigSource            string `json:"configSource"`
	InstanceID              string `json:"instanceId"`
	GitHubOwner             string `json:"githubOwner"`
	GitHubRepo              string `json:"githubRepo"`
	GitHubBranch            string `json:"githubBranch"`
	GitHubAPIURL            string `json:"githubApiUrl,omitempty"`
	AIProvider              string `json:"aiProvider"`
	AIBaseURL               string `json:"aiBaseUrl"`
	AIModel                 string `json:"aiModel"`
	IndexerIntervalSeconds  int    `json:"indexerIntervalSeconds"`
	IndexerRetryInitial     int    `json:"indexerRetryInitialSeconds"`
	IndexerRetryMaximum     int    `json:"indexerRetryMaximumSeconds"`
	RuntimeConfigMigrated   bool   `json:"runtimeConfigMigrated"`
	RuntimeConfigMigratedAt string `json:"runtimeConfigMigratedAt,omitempty"`
}

type RuntimeConfigStatus struct {
	SetupRequired          bool   `json:"setupRequired"`
	SetupComplete          bool   `json:"setupComplete"`
	ConfigSource           string `json:"configSource"`
	InstanceID             string `json:"instanceId,omitempty"`
	GitHubOwner            string `json:"githubOwner,omitempty"`
	GitHubRepo             string `json:"githubRepo,omitempty"`
	GitHubBranch           string `json:"githubBranch,omitempty"`
	GitHubAPIURL           string `json:"githubApiUrl,omitempty"`
	GitHubWriteTokenSet    bool   `json:"githubWriteTokenConfigured"`
	GitHubIndexTokenSet    bool   `json:"githubIndexTokenConfigured"`
	AIProvider             string `json:"aiProvider,omitempty"`
	AIBaseURL              string `json:"aiBaseUrl,omitempty"`
	AIModel                string `json:"aiModel,omitempty"`
	AIAPIKeySet            bool   `json:"aiApiKeyConfigured"`
	IndexerIntervalSeconds int    `json:"indexerIntervalSeconds,omitempty"`
	IndexerRetryInitial    int    `json:"indexerRetryInitialSeconds,omitempty"`
	IndexerRetryMaximum    int    `json:"indexerRetryMaximumSeconds,omitempty"`
}

type RuntimeConfigInstallInput struct {
	InstallCode            string `json:"installCode"`
	AdminPassword          string `json:"adminPassword"`
	GitHubOwner            string `json:"githubOwner"`
	GitHubRepo             string `json:"githubRepo"`
	GitHubBranch           string `json:"githubBranch"`
	GitHubAPIURL           string `json:"githubApiUrl"`
	GitHubWriteToken       string `json:"githubWriteToken"`
	GitHubIndexToken       string `json:"githubIndexToken"`
	AIProvider             string `json:"aiProvider"`
	AIBaseURL              string `json:"aiBaseUrl"`
	AIModel                string `json:"aiModel"`
	AIAPIKey               string `json:"aiApiKey"`
	IndexerIntervalSeconds int    `json:"indexerIntervalSeconds"`
	IndexerRetryInitial    int    `json:"indexerRetryInitialSeconds"`
	IndexerRetryMaximum    int    `json:"indexerRetryMaximumSeconds"`
}

type RuntimeConfigUpdateInput struct {
	AdminPassword          string `json:"adminPassword"`
	GitHubOwner            string `json:"githubOwner"`
	GitHubRepo             string `json:"githubRepo"`
	GitHubBranch           string `json:"githubBranch"`
	GitHubAPIURL           string `json:"githubApiUrl"`
	GitHubWriteToken       string `json:"githubWriteToken"`
	GitHubIndexToken       string `json:"githubIndexToken"`
	AIProvider             string `json:"aiProvider"`
	AIBaseURL              string `json:"aiBaseUrl"`
	AIModel                string `json:"aiModel"`
	AIAPIKey               string `json:"aiApiKey"`
	IndexerIntervalSeconds int    `json:"indexerIntervalSeconds"`
	IndexerRetryInitial    int    `json:"indexerRetryInitialSeconds"`
	IndexerRetryMaximum    int    `json:"indexerRetryMaximumSeconds"`
}

type IndexerRuntimeConfig struct {
	InstanceID          string `json:"instanceId"`
	RemoteURL           string `json:"remoteUrl"`
	Branch              string `json:"branch"`
	ReadToken           string `json:"readToken"`
	IntervalSeconds     int    `json:"intervalSeconds"`
	RetryInitialSeconds int    `json:"retryInitialSeconds"`
	RetryMaximumSeconds int    `json:"retryMaximumSeconds"`
}

type RuntimeConfigStore struct {
	db        *sql.DB
	masterKey []byte
}

func NewRuntimeConfigStore(db *sql.DB) (*RuntimeConfigStore, error) {
	if db == nil {
		return nil, errors.New("runtime configuration database is required")
	}
	authSecret := strings.TrimSpace(os.Getenv("AUTH_SECRET"))
	if authSecret == "" {
		return nil, errors.New("AUTH_SECRET is required")
	}
	key, err := deriveRuntimeConfigKey(authSecret)
	if err != nil {
		return nil, err
	}
	return &RuntimeConfigStore{db: db, masterKey: key}, nil
}

func (s *RuntimeConfigStore) VerifyInstallCode(ctx context.Context, code string) (bool, error) {
	var hash string
	err := s.db.QueryRowContext(ctx, `SELECT password_hash FROM instance_credentials WHERE key = $1`, installCodeKey).Scan(&hash)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(strings.ToUpper(strings.TrimSpace(code)))) == nil, nil
}

func deriveRuntimeConfigKey(authSecret string) ([]byte, error) {
	reader := hkdf.New(sha256.New, []byte(authSecret), []byte("beancount-ledger-web"), []byte("runtime-config-secrets-v1"))
	key := make([]byte, 32)
	if _, err := io.ReadFull(reader, key); err != nil {
		return nil, err
	}
	return key, nil
}

func (s *RuntimeConfigStore) Bootstrap(ctx context.Context, boot Config) (Config, error) {
	var installCode string
	err := withRuntimeConfigTransaction(ctx, s.db, func(tx *sql.Tx) error {
		settings, found, err := readRuntimeConfigSettings(ctx, tx)
		if err != nil {
			return err
		}
		if found && settings.SetupComplete {
			return nil
		}
		if legacyRuntimeConfigAvailable(boot) {
			return s.importLegacyEnvironment(ctx, tx, boot)
		}
		var existingHash string
		err = tx.QueryRowContext(ctx, `SELECT password_hash FROM instance_credentials WHERE key = $1`, installCodeKey).Scan(&existingHash)
		if err == nil {
			return nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		installCode, err = randomInstallCode()
		if err != nil {
			return err
		}
		hash, err := bcrypt.GenerateFromPassword([]byte(installCode), bcrypt.DefaultCost)
		if err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO instance_credentials (key, password_hash) VALUES ($1, $2)`, installCodeKey, string(hash))
		return err
	})
	if err != nil {
		return boot, err
	}
	if installCode != "" {
		log.Printf("runtime setup required; one-time install code: %s", installCode)
	}
	return s.EffectiveConfig(ctx, boot)
}

func withRuntimeConfigTransaction(ctx context.Context, db *sql.DB, fn func(*sql.Tx) error) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtext('beancount-ledger-runtime-config'))`); err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func randomInstallCode() (string, error) {
	raw := make([]byte, 15)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	encoded := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(raw)
	return strings.Join([]string{encoded[0:6], encoded[6:12], encoded[12:18], encoded[18:24]}, "-"), nil
}

func legacyRuntimeConfigAvailable(cfg Config) bool {
	return strings.TrimSpace(cfg.LedgerGitHubOwner) != "" &&
		strings.TrimSpace(cfg.LedgerGitHubRepo) != "" &&
		strings.TrimSpace(cfg.LedgerGitHubToken) != "" &&
		(authDisabled() || strings.TrimSpace(os.Getenv("APP_PASSWORD")) != "")
}

func (s *RuntimeConfigStore) importLegacyEnvironment(ctx context.Context, tx *sql.Tx, cfg Config) error {
	settings := runtimeConfigSettings{
		Version:                 1,
		SetupComplete:           true,
		ConfigSource:            "database",
		InstanceID:              valueOr(strings.TrimSpace(cfg.LedgerClusterID), newInstanceID()),
		GitHubOwner:             strings.TrimSpace(cfg.LedgerGitHubOwner),
		GitHubRepo:              strings.TrimSuffix(strings.TrimSpace(cfg.LedgerGitHubRepo), ".git"),
		GitHubBranch:            valueOr(strings.TrimSpace(cfg.LedgerGitBranch), "main"),
		GitHubAPIURL:            strings.TrimSpace(cfg.LedgerGitHubAPIURL),
		IndexerIntervalSeconds:  envInt("LEDGER_INDEX_INTERVAL_SECONDS", 60),
		IndexerRetryInitial:     envInt("LEDGER_INDEX_RETRY_INITIAL_SECONDS", 5),
		IndexerRetryMaximum:     envInt("LEDGER_INDEX_RETRY_MAX_SECONDS", 60),
		RuntimeConfigMigrated:   true,
		RuntimeConfigMigratedAt: time.Now().UTC().Format(time.RFC3339),
	}
	provider, baseURL, model, apiKey := legacyAIConfig()
	settings.AIProvider, settings.AIBaseURL, settings.AIModel = provider, baseURL, model
	if !authDisabled() {
		hash, err := bcrypt.GenerateFromPassword([]byte(os.Getenv("APP_PASSWORD")), bcrypt.DefaultCost)
		if err != nil {
			return err
		}
		if err := putCredential(ctx, tx, adminPasswordKey, string(hash)); err != nil {
			return err
		}
	}
	if err := s.putSecret(ctx, tx, githubWriteTokenKey, cfg.LedgerGitHubToken); err != nil {
		return err
	}
	if cfg.LedgerGitReadToken != "" {
		if err := s.putSecret(ctx, tx, githubIndexTokenKey, cfg.LedgerGitReadToken); err != nil {
			return err
		}
	}
	if apiKey != "" {
		if err := s.putSecret(ctx, tx, aiAPIKeySecretKey, apiKey); err != nil {
			return err
		}
	}
	if err := writeRuntimeConfigSettings(ctx, tx, settings); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `INSERT INTO runtime_config_audit (actor, action, changed_keys) VALUES ('system', 'legacy_env_import', $1::jsonb)`, `["runtime_config","admin_password","github_write_token","github_index_token","ai_api_key"]`)
	return err
}

func legacyAIConfig() (provider, baseURL, model, apiKey string) {
	provider = strings.ToLower(strings.TrimSpace(os.Getenv("LEDGER_AI_PROVIDER")))
	if provider == "" {
		if strings.TrimSpace(os.Getenv("DEEPSEEK_API_KEY")) != "" {
			provider = "deepseek"
		} else if strings.TrimSpace(os.Getenv("OPENAI_API_KEY")) != "" {
			provider = "openai"
		}
	}
	if provider == "deepseek" {
		return provider, env("DEEPSEEK_BASE_URL", "https://api.deepseek.com"), env("DEEPSEEK_MODEL", "deepseek-chat"), os.Getenv("DEEPSEEK_API_KEY")
	}
	if provider == "openai" || provider == "openai-compatible" {
		return "openai-compatible", env("OPENAI_BASE_URL", "https://api.openai.com/v1"), env("OPENAI_MODEL", "gpt-4.1-mini"), os.Getenv("OPENAI_API_KEY")
	}
	return "", "", "", ""
}

func newInstanceID() string {
	raw := make([]byte, 12)
	if _, err := rand.Read(raw); err != nil {
		return fmt.Sprintf("instance-%d", time.Now().UnixNano())
	}
	return "instance-" + base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(raw)
}

func (s *RuntimeConfigStore) EffectiveConfig(ctx context.Context, boot Config) (Config, error) {
	settings, found, err := readRuntimeConfigSettings(ctx, s.db)
	if err != nil || !found || !settings.SetupComplete {
		return boot, err
	}
	writeToken, _, err := s.getSecret(ctx, githubWriteTokenKey)
	if err != nil {
		return boot, err
	}
	indexToken, _, err := s.getSecret(ctx, githubIndexTokenKey)
	if err != nil {
		return boot, err
	}
	boot.LedgerStorage = "github_api"
	boot.LedgerReadModel = "postgres"
	boot.ReadModelStrict = true
	boot.LedgerGitHubOwner = settings.GitHubOwner
	boot.LedgerGitHubRepo = settings.GitHubRepo
	boot.LedgerGitBranch = settings.GitHubBranch
	boot.LedgerGitHubAPIURL = settings.GitHubAPIURL
	boot.LedgerGitHubToken = writeToken
	boot.LedgerGitReadToken = indexToken
	boot.LedgerGitRemoteURL = githubRemoteURL(settings.GitHubOwner, settings.GitHubRepo, settings.GitHubAPIURL)
	boot.LedgerClusterID = settings.InstanceID
	return boot, nil
}

func githubRemoteURL(owner, repo, apiURL string) string {
	if strings.TrimSpace(owner) == "" || strings.TrimSpace(repo) == "" {
		return ""
	}
	scheme, host, pathPrefix := "https", "github.com", ""
	if parsed, err := url.Parse(strings.TrimSpace(apiURL)); err == nil && parsed.Scheme != "" && parsed.Host != "" {
		scheme, host = parsed.Scheme, parsed.Host
		pathPrefix = strings.TrimRight(parsed.EscapedPath(), "/")
		pathPrefix = strings.TrimSuffix(pathPrefix, "/api/v3")
		pathPrefix = strings.TrimSuffix(pathPrefix, "/api")
	}
	return fmt.Sprintf("%s://%s%s/%s/%s.git", scheme, host, pathPrefix, strings.TrimSpace(owner), strings.TrimSuffix(strings.TrimSpace(repo), ".git"))
}

func (s *RuntimeConfigStore) SetupRequired(ctx context.Context) (bool, error) {
	settings, found, err := readRuntimeConfigSettings(ctx, s.db)
	return !found || !settings.SetupComplete, err
}

func (s *RuntimeConfigStore) Status(ctx context.Context) (RuntimeConfigStatus, error) {
	settings, found, err := readRuntimeConfigSettings(ctx, s.db)
	if err != nil {
		return RuntimeConfigStatus{}, err
	}
	status := RuntimeConfigStatus{SetupRequired: !found || !settings.SetupComplete, SetupComplete: found && settings.SetupComplete, ConfigSource: "database"}
	if found {
		status.InstanceID = settings.InstanceID
		status.GitHubOwner = settings.GitHubOwner
		status.GitHubRepo = settings.GitHubRepo
		status.GitHubBranch = settings.GitHubBranch
		status.GitHubAPIURL = settings.GitHubAPIURL
		status.AIProvider = settings.AIProvider
		status.AIBaseURL = settings.AIBaseURL
		status.AIModel = settings.AIModel
		status.IndexerIntervalSeconds = settings.IndexerIntervalSeconds
		status.IndexerRetryInitial = settings.IndexerRetryInitial
		status.IndexerRetryMaximum = settings.IndexerRetryMaximum
		if settings.ConfigSource != "" {
			status.ConfigSource = settings.ConfigSource
		}
	}
	status.GitHubWriteTokenSet, err = s.secretExists(ctx, githubWriteTokenKey)
	if err != nil {
		return RuntimeConfigStatus{}, err
	}
	status.GitHubIndexTokenSet, err = s.secretExists(ctx, githubIndexTokenKey)
	if err != nil {
		return RuntimeConfigStatus{}, err
	}
	status.AIAPIKeySet, err = s.secretExists(ctx, aiAPIKeySecretKey)
	return status, err
}

func (s *RuntimeConfigStore) Install(ctx context.Context, input RuntimeConfigInstallInput) error {
	input.normalize()
	if err := input.validate(); err != nil {
		return err
	}
	return withRuntimeConfigTransaction(ctx, s.db, func(tx *sql.Tx) error {
		settings, found, err := readRuntimeConfigSettings(ctx, tx)
		if err != nil {
			return err
		}
		if found && settings.SetupComplete {
			return errors.New("instance setup is already complete")
		}
		var installHash string
		if err := tx.QueryRowContext(ctx, `SELECT password_hash FROM instance_credentials WHERE key = $1`, installCodeKey).Scan(&installHash); err != nil {
			return errors.New("install code is unavailable; restart the service and inspect its logs")
		}
		if bcrypt.CompareHashAndPassword([]byte(installHash), []byte(input.InstallCode)) != nil {
			return errors.New("invalid install code")
		}
		passwordHash, err := bcrypt.GenerateFromPassword([]byte(input.AdminPassword), bcrypt.DefaultCost)
		if err != nil {
			return err
		}
		settings = runtimeConfigSettings{
			Version:                 1,
			SetupComplete:           true,
			ConfigSource:            "database",
			InstanceID:              newInstanceID(),
			GitHubOwner:             input.GitHubOwner,
			GitHubRepo:              input.GitHubRepo,
			GitHubBranch:            input.GitHubBranch,
			GitHubAPIURL:            input.GitHubAPIURL,
			AIProvider:              input.AIProvider,
			AIBaseURL:               input.AIBaseURL,
			AIModel:                 input.AIModel,
			IndexerIntervalSeconds:  input.IndexerIntervalSeconds,
			IndexerRetryInitial:     input.IndexerRetryInitial,
			IndexerRetryMaximum:     input.IndexerRetryMaximum,
			RuntimeConfigMigrated:   true,
			RuntimeConfigMigratedAt: time.Now().UTC().Format(time.RFC3339),
		}
		if err := writeRuntimeConfigSettings(ctx, tx, settings); err != nil {
			return err
		}
		if err := putCredential(ctx, tx, adminPasswordKey, string(passwordHash)); err != nil {
			return err
		}
		for key, value := range map[string]string{githubWriteTokenKey: input.GitHubWriteToken, githubIndexTokenKey: input.GitHubIndexToken, aiAPIKeySecretKey: input.AIAPIKey} {
			if err := s.putSecret(ctx, tx, key, value); err != nil {
				return err
			}
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM instance_credentials WHERE key = $1`, installCodeKey); err != nil {
			return err
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO runtime_config_audit (actor, action, changed_keys) VALUES ('installer', 'complete_setup', $1::jsonb)`, `["runtime_config","admin_password","github_write_token","github_index_token","ai_api_key"]`)
		return err
	})
}

func (s *RuntimeConfigStore) Update(ctx context.Context, input RuntimeConfigUpdateInput) error {
	input.GitHubOwner = strings.TrimSpace(input.GitHubOwner)
	input.GitHubRepo = strings.TrimSuffix(strings.TrimSpace(input.GitHubRepo), ".git")
	input.GitHubBranch = valueOr(strings.TrimSpace(input.GitHubBranch), "main")
	input.GitHubAPIURL = strings.TrimRight(strings.TrimSpace(input.GitHubAPIURL), "/")
	input.AIProvider = strings.ToLower(strings.TrimSpace(input.AIProvider))
	input.AIBaseURL = strings.TrimRight(strings.TrimSpace(input.AIBaseURL), "/")
	input.AIModel = strings.TrimSpace(input.AIModel)
	if input.GitHubOwner == "" || input.GitHubRepo == "" || input.AIProvider == "" || input.AIBaseURL == "" || input.AIModel == "" {
		return errors.New("GitHub repository and AI provider settings are required")
	}
	if err := validateRuntimeGitHubLocation(input.GitHubOwner, input.GitHubRepo, input.GitHubBranch); err != nil {
		return err
	}
	if err := validateRuntimeEndpointURLs(input.GitHubAPIURL, input.AIBaseURL); err != nil {
		return err
	}
	if input.AdminPassword != "" && len(strings.TrimSpace(input.AdminPassword)) < 12 {
		return errors.New("administrator password must contain at least 12 characters")
	}
	if input.IndexerIntervalSeconds <= 0 || input.IndexerRetryInitial <= 0 || input.IndexerRetryMaximum <= 0 || input.IndexerRetryMaximum < input.IndexerRetryInitial {
		return errors.New("indexer timing values are invalid")
	}
	return withRuntimeConfigTransaction(ctx, s.db, func(tx *sql.Tx) error {
		settings, found, err := readRuntimeConfigSettings(ctx, tx)
		if err != nil {
			return err
		}
		if !found || !settings.SetupComplete {
			return errors.New("instance setup is incomplete")
		}
		nextWriteToken, _, err := s.getSecretFromQuery(ctx, tx, githubWriteTokenKey)
		if err != nil {
			return err
		}
		nextIndexToken, _, err := s.getSecretFromQuery(ctx, tx, githubIndexTokenKey)
		if err != nil {
			return err
		}
		if value := strings.TrimSpace(input.GitHubWriteToken); value != "" {
			nextWriteToken = value
		}
		if value := strings.TrimSpace(input.GitHubIndexToken); value != "" {
			nextIndexToken = value
		}
		if nextWriteToken == nextIndexToken {
			return errors.New("GitHub write and indexer read tokens must be different")
		}
		settings.ConfigSource = "database"
		settings.GitHubOwner = input.GitHubOwner
		settings.GitHubRepo = input.GitHubRepo
		settings.GitHubBranch = input.GitHubBranch
		settings.GitHubAPIURL = input.GitHubAPIURL
		settings.AIProvider = input.AIProvider
		settings.AIBaseURL = input.AIBaseURL
		settings.AIModel = input.AIModel
		settings.IndexerIntervalSeconds = input.IndexerIntervalSeconds
		settings.IndexerRetryInitial = input.IndexerRetryInitial
		settings.IndexerRetryMaximum = input.IndexerRetryMaximum
		if err := writeRuntimeConfigSettings(ctx, tx, settings); err != nil {
			return err
		}
		changed := []string{"runtime_config"}
		for key, value := range map[string]string{
			githubWriteTokenKey: strings.TrimSpace(input.GitHubWriteToken),
			githubIndexTokenKey: strings.TrimSpace(input.GitHubIndexToken),
			aiAPIKeySecretKey:   strings.TrimSpace(input.AIAPIKey),
		} {
			if value == "" {
				continue
			}
			if err := s.putSecret(ctx, tx, key, value); err != nil {
				return err
			}
			changed = append(changed, key)
		}
		if password := strings.TrimSpace(input.AdminPassword); password != "" {
			hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
			if err != nil {
				return err
			}
			if err := putCredential(ctx, tx, adminPasswordKey, string(hash)); err != nil {
				return err
			}
			changed = append(changed, adminPasswordKey)
		}
		rawChanged, _ := json.Marshal(changed)
		_, err = tx.ExecContext(ctx, `INSERT INTO runtime_config_audit (actor, action, changed_keys) VALUES ('owner', 'update_runtime_config', $1::jsonb)`, rawChanged)
		return err
	})
}

func (input *RuntimeConfigInstallInput) normalize() {
	input.InstallCode = strings.ToUpper(strings.TrimSpace(input.InstallCode))
	input.AdminPassword = strings.TrimSpace(input.AdminPassword)
	input.GitHubOwner = strings.TrimSpace(input.GitHubOwner)
	input.GitHubRepo = strings.TrimSuffix(strings.TrimSpace(input.GitHubRepo), ".git")
	input.GitHubBranch = valueOr(strings.TrimSpace(input.GitHubBranch), "main")
	input.GitHubAPIURL = strings.TrimRight(strings.TrimSpace(input.GitHubAPIURL), "/")
	input.GitHubWriteToken = strings.TrimSpace(input.GitHubWriteToken)
	input.GitHubIndexToken = strings.TrimSpace(input.GitHubIndexToken)
	input.AIProvider = strings.ToLower(strings.TrimSpace(input.AIProvider))
	input.AIBaseURL = strings.TrimRight(strings.TrimSpace(input.AIBaseURL), "/")
	input.AIModel = strings.TrimSpace(input.AIModel)
	input.AIAPIKey = strings.TrimSpace(input.AIAPIKey)
	if input.IndexerIntervalSeconds <= 0 {
		input.IndexerIntervalSeconds = 60
	}
	if input.IndexerRetryInitial <= 0 {
		input.IndexerRetryInitial = 5
	}
	if input.IndexerRetryMaximum <= 0 {
		input.IndexerRetryMaximum = 60
	}
}

func (input RuntimeConfigInstallInput) validate() error {
	if input.InstallCode == "" {
		return errors.New("install code is required")
	}
	if len(input.AdminPassword) < 12 {
		return errors.New("administrator password must contain at least 12 characters")
	}
	if input.GitHubOwner == "" || input.GitHubRepo == "" || input.GitHubBranch == "" {
		return errors.New("GitHub owner, repository and branch are required")
	}
	if err := validateRuntimeGitHubLocation(input.GitHubOwner, input.GitHubRepo, input.GitHubBranch); err != nil {
		return err
	}
	if input.GitHubWriteToken == "" || input.GitHubIndexToken == "" {
		return errors.New("separate GitHub write and indexer read tokens are required")
	}
	if input.GitHubWriteToken == input.GitHubIndexToken {
		return errors.New("GitHub write and indexer read tokens must be different")
	}
	if input.AIProvider == "" || input.AIBaseURL == "" || input.AIModel == "" || input.AIAPIKey == "" {
		return errors.New("AI provider, base URL, model and API key are required")
	}
	if err := validateRuntimeEndpointURLs(input.GitHubAPIURL, input.AIBaseURL); err != nil {
		return err
	}
	if input.IndexerRetryMaximum < input.IndexerRetryInitial {
		return errors.New("indexer maximum retry must be greater than or equal to initial retry")
	}
	return nil
}

func validateRuntimeEndpointURLs(githubAPIURL, aiBaseURL string) error {
	if githubAPIURL != "" {
		parsed, err := url.ParseRequestURI(githubAPIURL)
		if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
			return errors.New("GitHub API URL must be an HTTPS URL without credentials, query, or fragment")
		}
	}
	parsed, err := url.ParseRequestURI(aiBaseURL)
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return errors.New("AI base URL must be an HTTP or HTTPS URL without credentials, query, or fragment")
	}
	return nil
}

func validateRuntimeGitHubLocation(owner, repo, branch string) error {
	if !githubOwnerPattern.MatchString(owner) {
		return errors.New("GitHub owner contains unsupported characters")
	}
	if !githubRepoPattern.MatchString(repo) || repo == "." || repo == ".." {
		return errors.New("GitHub repository contains unsupported characters")
	}
	if branch == "" || strings.HasPrefix(branch, "-") || strings.HasPrefix(branch, "/") || strings.HasSuffix(branch, "/") ||
		strings.HasSuffix(branch, ".") || strings.HasSuffix(branch, ".lock") || strings.Contains(branch, "..") ||
		strings.Contains(branch, "//") || strings.Contains(branch, "@{") || strings.ContainsAny(branch, " ~^:?*[\\\t\r\n") {
		return errors.New("GitHub branch is not a valid branch name")
	}
	return nil
}

func (s *RuntimeConfigStore) VerifyAdminPassword(ctx context.Context, password string) (bool, error) {
	var hash string
	err := s.db.QueryRowContext(ctx, `SELECT password_hash FROM instance_credentials WHERE key = $1`, adminPasswordKey).Scan(&hash)
	if errors.Is(err, sql.ErrNoRows) {
		return false, errors.New("administrator password is not configured")
	}
	if err != nil {
		return false, err
	}
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) == nil, nil
}

func (s *RuntimeConfigStore) AIProviderConfig(ctx context.Context) (aiProviderConfig, error) {
	settings, found, err := readRuntimeConfigSettings(ctx, s.db)
	if err != nil {
		return aiProviderConfig{}, err
	}
	if !found || !settings.SetupComplete || settings.AIProvider == "" {
		return aiProviderConfig{}, errors.New("AI provider is not configured")
	}
	apiKey, found, err := s.getSecret(ctx, aiAPIKeySecretKey)
	if err != nil {
		return aiProviderConfig{}, err
	}
	if !found || strings.TrimSpace(apiKey) == "" {
		return aiProviderConfig{}, errors.New("AI API key is not configured")
	}
	return aiProviderConfig{apiKey: apiKey, baseURL: settings.AIBaseURL, model: settings.AIModel}, nil
}

func (s *RuntimeConfigStore) IndexerConfig(ctx context.Context) (IndexerRuntimeConfig, error) {
	settings, found, err := readRuntimeConfigSettings(ctx, s.db)
	if err != nil {
		return IndexerRuntimeConfig{}, err
	}
	if !found || !settings.SetupComplete {
		return IndexerRuntimeConfig{}, errors.New("instance setup is incomplete")
	}
	readToken, found, err := s.getSecret(ctx, githubIndexTokenKey)
	if err != nil {
		return IndexerRuntimeConfig{}, err
	}
	if !found || strings.TrimSpace(readToken) == "" {
		return IndexerRuntimeConfig{}, errors.New("indexer read token is not configured")
	}
	return IndexerRuntimeConfig{
		InstanceID:          settings.InstanceID,
		RemoteURL:           githubRemoteURL(settings.GitHubOwner, settings.GitHubRepo, settings.GitHubAPIURL),
		Branch:              settings.GitHubBranch,
		ReadToken:           readToken,
		IntervalSeconds:     settings.IndexerIntervalSeconds,
		RetryInitialSeconds: settings.IndexerRetryInitial,
		RetryMaximumSeconds: settings.IndexerRetryMaximum,
	}, nil
}

func (s *RuntimeConfigStore) RecordIndexerIdentity(ctx context.Context, identityID, token string) error {
	hash := sha256.Sum256([]byte(token))
	settings, found, err := readRuntimeConfigSettings(ctx, s.db)
	if err != nil {
		return err
	}
	if !found || !settings.SetupComplete {
		return errors.New("instance setup is incomplete")
	}
	_, err = s.db.ExecContext(ctx, `
INSERT INTO indexer_identities (identity_id, instance_id, credential_hash, enabled, last_seen_at, updated_at)
VALUES ($1, $2, $3, true, now(), now())
ON CONFLICT (identity_id)
DO UPDATE SET instance_id = EXCLUDED.instance_id, credential_hash = EXCLUDED.credential_hash,
  enabled = true, last_seen_at = now(), updated_at = now()`,
		identityID, settings.InstanceID, fmt.Sprintf("%x", hash[:]))
	return err
}

type runtimeConfigQuery interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func readRuntimeConfigSettings(ctx context.Context, query runtimeConfigQuery) (runtimeConfigSettings, bool, error) {
	var raw []byte
	err := query.QueryRowContext(ctx, `SELECT value FROM instance_settings WHERE key = $1`, runtimeConfigSettingKey).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return runtimeConfigSettings{}, false, nil
	}
	if err != nil {
		return runtimeConfigSettings{}, false, err
	}
	var settings runtimeConfigSettings
	if err := json.Unmarshal(raw, &settings); err != nil {
		return runtimeConfigSettings{}, false, err
	}
	return settings, true, nil
}

func writeRuntimeConfigSettings(ctx context.Context, tx *sql.Tx, settings runtimeConfigSettings) error {
	raw, err := json.Marshal(settings)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO instance_settings (key, value, updated_at) VALUES ($1, $2::jsonb, now()) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()`, runtimeConfigSettingKey, raw)
	return err
}

func putCredential(ctx context.Context, tx *sql.Tx, key, hash string) error {
	_, err := tx.ExecContext(ctx, `INSERT INTO instance_credentials (key, password_hash, updated_at) VALUES ($1, $2, now()) ON CONFLICT (key) DO UPDATE SET password_hash = EXCLUDED.password_hash, updated_at = now()`, key, hash)
	return err
}

func (s *RuntimeConfigStore) putSecret(ctx context.Context, tx *sql.Tx, key, value string) error {
	block, err := aes.NewCipher(s.masterKey)
	if err != nil {
		return err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	ciphertext := gcm.Seal(nil, nonce, []byte(value), []byte(key))
	_, err = tx.ExecContext(ctx, `INSERT INTO instance_secrets (key, nonce, ciphertext, updated_at) VALUES ($1, $2, $3, now()) ON CONFLICT (key) DO UPDATE SET nonce = EXCLUDED.nonce, ciphertext = EXCLUDED.ciphertext, updated_at = now()`, key, nonce, ciphertext)
	return err
}

func (s *RuntimeConfigStore) getSecret(ctx context.Context, key string) (string, bool, error) {
	return s.getSecretFromQuery(ctx, s.db, key)
}

func (s *RuntimeConfigStore) getSecretFromQuery(ctx context.Context, query runtimeConfigQuery, key string) (string, bool, error) {
	var nonce, ciphertext []byte
	err := query.QueryRowContext(ctx, `SELECT nonce, ciphertext FROM instance_secrets WHERE key = $1`, key).Scan(&nonce, &ciphertext)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	block, err := aes.NewCipher(s.masterKey)
	if err != nil {
		return "", false, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", false, err
	}
	plaintext, err := gcm.Open(nil, nonce, ciphertext, []byte(key))
	if err != nil {
		return "", false, errors.New("runtime secret cannot be decrypted with the current AUTH_SECRET")
	}
	return string(plaintext), true, nil
}

func (s *RuntimeConfigStore) secretExists(ctx context.Context, key string) (bool, error) {
	var found bool
	err := s.db.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM instance_secrets WHERE key = $1)`, key).Scan(&found)
	return found, err
}
