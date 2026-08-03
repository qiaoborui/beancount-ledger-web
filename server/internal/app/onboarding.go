package app

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type LedgerOnboardingRequest struct {
	Title    string `json:"title"`
	Currency string `json:"currency"`
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
		errorJSON(c, http.StatusBadRequest, fmt.Errorf("无法读取账本仓库；请确认仓库已有默认分支和初始 README：%w", err))
		return
	}
	_, err = tx.readFile("main.bean")
	if errors.Is(err, os.ErrNotExist) {
		c.JSON(http.StatusOK, gin.H{"state": "uninitialized"})
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
	var input LedgerOnboardingRequest
	if !bindJSON(c, &input) {
		return
	}
	title := strings.TrimSpace(input.Title)
	currency := strings.ToUpper(strings.TrimSpace(input.Currency))
	if title == "" || len(title) > 120 {
		errorJSON(c, http.StatusBadRequest, errors.New("账本名称需为 1–120 个字符"))
		return
	}
	if !regexp.MustCompile(`^[A-Z]{3,8}$`).MatchString(currency) {
		errorJSON(c, http.StatusBadRequest, errors.New("基础货币格式无效"))
		return
	}
	files := starterLedgerFiles(title, currency, time.Now().UTC())
	err := s.writer.RunTransactionWithSource("onboarding-initialize", func(tx *LedgerWriteTransaction) error {
		if exists, err := tx.Exists("main.bean"); err != nil {
			return err
		} else if exists {
			return errors.New("账本已初始化，不会覆盖现有 main.bean")
		}
		for path, content := range files {
			if err := tx.WriteFile(path, []byte(content), 0o644); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusAccepted, gin.H{"ok": true, "state": "indexing"})
}

func starterLedgerFiles(title, currency string, now time.Time) map[string]string {
	date, year := now.Format("2006-01-02"), now.Format("2006")
	return map[string]string{
		"main.bean":        fmt.Sprintf("option \"title\" %q\noption \"operating_currency\" %q\noption \"booking_method\" \"FIFO\"\n\ninclude \"commodities.bean\"\ninclude \"accounts.bean\"\ninclude \"prices.bean\"\ninclude \"transactions/%s.bean\"\n", title, currency, year),
		"commodities.bean": fmt.Sprintf("%s commodity %s\n", date, currency), "prices.bean": "", "transactions/" + year + ".bean": "",
		"accounts.bean": fmt.Sprintf("%s open Assets:Cash %s\n%s open Assets:Bank:Checking %s\n%s open Liabilities:CreditCard %s\n%s open Income:Salary\n%s open Expenses:Food\n%s open Expenses:Transport\n%s open Expenses:Shopping\n%s open Equity:Opening-Balances\n", date, currency, date, currency, date, currency, date, date, date, date, date),
	}
}
