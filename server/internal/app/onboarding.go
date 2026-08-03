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
	"unicode"

	"github.com/gin-gonic/gin"
)

type LedgerOnboardingFundingSpace struct {
	Kind           string `json:"kind"`
	Name           string `json:"name"`
	Currency       string `json:"currency"`
	OpeningBalance string `json:"openingBalance"`
}

type LedgerOnboardingLiability struct {
	Kind           string `json:"kind"`
	Name           string `json:"name"`
	Currency       string `json:"currency"`
	OpeningBalance string `json:"openingBalance"`
}

type LedgerOnboardingCategory struct {
	TemplateKey string `json:"templateKey"`
	CustomName  string `json:"customName"`
}

type LedgerOnboardingRequest struct {
	Title             string                         `json:"title"`
	Currency          string                         `json:"currency"`
	StartDate         string                         `json:"startDate"`
	FundingSpaces     []LedgerOnboardingFundingSpace `json:"fundingSpaces"`
	Liabilities       []LedgerOnboardingLiability    `json:"liabilities"`
	IncomeCategories  []LedgerOnboardingCategory     `json:"incomeCategories"`
	ExpenseCategories []LedgerOnboardingCategory     `json:"expenseCategories"`
}

type onboardingCategoryTemplate struct {
	Key     string `json:"key"`
	Name    string `json:"name"`
	Account string `json:"-"`
}

var onboardingIncomeTemplates = []onboardingCategoryTemplate{
	{Key: "salary", Name: "工资", Account: "Income:Salary"},
	{Key: "bonus", Name: "奖金", Account: "Income:Bonus"},
	{Key: "freelance", Name: "副业", Account: "Income:Freelance"},
	{Key: "interest", Name: "利息", Account: "Income:Interest"},
	{Key: "investment", Name: "投资收益", Account: "Income:Investment"},
	{Key: "other_income", Name: "其他收入", Account: "Income:Other"},
}

var onboardingExpenseTemplates = []onboardingCategoryTemplate{
	{Key: "groceries", Name: "买菜", Account: "Expenses:Food:Groceries"},
	{Key: "dining", Name: "外出用餐", Account: "Expenses:Food:Dining"},
	{Key: "coffee", Name: "咖啡饮品", Account: "Expenses:Food:Coffee"},
	{Key: "public_transport", Name: "公交地铁", Account: "Expenses:Transport:Public"},
	{Key: "taxi", Name: "打车", Account: "Expenses:Transport:Taxi"},
	{Key: "rent", Name: "房租", Account: "Expenses:Home:Rent"},
	{Key: "utilities", Name: "水电燃气", Account: "Expenses:Home:Utilities"},
	{Key: "daily_goods", Name: "日用品", Account: "Expenses:Shopping:Daily"},
	{Key: "clothing", Name: "衣物", Account: "Expenses:Shopping:Clothing"},
	{Key: "medical", Name: "医疗健康", Account: "Expenses:Health:Medical"},
	{Key: "fitness", Name: "运动健身", Account: "Expenses:Health:Fitness"},
	{Key: "entertainment", Name: "娱乐", Account: "Expenses:Entertainment"},
	{Key: "subscriptions", Name: "订阅服务", Account: "Expenses:Entertainment:Subscriptions"},
	{Key: "education", Name: "学习成长", Account: "Expenses:Education"},
	{Key: "gifts", Name: "人情礼物", Account: "Expenses:Social:Gifts"},
}

