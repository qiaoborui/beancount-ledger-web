package mobileagent

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"github.com/MichaelKinsy/PiG/ai"
)

// appSettingsJSON is the snapshot the shell sends, spelled out exactly as the
// Swift encoder writes it. The two sides must agree on every key and value
// shape: the request decoder refuses unknown fields, and the shell applies the
// sections this side names.
const appSettingsJSON = `{
  "overview": {"sections": ["retention", "periodStats", "spendingTrend", "spendingCategories",
    "creditCards", "topPayees", "incomeBreakdown", "balanceSheet", "currencyExposure"]},
  "tabs": {"tabs": ["overview", "transactions", "accounts"]},
  "valuation": {"currency": "CNY"},
  "reminders": {
    "bookkeeping": {"enabled": true, "time": "21:30", "repeat": "daily", "days": [1, 2, 3, 4, 5, 6, 7],
      "skipsRecordedDays": true},
    "imports": {"enabled": false, "cadence": "weekly", "weekday": 1, "day": 1, "time": "20:00"}
  },
  "reports": {
    "weekly": {"enabled": false, "weekday": 2, "time": "09:00"},
    "monthly": {"enabled": false, "day": 1, "time": "09:00"},
    "importReminderBeforeReport": true,
    "firstWeekday": 2,
    "sections": [{"id": "overview", "visible": true}, {"id": "categories", "visible": true},
      {"id": "daily", "visible": true}, {"id": "largest", "visible": true},
      {"id": "coverage", "visible": true}, {"id": "assistant", "visible": true}]
  }
}`

func decodeAppSettings(t *testing.T, text string) appSettingsV1 {
	t.Helper()
	var settings appSettingsV1
	if err := json.Unmarshal([]byte(text), &settings); err != nil {
		t.Fatalf("decode settings: %v", err)
	}
	return settings
}

// shellAppSettings is the snapshot above, valid and normalized.
func shellAppSettings(t *testing.T) appSettingsV1 {
	t.Helper()
	settings := decodeAppSettings(t, appSettingsJSON).normalized()
	if err := settings.validate(); err != nil {
		t.Fatalf("the shell's snapshot does not validate: %v", err)
	}
	return settings
}

func openShellSettings(t *testing.T) *appSettingsSession {
	t.Helper()
	settings := shellAppSettings(t)
	session := openAppSettings(&settings)
	if session == nil {
		t.Fatal("the shell's snapshot opened no settings session")
	}
	return session
}

func TestAppSettingsSnapshotFromTheShellValidates(t *testing.T) {
	settings := shellAppSettings(t)
	if settings.Valuation.Currency != "CNY" || !settings.Reminders.Bookkeeping.Enabled ||
		settings.Reminders.Bookkeeping.Time != "21:30" || settings.Reminders.Imports.Cadence != "weekly" ||
		len(settings.Overview.Sections) != len(appOverviewSections) || len(settings.Reports.Sections) != len(appReportSections) {
		t.Fatalf("snapshot = %+v", settings)
	}
	// A daily reminder's days follow from its repeat, whatever the shell sent.
	settings.Reminders.Bookkeeping.Days = nil
	if days := settings.normalized().Reminders.Bookkeeping.Days; len(days) != 7 {
		t.Fatalf("daily days = %v", days)
	}
}

