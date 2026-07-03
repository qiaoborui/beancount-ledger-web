package app

import (
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/net/websocket"
)

type RealtimeEvent struct {
	Type string `json:"type"`
	At   string `json:"at"`
	Data any    `json:"data,omitempty"`
}

type EventHub struct {
	mu      sync.Mutex
	clients map[*eventSubscriber]bool
}

type eventSubscriber struct {
	hub  *EventHub
	ch   chan RealtimeEvent
	once sync.Once
}

var ledgerEventHub = NewEventHub()

func NewEventHub() *EventHub {
	return &EventHub{clients: map[*eventSubscriber]bool{}}
}

func (h *EventHub) Subscribe() *eventSubscriber {
	sub := &eventSubscriber{hub: h, ch: make(chan RealtimeEvent, 16)}
	h.mu.Lock()
	h.clients[sub] = true
	h.mu.Unlock()
	return sub
}

func (h *EventHub) Publish(eventType string, data any) {
	event := RealtimeEvent{Type: eventType, At: time.Now().UTC().Format(time.RFC3339Nano), Data: data}
	h.mu.Lock()
	defer h.mu.Unlock()
	for sub := range h.clients {
		select {
		case sub.ch <- event:
		default:
			// Drop stale events for slow clients; the next event will trigger a fresh REST read.
		}
	}
}

func (sub *eventSubscriber) Close() {
	sub.once.Do(func() {
		sub.hub.mu.Lock()
		delete(sub.hub.clients, sub)
		close(sub.ch)
		sub.hub.mu.Unlock()
	})
}

func publishLedgerUpdated(cfg Config, source string) {
	data := gin.H{"source": source}
	if version, err := ledgerVersion(cfg); err == nil {
		data["version"] = version
	}
	ledgerEventHub.Publish("ledger.updated", data)
}

func publishGitStatus(cfg Config, source string) {
	if err := ensureLedgerReady(cfg); err != nil {
		ledgerEventHub.Publish("git.status", gin.H{"source": source, "error": err.Error()})
		return
	}
	available, err := ledgerGitAvailable(cfg)
	if err != nil {
		ledgerEventHub.Publish("git.status", gin.H{"source": source, "error": err.Error()})
		return
	}
	if !available {
		data := ledgerGitUnavailablePayload()
		data["source"] = source
		ledgerEventHub.Publish("git.status", data)
		return
	}
	trackedPaths := ledgerGitTrackedPathspecs(cfg)
	output, err := gitLedger(cfg, append([]string{"status", "--short", "--"}, trackedPaths...)...)
	data := gin.H{"source": source}
	if err != nil {
		data["error"] = err.Error()
		ledgerEventHub.Publish("git.status", data)
		return
	}
	changes := parseGitChanges(output)
	data["status"] = output
	data["dirty"] = len(changes) > 0
	data["changedFileCount"] = len(changes)
	data["changes"] = changes
	ledgerEventHub.Publish("git.status", data)
}

func publishJobStatus(name, status, message string) {
	data := gin.H{"name": name, "status": status}
	if message != "" {
		data["message"] = message
	}
	ledgerEventHub.Publish("job.status", data)
}

func (s *Server) eventsWS(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	websocket.Handler(func(conn *websocket.Conn) {
		defer conn.Close()
		sub := s.events.Subscribe()
		defer sub.Close()
		if err := websocket.JSON.Send(conn, RealtimeEvent{Type: "hello", At: time.Now().UTC().Format(time.RFC3339Nano)}); err != nil {
			return
		}
		publishGitStatus(s.cfg, "connect")
		for event := range sub.ch {
			if err := websocket.JSON.Send(conn, event); err != nil {
				return
			}
		}
	}).ServeHTTP(c.Writer, c.Request)
}
