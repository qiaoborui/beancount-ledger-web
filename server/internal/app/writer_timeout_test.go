package app

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"
)

func TestGitHubLedgerWriteTimeoutFromEnv(t *testing.T) {
	t.Setenv("LEDGER_GITHUB_WRITE_TIMEOUT", "45s")
	if got := githubLedgerWriteTimeout(); got != 45*time.Second {
		t.Fatalf("githubLedgerWriteTimeout() = %s, want 45s", got)
	}

	t.Setenv("LEDGER_GITHUB_WRITE_TIMEOUT", "42")
	if got := githubLedgerWriteTimeout(); got != 42*time.Second {
		t.Fatalf("githubLedgerWriteTimeout() = %s, want 42s", got)
	}

	t.Setenv("LEDGER_GITHUB_WRITE_TIMEOUT", "not-a-duration")
	if got := githubLedgerWriteTimeout(); got != defaultGitHubLedgerWriteTimeout {
		t.Fatalf("githubLedgerWriteTimeout() = %s, want default %s", got, defaultGitHubLedgerWriteTimeout)
	}
}

func TestLedgerWriteTimeoutMapsToGatewayTimeout(t *testing.T) {
	err := ledgerWriteTimeoutError(50*time.Second, context.DeadlineExceeded)
	if !errors.Is(err, errLedgerWriteTimeout) {
		t.Fatalf("ledgerWriteTimeoutError should wrap errLedgerWriteTimeout")
	}
	if got := ledgerWriteErrorStatus(err); got != http.StatusGatewayTimeout {
		t.Fatalf("ledgerWriteErrorStatus(timeout) = %d, want %d", got, http.StatusGatewayTimeout)
	}
	if got := ledgerWriteErrorStatus(errors.New("bad input")); got != http.StatusBadRequest {
		t.Fatalf("ledgerWriteErrorStatus(non-timeout) = %d, want %d", got, http.StatusBadRequest)
	}
}

func TestValidateCurrenciesUsesCommoditiesProvider(t *testing.T) {
	writer := NewLedgerWriterWithRuntimeStoreAndCommodities(Config{LedgerRoot: "/path/that/does/not/exist"}, nil, nil, func() ([]string, error) {
		return []string{"CNY"}, nil
	})
	if err := writer.validateCurrencies(&LedgerWriteTransaction{}, []string{"CNY"}); err != nil {
		t.Fatalf("validateCurrencies() error = %v", err)
	}
}
