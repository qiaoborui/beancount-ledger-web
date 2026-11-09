package mobileagent

import (
	"encoding/json"
	"sync"
	"time"
	"unicode/utf8"
)

// Observer hears what a running turn is doing: each model request and each
// tool call, as they start, and the reply and reasoning as they stream. The
// shell shows the step on screen and in the background progress it holds
// while the app is away, and a request with no event for a while tells it
// nothing is moving. Event is called in order on
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
	//
	// The kinds after those stream the turn as it is written. Only a turn
	// whose request sets streamEvents gets them, so a shell that predates
	// them sees the two kinds it knows:
	//   - "text_delta" and "thinking_delta" carry more of the reply or of the
	//     reasoning in Text. Consecutive deltas of one kind arrive joined, so
	//     one event may hold many tokens.
	//   - "thinking_end" closes a reasoning block: DurationMs, Redacted.
	//   - "tool_start" opens any tool call, admitted or not: CallID, Name,
	//     Arguments. An admitted call reports "tool" just before it.
	//   - "tool_end" closes it: CallID, Name, IsError, DurationMs (absent when
	//     the tool did not run), Preview, ErrorText.
	//   - "usage" follows each model message: Usage holds the turn so far.
	//   - "compaction_start" and "compaction_end" bracket the summary of older
	//     turns a long transcript gets before the turn's first "model".
	//     SummarizedTurns on "compaction_end" is how many questions the
	//     summary replaced; it is absent when the summary failed and the turn
	//     went on with the transcript trimmed instead, or was stopped.
	Kind       string          `json:"kind"`
	Name       string          `json:"name,omitempty"`
	Arguments  json.RawMessage `json:"arguments,omitempty"`
	CallID     string          `json:"callId,omitempty"`
	Text       string          `json:"text,omitempty"`
	DurationMs int64           `json:"durationMs,omitempty"`
	Redacted   bool            `json:"redacted,omitempty"`
	IsError    bool            `json:"isError,omitempty"`
	// Preview is the start of a tool's result, at most previewRunes long.
	Preview   string   `json:"preview,omitempty"`
	ErrorText string   `json:"errorText,omitempty"`
	Usage     *usageV1 `json:"usage,omitempty"`
	// Attempt is reserved for the retry count of a model request.
	Attempt         int `json:"attempt,omitempty"`
	SummarizedTurns int `json:"summarizedTurns,omitempty"`
}

// Deltas wait this long, or until this many bytes, to be joined with the
// ones after them: a token per event would cost the shell a redraw each.
const (
	deltaFlushInterval = 50 * time.Millisecond
	deltaFlushBytes    = 512
)

func isDelta(kind string) bool { return kind == "text_delta" || kind == "thinking_delta" }

// eventFeed hands a turn's events to the observer without ever blocking the
// turn. Every event is kept until the observer has it; a slow shell gets the
// deltas in fewer, larger pieces instead.
type eventFeed struct {
	mu sync.Mutex
	// ready waits for the observer, in order.
	ready []turnEventV1
	// delta is the delta still being joined, and since when.
	delta      *turnEventV1
	deltaSince time.Time
	closed     bool
	// streaming lets the kinds after "model" and "tool" through.
	streaming bool
	wake      chan struct{}
	done      chan struct{}
}

// openEventFeed returns nil when there is no observer or the turn has no id
// to report under; a nil feed ignores everything.
func openEventFeed(turnID string, streaming bool) *eventFeed {
	o := currentObserver()
	if o == nil || turnID == "" {
		return nil
	}
	feed := &eventFeed{streaming: streaming, wake: make(chan struct{}, 1), done: make(chan struct{})}
	go feed.deliver(o, turnID)
	return feed
}

func (f *eventFeed) deliver(o Observer, turnID string) {
	defer close(f.done)
	timer := time.NewTimer(deltaFlushInterval)
	timer.Stop()
	for {
		f.mu.Lock()
		// One reading of the clock decides both whether the delta is due and
		// how long to wait for it, so a delta that comes due between two
		// readings is never left without a timer.
		now := time.Now()
		if f.delta != nil && (f.closed || now.Sub(f.deltaSince) >= deltaFlushInterval) {
			f.readyDelta(f.closed)
		}
		batch := f.ready
		f.ready = nil
		wait := time.Duration(-1)
		if f.delta != nil {
			wait = max(deltaFlushInterval-now.Sub(f.deltaSince), 0)
		}
		finished := f.closed && f.delta == nil
		f.mu.Unlock()
		for _, event := range batch {
			o.Event(turnID, encode(event))
		}
		switch {
		case len(batch) > 0:
		case finished:
			return
		case wait >= 0:
			timer.Reset(wait)
			select {
			case <-f.wake:
				timer.Stop()
			case <-timer.C:
			}
		default:
			<-f.wake
		}
	}
}

func (f *eventFeed) send(event turnEventV1) {
	if f == nil {
		return
	}
	if !f.streaming && event.Kind != "model" && event.Kind != "tool" {
		return
	}
	event.Version = 1
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return
	}
	if isDelta(event.Kind) {
		if event.Text == "" {
			return
		}
		if f.delta != nil && f.delta.Kind == event.Kind {
			f.delta.Text += event.Text
		} else {
			f.readyDelta(true)
			f.delta, f.deltaSince = &event, time.Now()
		}
		if len(f.delta.Text) >= deltaFlushBytes {
			f.readyDelta(false)
		}
	} else {
		f.readyDelta(true)
		f.ready = append(f.ready, event)
	}
	f.poke()
}

// readyDelta moves the joined delta to the ready events, onto the last one
// when that is a delta of the same kind the observer has not taken yet.
// Unless all is set, a character cut in two by the stream stays behind for
// its other half, so every delta the observer gets is valid text.
func (f *eventFeed) readyDelta(all bool) {
	if f.delta == nil {
		return
	}
	event := *f.delta
	f.delta = nil
	if !all {
		var rest string
		event.Text, rest = splitIncompleteRune(event.Text)
		if rest != "" {
			f.delta = &turnEventV1{Version: event.Version, Kind: event.Kind, Text: rest}
			f.deltaSince = time.Now()
		}
		if event.Text == "" {
			return
		}
	}
	if last := len(f.ready) - 1; last >= 0 && f.ready[last].Kind == event.Kind {
		f.ready[last].Text += event.Text
		return
	}
	f.ready = append(f.ready, event)
}

func (f *eventFeed) poke() {
	select {
	case f.wake <- struct{}{}:
	default:
	}
}

// splitIncompleteRune splits off the start of a character at the end of
// text whose remaining bytes have not arrived.
func splitIncompleteRune(text string) (complete, rest string) {
	for index := len(text) - 1; index >= 0 && index >= len(text)-utf8.UTFMax; index-- {
		if utf8.RuneStart(text[index]) {
			if !utf8.FullRuneInString(text[index:]) {
				return text[:index], text[index:]
			}
			break
		}
	}
	return text, ""
}

// close delivers every event before the turn's response is returned.
func (f *eventFeed) close() {
	if f == nil {
		return
	}
	f.mu.Lock()
	f.closed = true
	f.mu.Unlock()
	f.poke()
	<-f.done
}
