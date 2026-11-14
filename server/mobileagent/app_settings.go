package mobileagent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"sync"

	"github.com/MichaelKinsy/PiG/agent"
	"github.com/MichaelKinsy/PiG/ai"
)

// The App's own settings — the pages, tabs, reminders and reports the shell
// keeps in UserDefaults — are not files in the ledger, so the ledger tools
// cannot reach them. The shell sends a snapshot of them with every ordinary
// turn and applies the changed sections itself when the turn succeeds; this
// file validates the model's edits and hands the shell back the result. The
// shell's Codable types are the other half of the wire format below, and the
// two must be edited together.

// appSettingsV1 is one snapshot of the App settings, grouped by area. Only
// settings that are the user's own choices are here: credentials, the privacy
// lock, the consent-gated import classifier and the assistant's own model
// choice stay in their screens.
type appSettingsV1 struct {
	Overview  appOverviewV1  `json:"overview"`
	Tabs      appTabsV1      `json:"tabs"`
	Valuation appValuationV1 `json:"valuation"`
	Reminders appRemindersV1 `json:"reminders"`
	Reports   appReportsV1   `json:"reports"`
}

// appOverviewV1 is the overview page: the blocks shown, in order. A block left
// out is hidden.
type appOverviewV1 struct {
	Sections []string `json:"sections"`
}

// appTabsV1 is the three tabs beside 更多.
type appTabsV1 struct {
	Tabs []string `json:"tabs"`
}

// appValuationV1 is the currency amounts are converted to.
type appValuationV1 struct {
	Currency string `json:"currency"`
}

type appRemindersV1 struct {
	Bookkeeping appBookkeepingReminderV1 `json:"bookkeeping"`
	Imports     appImportReminderV1      `json:"imports"`
}

// appBookkeepingReminderV1 is the 记账提醒.
type appBookkeepingReminderV1 struct {
	Enabled           bool   `json:"enabled"`
	Time              string `json:"time"`
	Repeat            string `json:"repeat"`
	Days              []int  `json:"days"`
	SkipsRecordedDays bool   `json:"skipsRecordedDays"`
}

// appImportReminderV1 is the 导入账单提醒. Weekday uses Calendar numbering
// (1 is Sunday); a cadence that does not use the other one ignores it.
type appImportReminderV1 struct {
	Enabled bool   `json:"enabled"`
	Cadence string `json:"cadence"`
	Weekday int    `json:"weekday"`
	Day     int    `json:"day"`
	Time    string `json:"time"`
}

type appReportsV1 struct {
	Weekly                     appWeeklyReportV1    `json:"weekly"`
	Monthly                    appMonthlyReportV1   `json:"monthly"`
	ImportReminderBeforeReport bool                 `json:"importReminderBeforeReport"`
	FirstWeekday               int                  `json:"firstWeekday"`
	Sections                   []appReportSectionV1 `json:"sections"`
}

type appWeeklyReportV1 struct {
	Enabled bool   `json:"enabled"`
	Weekday int    `json:"weekday"`
	Time    string `json:"time"`
}

type appMonthlyReportV1 struct {
	Enabled bool   `json:"enabled"`
	Day     int    `json:"day"`
	Time    string `json:"time"`
}

// appReportSectionV1 is one block of the report and whether it prints.
type appReportSectionV1 struct {
	ID      string `json:"id"`
	Visible bool   `json:"visible"`
}

// appSettingsResultV1 is what a turn returns when it changed settings: the
// settings as they now stand and the sections that moved.
type appSettingsResultV1 struct {
	Snapshot        appSettingsV1 `json:"snapshot"`
	ChangedSections []string      `json:"changedSections"`
}

// appSettingsUpdateV1 is a partial update. Every section and every field is
// optional, so the model sends only what the user asked to change; the rest
// stays as the snapshot had it.
type appSettingsUpdateV1 struct {
	Overview  *appOverviewUpdateV1  `json:"overview,omitempty"`
	Tabs      *appTabsUpdateV1      `json:"tabs,omitempty"`
	Valuation *appValuationUpdateV1 `json:"valuation,omitempty"`
	Reminders *appRemindersUpdateV1 `json:"reminders,omitempty"`
	Reports   *appReportsUpdateV1   `json:"reports,omitempty"`
}

type appOverviewUpdateV1 struct {
	Sections *[]string `json:"sections,omitempty"`
}

