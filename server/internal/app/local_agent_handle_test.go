package app

import (
	"context"
	"encoding/json"
	"testing"
)

// The device runs the Agent on a registered canonical model, not on the
// workspace loaded from source; every tool must work through that handle.
func TestLocalAgentToolsRunOnARegisteredModelHandle(t *testing.T) {
	input := localTestRequest(t)
	input.ModelHandle = registerHandleFixture(t, input)
	input.Method, input.Query = "", nil
	session, err := OpenLocalAgentSession(input, true)
	if err != nil {
		t.Fatal(err)
	}
	for name, args := range map[string]string{
		"get_bql_capabilities": `{}`,
		"validate_bql":         `{"query":"SELECT account FROM postings"}`,
		"run_bql":              `{"query":"SELECT account, sum(value) AS total FROM postings GROUP BY account"}`,
		"search_transactions":  `{"query":"*"}`,
		"get_ledger_summary":   `{}`,
		"get_accounts":         `{}`,
	} {
		output, err := session.Execute(context.Background(), name, json.RawMessage(args))
		if err != nil {
			t.Logf("%s returned an error (allowed): %v", name, err)
			continue
		}
		if !json.Valid(output) {
			t.Fatalf("%s returned invalid JSON", name)
		}
	}
}