var onboardingTemplateResponse = gin.H{
	"income":   onboardingIncomeTemplates,
	"expenses": onboardingExpenseTemplates,
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
		c.JSON(http.StatusOK, gin.H{"state": "uninitialized", "templates": onboardingTemplateResponse})
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
	for index := range r.FundingSpaces {
		r.FundingSpaces[index].Kind = strings.TrimSpace(r.FundingSpaces[index].Kind)
		r.FundingSpaces[index].Name = strings.TrimSpace(r.FundingSpaces[index].Name)
		r.FundingSpaces[index].Currency = strings.ToUpper(strings.TrimSpace(r.FundingSpaces[index].Currency))
		r.FundingSpaces[index].OpeningBalance = strings.TrimSpace(r.FundingSpaces[index].OpeningBalance)
	}
	for index := range r.Liabilities {
		r.Liabilities[index].Kind = strings.TrimSpace(r.Liabilities[index].Kind)
		r.Liabilities[index].Name = strings.TrimSpace(r.Liabilities[index].Name)
		r.Liabilities[index].Currency = strings.ToUpper(strings.TrimSpace(r.Liabilities[index].Currency))
		r.Liabilities[index].OpeningBalance = strings.TrimSpace(r.Liabilities[index].OpeningBalance)
	}
	for index := range r.IncomeCategories {
		r.IncomeCategories[index].TemplateKey = strings.TrimSpace(r.IncomeCategories[index].TemplateKey)
		r.IncomeCategories[index].CustomName = strings.TrimSpace(r.IncomeCategories[index].CustomName)
	}
	for index := range r.ExpenseCategories {
		r.ExpenseCategories[index].TemplateKey = strings.TrimSpace(r.ExpenseCategories[index].TemplateKey)
		r.ExpenseCategories[index].CustomName = strings.TrimSpace(r.ExpenseCategories[index].CustomName)
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
	if len(r.FundingSpaces) == 0 {
		return errors.New("请至少添加一个钱在哪里")
	}
	seenNames := map[string]bool{}
	for i, space := range r.FundingSpaces {
		if _, ok := fundingSpacePrefixes[space.Kind]; !ok {
			return fmt.Errorf("fundingSpaces[%d].kind 无效", i)
		}
		if err := validateOnboardingName(fmt.Sprintf("fundingSpaces[%d].name", i), space.Name); err != nil {
			return err
		}
		if seenNames["funding:"+space.Name] {
			return fmt.Errorf("钱在哪里重复：%s", space.Name)
		}
		seenNames["funding:"+space.Name] = true
		if err := validateOnboardingAmount(fmt.Sprintf("fundingSpaces[%d]", i), space.Currency, space.OpeningBalance); err != nil {
			return err
		}
	}
	for i, liability := range r.Liabilities {
		if _, ok := liabilityPrefixes[liability.Kind]; !ok {
			return fmt.Errorf("liabilities[%d].kind 无效", i)
		}
		if err := validateOnboardingName(fmt.Sprintf("liabilities[%d].name", i), liability.Name); err != nil {
			return err
		}
		if seenNames["liability:"+liability.Name] {
			return fmt.Errorf("欠款账户重复：%s", liability.Name)
		}
		seenNames["liability:"+liability.Name] = true
		if err := validateOnboardingAmount(fmt.Sprintf("liabilities[%d]", i), liability.Currency, liability.OpeningBalance); err != nil {
			return err
		}
	}
	if err := validateOnboardingCategories("incomeCategories", r.IncomeCategories, onboardingIncomeTemplates); err != nil {
		return err
	}
	if err := validateOnboardingCategories("expenseCategories", r.ExpenseCategories, onboardingExpenseTemplates); err != nil {
		return err
	}
	return nil
}

var fundingSpacePrefixes = map[string]string{
	"cash":           "Assets:Cash",
	"bank_card":      "Assets:Bank",
	"digital_wallet": "Assets:Wallet",
	"savings":        "Assets:Savings",
	"investment":     "Assets:Investment",
}

var liabilityPrefixes = map[string]string{
	"credit_card":   "Liabilities:CreditCard",
	"consumer_loan": "Liabilities:Loan",
	"other_debt":    "Liabilities:Other",
}

func validateOnboardingName(field, value string) error {
	if value == "" || len([]rune(value)) > 80 {
		return fmt.Errorf("%s 需为 1–80 个字符", field)
	}
	return nil
}

func validateOnboardingAmount(field, currency, balance string) error {
	if currency != "" && !currencyPattern.MatchString(currency) {
		return fmt.Errorf("%s.currency 无效", field)
	}
	if balance != "" && !decimal2Re.MatchString(balance) {
		return fmt.Errorf("%s.openingBalance 无效", field)
	}
	if strings.HasPrefix(balance, "-") {
		return fmt.Errorf("%s.openingBalance 请填写正数金额", field)
	}
	return nil
}

func validateOnboardingCategories(field string, categories []LedgerOnboardingCategory, templates []onboardingCategoryTemplate) error {
	known := map[string]bool{}
	for _, template := range templates {
		known[template.Key] = true
	}
	seen := map[string]bool{}
	for i, category := range categories {
		if (category.TemplateKey == "") == (category.CustomName == "") {
			return fmt.Errorf("%s[%d] 需选择一个模板或填写自定义名称", field, i)
		}
		key := "custom:" + category.CustomName
		if category.TemplateKey != "" {
			if !known[category.TemplateKey] {
				return fmt.Errorf("%s[%d].templateKey 无效", field, i)
			}
			key = "template:" + category.TemplateKey
		} else if err := validateOnboardingName(fmt.Sprintf("%s[%d].customName", field, i), category.CustomName); err != nil {
			return err
		}
		if seen[key] {
			return fmt.Errorf("%s 包含重复分类", field)
		}
		seen[key] = true
	}
	return nil
}

func starterLedgerFiles(input LedgerOnboardingRequest) (map[string]string, error) {
	date, err := time.Parse("2006-01-02", input.StartDate)
	if err != nil {
		return nil, err
	}
	currency, year := strings.ToUpper(input.Currency), date.Format("2006")
	accounts, err := starterLedgerAccounts(input)
	if err != nil {
		return nil, err
	}
	sort.Slice(accounts, func(i, j int) bool { return accounts[i].Account < accounts[j].Account })
	var accountLines []string
	for _, account := range accounts {
		accountLines = append(accountLines, strings.TrimSpace(AccountToBean(input.StartDate, account.Account, account.Alias, accountCurrency(account.Currency, currency))))
	}
	var opening []string
	for _, account := range accounts {
		if isZeroDecimal(account.OpeningBalance) {
			continue
		}
		amount := account.OpeningBalance
		if account.IsLiability {
			amount = negateDecimal(amount)
		}
		opening = append(opening, fmt.Sprintf("  %s %s %s\n  Equity:Opening-Balances %s %s", account.Account, amount, accountCurrency(account.Currency, currency), negateDecimal(amount), accountCurrency(account.Currency, currency)))
	}
	transactions := ""
	if len(opening) > 0 {
		transactions = fmt.Sprintf("%s * \"期初余额\"\n%s\n", input.StartDate, strings.Join(opening, "\n"))
	}
	return map[string]string{"main.bean": fmt.Sprintf("option \"title\" %q\noption \"operating_currency\" %q\noption \"booking_method\" \"FIFO\"\n\ninclude \"commodities.bean\"\ninclude \"accounts.bean\"\ninclude \"prices.bean\"\ninclude \"transactions/%s.bean\"\n", input.Title, currency, year), "commodities.bean": fmt.Sprintf("%s commodity %s\n", input.StartDate, currency), "accounts.bean": strings.Join(accountLines, "\n") + "\n", "prices.bean": "", "transactions/" + year + ".bean": transactions}, nil
}

type starterLedgerAccount struct {
	Account        string
	Alias          string
	Currency       string
	OpeningBalance string
	IsLiability    bool
}

func starterLedgerAccounts(input LedgerOnboardingRequest) ([]starterLedgerAccount, error) {
	accounts := []starterLedgerAccount{{Account: "Equity:Opening-Balances", Alias: "期初余额"}}
	usedSegments := map[string]map[string]bool{}
	for _, space := range input.FundingSpaces {
		prefix := fundingSpacePrefixes[space.Kind]
		segment := uniqueAccountSegment(safeAccountSegment(space.Name), usedSegments, prefix)
		accounts = append(accounts, starterLedgerAccount{Account: prefix + ":" + segment, Alias: space.Name, Currency: space.Currency, OpeningBalance: space.OpeningBalance})
	}
	for _, liability := range input.Liabilities {
		prefix := liabilityPrefixes[liability.Kind]
		segment := uniqueAccountSegment(safeAccountSegment(liability.Name), usedSegments, prefix)
		accounts = append(accounts, starterLedgerAccount{Account: prefix + ":" + segment, Alias: liability.Name, Currency: liability.Currency, OpeningBalance: liability.OpeningBalance, IsLiability: true})
	}
	for _, category := range input.IncomeCategories {
		account, alias, err := categoryAccount(category, onboardingIncomeTemplates, "Income", usedSegments)
		if err != nil {
			return nil, err
		}
		accounts = append(accounts, starterLedgerAccount{Account: account, Alias: alias})
	}
	for _, category := range input.ExpenseCategories {
		account, alias, err := categoryAccount(category, onboardingExpenseTemplates, "Expenses", usedSegments)
		if err != nil {
			return nil, err
		}
		accounts = append(accounts, starterLedgerAccount{Account: account, Alias: alias})
	}
	return accounts, nil
}

func categoryAccount(category LedgerOnboardingCategory, templates []onboardingCategoryTemplate, root string, usedSegments map[string]map[string]bool) (string, string, error) {
	if category.TemplateKey != "" {
		for _, template := range templates {
			if template.Key == category.TemplateKey {
				return template.Account, template.Name, nil
			}
		}
		return "", "", fmt.Errorf("未知的分类模板：%s", category.TemplateKey)
	}
	prefix := root + ":Custom"
	segment := uniqueAccountSegment(safeAccountSegment(category.CustomName), usedSegments, prefix)
	return prefix + ":" + segment, category.CustomName, nil
}

func accountCurrency(value, fallback string) string {
	if value != "" {
		return value
	}
	return fallback
}

func safeAccountSegment(value string) string {
	var builder strings.Builder
	lastSeparator := false
	for _, character := range strings.TrimSpace(value) {
		switch {
		case character >= 'A' && character <= 'Z', character >= 'a' && character <= 'z', character >= '0' && character <= '9':
			builder.WriteRune(unicode.ToLower(character))
			lastSeparator = false
		case character == '-' || character == '_' || unicode.IsSpace(character):
			if builder.Len() > 0 && !lastSeparator {
				builder.WriteByte('-')
				lastSeparator = true
			}
		default:
			builder.WriteString(fmt.Sprintf("u%x", character))
			lastSeparator = false
		}
	}
	segment := strings.Trim(builder.String(), "-")
	if segment == "" || !((segment[0] >= 'a' && segment[0] <= 'z') || (segment[0] >= '0' && segment[0] <= '9')) {
		segment = "item-" + segment
	}
	if segment[0] >= 'a' && segment[0] <= 'z' {
		segment = strings.ToUpper(segment[:1]) + segment[1:]
	}
	return segment
}

func uniqueAccountSegment(base string, used map[string]map[string]bool, prefix string) string {
	if used[prefix] == nil {
		used[prefix] = map[string]bool{}
	}
	segment := base
	for suffix := 2; used[prefix][segment]; suffix++ {
		segment = fmt.Sprintf("%s-%d", base, suffix)
	}
	used[prefix][segment] = true
	return segment
}

func isZeroDecimal(value string) bool {
	value = strings.TrimPrefix(strings.TrimSpace(value), "-")
	value = strings.ReplaceAll(value, ".", "")
	return value == "" || strings.Trim(value, "0") == ""
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
