package app

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type LedgerOnboardingAsset struct {
	Account        string `json:"account"`
	Currency       string `json:"currency"`
	OpeningBalance string `json:"openingBalance"`
}
type LedgerOnboardingRequest struct {
	Title      string                  `json:"title"`
	Currency   string                  `json:"currency"`
	StartDate  string                  `json:"startDate"`
	Assets     []LedgerOnboardingAsset `json:"assets"`
	Categories []string                `json:"categories"`
}

var starterCategoryTemplates = map[string][]string{
	"personal": {"Expenses:Food", "Expenses:Transport", "Expenses:Shopping", "Expenses:Home", "Income:Salary", "Income:Other"},
}

func (s *Server) onboardingStatus(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	client, err := newGitHubLedgerClient(s.cfg)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	tx, err := client.beginTransaction(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusBadRequest, fmt.Errorf("无法读取账本仓库，请确认仓库已有默认分支和初始 README：%w", err))
		return
	}
	_, err = tx.readFile("main.bean")
	if errors.Is(err, os.ErrNotExist) {
		c.JSON(http.StatusOK, gin.H{"state": "uninitialized", "templates": starterCategoryTemplates})
		return
	}
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"state": "ready"})
}

func (s *Server) initializeLedger(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	if !githubAPIEnabled(s.cfg) {
		errorJSON(c, http.StatusBadRequest, errors.New("新账本初始化只支持 GitHub API 账本存储"))
		return
	}
	var input LedgerOnboardingRequest
	if !bindJSON(c, &input) {
		return
	}
	input.Normalize()
	if err := input.Validate(); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	files, err := starterLedgerFiles(input)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	gitSHA, err := s.writer.RunTransactionWithSourceResult("onboarding-initialize", func(tx *LedgerWriteTransaction) error {
		if exists, err := tx.Exists("main.bean"); err != nil {
			return err
		} else if exists {
			return errors.New("账本已初始化，不会覆盖现有 main.bean")
		}
		for _, path := range sortedStringKeys(files) {
			if err := tx.WriteFile(filepath.ToSlash(path), []byte(files[path]), 0o644); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusAccepted, gin.H{"ok": true, "state": "indexing", "gitSHA": gitSHA})
}

func (r *LedgerOnboardingRequest) Normalize() {
	r.Title = strings.TrimSpace(r.Title)
	r.Currency = strings.ToUpper(strings.TrimSpace(r.Currency))
	r.StartDate = strings.TrimSpace(r.StartDate)
	for index := range r.Assets {
		r.Assets[index].Account = strings.TrimSpace(r.Assets[index].Account)
		r.Assets[index].Currency = strings.ToUpper(strings.TrimSpace(r.Assets[index].Currency))
		r.Assets[index].OpeningBalance = strings.TrimSpace(r.Assets[index].OpeningBalance)
	}
	for index := range r.Categories {
		r.Categories[index] = strings.TrimSpace(r.Categories[index])
	}
}

func (r LedgerOnboardingRequest) Validate() error {
	r.Normalize()
	if r.Title == "" || len(r.Title) > 120 {
		return errors.New("账本名称需为 1–120 个字符")
	}
	if !currencyPattern.MatchString(r.Currency) {
		return errors.New("基础货币格式无效")
	}
	if err := validateDate("startDate", r.StartDate); err != nil {
		return err
	}
	if len(r.Assets) == 0 {
		return errors.New("请至少添加一个资金账户")
	}
	seen := map[string]bool{}
	for i, asset := range r.Assets {
		if err := validateAccount(fmt.Sprintf("assets[%d].account", i), asset.Account); err != nil {
			return err
		}
		if !strings.HasPrefix(asset.Account, "Assets:") && !strings.HasPrefix(asset.Account, "Liabilities:") {
			return errors.New("资金账户必须属于 Assets 或 Liabilities")
		}
		if seen[asset.Account] {
			return fmt.Errorf("资金账户重复：%s", asset.Account)
		}
		seen[asset.Account] = true
		if asset.Currency != "" && !currencyPattern.MatchString(strings.ToUpper(asset.Currency)) {
			return fmt.Errorf("assets[%d].currency 无效", i)
		}
		if asset.OpeningBalance != "" && !decimal2Re.MatchString(asset.OpeningBalance) {
			return fmt.Errorf("assets[%d].openingBalance 无效", i)
		}
	}
	for i, account := range r.Categories {
		if err := validateAccount(fmt.Sprintf("categories[%d]", i), account); err != nil {
			return err
		}
		if !strings.HasPrefix(account, "Expenses:") && !strings.HasPrefix(account, "Income:") {
			return errors.New("分类必须属于 Expenses 或 Income")
		}
		if seen[account] {
			return fmt.Errorf("账户重复：%s", account)
		}
		seen[account] = true
	}
	return nil
}

func starterLedgerFiles(input LedgerOnboardingRequest) (map[string]string, error) {
	date, err := time.Parse("2006-01-02", input.StartDate)
	if err != nil {
		return nil, err
	}
	currency, year := strings.ToUpper(input.Currency), date.Format("2006")
	accounts := append([]string{"Equity:Opening-Balances"}, input.Categories...)
	for _, asset := range input.Assets {
		accounts = append(accounts, asset.Account)
	}
	sort.Strings(accounts)
	var accountLines []string
	for _, account := range accounts {
		accountLines = append(accountLines, fmt.Sprintf("%s open %s%s", input.StartDate, account, accountCurrency(account, input.Assets, currency)))
	}
	var opening []string
	for _, asset := range input.Assets {
		if isZeroDecimal(asset.OpeningBalance) {
			continue
		}
		amount := asset.OpeningBalance
		if strings.HasPrefix(asset.Account, "Liabilities:") {
			amount = negateDecimal(amount)
		}
		opening = append(opening, fmt.Sprintf("  %s %s %s\n  Equity:Opening-Balances %s %s", asset.Account, amount, assetCurrency(asset, currency), negateDecimal(amount), assetCurrency(asset, currency)))
	}
	transactions := ""
	if len(opening) > 0 {
		transactions = fmt.Sprintf("%s * \"期初余额\"\n%s\n", input.StartDate, strings.Join(opening, "\n"))
	}
	return map[string]string{"main.bean": fmt.Sprintf("option \"title\" %q\noption \"operating_currency\" %q\noption \"booking_method\" \"FIFO\"\n\ninclude \"commodities.bean\"\ninclude \"accounts.bean\"\ninclude \"prices.bean\"\ninclude \"transactions/%s.bean\"\n", input.Title, currency, year), "commodities.bean": fmt.Sprintf("%s commodity %s\n", input.StartDate, currency), "accounts.bean": strings.Join(accountLines, "\n") + "\n", "prices.bean": "", "transactions/" + year + ".bean": transactions}, nil
}

func isZeroDecimal(value string) bool {
	value = strings.TrimPrefix(strings.TrimSpace(value), "-")
	value = strings.ReplaceAll(value, ".", "")
	return value == "" || strings.Trim(value, "0") == ""
}
func accountCurrency(account string, assets []LedgerOnboardingAsset, fallback string) string {
	for _, asset := range assets {
		if asset.Account == account {
			return " " + assetCurrency(asset, fallback)
		}
	}
	return ""
}
func assetCurrency(asset LedgerOnboardingAsset, fallback string) string {
	if value := strings.ToUpper(strings.TrimSpace(asset.Currency)); value != "" {
		return value
	}
	return fallback
}
func negateDecimal(value string) string {
	value = strings.TrimSpace(value)
	if strings.HasPrefix(value, "-") {
		return strings.TrimPrefix(value, "-")
	}
	return "-" + value
}
func sortedStringKeys(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
