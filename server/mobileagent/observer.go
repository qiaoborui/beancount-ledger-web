package mobileagent

import (
	"encoding/json"
	"sync"
)

// Observer hears what a running turn is doing: each model request and each
// tool call, as they start. The shell shows the step on screen and in the
// background progress it holds while the app is away, and a request with no
// event for a while tells it nothing is moving. Event is called in order on
// one goroutine per turn, never on the turn's own.
type Observer interface {
	Event(turnID, eventJSON string)
}

var (
	observerMu sync.Mutex
	observer   Observer
)

// SetObserver installs the listener for every later turn; nil removes it.
func SetObserver(o Observer) {
	observerMu.Lock()
	observer = o
	observerMu.Unlock()
}

func currentObserver() Observer {
	observerMu.Lock()
	defer observerMu.Unlock()
	return observer
}

type turnEventV1 struct {
	Version int `json:"version"`
	// Kind is "model" when a request goes to the model and "tool" when a
	// tool starts.
	Kind      string          `json:"kind"`
	Name      string          `json:"name,omitempty"`
	Arguments json.RawMessage `json:"arguments,omitempty"`
}

// eventFeed hands a turn's events to the observer without ever blocking the
// turn: a slow shell loses events, not time.
type eventFeed struct {
	events chan turnEventV1
	done   chan struct{}
}

// openEventFeed returns nil when there is no observer or the turn has no id
// to report under; a nil feed ignores everything.
func openEventFeed(turnID string) *eventFeed {
	o := currentObserver()
	if o == nil || turnID == "" {
		return nil
	}
	feed := &eventFeed{events: make(chan turnEventV1, 32), done: make(chan struct{})}
	go func() {
		defer close(feed.done)
		for event := range feed.events {
			o.Event(turnID, encode(event))
		}
	}()
	return feed
}

func (f *eventFeed) send(event turnEventV1) {
	if f == nil {
		return
	}
	event.Version = 1
	select {
	case f.events <- event:
	default:
	}
}

// close delivers what is queued before the turn's response is returned.
func (f *eventFeed) close() {
	if f == nil {
		return
	}
	close(f.events)
	<-f.done
}
