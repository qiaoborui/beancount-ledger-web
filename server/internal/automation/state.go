package automation

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// State is the scheduler's memory, kept in state.json on the record branch
// so the phone can show when each task last ran.
type State struct {
	Version int                   `json:"version"`
	Tasks   map[string]*TaskState `json:"tasks"`
}

// TaskState is one task's progress. Slots are the planned run times; a slot
// runs at most once, plus the retries of its Agent part.
type TaskState struct {
	// LastSlot is the newest planned time this task has been handled for:
	// run, or skipped because the task was created after it.
	LastSlot time.Time `json:"lastSlot"`
	// LastRunID and LastStatus describe the newest run, if any.
	LastRunID  string    `json:"lastRunId,omitempty"`
	LastStatus string    `json:"lastStatus,omitempty"`
	LastRunAt  time.Time `json:"lastRunAt,omitzero"`
	// Retry is set while the Agent part of the newest run failed and may
	// still be tried again.
	Retry *RetryState `json:"retry,omitempty"`
	// Known are the audit fingerprints already reported, so a notification
	// only counts new findings.
	Known []string `json:"known,omitempty"`
	// FailureNotifiedOn is the local day of the last failure notification;
	// failures are announced at most once a day per task.
	FailureNotifiedOn string `json:"failureNotifiedOn,omitempty"`
}

// RetryState schedules another attempt of a degraded run.
type RetryState struct {
	RunID    string    `json:"runId"`
	Slot     time.Time `json:"slot"`
	Attempts int       `json:"attempts"`
	NextAt   time.Time `json:"nextAt"`
}

const stateFile = "state.json"

func loadState(dir string) (*State, error) {
	data, err := os.ReadFile(filepath.Join(dir, stateFile))
	if errors.Is(err, os.ErrNotExist) {
		return &State{Version: 1, Tasks: map[string]*TaskState{}}, nil
	}
	if err != nil {
		return nil, err
	}
	var state State
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, err
	}
	if state.Tasks == nil {
		state.Tasks = map[string]*TaskState{}
	}
	return &state, nil
}

func (s *State) save(dir string) error {
	return writeJSON(filepath.Join(dir, stateFile), s)
}

func writeJSON(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}

// mergeKnown adds new fingerprints and keeps only those still reported, so
// a finding that was fixed and comes back counts as new again.
func mergeKnown(current []string) []string {
	out := append([]string(nil), current...)
	sort.Strings(out)
	return out
}
