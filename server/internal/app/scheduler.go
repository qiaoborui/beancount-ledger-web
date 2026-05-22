package app

import (
	"log"
	"strconv"
	"strings"
	"time"
)

func StartLedgerScheduler(cfg Config) {
	if !gitSchedulerEnabled() {
		return
	}
	pullInterval := schedulerInterval("LEDGER_GIT_PULL_INTERVAL_MINUTES", 15)
	commitInterval := schedulerInterval("LEDGER_GIT_COMMIT_INTERVAL_MINUTES", 60)
	if pullInterval <= 0 && commitInterval <= 0 {
		log.Printf("[ledger-scheduler] disabled by non-positive intervals")
		return
	}
	if pullInterval > 0 {
		go runSchedulerLoop("pull", pullInterval, 1500*time.Millisecond, func() (string, error) {
			if gitRemoteDisabled() {
				return "Git remote sync disabled\n", nil
			}
			return gitLedgerOutput(cfg, "pull", "--rebase")
		})
	}
	if commitInterval > 0 {
		go runSchedulerLoop("commit-push", commitInterval, commitInterval, func() (string, error) {
			return ledgerGitCommitPullPush(cfg, "chore: autosave ledger")
		})
	}
	log.Printf("[ledger-scheduler] started pull=%sm commit=%sm", minutesForLog(pullInterval), minutesForLog(commitInterval))
}

func runSchedulerLoop(name string, interval time.Duration, initialDelay time.Duration, job func() (string, error)) {
	if initialDelay > 0 {
		timer := time.NewTimer(initialDelay)
		<-timer.C
		runSchedulerJob(name, job)
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for range ticker.C {
		runSchedulerJob(name, job)
	}
}

func runSchedulerJob(name string, job func() (string, error)) {
	output, err := job()
	if err != nil {
		log.Printf("[ledger-scheduler] %s failed: %v", name, err)
		return
	}
	log.Printf("[ledger-scheduler] %s ok\n%s", name, output)
}

func ledgerGitCommitPullPush(cfg Config, message string) (string, error) {
	trackedPaths := ledgerGitTrackedPathspecs(cfg)
	before, err := gitLedger(cfg, append([]string{"status", "--short", "--"}, trackedPaths...)...)
	if err != nil {
		return "", err
	}
	beforeChanges := parseGitChanges(before)
	if len(beforeChanges) == 0 {
		return "No ledger changes to commit.", nil
	}
	if _, err := gitLedgerOutput(cfg, append([]string{"add", "--"}, trackedPaths...)...); err != nil {
		return "", err
	}
	commitOut, err := gitLedgerOutput(cfg, append([]string{"commit", "-m", message, "--"}, trackedPaths...)...)
	if err != nil {
		return "", err
	}
	output := commitOut
	if gitRemoteDisabled() {
		return output + "\nGit remote sync disabled\n", nil
	}
	pullOut, pullErr := gitLedgerOutput(cfg, "pull", "--rebase", "--autostash")
	pushOut, pushErr := gitLedgerOutput(cfg, "push")
	output += pullOut + pushOut
	if pullErr != nil {
		return output, pullErr
	}
	if pushErr != nil {
		return output, pushErr
	}
	return output, nil
}

func gitSchedulerEnabled() bool {
	raw := strings.TrimSpace(strings.ToLower(env("LEDGER_GIT_SCHEDULER", "false")))
	return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
}

func schedulerInterval(name string, fallbackMinutes int) time.Duration {
	raw := strings.TrimSpace(env(name, strconv.Itoa(fallbackMinutes)))
	minutes, err := strconv.ParseFloat(raw, 64)
	if err != nil || minutes <= 0 {
		return 0
	}
	return time.Duration(minutes * float64(time.Minute))
}

func minutesForLog(duration time.Duration) string {
	if duration <= 0 {
		return "0"
	}
	return strconv.FormatFloat(duration.Minutes(), 'f', -1, 64)
}
