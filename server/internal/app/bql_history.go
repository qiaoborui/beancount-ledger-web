package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

const (
	bqlHistoryScope = "bql-history"
	bqlHistoryKey   = "history"
	bqlHistoryLimit = 30
)

type BQLHistoryRecord struct {
	ID          string    `json:"id"`
	Query       string    `json:"query"`
	Title       string    `json:"title"`
	TitleSource string    `json:"titleSource"`
	CreatedAt   time.Time `json:"createdAt"`
	LastRunAt   time.Time `json:"lastRunAt"`
	RunCount    int       `json:"runCount"`
}

type bqlHistoryStore struct {
	Version int                `json:"version"`
	Records []BQLHistoryRecord `json:"records"`
}

type BQLHistorySaveRequest struct {
	Query string `json:"query"`
}

func (r BQLHistorySaveRequest) Validate() error {
	query := strings.TrimSpace(r.Query)
	if len(query) > 12000 {
		return errors.New("query is too long")
	}
	statements := splitBQLHistoryStatements(query)
	if len(statements) == 0 {
		return errors.New("BQL 查询不能为空")
	}
	for _, statement := range statements {
		if _, err := parseBQL(statement); err != nil {
			return err
		}
	}
	return nil
}

type BQLHistoryRenameRequest struct {
	Title string `json:"title"`
}

func (r BQLHistoryRenameRequest) Validate() error {
	_, err := normalizeBQLHistoryTitle(r.Title)
	return err
}

func (s *Server) bqlHistory(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	records, err := s.listBQLHistory(c.Request.Context())
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"records": records})
}

func (s *Server) saveBQLHistory(c *gin.Context) {
	if !s.limiter.Check(c, "bql.history.save", 30, 5*time.Minute) {
		return
	}
	if !requireSensitive(c) {
		return
	}
	var input BQLHistorySaveRequest
	if !bindJSON(c, &input) {
		return
	}
	record, _, err := s.touchBQLHistory(c.Request.Context(), input.Query)
	if err != nil {
		errorJSON(c, http.StatusInternalServerError, err)
		return
	}
	c.JSON(http.StatusOK, record)
}

func (s *Server) generateBQLHistoryTitleHandler(c *gin.Context) {
	if !s.limiter.Check(c, "bql.history.title", 30, 5*time.Minute) {
		return
	}
	if !requireSensitive(c) {
		return
	}
	record, err := s.getBQLHistoryRecord(c.Request.Context(), c.Param("id"))
	if err != nil {
		bqlHistoryError(c, err)
		return
	}
	if record.TitleSource == "manual" || record.TitleSource == "ai" {
		c.JSON(http.StatusOK, record)
		return
	}
	title, err := s.generateBQLHistoryTitle(c.Request.Context(), record.Query)
	if err != nil {
		errorJSON(c, http.StatusServiceUnavailable, err)
		return
	}
	record, err = s.setBQLHistoryGeneratedTitle(c.Request.Context(), record.ID, title)
	if err != nil {
		bqlHistoryError(c, err)
		return
	}
	c.JSON(http.StatusOK, record)
}

func (s *Server) renameBQLHistory(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	var input BQLHistoryRenameRequest
	if !bindJSON(c, &input) {
		return
	}
	title, _ := normalizeBQLHistoryTitle(input.Title)
	record, err := s.renameBQLHistoryRecord(c.Request.Context(), c.Param("id"), title)
	if err != nil {
		bqlHistoryError(c, err)
		return
	}
	c.JSON(http.StatusOK, record)
}

