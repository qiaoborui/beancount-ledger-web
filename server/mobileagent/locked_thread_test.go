package mobileagent

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"runtime"
	"testing"
)

// Swift calls RunTurnJSON from a cgo callback, whose goroutine is locked to the calling thread.
func TestRunTurnSurvivesALockedCallerThread(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		for _, event := range []string{
			`{"choices":[{"index":0,"delta":{"role":"assistant","content":"Hi"}}]}`,
			`{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`,
		} {
			fmt.Fprintf(w, "data: %s\n\n", event)
			w.(http.Flusher).Flush()
		}
		fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	defer server.Close()
	raw, _ := json.Marshal(map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t), "provider": "custom",
		"model": "my-model", "apiKey": "secret", "message": "hi", "custom": map[string]any{"api": "openai-completions", "baseURL": server.URL}})
	done := make(chan string)
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		done <- RunTurnJSON(string(raw))
	}()
	var response turnResponseV1
	if err := json.Unmarshal([]byte(<-done), &response); err != nil || !response.OK || response.Reply != "Hi" {
		t.Fatalf("turn on a locked thread: %+v %v", response, err)
	}
}
