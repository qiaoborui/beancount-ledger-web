package mobileagent

import (
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
	"time"
)

// Network budgets of one turn. A phone moves between networks and is
// suspended between turns, so nothing here may wait on a connection forever.
const connectTimeout = 15 * time.Second

// streamIdleTimeout bounds how long a single read of a model response may
// wait for a byte, headers included. Reasoning models can be quiet for a
// while before they answer, so it is generous; it exists to turn a dead
// connection into an error the user sees. Tests shorten it.
var streamIdleTimeout = 150 * time.Second

const (
	// providerRetries is how often a request that failed before any reply
	// (a dropped connection, 429, 5xx, overloaded) is sent again.
	providerRetries         = 2
	providerMaxRetryDelayMs = 20_000
)

// errStreamStalled replaces the read error of a response that went quiet.
var errStreamStalled = errors.New("model stream stalled")

// turnHTTP is the HTTP client of one turn. Each turn dials fresh
// connections: iOS suspends the app between turns and the clock that ages
// idle connections stops with it, so a pooled connection from the last turn
// is often already dead, and a request written into it would wait for a
// reply that never comes. Within a turn the model calls follow each other
// closely and share connections.
type turnHTTP struct {
	transport *http.Transport
	client    *http.Client
	// stalled is set once any response of the turn went quiet past
	// streamIdleTimeout or never sent its headers.
	stalled atomic.Bool
}

func newTurnHTTP() *turnHTTP {
	dialer := &net.Dialer{Timeout: connectTimeout, KeepAlive: 15 * time.Second, FallbackDelay: 2 * time.Second}
	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           dialer.DialContext,
		TLSHandshakeTimeout:   connectTimeout,
		ResponseHeaderTimeout: streamIdleTimeout,
		ExpectContinueTimeout: time.Second,
		MaxIdleConnsPerHost:   4,
		IdleConnTimeout:       60 * time.Second,
	}
	h := &turnHTTP{transport: transport}
	h.client = &http.Client{Transport: &idleGuard{base: transport, idle: streamIdleTimeout, stalled: &h.stalled}}
	return h
}

// close drops the turn's connections.
func (h *turnHTTP) close() { h.transport.CloseIdleConnections() }

// idleGuard fails a response whose body stops delivering data.
type idleGuard struct {
	base    http.RoundTripper
	idle    time.Duration
	stalled *atomic.Bool
}

func (g *idleGuard) RoundTrip(request *http.Request) (*http.Response, error) {
	response, err := g.base.RoundTrip(originForm(request))
	if err != nil {
		if isTimeout(err) && request.Context().Err() == nil {
			g.stalled.Store(true)
		}
		return response, err
	}
	response.Body = newIdleBody(response.Body, g.idle, g.stalled)
	return response, nil
}

// originForm sends a request whose URL PiG keeps in opaque form (to
// preserve the raw path) with that path as the request target, as PiG's own
// transport does.
func originForm(request *http.Request) *http.Request {
	prefix := "//" + request.URL.Host
	if request.URL.Opaque == "" || !strings.HasPrefix(request.URL.Opaque, prefix+"/") {
		return request
	}
	copied := request.Clone(request.Context())
	copied.URL.Opaque, _, _ = strings.Cut(strings.TrimPrefix(request.URL.Opaque, prefix), "#")
	return copied
}

func isTimeout(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}

// idleBody closes the body when one read waits longer than idle. Only time
// spent inside Read counts, so a slow consumer is never mistaken for a
// silent server.
type idleBody struct {
	body    io.ReadCloser
	idle    time.Duration
	stalled *atomic.Bool
	timer   *time.Timer
	fired   atomic.Bool
}

func newIdleBody(body io.ReadCloser, idle time.Duration, stalled *atomic.Bool) *idleBody {
	b := &idleBody{body: body, idle: idle, stalled: stalled}
	b.timer = time.AfterFunc(idle, func() {
		b.fired.Store(true)
		b.stalled.Store(true)
		_ = b.body.Close()
	})
	b.timer.Stop()
	return b
}

func (b *idleBody) Read(p []byte) (int, error) {
	if b.fired.Load() {
		return 0, errStreamStalled
	}
	b.timer.Reset(b.idle)
	n, err := b.body.Read(p)
	b.timer.Stop()
	if b.fired.Load() {
		return n, errStreamStalled
	}
	return n, err
}

func (b *idleBody) Close() error {
	b.timer.Stop()
	return b.body.Close()
}