func (s *Server) deleteBQLHistory(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	if err := s.deleteBQLHistoryRecord(c.Request.Context(), c.Param("id")); err != nil {
		bqlHistoryError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

func bqlHistoryError(c *gin.Context, err error) {
	if errors.Is(err, errBQLHistoryRecordNotFound) {
		errorJSON(c, http.StatusNotFound, err)
		return
	}
	errorJSON(c, http.StatusInternalServerError, err)
}

var errBQLHistoryRecordNotFound = errors.New("BQL history record not found")

func (s *Server) listBQLHistory(ctx context.Context) ([]BQLHistoryRecord, error) {
	if s.bqlHistoryRepository != nil {
		return s.bqlHistoryRepository.List(ctx, ledgerClusterID(s.cfg))
	}
	store, err := s.readBQLHistoryStore(ctx)
	if err != nil {
		return nil, err
	}
	records := append([]BQLHistoryRecord(nil), store.Records...)
	sortBQLHistory(records)
	return records, nil
}

func (s *Server) getBQLHistoryRecord(ctx context.Context, id string) (BQLHistoryRecord, error) {
	if s.bqlHistoryRepository != nil {
		return s.bqlHistoryRepository.Get(ctx, ledgerClusterID(s.cfg), id)
	}
	store, err := s.readBQLHistoryStore(ctx)
	if err != nil {
		return BQLHistoryRecord{}, err
	}
	for _, record := range store.Records {
		if record.ID == id {
			return record, nil
		}
	}
	return BQLHistoryRecord{}, errBQLHistoryRecordNotFound
}

func (s *Server) touchBQLHistory(ctx context.Context, rawQuery string) (BQLHistoryRecord, bool, error) {
	query := strings.TrimSpace(rawQuery)
	if s.bqlHistoryRepository != nil {
		now := time.Now().UTC()
		return s.bqlHistoryRepository.Touch(ctx, ledgerClusterID(s.cfg), BQLHistoryRecord{
			ID:          bqlHistoryID(query),
			Query:       query,
			Title:       fallbackBQLHistoryTitle(query),
			TitleSource: "fallback",
			CreatedAt:   now,
			LastRunAt:   now,
			RunCount:    1,
		})
	}
	var record BQLHistoryRecord
	created := false
	err := s.runtime().WithLock(ctx, s.bqlHistoryLockName(), func(lockCtx context.Context) error {
		store, err := s.readBQLHistoryStore(lockCtx)
		if err != nil {
			return err
		}
		now := time.Now().UTC()
		for index := range store.Records {
			if store.Records[index].Query != query {
				continue
			}
			store.Records[index].LastRunAt = now
			store.Records[index].RunCount++
			record = store.Records[index]
			return s.writeBQLHistoryStore(lockCtx, store)
		}
		record = BQLHistoryRecord{
			ID:          bqlHistoryID(query),
			Query:       query,
			Title:       fallbackBQLHistoryTitle(query),
			TitleSource: "fallback",
			CreatedAt:   now,
			LastRunAt:   now,
			RunCount:    1,
		}
		store.Version = 1
		store.Records = append(store.Records, record)
		sortBQLHistory(store.Records)
		if len(store.Records) > bqlHistoryLimit {
			store.Records = store.Records[:bqlHistoryLimit]
		}
		created = true
		return s.writeBQLHistoryStore(lockCtx, store)
	})
	return record, created, err
}

func (s *Server) setBQLHistoryGeneratedTitle(ctx context.Context, id, title string) (BQLHistoryRecord, error) {
	if s.bqlHistoryRepository != nil {
		return s.bqlHistoryRepository.SetGeneratedTitle(ctx, ledgerClusterID(s.cfg), id, title)
	}
	var record BQLHistoryRecord
	err := s.runtime().WithLock(ctx, s.bqlHistoryLockName(), func(lockCtx context.Context) error {
		store, err := s.readBQLHistoryStore(lockCtx)
		if err != nil {
			return err
		}
		for index := range store.Records {
			if store.Records[index].ID != id {
				continue
			}
			if store.Records[index].TitleSource == "manual" {
				record = store.Records[index]
				return nil
			}
			store.Records[index].Title = title
			store.Records[index].TitleSource = "ai"
			record = store.Records[index]
			return s.writeBQLHistoryStore(lockCtx, store)
		}
		return errBQLHistoryRecordNotFound
	})
	return record, err
}

func (s *Server) renameBQLHistoryRecord(ctx context.Context, id, title string) (BQLHistoryRecord, error) {
	if s.bqlHistoryRepository != nil {
		return s.bqlHistoryRepository.Rename(ctx, ledgerClusterID(s.cfg), id, title)
	}
	var record BQLHistoryRecord
	err := s.runtime().WithLock(ctx, s.bqlHistoryLockName(), func(lockCtx context.Context) error {
		store, err := s.readBQLHistoryStore(lockCtx)
		if err != nil {
			return err
		}
		for index := range store.Records {
			if store.Records[index].ID != id {
				continue
			}
			store.Records[index].Title = title
			store.Records[index].TitleSource = "manual"
			record = store.Records[index]
			return s.writeBQLHistoryStore(lockCtx, store)
		}
		return errBQLHistoryRecordNotFound
	})
	return record, err
}

func (s *Server) deleteBQLHistoryRecord(ctx context.Context, id string) error {
	if s.bqlHistoryRepository != nil {
		return s.bqlHistoryRepository.Delete(ctx, ledgerClusterID(s.cfg), id)
	}
	return s.runtime().WithLock(ctx, s.bqlHistoryLockName(), func(lockCtx context.Context) error {
		store, err := s.readBQLHistoryStore(lockCtx)
		if err != nil {
			return err
		}
		for index := range store.Records {
			if store.Records[index].ID != id {
				continue
			}
			store.Records = append(store.Records[:index], store.Records[index+1:]...)
			return s.writeBQLHistoryStore(lockCtx, store)
		}
		return errBQLHistoryRecordNotFound
	})
}

func (s *Server) readBQLHistoryStore(ctx context.Context) (bqlHistoryStore, error) {
	var store bqlHistoryStore
	ok, err := s.runtime().GetJSON(ctx, bqlHistoryScope, s.bqlHistoryStoreKey(), &store)
	if err != nil {
		return bqlHistoryStore{}, err
	}
	if !ok {
		return bqlHistoryStore{Version: 1, Records: []BQLHistoryRecord{}}, nil
	}
	if store.Version == 0 {
		store.Version = 1
	}
	if store.Records == nil {
		store.Records = []BQLHistoryRecord{}
	}
	return store, nil
}

func (s *Server) writeBQLHistoryStore(ctx context.Context, store bqlHistoryStore) error {
	store.Version = 1
	return s.runtime().PutJSON(ctx, bqlHistoryScope, s.bqlHistoryStoreKey(), store)
}

func (s *Server) bqlHistoryStoreKey() string {
	return bqlHistoryKey + ":" + bqlHistoryScopeHash(ledgerClusterID(s.cfg))
}

func (s *Server) bqlHistoryLockName() string {
	return "bql-history:" + s.bqlHistoryStoreKey()
}

func bqlHistoryScopeHash(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:12])
}