func TestAppSettingsUpdateAcceptsEverySection(t *testing.T) {
	cases := []struct {
		name   string
		update string
		check  func(t *testing.T, settings appSettingsV1)
	}{
		{"overview", `{"overview": {"sections": ["spendingCategories", "retention"]}}`,
			func(t *testing.T, settings appSettingsV1) {
				if strings.Join(settings.Overview.Sections, ",") != "spendingCategories,retention" {
					t.Fatalf("overview = %v", settings.Overview.Sections)
				}
			}},
		{"tabs", `{"tabs": {"tabs": ["overview", "search"]}}`,
			func(t *testing.T, settings appSettingsV1) {
				if strings.Join(settings.Tabs.Tabs, ",") != "overview,search" {
					t.Fatalf("tabs = %v", settings.Tabs.Tabs)
				}
			}},
		{"valuation", `{"valuation": {"currency": "usd"}}`,
			func(t *testing.T, settings appSettingsV1) {
				if settings.Valuation.Currency != "USD" {
					t.Fatalf("currency = %q", settings.Valuation.Currency)
				}
			}},
		{"reminder time and repeat", `{"reminders": {"bookkeeping": {"time": "22:00", "repeat": "weekdays"}}}`,
			func(t *testing.T, settings appSettingsV1) {
				bookkeeping := settings.Reminders.Bookkeeping
				if bookkeeping.Time != "22:00" || bookkeeping.Repeat != "weekdays" ||
					!slices.Equal(bookkeeping.Days, []int{2, 3, 4, 5, 6}) {
					t.Fatalf("bookkeeping = %+v", bookkeeping)
				}
			}},
		{"custom weekdays", `{"reminders": {"bookkeeping": {"repeat": "custom", "days": [6, 2, 7]}}}`,
			func(t *testing.T, settings appSettingsV1) {
				if !slices.Equal(settings.Reminders.Bookkeeping.Days, []int{2, 6, 7}) {
					t.Fatalf("days = %v", settings.Reminders.Bookkeeping.Days)
				}
			}},
		{"import reminder", `{"reminders": {"imports": {"enabled": true, "cadence": "monthly", "day": -1, "time": "08:15"}}}`,
			func(t *testing.T, settings appSettingsV1) {
				imports := settings.Reminders.Imports
				if !imports.Enabled || imports.Cadence != "monthly" || imports.Day != -1 || imports.Time != "08:15" {
					t.Fatalf("imports = %+v", imports)
				}
			}},
		{"reports", `{"reports": {"weekly": {"enabled": true, "weekday": 1, "time": "18:30"}, "monthly": {"enabled": true, "day": 28},
			"importReminderBeforeReport": false, "firstWeekday": 1}}`,
			func(t *testing.T, settings appSettingsV1) {
				reports := settings.Reports
				if !reports.Weekly.Enabled || reports.Weekly.Weekday != 1 || reports.Weekly.Time != "18:30" ||
					!reports.Monthly.Enabled || reports.Monthly.Day != 28 || reports.ImportReminderBeforeReport ||
					reports.FirstWeekday != 1 {
					t.Fatalf("reports = %+v", reports)
				}
			}},
		{"report sections", `{"reports": {"sections": [{"id": "categories", "visible": true}, {"id": "overview", "visible": false},
			{"id": "daily", "visible": true}, {"id": "largest", "visible": true}, {"id": "coverage", "visible": false},
			{"id": "assistant", "visible": true}]}}`,
			func(t *testing.T, settings appSettingsV1) {
				sections := settings.Reports.Sections
				if len(sections) != 6 || sections[0].ID != "categories" || sections[1].Visible {
					t.Fatalf("sections = %+v", sections)
				}
			}},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			session := openShellSettings(t)
			update := testCase.update
			text, err := session.apply(json.RawMessage(update))
			if err != nil {
				t.Fatalf("apply %s: %v", update, err)
			}
			if testCase.check != nil {
				testCase.check(t, session.snapshot())
			}
			if !strings.Contains(text, "已更新") {
				t.Fatalf("result = %q", text)
			}
			// Every accepted update leaves settings that validate again.
			if err := session.snapshot().validate(); err != nil {
				t.Fatalf("settings after %s: %v", update, err)
			}
		})
	}
}

func TestAppSettingsUpdateRejectsUnknownFieldsAndBadValues(t *testing.T) {
	cases := map[string]string{
		"unknown section":            `{"theme": {"dark": true}}`,
		"unknown field":              `{"reminders": {"bookkeeping": {"at": "22:00"}}}`,
		"unknown nested field":       `{"reports": {"weekly": {"weekday": 2, "repeat": "weekly"}}}`,
		"number as time":             `{"reminders": {"bookkeeping": {"time": 2200}}}`,
		"bad clock hour":             `{"reminders": {"bookkeeping": {"time": "24:00"}}}`,
		"bad clock form":             `{"reminders": {"bookkeeping": {"time": "9:00"}}}`,
		"bad repeat":                 `{"reminders": {"bookkeeping": {"repeat": "weekly"}}}`,
		"custom without days":        `{"reminders": {"bookkeeping": {"repeat": "custom", "days": []}}}`,
		"day out of range":           `{"reminders": {"bookkeeping": {"repeat": "custom", "days": [0, 2]}}}`,
		"repeated day":               `{"reminders": {"bookkeeping": {"repeat": "custom", "days": [2, 2]}}}`,
		"bad cadence":                `{"reminders": {"imports": {"cadence": "yearly"}}}`,
		"bad month day":              `{"reminders": {"imports": {"cadence": "monthly", "day": 31}}}`,
		"bad weekday":                `{"reports": {"weekly": {"weekday": 8}}}`,
		"bad first weekday":          `{"reports": {"firstWeekday": 3}}`,
		"bad currency":               `{"valuation": {"currency": "元"}}`,
		"empty overview":             `{"overview": {"sections": []}}`,
		"unknown overview section":   `{"overview": {"sections": ["budget"]}}`,
		"duplicate overview section": `{"overview": {"sections": ["retention", "retention"]}}`,
		"too many tabs":              `{"tabs": {"tabs": ["overview", "transactions", "accounts", "search"]}}`,
		"settings tab":               `{"tabs": {"tabs": ["settings"]}}`,
		"missing report section":     `{"reports": {"sections": [{"id": "overview", "visible": true}]}}`,
		"unknown report section":     `{"reports": {"sections": [{"id": "summary", "visible": true}]}}`,
	}
	for name, update := range cases {
		t.Run(name, func(t *testing.T) {
			session := openShellSettings(t)
			before := session.snapshot()
			if _, err := session.apply(json.RawMessage(update)); err == nil {
				t.Fatalf("%s was accepted", update)
			}
			// A refused update changes nothing.
			if after := session.snapshot(); len(changedSections(before, after)) != 0 || session.result() != nil {
				t.Fatalf("%s changed the settings anyway: %+v", update, after)
			}
		})
	}
	// The error says what to do instead.
	session := openShellSettings(t)
	_, err := session.apply(json.RawMessage(`{"reminders": {"bookkeeping": {"time": "9:00"}}}`))
	if err == nil || !strings.Contains(err.Error(), "HH:MM") {
		t.Fatalf("error = %v", err)
	}
}

