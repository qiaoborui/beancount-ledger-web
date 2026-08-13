package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
)

type setupReadinessStatus struct {
	State   string              `json:"state"`
	Active  bool                `json:"active"`
	Error   string              `json:"error,omitempty"`
	Indexer *indexerDiagnostics `json:"indexer,omitempty"`
}

type indexerDiagnostics struct {
	Reachable           bool      `json:"reachable"`
	Attempts            int       `json:"attempts"`
	FirstIndexSucceeded bool      `json:"firstIndexSucceeded"`
	LastAttempt         time.Time `json:"lastAttempt,omitempty"`
	LastSuccess         time.Time `json:"lastSuccess,omitempty"`
	LastError           string    `json:"lastError,omitempty"`
	LastRevision        int64     `json:"lastRevision,omitempty"`
}

const databaseReadinessError = "database read model unavailable; verify DATABASE_URL and the Postgres service, then inspect the server logs"

func (s *Server) setupReadiness(ctx context.Context) setupReadinessStatus {
	if s.indexStoreErr != nil {
		s.loggerOr().Warn("setup readiness database adapter unavailable", "error", s.indexStoreErr)
		return setupReadinessStatus{State: "database_error", Error: databaseReadinessError}
	}
	if s.indexStore == nil {
		return setupReadinessStatus{State: "ready", Active: true}
	}
	_, indexed, err := s.indexStore.ActiveRevision(ctx)
	if err != nil {
		s.loggerOr().Warn("read setup readiness revision", "error", err)
		return setupReadinessStatus{State: "database_error", Error: databaseReadinessError}
	}
	if s.cfg.IndexerHealthURL == "" {
		if indexed {
			return setupReadinessStatus{State: "ready", Active: true}
		}
		return setupReadinessStatus{State: "indexing"}
	}

	diagnostics, err := fetchIndexerDiagnostics(ctx, s.cfg.IndexerHealthURL, &http.Client{Timeout: 2 * time.Second})
	if err != nil {
		return setupReadinessStatus{
			State:   "indexer_unavailable",
			Active:  indexed,
			Error:   "indexer diagnostics unavailable: " + err.Error(),
			Indexer: &indexerDiagnostics{Reachable: false},
		}
	}
	// The indexer's health counters reset when its container restarts, while an
	// active Postgres revision proves the instance has completed an index before.
	diagnostics.FirstIndexSucceeded = diagnostics.FirstIndexSucceeded || indexed
	if diagnostics.LastError != "" {
		publicError := actionableIndexerError(diagnostics.LastError)
		diagnostics.LastError = publicError
		return setupReadinessStatus{State: "indexer_error", Active: indexed, Error: publicError, Indexer: &diagnostics}
	}
	if indexed {
		return setupReadinessStatus{State: "ready", Active: true, Indexer: &diagnostics}
	}
	return setupReadinessStatus{State: "indexing", Indexer: &diagnostics}
}

func actionableIndexerError(raw string) string {
	lower := strings.ToLower(raw)
	switch {
	case strings.Contains(lower, "uncommitted changes") || strings.Contains(lower, "not a git repository and is not empty"):
		return "ledger checkout is not clean; keep LEDGER_CHECKOUT_HOST_PATH dedicated to the indexer and inspect the indexer logs"
	case strings.Contains(lower, "permission denied") || strings.Contains(lower, "ledger_root"):
		return "indexer cannot access LEDGER_ROOT; verify the bind mount and LEDGER_UID/LEDGER_GID, then restart the indexer"
	case strings.Contains(lower, "main.bean") && (strings.Contains(lower, "no such file") || strings.Contains(lower, "not found") || strings.Contains(lower, "does not exist")):
		return "ledger repository is waiting for main.bean; finish first-run onboarding, then retry indexing"
	case strings.Contains(lower, "bean-check") || strings.Contains(lower, "main.bean"):
		return "latest ledger revision failed validation; inspect the indexer logs for bean-check details and fix the private ledger repository"
	case strings.Contains(lower, "runtime configuration"):
		return "indexer cannot retrieve runtime configuration; verify INDEXER_IDENTITY_TOKEN matches the API and indexer services"
	case strings.Contains(lower, "clone ledger checkout") || strings.Contains(lower, "fetch ledger checkout") || strings.Contains(lower, "fast-forward ledger checkout") || strings.Contains(lower, "authentication failed"):
		return "indexer cannot synchronize the private Git repository; verify the read-only token, repository, and branch, then inspect the indexer logs"
	default:
		return "indexer attempt failed; inspect the indexer logs for the private diagnostic details and retry after correcting the cause"
	}
}

func fetchIndexerDiagnostics(ctx context.Context, endpoint string, client *http.Client) (indexerDiagnostics, error) {
	if endpoint == "" {
		return indexerDiagnostics{}, errors.New("INDEXER_HEALTH_URL is not configured")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return indexerDiagnostics{}, err
	}
	response, err := client.Do(request)
	if err != nil {
		return indexerDiagnostics{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return indexerDiagnostics{}, fmt.Errorf("health endpoint returned HTTP %d", response.StatusCode)
	}
	var diagnostics indexerDiagnostics
	if err := json.NewDecoder(response.Body).Decode(&diagnostics); err != nil {
		return indexerDiagnostics{}, fmt.Errorf("decode health response: %w", err)
	}
	diagnostics.Reachable = true
	return diagnostics, nil
}
