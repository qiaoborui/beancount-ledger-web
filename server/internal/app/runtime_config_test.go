package app

import (
	"bytes"
	"regexp"
	"strings"
	"testing"
)

func TestRuntimeConfigKeyDerivationIsStableAndScoped(t *testing.T) {
	first, err := deriveRuntimeConfigKey("stable-auth-secret")
	if err != nil {
		t.Fatal(err)
	}
	second, err := deriveRuntimeConfigKey("stable-auth-secret")
	if err != nil {
		t.Fatal(err)
	}
	other, err := deriveRuntimeConfigKey("different-auth-secret")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first, second) {
		t.Fatal("same AUTH_SECRET must derive the same encryption key")
	}
	if bytes.Equal(first, other) {
		t.Fatal("different AUTH_SECRET values must derive different encryption keys")
	}
}

func TestRandomInstallCodeIsHumanReadable(t *testing.T) {
	code, err := randomInstallCode()
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^[A-Z2-7]{6}(?:-[A-Z2-7]{6}){3}$`).MatchString(code) {
		t.Fatalf("install code format=%q", code)
	}
}

func TestGitHubRemoteURLUsesConfiguredEnterpriseHost(t *testing.T) {
	if got := githubRemoteURL("owner", "ledger.git", ""); got != "https://github.com/owner/ledger.git" {
		t.Fatalf("github remote=%q", got)
	}
	if got := githubRemoteURL("owner", "ledger", "https://github.example/api/v3"); got != "https://github.example/owner/ledger.git" {
		t.Fatalf("enterprise remote=%q", got)
	}
}

func TestRuntimeConfigInstallInputValidation(t *testing.T) {
	input := RuntimeConfigInstallInput{
		InstallCode:            "AAAAAA-BBBBBB-CCCCCC-DDDDDD",
		AdminPassword:          "long-enough-password",
		GitHubOwner:            "owner",
		GitHubRepo:             "ledger",
		GitHubBranch:           "main",
		GitHubWriteToken:       "write-token",
		GitHubIndexToken:       "read-token",
		AIProvider:             "openai-compatible",
		AIBaseURL:              "http://localhost:8317/v1",
		AIModel:                "model",
		AIAPIKey:               "key",
		IndexerIntervalSeconds: 60,
		IndexerRetryInitial:    5,
		IndexerRetryMaximum:    60,
	}
	input.normalize()
	if err := input.validate(); err != nil {
		t.Fatal(err)
	}
	input.GitHubIndexToken = ""
	if err := input.validate(); err == nil || !strings.Contains(err.Error(), "separate GitHub") {
		t.Fatalf("error=%v", err)
	}
	input.GitHubIndexToken = input.GitHubWriteToken
	if err := input.validate(); err == nil || !strings.Contains(err.Error(), "must be different") {
		t.Fatalf("error=%v", err)
	}
	input.GitHubIndexToken = "read-token"
	input.GitHubBranch = "--upload-pack=malicious"
	if err := input.validate(); err == nil || !strings.Contains(err.Error(), "valid branch") {
		t.Fatalf("error=%v", err)
	}
}
