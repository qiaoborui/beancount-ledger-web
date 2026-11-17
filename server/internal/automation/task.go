// Package automation runs the scheduled tasks of a ledger: Markdown files
// under automations/ that name a schedule and hold a prompt. A tick finds
// the tasks that are due, runs the deterministic audit and then the ledger
// Agent headlessly against a pinned commit, and records each run on a
// separate branch the phone pulls. A run never writes the ledger: any fix
// is a draft patch the user reviews on the phone.
package automation

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// TaskDir is where a ledger keeps its scheduled tasks.
const TaskDir = "automations"

var taskIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)

// Task is one automations/<id>.md file.
type Task struct {
	ID       string
	Name     string
	Schedule Schedule
	Location *time.Location
	Enabled  bool
	// Model and Thinking override the runner's defaults when set.
	Model    string
	Thinking string
	// Audit runs the deterministic checks first and hands their findings
	// to the Agent; on by default.
	Audit  bool
	Prompt string
}

type taskFrontmatter struct {
	Name     string `yaml:"name"`
	Schedule string `yaml:"schedule"`
	Timezone string `yaml:"timezone"`
	Enabled  *bool  `yaml:"enabled"`
	Model    string `yaml:"model"`
	Thinking string `yaml:"thinking"`
	Audit    *bool  `yaml:"audit"`
}

// ParseTask reads one task file. defaultLocation is used when the file
// names no timezone.
func ParseTask(id string, data []byte, defaultLocation *time.Location) (Task, error) {
	if !taskIDPattern.MatchString(id) {
		return Task{}, fmt.Errorf("task id %q must be lowercase letters, digits and dashes", id)
	}
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	if !strings.HasPrefix(text, "---\n") {
		return Task{}, errors.New("task file must start with a --- frontmatter block")
	}
	rest := text[len("---\n"):]
	end := strings.Index(rest, "\n---")
	if end < 0 {
		return Task{}, errors.New("task frontmatter is not closed with ---")
	}
	var front taskFrontmatter
	decoder := yaml.NewDecoder(bytes.NewReader([]byte(rest[:end])))
	decoder.KnownFields(true)
	if err := decoder.Decode(&front); err != nil {
		return Task{}, fmt.Errorf("task frontmatter: %w", err)
	}
	body := rest[end+len("\n---"):]
	body = strings.TrimPrefix(strings.TrimLeft(body, "-"), "\n")
	task := Task{ID: id, Name: strings.TrimSpace(front.Name), Enabled: true, Audit: true,
		Model: strings.TrimSpace(front.Model), Thinking: strings.TrimSpace(front.Thinking), Prompt: strings.TrimSpace(body)}
	if task.Name == "" {
		task.Name = id
	}
	if front.Enabled != nil {
		task.Enabled = *front.Enabled
	}
	if front.Audit != nil {
		task.Audit = *front.Audit
	}
	if task.Prompt == "" {
		return Task{}, errors.New("task has no prompt")
	}
	schedule, err := ParseSchedule(front.Schedule)
	if err != nil {
		return Task{}, err
	}
	task.Schedule = schedule
	task.Location = defaultLocation
	if front.Timezone != "" {
		location, err := time.LoadLocation(front.Timezone)
		if err != nil {
			return Task{}, fmt.Errorf("timezone: %w", err)
		}
		task.Location = location
	}
	if task.Location == nil {
		task.Location = time.Local
	}
	return task, nil
}

// LoadTasks reads every automations/*.md of a checkout. A file that does
// not parse is reported, not fatal: one typo must not stop the other tasks.
func LoadTasks(root string, defaultLocation *time.Location) ([]Task, map[string]error, error) {
	entries, err := os.ReadDir(filepath.Join(root, TaskDir))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	var tasks []Task
	problems := map[string]error{}
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".md") || strings.HasPrefix(name, ".") || strings.EqualFold(name, "README.md") {
			continue
		}
		id := strings.TrimSuffix(name, ".md")
		data, err := os.ReadFile(filepath.Join(root, TaskDir, name))
		if err != nil {
			problems[id] = err
			continue
		}
		task, err := ParseTask(id, data, defaultLocation)
		if err != nil {
			problems[id] = err
			continue
		}
		tasks = append(tasks, task)
	}
	sort.Slice(tasks, func(i, j int) bool { return tasks[i].ID < tasks[j].ID })
	return tasks, problems, nil
}