type appTabsUpdateV1 struct {
	Tabs *[]string `json:"tabs,omitempty"`
}

type appValuationUpdateV1 struct {
	Currency *string `json:"currency,omitempty"`
}

type appRemindersUpdateV1 struct {
	Bookkeeping *appBookkeepingReminderUpdateV1 `json:"bookkeeping,omitempty"`
	Imports     *appImportReminderUpdateV1      `json:"imports,omitempty"`
}

type appBookkeepingReminderUpdateV1 struct {
	Enabled           *bool   `json:"enabled,omitempty"`
	Time              *string `json:"time,omitempty"`
	Repeat            *string `json:"repeat,omitempty"`
	Days              *[]int  `json:"days,omitempty"`
	SkipsRecordedDays *bool   `json:"skipsRecordedDays,omitempty"`
}

type appImportReminderUpdateV1 struct {
	Enabled *bool   `json:"enabled,omitempty"`
	Cadence *string `json:"cadence,omitempty"`
	Weekday *int    `json:"weekday,omitempty"`
	Day     *int    `json:"day,omitempty"`
	Time    *string `json:"time,omitempty"`
}

type appReportsUpdateV1 struct {
	Weekly                     *appWeeklyReportUpdateV1  `json:"weekly,omitempty"`
	Monthly                    *appMonthlyReportUpdateV1 `json:"monthly,omitempty"`
	ImportReminderBeforeReport *bool                     `json:"importReminderBeforeReport,omitempty"`
	FirstWeekday               *int                      `json:"firstWeekday,omitempty"`
	Sections                   *[]appReportSectionV1     `json:"sections,omitempty"`
}

type appWeeklyReportUpdateV1 struct {
	Enabled *bool   `json:"enabled,omitempty"`
	Weekday *int    `json:"weekday,omitempty"`
	Time    *string `json:"time,omitempty"`
}

type appMonthlyReportUpdateV1 struct {
	Enabled *bool   `json:"enabled,omitempty"`
	Day     *int    `json:"day,omitempty"`
	Time    *string `json:"time,omitempty"`
}

// The ids the shell's settings use, in the order it lists them.
var (
	appOverviewSections = []string{"retention", "periodStats", "spendingTrend", "spendingCategories",
		"creditCards", "topPayees", "incomeBreakdown", "balanceSheet", "currencyExposure"}
	// 更多 and 账本助手 are not tab choices: 更多 holds the pages that are not
	// tabs and the assistant floats beside the bar.
	appCompactTabs    = []string{"overview", "assets", "incomeExpense", "investments", "currencies", "query", "imports", "transactions", "accounts", "search"}
	appReportSections = []string{"overview", "categories", "daily", "largest", "coverage", "assistant"}
	appRepeats        = []string{"daily", "weekdays", "custom"}
	appCadences       = []string{"weekly", "monthly"}
	appSettingsNames  = []string{"overview", "tabs", "valuation", "reminders", "reports"}
)

// appSettingsNameTitles name the sections as the chat shows them.
var appSettingsNameTitles = map[string]string{
	"overview": "首页布局", "tabs": "底部标签", "valuation": "估值币种", "reminders": "提醒",
	"reports": "周报月报",
}

const maxCompactTabs = 3

var appClock = regexp.MustCompile(`^([01][0-9]|2[0-3]):[0-5][0-9]$`)

// appSettingsPrompt tells the model the App's own settings are editable. It
// follows the main prompt of an ordinary turn.
const appSettingsPrompt = `

App 设置：
- 除了账本文件，App 自身的设置也能改：get_app_settings 读取当前值，update_app_settings 修改。它们存在本机，不在账本里，不要用文件工具去找。
- 用户提出这类要求时直接改，不必先问：说「每天晚上提醒我记账」「提醒改到 22 点、只在工作日」就改 reminders；「首页别显示预算」「首页先看支出分类」改 overview；「底部标签换成…」改 tabs；「周报改到周日发」「月报关掉」改 reports；「用美元看资产」改 valuation。
- 只改用户说的那一项，用局部更新；拿不准当前值就先 get_app_settings。时间用 24 小时制 HH:MM。星期用 1=周日 … 7=周六。
- 改完在回答末尾用一句话说改了什么，例如「已把记账提醒改到每天 22:00，只在周一到周五」。App 会在回答下显示一行改动记录，用户可以撤销。
- 这些设置以外的东西（模型、API Key、隐私锁、通知权限）不能改；用户要改就说明在设置页里改。`

