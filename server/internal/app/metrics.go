package app

import (
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const metricsNamespace = "beancount_ledger_web"

const (
	cacheFilesystemSnapshot = "filesystem_snapshot"
	cacheReadModelRevision  = "read_model_revision"
	cacheReadModelSnapshot  = "read_model_snapshot"

	cacheResultHit  = "hit"
	cacheResultMiss = "miss"

	operationBeanCompile           = "bean_compile"
	operationFilesystemSnapshot    = "filesystem_snapshot"
	operationReadModelRevision     = "read_model_revision"
	operationReadModelSnapshotFull = "read_model_snapshot_full"
	operationReadModelSnapshotLite = "read_model_snapshot_lite"
	operationReadModelTransactions = "read_model_transactions"
	operationReadModelBalances     = "read_model_balances"
	operationResultSuccess         = "success"
	operationResultError           = "error"
	operationResultUnavailable     = "unavailable"
	operationResultWithParseErrors = "parse_errors"
)

var requestDurationBuckets = []float64{
	0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1,
	2.5, 5, 10, 30, 60, 300, 900,
}

// Metrics owns an application-local registry. Keeping it out of Prometheus's
// global registry makes application construction deterministic in tests and
// prevents duplicate collector registration in embedded deployments.
type Metrics struct {
	registry                *prometheus.Registry
	httpRequests            *prometheus.CounterVec
	httpRequestDuration     *prometheus.HistogramVec
	httpRequestsInFlight    *prometheus.GaugeVec
	cacheRequests           *prometheus.CounterVec
	ledgerOperations        *prometheus.CounterVec
	ledgerOperationDuration *prometheus.HistogramVec
}

func NewMetrics() *Metrics {
	metrics := &Metrics{
		registry: prometheus.NewRegistry(),
		httpRequests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: metricsNamespace,
			Subsystem: "http",
			Name:      "requests_total",
			Help:      "Completed HTTP requests by bounded method, stable Gin route template, and status code.",
		}, []string{"method", "route", "status"}),
		httpRequestDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Namespace: metricsNamespace,
			Subsystem: "http",
			Name:      "request_duration_seconds",
			Help:      "HTTP request duration by bounded method and stable Gin route template.",
			Buckets:   requestDurationBuckets,
		}, []string{"method", "route"}),
		httpRequestsInFlight: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Namespace: metricsNamespace,
			Subsystem: "http",
			Name:      "requests_in_flight",
			Help:      "HTTP requests currently being served by bounded method and stable Gin route template.",
		}, []string{"method", "route"}),
		cacheRequests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: metricsNamespace,
			Subsystem: "ledger",
			Name:      "cache_requests_total",
			Help:      "Ledger cache lookups by fixed cache layer and hit or miss result.",
		}, []string{"cache", "result"}),
		ledgerOperations: prometheus.NewCounterVec(prometheus.CounterOpts{
			Namespace: metricsNamespace,
			Subsystem: "ledger",
			Name:      "operations_total",
			Help:      "Key ledger read and parse operations by fixed operation and bounded result.",
		}, []string{"operation", "result"}),
		ledgerOperationDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Namespace: metricsNamespace,
			Subsystem: "ledger",
			Name:      "operation_duration_seconds",
			Help:      "Duration of key ledger read and parse operations by fixed operation and bounded result.",
			Buckets:   requestDurationBuckets,
		}, []string{"operation", "result"}),
	}
	metrics.registry.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		metrics.httpRequests,
		metrics.httpRequestDuration,
		metrics.httpRequestsInFlight,
		metrics.cacheRequests,
		metrics.ledgerOperations,
		metrics.ledgerOperationDuration,
	)
	return metrics
}

func (m *Metrics) Handler() http.Handler {
	if m == nil {
		return http.NotFoundHandler()
	}
	return promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{
		EnableOpenMetrics:   true,
		MaxRequestsInFlight: 2,
		Timeout:             5 * time.Second,
	})
}

func (m *Metrics) requestMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		method := metricsHTTPMethod(c.Request.Method)
		route := c.FullPath()
		if route == "" {
			route = "unmatched"
		}
		started := time.Now()
		m.httpRequestsInFlight.WithLabelValues(method, route).Inc()
		defer func() {
			status := metricsHTTPStatus(c.Writer.Status())
			m.httpRequestsInFlight.WithLabelValues(method, route).Dec()
			m.httpRequests.WithLabelValues(method, route, status).Inc()
			m.httpRequestDuration.WithLabelValues(method, route).Observe(time.Since(started).Seconds())
		}()
		c.Next()
	}
}

func metricsHTTPMethod(method string) string {
	switch method {
	case http.MethodGet, http.MethodHead, http.MethodPost, http.MethodPut,
		http.MethodPatch, http.MethodDelete, http.MethodConnect, http.MethodOptions,
		http.MethodTrace:
		return method
	default:
		return "OTHER"
	}
}

func metricsHTTPStatus(status int) string {
	if status < 100 || status > 599 {
		return "other"
	}
	return strconv.Itoa(status)
}

func (m *Metrics) observeCache(cache, result string) {
	if m == nil {
		return
	}
	m.cacheRequests.WithLabelValues(cache, result).Inc()
}

func (m *Metrics) observeOperation(operation, result string, started time.Time) {
	if m == nil {
		return
	}
	m.ledgerOperations.WithLabelValues(operation, result).Inc()
	m.ledgerOperationDuration.WithLabelValues(operation, result).Observe(time.Since(started).Seconds())
}

func operationResult(err error) string {
	if err != nil {
		return operationResultError
	}
	return operationResultSuccess
}

func operationAvailabilityResult(err error, available bool) string {
	if err != nil {
		return operationResultError
	}
	if !available {
		return operationResultUnavailable
	}
	return operationResultSuccess
}