// Schedule is when a task runs, in the task's own timezone:
//
//	hourly            every hour on the hour
//	hourly :15        every hour at minute 15
//	daily 21:00
//	weekly mon,thu 09:00
//	monthly 1 09:00   (a day past the month's end runs on its last day)
type Schedule struct {
	Kind   string
	Hour   int
	Minute int
	// Weekdays for weekly, DayOfMonth for monthly.
	Weekdays   []time.Weekday
	DayOfMonth int
	text       string
}

func (s Schedule) String() string { return s.text }

var weekdayNames = map[string]time.Weekday{"sun": time.Sunday, "mon": time.Monday, "tue": time.Tuesday,
	"wed": time.Wednesday, "thu": time.Thursday, "fri": time.Friday, "sat": time.Saturday}

func parseClock(text string) (int, int, error) {
	parts := strings.Split(text, ":")
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("time %q must be HH:MM", text)
	}
	hour, errH := strconv.Atoi(parts[0])
	minute, errM := strconv.Atoi(parts[1])
	if errH != nil || errM != nil || hour < 0 || hour > 23 || minute < 0 || minute > 59 {
		return 0, 0, fmt.Errorf("time %q must be HH:MM", text)
	}
	return hour, minute, nil
}

// ParseSchedule reads the schedule line of a task.
func ParseSchedule(text string) (Schedule, error) {
	fields := strings.Fields(strings.ToLower(strings.TrimSpace(text)))
	invalid := fmt.Errorf("schedule %q: use hourly, daily HH:MM, weekly mon,thu HH:MM or monthly D HH:MM", text)
	if len(fields) == 0 {
		return Schedule{}, invalid
	}
	s := Schedule{Kind: fields[0], text: strings.Join(fields, " ")}
	var err error
	switch {
	case s.Kind == "hourly" && len(fields) == 1:
	case s.Kind == "hourly" && len(fields) == 2 && strings.HasPrefix(fields[1], ":"):
		s.Minute, err = strconv.Atoi(fields[1][1:])
		if err != nil || s.Minute < 0 || s.Minute > 59 {
			return Schedule{}, invalid
		}
	case s.Kind == "daily" && len(fields) == 2:
		s.Hour, s.Minute, err = parseClock(fields[1])
	case s.Kind == "weekly" && len(fields) == 3:
		for _, name := range strings.Split(fields[1], ",") {
			day, ok := weekdayNames[strings.TrimSpace(name)[:min(3, len(strings.TrimSpace(name)))]]
			if !ok {
				return Schedule{}, invalid
			}
			s.Weekdays = append(s.Weekdays, day)
		}
		s.Hour, s.Minute, err = parseClock(fields[2])
	case s.Kind == "monthly" && len(fields) == 3:
		s.DayOfMonth, err = strconv.Atoi(fields[1])
		if err != nil || s.DayOfMonth < 1 || s.DayOfMonth > 31 {
			return Schedule{}, invalid
		}
		s.Hour, s.Minute, err = parseClock(fields[2])
	default:
		return Schedule{}, invalid
	}
	if err != nil {
		return Schedule{}, err
	}
	return s, nil
}

// LatestSlot is the most recent planned run at or before now.
func (s Schedule) LatestSlot(now time.Time, location *time.Location) time.Time {
	local := now.In(location)
	switch s.Kind {
	case "hourly":
		slot := time.Date(local.Year(), local.Month(), local.Day(), local.Hour(), s.Minute, 0, 0, location)
		if slot.After(local) {
			slot = slot.Add(-time.Hour)
		}
		return slot
	case "daily", "weekly":
		for back := 0; back <= 7; back++ {
			day := local.AddDate(0, 0, -back)
			slot := time.Date(day.Year(), day.Month(), day.Day(), s.Hour, s.Minute, 0, 0, location)
			if slot.After(local) {
				continue
			}
			if s.Kind == "daily" || containsWeekday(s.Weekdays, slot.Weekday()) {
				return slot
			}
		}
	case "monthly":
		for back := 0; back <= 2; back++ {
			first := time.Date(local.Year(), local.Month()-time.Month(back), 1, 0, 0, 0, 0, location)
			last := first.AddDate(0, 1, -1).Day()
			slot := time.Date(first.Year(), first.Month(), min(s.DayOfMonth, last), s.Hour, s.Minute, 0, 0, location)
			if !slot.After(local) {
				return slot
			}
		}
	}
	return time.Time{}
}

func containsWeekday(days []time.Weekday, day time.Weekday) bool {
	for _, candidate := range days {
		if candidate == day {
			return true
		}
	}
	return false
}
