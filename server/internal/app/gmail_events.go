package app

import (
	"crypto/sha256"
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

const gmailPendingKeepAliveInterval = 15 * time.Second
const gmailPendingCrossInstanceInterval = 3 * time.Second
const maxGmailPendingEventSubscribers = 4

type gmailPendingEventHub struct {
	mu          sync.Mutex
	nextID      uint64
	subscribers map[uint64]chan struct{}
}

func newGmailPendingEventHub() *gmailPendingEventHub {
	return &gmailPendingEventHub{subscribers: make(map[uint64]chan struct{})}
}

func (h *gmailPendingEventHub) subscribe() (<-chan struct{}, func(), bool) {
	h.mu.Lock()
	if len(h.subscribers) >= maxGmailPendingEventSubscribers {
		h.mu.Unlock()
		return nil, func() {}, false
	}
	h.nextID++
	id := h.nextID
	updates := make(chan struct{}, 1)
	h.subscribers[id] = updates
	h.mu.Unlock()

	return updates, func() {
		h.mu.Lock()
		delete(h.subscribers, id)
		h.mu.Unlock()
	}, true
}

func (h *gmailPendingEventHub) publish() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, subscriber := range h.subscribers {
		select {
		case subscriber <- struct{}{}:
		default:
		}
	}
}

func (s *Server) gmailPendingEventHub() *gmailPendingEventHub {
	s.gmailEventsOnce.Do(func() {
		s.gmailEvents = newGmailPendingEventHub()
	})
	return s.gmailEvents
}

func (s *Server) gmailPendingEvents(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	flusher, ok := c.Writer.(http.Flusher)
	if !ok {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "streaming is unavailable"})
		return
	}
	updates, unsubscribe, subscribed := s.gmailPendingEventHub().subscribe()
	if !subscribed {
		c.Header("Retry-After", "5")
		c.JSON(http.StatusTooManyRequests, gin.H{"error": "too many realtime import connections"})
		return
	}
	defer unsubscribe()

	c.Header("Content-Type", "text/event-stream; charset=utf-8")
	c.Header("Cache-Control", "no-cache, no-store")
	c.Header("Connection", "keep-alive")
	c.Header("X-Accel-Buffering", "no")
	revision := s.gmailPendingRevision(c)
	c.Status(http.StatusOK)
	_, _ = c.Writer.Write([]byte("event: pending\ndata: {\"reason\":\"connected\"}\n\n"))
	flusher.Flush()

	keepAlive := time.NewTicker(gmailPendingKeepAliveInterval)
	defer keepAlive.Stop()
	crossInstance := time.NewTicker(gmailPendingCrossInstanceInterval)
	defer crossInstance.Stop()

	for {
		select {
		case <-c.Request.Context().Done():
			return
		case <-updates:
			revision = s.gmailPendingRevision(c)
			_, _ = c.Writer.Write([]byte("event: pending\ndata: {\"reason\":\"changed\"}\n\n"))
			flusher.Flush()
		case <-crossInstance.C:
			latest := s.gmailPendingRevision(c)
			if latest != "" && latest != revision {
				revision = latest
				_, _ = c.Writer.Write([]byte("event: pending\ndata: {\"reason\":\"changed\"}\n\n"))
				flusher.Flush()
			}
		case <-keepAlive.C:
			_, _ = c.Writer.Write([]byte(": keep-alive\n\n"))
			flusher.Flush()
		}
	}
}

func (s *Server) gmailPendingRevision(c *gin.Context) string {
	store, err := s.readGmailPending(c.Request.Context())
	if err != nil {
		return ""
	}
	encoded, err := json.Marshal(store)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(encoded)
	return string(sum[:])
}