// normalized fills the lists a client may have left out and puts the derived
// values in their one canonical form, so an unchanged update compares equal.
func (s appSettingsV1) normalized() appSettingsV1 {
	s.Overview.Sections = nonNil(s.Overview.Sections)
	s.Tabs.Tabs = nonNil(s.Tabs.Tabs)
	if days := s.Reminders.Bookkeeping.Days; s.Reminders.Bookkeeping.Repeat != "custom" {
		// The days of a daily or weekday reminder follow from its repeat.
		s.Reminders.Bookkeeping.Days = repeatDays(s.Reminders.Bookkeeping.Repeat)
	} else if days != nil {
		ordered := append([]int{}, days...)
		sort.Ints(ordered)
		s.Reminders.Bookkeeping.Days = ordered
	}
	s.Reports.Sections = nonNilSections(s.Reports.Sections)
	return s
}

func nonNil(values []string) []string {
	if values == nil {
		return []string{}
	}
	return values
}

func nonNilSections(values []appReportSectionV1) []appReportSectionV1 {
	if values == nil {
		return []appReportSectionV1{}
	}
	return values
}

// repeatDays is the day set a repeat implies; custom has none of its own.
func repeatDays(repeat string) []int {
	switch repeat {
	case "daily":
		return []int{1, 2, 3, 4, 5, 6, 7}
	case "weekdays":
		return []int{2, 3, 4, 5, 6}
	}
	return []int{}
}

// validate checks a whole snapshot, since a partial update is merged into one
// before it is checked: a value the model sends only shows up as invalid in
// the snapshot it produces.
func (s appSettingsV1) validate() error {
	if err := validateOverview(s.Overview); err != nil {
		return err
	}
	if err := validateTabs(s.Tabs); err != nil {
		return err
	}
	if !onboardingCurrency.MatchString(s.Valuation.Currency) {
		return fmt.Errorf("valuation.currency %q 不是货币代码；用 CNY、USD、HKD 这样的三字母代码", s.Valuation.Currency)
	}
	if err := validateReminders(s.Reminders); err != nil {
		return err
	}
	return validateReports(s.Reports)
}

func validateOverview(overview appOverviewV1) error {
	if len(overview.Sections) == 0 {
		return errors.New("overview.sections 不能为空；首页至少要显示一个分区，全部隐藏的话用默认的全部")
	}
	seen := map[string]bool{}
	for _, section := range overview.Sections {
		if !contains(appOverviewSections, section) {
			return fmt.Errorf("overview.sections 里的 %q 不是首页分区；可以填 %s（顺序就是显示顺序，没列出的不显示）",
				section, strings.Join(appOverviewSections, "、"))
		}
		if seen[section] {
			return fmt.Errorf("overview.sections 里的 %q 出现了两次", section)
		}
		seen[section] = true
	}
	return nil
}

func validateTabs(tabs appTabsV1) error {
	if len(tabs.Tabs) == 0 || len(tabs.Tabs) > maxCompactTabs {
		return fmt.Errorf("tabs.tabs 需要 1 到 %d 个标签", maxCompactTabs)
	}
	seen := map[string]bool{}
	for _, tab := range tabs.Tabs {
		if !contains(appCompactTabs, tab) {
			return fmt.Errorf("tabs.tabs 里的 %q 不是可选的标签；可以填 %s（顺序就是显示顺序）", tab, strings.Join(appCompactTabs, "、"))
		}
		if seen[tab] {
			return fmt.Errorf("tabs.tabs 里的 %q 出现了两次", tab)
		}
		seen[tab] = true
	}
	return nil
}

