package app

import (
	"strings"
	"testing"
)

// Account links that carry no currency still open (the app resolves one),
// but the prompt asks for &currency= whenever the tools reported it.
func TestLocalAgentSystemPromptAccountLinksMentionCurrency(t *testing.T) {
	for _, canEdit := range []bool{false, true} {
		prompt := LocalAgentSystemPrompt(canEdit)
		if !strings.Contains(prompt, "ledger://accounts?account=Expenses:Food") {
			t.Fatalf("canEdit=%v: prompt lost the account link example", canEdit)
		}
		if !strings.Contains(prompt, "&currency=") {
			t.Fatalf("canEdit=%v: prompt does not tell the model to add &currency= to account links", canEdit)
		}
	}
}
