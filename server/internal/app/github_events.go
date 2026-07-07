package app

import (
	"context"
	"log"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/google/go-github/v74/github"
)

// StartGitHubEventsPoller polls GitHub repository events to detect pushes
// and triggers an immediate ledger sync, giving much lower latency than
// the periodic scheduler while requiring no public-facing webhook URL.
func StartGitHubEventsPoller(cfg Config) {
	StartGitHubEventsPollerWithAfterSync(cfg, nil)
}

func StartGitHubEventsPollerWithAfterSync(cfg Config, afterSync func()) {
	owner, repo, token := resolveGitHubPollAuth(cfg)
	if owner == "" || repo == "" || token == "" {
		return
	}
	interval := time.Duration(cfg.LedgerGitEventsPollSeconds) * time.Second
	if interval <= 0 {
		interval = 30 * time.Second
	}
	go runGitHubEventsPoll(cfg, owner, repo, token, interval, afterSync)
	log.Printf("[github-events] started owner=%s repo=%s branch=%s interval=%s",
		owner, repo, cfg.LedgerGitBranch, interval)
}

// resolveGitHubPollAuth resolves the owner, repo, and token needed for the
// Events API. It prefers explicit env vars and falls back to parsing the
// LEDGER_GIT_REMOTE URL when those are not set.
func resolveGitHubPollAuth(cfg Config) (owner, repo, token string) {
	if !remoteGitEnabled(cfg) {
		return "", "", ""
	}
	owner = cfg.LedgerGitHubOwner
	repo = cfg.LedgerGitHubRepo
	token = cfg.LedgerGitHubToken

	if owner == "" || repo == "" || token == "" {
		o, r, t := parseGitHubRemote(cfg.LedgerGitRemote)
		if owner == "" {
			owner = o
		}
		if repo == "" {
			repo = r
		}
		if token == "" {
			token = t
		}
	}
	return owner, repo, token
}

// parseGitHubRemote extracts owner, repo, and token from a GitHub remote URL.
// Supports both https://token@github.com/owner/repo.git and
// https://x-access-token:token@github.com/owner/repo.git formats.
func parseGitHubRemote(remote string) (owner, repo, token string) {
	if remote == "" {
		return "", "", ""
	}
	u, err := url.Parse(remote)
	if err != nil {
		return "", "", ""
	}
	if u.User != nil {
		token = u.User.Username()
		if pass, ok := u.User.Password(); ok {
			token = pass
			if u.User.Username() == "x-access-token" {
				// ok — token is in the password
			} else {
				token = u.User.Username()
			}
		}
	}
	path := strings.TrimPrefix(u.Path, "/")
	path = strings.TrimSuffix(path, ".git")
	parts := strings.SplitN(path, "/", 2)
	if len(parts) == 2 {
		owner = parts[0]
		repo = parts[1]
	}
	return owner, repo, token
}

func runGitHubEventsPoll(cfg Config, owner, repo, token string, interval time.Duration, afterSync func()) {
	client := github.NewClient(nil).WithAuthToken(token)
	if cfg.LedgerGitHubAPIURL != "" {
		if u, err := url.Parse(strings.TrimRight(cfg.LedgerGitHubAPIURL, "/") + "/"); err == nil {
			client.BaseURL = u
		}
	}

	branch := cfg.LedgerGitBranch
	if branch == "" {
		branch = "main"
	}
	var lastEventID int64

	// Let the server settle before the first poll.
	time.Sleep(3 * time.Second)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	ctx := context.Background()
	for range ticker.C {
		newest, triggered, err := pollRepositoryEvents(ctx, client, owner, repo, branch, lastEventID)
		if triggered && err == nil {
			publishJobStatus("git.pull", "running", "")
			if syncErr := syncLedgerNow(cfg); syncErr != nil {
				log.Printf("[github-events] sync failed: %v", syncErr)
				publishJobStatus("git.pull", "error", syncErr.Error())
			} else {
				log.Printf("[github-events] sync ok")
				publishJobStatus("git.pull", "ok", "Synced via GitHub events poll.")
				publishLedgerUpdated(cfg, "github-events")
				publishGitStatus(cfg, "github-events")
				if afterSync != nil {
					afterSync()
				}
			}
		}
		if newest > lastEventID {
			lastEventID = newest
		}
	}
}

// pollRepositoryEvents fetches the most recent repository events and returns
// the newest event ID seen and whether a push to the target branch was found.
func pollRepositoryEvents(ctx context.Context, client *github.Client, owner, repo, branch string, lastEventID int64) (int64, bool, error) {
	events, _, err := client.Activity.ListRepositoryEvents(ctx, owner, repo, &github.ListOptions{PerPage: 5})
	if err != nil {
		log.Printf("[github-events] poll error: %v", err)
		return lastEventID, false, err
	}

	newest := lastEventID
	triggered := false
	for _, evt := range events {
		eid, err := strconv.ParseInt(evt.GetID(), 10, 64)
		if err != nil {
			continue
		}
		if eid > newest {
			newest = eid
		}
		if eid <= lastEventID {
			continue
		}
		if evt.GetType() != "PushEvent" {
			continue
		}
		payload, err := evt.ParsePayload()
		if err != nil {
			continue
		}
		push, ok := payload.(*github.PushEvent)
		if !ok {
			continue
		}
		refBranch := strings.TrimPrefix(push.GetRef(), "refs/heads/")
		if refBranch == branch {
			log.Printf("[github-events] push detected on %s, syncing ledger", refBranch)
			triggered = true
			break
		}
	}
	return newest, triggered, nil
}
