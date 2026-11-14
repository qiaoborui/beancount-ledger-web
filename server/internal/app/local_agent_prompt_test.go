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

// Writing is the app's decision, taken after validation: the model must not
// describe a change as written, and must not promise the user has to confirm
// every one of them.
func TestLocalAgentSystemPromptDoesNotClaimAWrite(t *testing.T) {
	prompt := LocalAgentSystemPrompt(true)
	if strings.Contains(prompt, "用户点「写入账本」才会真正写入") {
		t.Fatal("prompt still says the change card's button is the only way a change is written")
	}
	for _, want := range []string{"校验通过后会写入", "不能说「已记账」或「已写入」", "删除文件或一次删改很多行时会先让用户确认"} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("prompt lost %q", want)
		}
	}
}