func TestAppSettingsUpdateOfTheSameValuesChangesNothing(t *testing.T) {
	session := openShellSettings(t)
	current := session.snapshot()
	encoded, err := json.Marshal(current)
	if err != nil {
		t.Fatal(err)
	}
	text, err := session.apply(encoded)
	if err != nil {
		t.Fatalf("apply the current settings: %v", err)
	}
	if !strings.Contains(text, "没有变化") {
		t.Fatalf("result = %q", text)
	}
	if result := session.result(); result != nil {
		t.Fatalf("unchanged settings reported a change: %+v", result)
	}

	// One field is enough to count as a change, and the sections are listed in
	// the shell's order however the tool calls were ordered.
	if _, err := session.apply(json.RawMessage(`{"valuation": {"currency": "HKD"}}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := session.apply(json.RawMessage(`{"reminders": {"bookkeeping": {"time": "22:00"}}}`)); err != nil {
		t.Fatal(err)
	}
	result := session.result()
	if result == nil || strings.Join(result.ChangedSections, ",") != "valuation,reminders" {
		t.Fatalf("result = %+v", result)
	}
	if result.Snapshot.Valuation.Currency != "HKD" || result.Snapshot.Reminders.Bookkeeping.Time != "22:00" {
		t.Fatalf("snapshot = %+v", result.Snapshot)
	}
}

func TestAppSettingsToolsReadTheSnapshot(t *testing.T) {
	session := openShellSettings(t)
	text, err := session.read("")
	if err != nil {
		t.Fatal(err)
	}
	var read struct {
		Settings appSettingsV1  `json:"settings"`
		Allowed  map[string]any `json:"allowed"`
	}
	if err := json.Unmarshal([]byte(text), &read); err != nil {
		t.Fatalf("read result is not JSON: %v", err)
	}
	if read.Settings.Reminders.Bookkeeping.Time != "21:30" || read.Settings.Valuation.Currency != "CNY" {
		t.Fatalf("settings = %+v", read.Settings)
	}
	for _, section := range appSettingsNames {
		if _, ok := read.Allowed[section]; !ok {
			t.Fatalf("allowed values miss %s: %v", section, read.Allowed)
		}
	}
	if overview, ok := read.Allowed["overview"].(map[string]any); !ok || len(overview["sections"].([]any)) != len(appOverviewSections) {
		t.Fatalf("allowed overview = %v", read.Allowed["overview"])
	}

	one, err := session.read("tabs")
	if err != nil {
		t.Fatal(err)
	}
	var section map[string]map[string]any
	if err := json.Unmarshal([]byte(one), &section); err != nil {
		t.Fatalf("section result is not JSON: %v", err)
	}
	if len(section["settings"]) != 1 || section["settings"]["tabs"] == nil {
		t.Fatalf("section result = %s", one)
	}
	if _, err := session.read("theme"); err == nil || !strings.Contains(err.Error(), "tabs") {
		t.Fatalf("unknown section error = %v", err)
	}
}

func TestRunTurnOffersAppSettingsToolsAndReturnsTheChange(t *testing.T) {
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxToolCall("update_app_settings", map[string]any{"updates": map[string]any{
				"reminders": map[string]any{"bookkeeping": map[string]any{"time": "22:00", "repeat": "weekdays"}}}},
				&ai.FauxToolCallOptions{ID: "call_settings"}),
		}}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("已把记账提醒改到工作日 22:00。")}}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "提醒改到 22 点，只在工作日",
		"appSettings": json.RawMessage(appSettingsJSON)})
	if !response.OK || len(response.ToolCalls) != 1 || response.ToolCalls[0].IsError {
		t.Fatalf("unexpected response: %+v", response)
	}
	if response.AppSettings == nil {
		t.Fatal("the turn changed settings but returned none")
	}
	if strings.Join(response.AppSettings.ChangedSections, ",") != "reminders" {
		t.Fatalf("changed sections = %v", response.AppSettings.ChangedSections)
	}
	bookkeeping := response.AppSettings.Snapshot.Reminders.Bookkeeping
	if bookkeeping.Time != "22:00" || bookkeeping.Repeat != "weekdays" || len(bookkeeping.Days) != 5 {
		t.Fatalf("bookkeeping = %+v", bookkeeping)
	}
	if response.AppSettings.Snapshot.Valuation.Currency != "CNY" {
		t.Fatalf("an untouched section moved: %+v", response.AppSettings.Snapshot)
	}
}

func TestRunTurnWithoutSettingsChangeReturnsNone(t *testing.T) {
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxToolCall("get_app_settings", map[string]any{}, &ai.FauxToolCallOptions{ID: "call_read"}),
		}}),
		ai.FauxStaticStep(ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("提醒是每天 21:30。")}}),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "现在几点提醒？",
		"appSettings": json.RawMessage(appSettingsJSON)})
	if !response.OK || response.AppSettings != nil {
		t.Fatalf("a read returned a change: %+v", response.AppSettings)
	}
}

func TestOnboardingAndFailedTurnsOfferNoAppSettings(t *testing.T) {
	// Onboarding has no settings page behind it: the tool is not in the list.
	useFaux(t,
		onboardingStep(ai.FauxToolCall("update_app_settings", map[string]any{"updates": map[string]any{
			"valuation": map[string]any{"currency": "USD"}}}, nil)),
		onboardingStep(ai.FauxText("先建好账本再说。")),
	)
	response := runTurnFor(t, map[string]any{"version": 1, "provider": "faux", "model": "faux-1", "message": "用美元",
		"onboarding": map[string]any{"draft": defaultOnboardingDraft(), "ready": false}})
	if !response.OK || len(response.ToolCalls) != 1 || !response.ToolCalls[0].IsError {
		t.Fatalf("onboarding turn = %+v", response)
	}
	if response.AppSettings != nil {
		t.Fatalf("onboarding returned settings: %+v", response.AppSettings)
	}

	// A failed turn drops the change: the shell only applies an answered one.
	useFaux(t,
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonToolUse), Content: []ai.FauxContentBlock{
			ai.FauxToolCall("update_app_settings", map[string]any{"updates": map[string]any{
				"valuation": map[string]any{"currency": "USD"}}}, &ai.FauxToolCallOptions{ID: "call_settings"}),
		}}),
		ai.FauxStaticStep(ai.FauxResponse{StopReason: string(ai.StopReasonError), ErrorMessage: "provider fell over"}),
	)
	failed := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "用美元看", "appSettings": json.RawMessage(appSettingsJSON)})
	if failed.OK || failed.AppSettings != nil {
		t.Fatalf("a failed turn returned settings: %+v", failed)
	}
}

func TestAnUnreadableSettingsSnapshotLeavesTheTurnAlone(t *testing.T) {
	var asked string
	useFaux(t,
		ai.FauxFactoryStep(func(request ai.TranscriptContext, _ ai.StreamOptions, _ *ai.FauxProviderState, _ *ai.Model) (ai.AssistantMessage, error) {
			asked = lastUserText(request)
			return ai.FauxResponse{Content: []ai.FauxContentBlock{ai.FauxText("一月餐饮 25 元。")}}.AssistantMessage(), nil
		}),
	)
	broken := strings.Replace(appSettingsJSON, `"currency": "CNY"`, `"currency": "元"`, 1)
	response := runTurnFor(t, map[string]any{"version": 1, "workspaceRoot": committedWorkspace(t),
		"provider": "faux", "model": "faux-1", "message": "一月花了多少", "appSettings": json.RawMessage(broken)})
	if !response.OK || response.Reply != "一月餐饮 25 元。" || response.AppSettings != nil {
		t.Fatalf("turn = %+v", response)
	}
	if asked != "一月花了多少" {
		t.Fatalf("question = %q", asked)
	}
}
