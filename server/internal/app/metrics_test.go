package app

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestMetricsMiddlewareUsesStableBoundedLabels(t *testing.T) {
	gin.SetMode(gin.TestMode)
	metrics := NewMetrics()
	router := gin.New()
	router.Use(metrics.requestMiddleware())
	router.GET("/api/ledger/items/:id", func(c *gin.Context) {
		c.Status(http.StatusCreated)
	})

	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/ledger/items/private-account?q=salary", nil))
	if response.Code != http.StatusCreated {
		t.Fatalf("status=%d, want %d", response.Code, http.StatusCreated)
	}

	unmatched := httptest.NewRecorder()
	router.ServeHTTP(unmatched, httptest.NewRequest("PROPFIND", "/secret-ledger-path", nil))

	body := scrapeMetrics(t, metrics)
	for _, want := range []string{
		`method="GET",route="/api/ledger/items/:id",status="201"`,
		`method="OTHER",route="unmatched",status="404"`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("metrics missing %q:\n%s", want, body)
		}
	}
	for _, sensitive := range []string{"private-account", "salary", "secret-ledger-path"} {
		if strings.Contains(body, sensitive) {
			t.Fatalf("metrics exposed request data %q", sensitive)
		}
	}
}

func TestMetricsMiddlewareTracksInFlightRequests(t *testing.T) {
	gin.SetMode(gin.TestMode)
	metrics := NewMetrics()
	router := gin.New()
	router.Use(metrics.requestMiddleware())
	entered := make(chan struct{})
	release := make(chan struct{})
	router.GET("/slow/:id", func(c *gin.Context) {
		close(entered)
		<-release
		c.Status(http.StatusNoContent)
	})
	done := make(chan struct{})
	go func() {
		defer close(done)
		router.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/slow/secret", nil))
	}()
	<-entered

	if got := testutil.ToFloat64(metrics.httpRequestsInFlight.WithLabelValues("GET", "/slow/:id")); got != 1 {
		t.Fatalf("in-flight=%v, want 1", got)
	}
	close(release)
	<-done
	if got := testutil.ToFloat64(metrics.httpRequestsInFlight.WithLabelValues("GET", "/slow/:id")); got != 0 {
		t.Fatalf("in-flight=%v, want 0", got)
	}
}

func TestMetricsMiddlewareRecordsRecoveredPanicAs500(t *testing.T) {
	gin.SetMode(gin.TestMode)
	metrics := NewMetrics()
	router := gin.New()
	router.Use(metrics.requestMiddleware(), recoveryMiddleware(slog.New(slog.NewTextHandler(io.Discard, nil))))
	router.GET("/panic", func(*gin.Context) {
		panic("test panic")
	})

	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/panic", nil))
	if response.Code != http.StatusInternalServerError {
		t.Fatalf("status=%d, want %d", response.Code, http.StatusInternalServerError)
	}
	if got := testutil.ToFloat64(metrics.httpRequests.WithLabelValues("GET", "/panic", "500")); got != 1 {
		t.Fatalf("500 requests=%v, want 1", got)
	}
}

func TestLedgerMetricsCoverExampleCacheAndReadModel(t *testing.T) {
	metrics := NewMetrics()
	ledgerRoot, err := filepath.Abs(filepath.Join("..", "..", "..", "examples", "minimal-ledger"))
	if err != nil {
		t.Fatal(err)
	}
	cache := NewLedgerCacheWithMetrics(Config{LedgerRoot: ledgerRoot}, metrics)
	if _, err := cache.Snapshot(); err != nil {
		t.Fatal(err)
	}
	if _, err := cache.Snapshot(); err != nil {
		t.Fatal(err)
	}
	if got := testutil.ToFloat64(metrics.cacheRequests.WithLabelValues(cacheFilesystemSnapshot, cacheResultMiss)); got != 1 {
		t.Fatalf("filesystem misses=%v, want 1", got)
	}
	if got := testutil.ToFloat64(metrics.cacheRequests.WithLabelValues(cacheFilesystemSnapshot, cacheResultHit)); got != 1 {
		t.Fatalf("filesystem hits=%v, want 1", got)
	}
	if body := scrapeMetrics(t, metrics); strings.Contains(body, ledgerRoot) || strings.Contains(body, "accounts.bean") {
		t.Fatal("ledger metrics exposed a ledger path or filename")
	}

	snapshot := &LedgerSnapshot{LedgerVersion: LedgerVersion{Version: "example"}}
	prepareLedgerSnapshot(snapshot)
	index := &bootstrapIndexPort{snapshot: snapshot}
	service := NewLedgerReadServiceWithIndexAndMetrics(nil, index, nil, true, metrics)
	if _, err := service.SnapshotLite(t.Context()); err != nil {
		t.Fatal(err)
	}
	if _, err := service.SnapshotLite(t.Context()); err != nil {
		t.Fatal(err)
	}
	if got := testutil.ToFloat64(metrics.cacheRequests.WithLabelValues(cacheReadModelRevision, cacheResultHit)); got != 1 {
		t.Fatalf("revision hits=%v, want 1", got)
	}
	if got := testutil.ToFloat64(metrics.cacheRequests.WithLabelValues(cacheReadModelSnapshot, cacheResultHit)); got != 1 {
		t.Fatalf("snapshot hits=%v, want 1", got)
	}
	if got := testutil.ToFloat64(metrics.ledgerOperations.WithLabelValues(operationReadModelSnapshotLite, operationResultSuccess)); got != 1 {
		t.Fatalf("read-model snapshot operations=%v, want 1", got)
	}
}

func scrapeMetrics(t *testing.T, metrics *Metrics) string {
	t.Helper()
	request := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	response := httptest.NewRecorder()
	metrics.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("metrics status=%d", response.Code)
	}
	body, err := io.ReadAll(response.Result().Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}
