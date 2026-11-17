package automation

import (
	"testing"
	"time"
)

func TestParseTask(t *testing.T) {
	task, err := ParseTask("daily-audit", []byte("---\nname: 每日巡检\nschedule: daily 21:00\ntimezone: Asia/Singapore\nthinking: low\n---\n\n看看账本有没有问题。\n"), time.UTC)
	if err != nil {
		t.Fatal(err)
	}
	if task.Name != "每日巡检" || !task.Enabled || !task.Audit || task.Prompt != "看看账本有没有问题。" ||
		task.Location.String() != "Asia/Singapore" || task.Thinking != "low" {
		t.Fatalf("task = %+v", task)
	}
	for _, bad := range []string{
		"no frontmatter",
		"---\nschedule: daily 21:00\n---\n",
		"---\nschedule: sometimes\n---\nprompt",
		"---\nschedule: daily 21:00\nunknown: 1\n---\nprompt",
	} {
		if _, err := ParseTask("x", []byte(bad), time.UTC); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
	if _, err := ParseTask("Bad_ID", []byte("---\nschedule: hourly\n---\np"), time.UTC); err == nil {
		t.Fatal("accepted a bad id")
	}
}

func TestLatestSlot(t *testing.T) {
	sg, _ := time.LoadLocation("Asia/Singapore")
	now := time.Date(2026, 11, 17, 9, 35, 0, 0, sg) // Tuesday
	cases := map[string]string{
		"hourly":               "2026-11-17 09:00",
		"hourly :45":           "2026-11-17 08:45",
		"daily 21:00":          "2026-11-16 21:00",
		"daily 09:00":          "2026-11-17 09:00",
		"weekly mon,thu 10:00": "2026-11-16 10:00",
		"weekly tue 09:30":     "2026-11-17 09:30",
		"weekly tue 10:00":     "2026-11-10 10:00",
		"monthly 1 08:00":      "2026-11-01 08:00",
		"monthly 31 08:00":     "2026-10-31 08:00",
		"monthly 20 08:00":     "2026-10-20 08:00",
	}
	for text, want := range cases {
		schedule, err := ParseSchedule(text)
		if err != nil {
			t.Fatal(err)
		}
		if got := schedule.LatestSlot(now, sg).Format("2006-01-02 15:04"); got != want {
			t.Errorf("%s: got %s, want %s", text, got, want)
		}
	}
}

// The phone writes task files (LedgerAutomationTask.fileText); this is the
// text LedgerAutomationTasksTests expects it to write.
func TestParseTaskReadsWhatThePhoneWrites(t *testing.T) {
	written := "---\nname: \"周报: 本周 #消费\"\nschedule: weekly mon,thu 09:30\ntimezone: Asia/Singapore\nenabled: false\n" +
		"model: \"auto/deepseek-flash\"\nthinking: low\naudit: false\n---\n\n总结本周。\n\n不要改账本。\n"
	task, err := ParseTask("weekly", []byte(written), time.UTC)
	if err != nil {
		t.Fatal(err)
	}
	if task.Name != "周报: 本周 #消费" || task.Enabled || task.Audit || task.Model != "auto/deepseek-flash" ||
		task.Thinking != "low" || task.Schedule.String() != "weekly mon,thu 09:30" ||
		task.Prompt != "总结本周。\n\n不要改账本。" || task.Location.String() != "Asia/Singapore" {
		t.Fatalf("task = %+v", task)
	}
}