func validateReminders(reminders appRemindersV1) error {
	bookkeeping := reminders.Bookkeeping
	if err := validateClock("reminders.bookkeeping.time", bookkeeping.Time); err != nil {
		return err
	}
	if !contains(appRepeats, bookkeeping.Repeat) {
		return fmt.Errorf("reminders.bookkeeping.repeat 只能是 daily（每天）、weekdays（工作日）或 custom（自定义星期），现在收到 %q", bookkeeping.Repeat)
	}
	if bookkeeping.Repeat == "custom" {
		if len(bookkeeping.Days) == 0 {
			return errors.New("reminders.bookkeeping.repeat 是 custom 时，days 要列出 1 到 7 里的星期（1 是周日）")
		}
		seen := map[int]bool{}
		for _, day := range bookkeeping.Days {
			if day < 1 || day > 7 {
				return fmt.Errorf("reminders.bookkeeping.days 里的 %d 不是星期；1 是周日，7 是周六", day)
			}
			if seen[day] {
				return fmt.Errorf("reminders.bookkeeping.days 里的 %d 出现了两次", day)
			}
			seen[day] = true
		}
	} else if len(bookkeeping.Days) != 0 && len(bookkeeping.Days) != len(repeatDays(bookkeeping.Repeat)) {
		return fmt.Errorf("reminders.bookkeeping.repeat 是 %s 时 days 由它决定，不需要自己填", bookkeeping.Repeat)
	}
	imports := reminders.Imports
	if err := validateClock("reminders.imports.time", imports.Time); err != nil {
		return err
	}
	if !contains(appCadences, imports.Cadence) {
		return fmt.Errorf("reminders.imports.cadence 只能是 weekly（每周）或 monthly（每月），现在收到 %q", imports.Cadence)
	}
	if imports.Cadence == "weekly" {
		if err := validateWeekday("reminders.imports.weekday", imports.Weekday); err != nil {
			return err
		}
	} else if err := validateMonthDay("reminders.imports.day", imports.Day); err != nil {
		return err
	}
	return nil
}

func validateReports(reports appReportsV1) error {
	if err := validateClock("reports.weekly.time", reports.Weekly.Time); err != nil {
		return err
	}
	if err := validateWeekday("reports.weekly.weekday", reports.Weekly.Weekday); err != nil {
		return err
	}
	if err := validateClock("reports.monthly.time", reports.Monthly.Time); err != nil {
		return err
	}
	if err := validateMonthDay("reports.monthly.day", reports.Monthly.Day); err != nil {
		return err
	}
	if reports.FirstWeekday != 1 && reports.FirstWeekday != 2 {
		return fmt.Errorf("reports.firstWeekday 只能是 1（周日）或 2（周一），现在收到 %d", reports.FirstWeekday)
	}
	seen := map[string]bool{}
	for _, section := range reports.Sections {
		if !contains(appReportSections, section.ID) {
			return fmt.Errorf("reports.sections 里的 %q 不是报告分区；sections 要按显示顺序列出全部 %d 项：%s",
				section.ID, len(appReportSections), strings.Join(appReportSections, "、"))
		}
		if seen[section.ID] {
			return fmt.Errorf("reports.sections 里的 %q 出现了两次", section.ID)
		}
		seen[section.ID] = true
	}
	for _, id := range appReportSections {
		if !seen[id] {
			return fmt.Errorf("reports.sections 缺少 %q；要按显示顺序列出全部 %d 项，不要的写 visible: false", id, len(appReportSections))
		}
	}
	return nil
}

func validateClock(name, value string) error {
	if !appClock.MatchString(value) {
		return fmt.Errorf("%s 要写成 24 小时制的 HH:MM，例如 22:00，现在收到 %q", name, value)
	}
	return nil
}

func validateWeekday(name string, value int) error {
	if value < 1 || value > 7 {
		return fmt.Errorf("%s 要是 1 到 7 的星期，1 是周日、2 是周一，现在收到 %d", name, value)
	}
	return nil
}

// validateMonthDay accepts 1 to 28, which every month has, and -1 for the
// month's last day.
func validateMonthDay(name string, value int) error {
	if value != -1 && (value < 1 || value > 28) {
		return fmt.Errorf("%s 要是 1 到 28（每月都有这一天）或 -1（当月最后一天），现在收到 %d", name, value)
	}
	return nil
}

func contains(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
}