func bqlHistoryID(query string) string {
	sum := sha256.Sum256([]byte(query))
	return "bqlq_" + hex.EncodeToString(sum[:12])
}

func fallbackBQLHistoryTitle(query string) string {
	statements := splitBQLHistoryStatements(query)
	if len(statements) > 1 {
		return "组合查询"
	}
	parsed, err := parseBQL(query)
	if err == nil {
		switch parsed.table {
		case "postings":
			return "分录查询"
		case "transactions":
			return "交易查询"
		}
	}
	return "BQL 查询"
}

func (s *Server) generateBQLHistoryTitle(ctx context.Context, query string) (string, error) {
	titleCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	result, err := s.modelClient().Complete(titleCtx, `你负责为个人账本的 BQL 查询生成简短标题。只输出一个 4 到 20 个字符的中文标题，不要 Markdown、引号、解释或结果数据。标题概括查询的意图，不重复 BQL 语法。`, []agentModelMessage{{Role: "user", Content: query}}, nil)
	if err != nil {
		return "", err
	}
	if len(result.ToolCalls) > 0 {
		return "", errors.New("AI returned an unexpected tool call")
	}
	return normalizeBQLHistoryTitle(result.Content)
}

func normalizeBQLHistoryTitle(value string) (string, error) {
	lines := strings.FieldsFunc(value, func(r rune) bool { return r == '\n' || r == '\r' })
	if len(lines) == 0 {
		return "", errors.New("title is required")
	}
	title := strings.Trim(strings.TrimSpace(lines[0]), "`\\\"'")
	title = strings.TrimPrefix(title, "标题：")
	title = strings.TrimPrefix(title, "标题:")
	title = strings.TrimSpace(title)
	length := len([]rune(title))
	if length < 2 {
		return "", errors.New("title is too short")
	}
	if length > 40 {
		return "", fmt.Errorf("title is too long")
	}
	return title, nil
}

func sortBQLHistory(records []BQLHistoryRecord) {
	sort.SliceStable(records, func(left, right int) bool {
		if records[left].LastRunAt.Equal(records[right].LastRunAt) {
			return records[left].ID < records[right].ID
		}
		return records[left].LastRunAt.After(records[right].LastRunAt)
	})
}

func splitBQLHistoryStatements(raw string) []string {
	statements := []string{}
	start := 0
	quote := rune(0)
	escaped := false
	for index, char := range raw {
		if quote != 0 {
			if escaped {
				escaped = false
				continue
			}
			if char == '\\' {
				escaped = true
				continue
			}
			if char == quote {
				quote = 0
			}
			continue
		}
		if char == '\'' || char == '"' {
			quote = char
			continue
		}
		if char == ';' {
			if statement := strings.TrimSpace(raw[start:index]); statement != "" {
				statements = append(statements, statement)
			}
			start = index + 1
		}
	}
	if statement := strings.TrimSpace(raw[start:]); statement != "" {
		statements = append(statements, statement)
	}
	return statements
}