// merge applies a partial update over the snapshot. It keeps the receiver's
// values for everything the update leaves out.
func (s appSettingsV1) merge(update appSettingsUpdateV1) appSettingsV1 {
	if section := update.Overview; section != nil && section.Sections != nil {
		s.Overview.Sections = append([]string{}, (*section.Sections)...)
	}
	if section := update.Tabs; section != nil && section.Tabs != nil {
		s.Tabs.Tabs = append([]string{}, (*section.Tabs)...)
	}
	if section := update.Valuation; section != nil && section.Currency != nil {
		s.Valuation.Currency = strings.ToUpper(strings.TrimSpace(*section.Currency))
	}
	if section := update.Reminders; section != nil {
		if bookkeeping := section.Bookkeeping; bookkeeping != nil {
			if bookkeeping.Enabled != nil {
				s.Reminders.Bookkeeping.Enabled = *bookkeeping.Enabled
			}
			if bookkeeping.Time != nil {
				s.Reminders.Bookkeeping.Time = strings.TrimSpace(*bookkeeping.Time)
			}
			if bookkeeping.Repeat != nil {
				s.Reminders.Bookkeeping.Repeat = strings.TrimSpace(*bookkeeping.Repeat)
			}
			if bookkeeping.Days != nil {
				s.Reminders.Bookkeeping.Days = append([]int{}, (*bookkeeping.Days)...)
			}
			if bookkeeping.SkipsRecordedDays != nil {
				s.Reminders.Bookkeeping.SkipsRecordedDays = *bookkeeping.SkipsRecordedDays
			}
		}
		if imports := section.Imports; imports != nil {
			if imports.Enabled != nil {
				s.Reminders.Imports.Enabled = *imports.Enabled
			}
			if imports.Cadence != nil {
				s.Reminders.Imports.Cadence = strings.TrimSpace(*imports.Cadence)
			}
			if imports.Weekday != nil {
				s.Reminders.Imports.Weekday = *imports.Weekday
			}
			if imports.Day != nil {
				s.Reminders.Imports.Day = *imports.Day
			}
			if imports.Time != nil {
				s.Reminders.Imports.Time = strings.TrimSpace(*imports.Time)
			}
		}
	}
	if section := update.Reports; section != nil {
		if weekly := section.Weekly; weekly != nil {
			if weekly.Enabled != nil {
				s.Reports.Weekly.Enabled = *weekly.Enabled
			}
			if weekly.Weekday != nil {
				s.Reports.Weekly.Weekday = *weekly.Weekday
			}
			if weekly.Time != nil {
				s.Reports.Weekly.Time = strings.TrimSpace(*weekly.Time)
			}
		}
		if monthly := section.Monthly; monthly != nil {
			if monthly.Enabled != nil {
				s.Reports.Monthly.Enabled = *monthly.Enabled
			}
			if monthly.Day != nil {
				s.Reports.Monthly.Day = *monthly.Day
			}
			if monthly.Time != nil {
				s.Reports.Monthly.Time = strings.TrimSpace(*monthly.Time)
			}
		}
		if section.ImportReminderBeforeReport != nil {
			s.Reports.ImportReminderBeforeReport = *section.ImportReminderBeforeReport
		}
		if section.FirstWeekday != nil {
			s.Reports.FirstWeekday = *section.FirstWeekday
		}
		if section.Sections != nil {
			s.Reports.Sections = append([]appReportSectionV1{}, (*section.Sections)...)
		}
	}
	return s
}

// appSettingsSession is the settings one turn edits. A change is kept only
// when the whole snapshot still validates.
type appSettingsSession struct {
	mu      sync.Mutex
	current appSettingsV1
	changed []string
}

// openAppSettings takes the snapshot the shell sent. A snapshot this build
// cannot read leaves the turn without these tools rather than failing it.
func openAppSettings(settings *appSettingsV1) *appSettingsSession {
	if settings == nil {
		return nil
	}
	snapshot := settings.normalized()
	if err := snapshot.validate(); err != nil {
		return nil
	}
	return &appSettingsSession{current: snapshot}
}

func (s *appSettingsSession) snapshot() appSettingsV1 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.current
}

// result is what the response reports; nil when nothing changed.
func (s *appSettingsSession) result() *appSettingsResultV1 {
	if s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.changed) == 0 {
		return nil
	}
	return &appSettingsResultV1{Snapshot: s.current, ChangedSections: append([]string{}, s.changed...)}
}

// apply merges one partial update, keeps it when it validates, and reports the
// sections it moved.
func (s *appSettingsSession) apply(raw json.RawMessage) (string, error) {
	var update appSettingsUpdateV1
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&update); err != nil {
		return "", fmt.Errorf("参数不对：%v。updates 里只能出现 %s 这几个分区，每个分区只填要改的字段", err,
			strings.Join(appSettingsNames, "、"))
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	next := s.current.merge(update).normalized()
	if err := next.validate(); err != nil {
		return "", err
	}
	moved := changedSections(s.current, next)
	if len(moved) == 0 {
		return "设置没有变化，和现在一样。", nil
	}
	s.current = next
	for _, name := range moved {
		if !contains(s.changed, name) {
			s.changed = append(s.changed, name)
		}
	}
	sort.SliceStable(s.changed, func(i, j int) bool {
		return indexOf(appSettingsNames, s.changed[i]) < indexOf(appSettingsNames, s.changed[j])
	})
	encoded, _ := json.Marshal(next)
	titles := make([]string, 0, len(moved))
	for _, name := range moved {
		titles = append(titles, appSettingsNameTitles[name])
	}
	return fmt.Sprintf("已更新：%s。现在的设置是 %s。", strings.Join(titles, "、"), encoded), nil
}

func indexOf(values []string, value string) int {
	for index, candidate := range values {
		if candidate == value {
			return index
		}
	}
	return len(values)
}

// changedSections lists the sections two snapshots differ in, in the shell's
// order.
func changedSections(before, after appSettingsV1) []string {
	var moved []string
	for _, name := range appSettingsNames {
		if !sameSection(name, before, after) {
			moved = append(moved, name)
		}
	}
	return moved
}

func sameSection(name string, before, after appSettingsV1) bool {
	switch name {
	case "overview":
		return sameStrings(before.Overview.Sections, after.Overview.Sections)
	case "tabs":
		return sameStrings(before.Tabs.Tabs, after.Tabs.Tabs)
	case "valuation":
		return before.Valuation == after.Valuation
	case "reminders":
		return sameReminders(before.Reminders, after.Reminders)
	case "reports":
		return sameReports(before.Reports, after.Reports)
	}
	return true
}

func sameStrings(before, after []string) bool {
	if len(before) != len(after) {
		return false
	}
	for index := range before {
		if before[index] != after[index] {
			return false
		}
	}
	return true
}

func sameReminders(before, after appRemindersV1) bool {
	if before.Imports != after.Imports {
		return false
	}
	a, b := before.Bookkeeping, after.Bookkeeping
	return a.Enabled == b.Enabled && a.Time == b.Time && a.Repeat == b.Repeat &&
		a.SkipsRecordedDays == b.SkipsRecordedDays && sameInts(a.Days, b.Days)
}

func sameInts(before, after []int) bool {
	if len(before) != len(after) {
		return false
	}
	for index := range before {
		if before[index] != after[index] {
			return false
		}
	}
	return true
}

func sameReports(before, after appReportsV1) bool {
	if before.Weekly != after.Weekly || before.Monthly != after.Monthly ||
		before.ImportReminderBeforeReport != after.ImportReminderBeforeReport ||
		before.FirstWeekday != after.FirstWeekday || len(before.Sections) != len(after.Sections) {
		return false
	}
	for index := range before.Sections {
		if before.Sections[index] != after.Sections[index] {
			return false
		}
	}
	return true
}

// tools are get_app_settings and update_app_settings.
func (s *appSettingsSession) tools() []agent.AgentTool {
	return []agent.AgentTool{
		appSettingsTool{session: s, update: false},
		appSettingsTool{session: s, update: true},
	}
}

// appSettingsTool is one of the two settings tools.
type appSettingsTool struct {
	session *appSettingsSession
	update  bool
}

func (t appSettingsTool) Name() string {
	if t.update {
		return "update_app_settings"
	}
	return "get_app_settings"
}

func (t appSettingsTool) Label() string {
	if t.update {
		return "修改 App 设置"
	}
	return "读取 App 设置"
}

func (t appSettingsTool) Schema() ai.ToolSchema { return appSettingsToolSchema(t.update) }

func (t appSettingsTool) ExecutionMode() agent.ToolExecutionMode { return agent.ToolModeSequential }

func (t appSettingsTool) Execute(_ context.Context, _ string, params json.RawMessage, _ agent.ToolUpdateCallback) (agent.AgentToolResult, error) {
	if len(params) == 0 {
		params = json.RawMessage("{}")
	}
	var text string
	var err error
	if t.update {
		var input struct {
			Updates json.RawMessage `json:"updates"`
		}
		decoder := json.NewDecoder(bytes.NewReader(params))
		decoder.DisallowUnknownFields()
		if err = decoder.Decode(&input); err != nil {
			return agent.AgentToolResult{}, fmt.Errorf("参数不对：%v。updates 里写入要改的分区，例如 {\"updates\":{\"reminders\":{\"bookkeeping\":{\"time\":\"22:00\"}}}}", err)
		}
		if len(input.Updates) == 0 {
			return agent.AgentToolResult{}, errors.New("updates 不能为空：写下要改的分区，例如 {\"reminders\":{\"bookkeeping\":{\"enabled\":true}}}")
		}
		text, err = t.session.apply(input.Updates)
	} else {
		var input struct {
			Section string `json:"section"`
		}
		decoder := json.NewDecoder(bytes.NewReader(params))
		decoder.DisallowUnknownFields()
		if err = decoder.Decode(&input); err != nil {
			return agent.AgentToolResult{}, fmt.Errorf("参数不对：%v。section 可以留空（返回全部）或填 %s", err,
				strings.Join(appSettingsNames, "、"))
		}
		text, err = t.session.read(input.Section)
	}
	if err != nil {
		return agent.AgentToolResult{}, err
	}
	return agent.AgentToolResult{Content: []ai.ToolResultMessageContent{ai.TextContent{Text: text}},
		Details: map[string]any{}}, nil
}

func (s *appSettingsSession) read(section string) (string, error) {
	s.mu.Lock()
	current := s.current
	s.mu.Unlock()
	if section == "" {
		encoded, _ := json.Marshal(map[string]any{"settings": current, "allowed": appSettingsGuide()})
		return string(encoded), nil
	}
	if !contains(appSettingsNames, section) {
		return "", fmt.Errorf("%q 不是 App 设置的分区；可以填 %s", section, strings.Join(appSettingsNames, "、"))
	}
	encoded, _ := json.Marshal(map[string]any{"settings": map[string]any{section: sectionValue(section, current)},
		"allowed": map[string]any{section: appSettingsGuide()[section]}})
	return string(encoded), nil
}

func sectionValue(section string, settings appSettingsV1) any {
	switch section {
	case "overview":
		return settings.Overview
	case "tabs":
		return settings.Tabs
	case "valuation":
		return settings.Valuation
	case "reminders":
		return settings.Reminders
	}
	return settings.Reports
}

// appSettingsGuide spells out what each section accepts, so the model can
// change a setting from the tool result alone.
func appSettingsGuide() map[string]any {
	return map[string]any{
		"overview": map[string]any{"sections": appOverviewSections,
			"hint": "首页显示哪些分区，顺序就是显示顺序；没列出的分区不显示，至少要留一个"},
		"tabs": map[string]any{"tabs": appCompactTabs, "max": maxCompactTabs,
			"hint": "底部标签栏的 1 到 3 个标签，顺序就是显示顺序；更多和账本助手不在其中"},
		"valuation": map[string]any{"currency": "三字母货币代码，如 CNY、USD、HKD",
			"hint": "资产和统计换算成这个币种显示"},
		"reminders": map[string]any{
			"bookkeeping": map[string]any{"time": "HH:MM", "repeat": appRepeats,
				"days":              "1 是周日、7 是周六；repeat 是 custom 时必填，daily 和 weekdays 由 repeat 决定",
				"skipsRecordedDays": "当天已经记过账就跳过提醒"},
			"imports": map[string]any{"cadence": appCadences, "time": "HH:MM", "weekday": "1 到 7，1 是周日（cadence 为 weekly 时用）",
				"day": "1 到 28，或 -1 表示当月最后一天（cadence 为 monthly 时用）"},
		},
		"reports": map[string]any{
			"weekly":                     map[string]any{"weekday": "1 到 7，1 是周日", "time": "HH:MM"},
			"monthly":                    map[string]any{"day": "1 到 28，或 -1 表示当月最后一天", "time": "HH:MM"},
			"importReminderBeforeReport": "出报告前一晚提醒导入账单",
			"firstWeekday":               "1 是周日，2 是周一",
			"sections":                   "按显示顺序列出全部报告分区，不要的写 visible: false",
			"sectionIds":                 appReportSections,
		},
	}
}

// appSettingsUpdateSchema is the parameters of update_app_settings: one
// optional object per section, each listing only the fields that section has.
func appSettingsUpdateSchema() map[string]any {
	field := func(kind, description string) map[string]any {
		return map[string]any{"type": kind, "description": description}
	}
	str, boolean, integer := "string", "boolean", "integer"
	weekday := field(integer, "1 到 7，1 是周日、2 是周一")
	monthDay := field(integer, "1 到 28，或 -1 表示当月最后一天")
	clock := field(str, "24 小时制的 HH:MM，例如 22:00")
	enabled := field(boolean, "是否打开")
	sections := objectParameters(map[string]any{
		"overview": objectParameters(map[string]any{
			"sections": map[string]any{"type": "array", "items": map[string]any{"type": "string", "enum": appOverviewSections},
				"description": "首页显示的分区，顺序就是显示顺序；没列出的不显示"},
		}),
		"tabs": objectParameters(map[string]any{
			"tabs": map[string]any{"type": "array", "minItems": 1, "maxItems": maxCompactTabs,
				"items":       map[string]any{"type": "string", "enum": appCompactTabs},
				"description": "底部标签栏的标签，1 到 3 个，顺序就是显示顺序"},
		}),
		"valuation": objectParameters(map[string]any{
			"currency": field(str, "三字母货币代码，如 CNY、USD"),
		}),
		"reminders": objectParameters(map[string]any{
			"bookkeeping": objectParameters(map[string]any{
				"enabled":           enabled,
				"time":              clock,
				"repeat":            map[string]any{"type": str, "enum": appRepeats, "description": "daily 每天、weekdays 工作日、custom 自定义星期"},
				"days":              map[string]any{"type": "array", "items": map[string]any{"type": integer}, "description": "custom 时的星期，1 是周日、7 是周六"},
				"skipsRecordedDays": field(boolean, "当天已经记过账就跳过提醒"),
			}),
			"imports": objectParameters(map[string]any{
				"enabled": enabled,
				"cadence": map[string]any{"type": str, "enum": appCadences, "description": "weekly 每周、monthly 每月"},
				"weekday": weekday,
				"day":     monthDay,
				"time":    clock,
			}),
		}),
		"reports": objectParameters(map[string]any{
			"weekly": objectParameters(map[string]any{
				"enabled": enabled, "weekday": weekday, "time": clock,
			}),
			"monthly": objectParameters(map[string]any{
				"enabled": enabled, "day": monthDay, "time": clock,
			}),
			"importReminderBeforeReport": field(boolean, "出报告前一晚提醒导入账单"),
			"firstWeekday":               map[string]any{"type": integer, "enum": []int{1, 2}, "description": "1 是周日，2 是周一"},
			"sections": map[string]any{"type": "array", "minItems": len(appReportSections), "maxItems": len(appReportSections),
				"items": objectParameters(map[string]any{
					"id":      map[string]any{"type": str, "enum": appReportSections},
					"visible": field(boolean, "是否出现在报告里"),
				}, "id", "visible"),
				"description": "按显示顺序列出全部报告分区，不要的写 visible: false"},
		}),
	})
	return objectParameters(map[string]any{"updates": sections}, "updates")
}

// appSettingsReadSchema is the parameters of get_app_settings.
func appSettingsReadSchema() map[string]any {
	return objectParameters(map[string]any{
		"section": map[string]any{"type": "string", "enum": appSettingsNames,
			"description": "只读某一个分区；留空返回全部"},
	})
}

// appSettingsToolSchema is the ai.ToolSchema of one settings tool.
func appSettingsToolSchema(update bool) ai.ToolSchema {
	if !update {
		return ai.ToolSchema{Name: "get_app_settings",
			Description: "读取 App 自身的设置（不是账本文件）：首页显示哪些分区、底部标签、估值币种、记账与导入提醒、周报月报。每轮请求里已经带了当前值，需要确认或用户问「现在是什么设置」时再调用。返回设置和每个字段允许的取值。",
			Parameters:  appSettingsReadSchema()}
	}
	return ai.ToolSchema{Name: "update_app_settings",
		Description: "修改 App 自身的设置（不是账本文件）。只传要改的分区与字段，没传的保持不变；每个分区都校验，错了会说明怎么改。可以改：" +
			"overview 首页分区与顺序；tabs 底部标签（≤3 个）；valuation 估值币种；" +
			"reminders 记账提醒（开关、时间、每天/工作日/自定义星期、记过账就跳过）与导入账单提醒（开关、每周星期几或每月几号、时间）；" +
			"reports 周报与月报（开关、星期几/几号、时间、报告分区、是否出报告前提醒导入）。" +
			"改完用一句话告诉用户改了什么；用户可以在回答下撤销。凭据、隐私锁和模型设置不在其中。",
		Parameters: appSettingsUpdateSchema()}
}
