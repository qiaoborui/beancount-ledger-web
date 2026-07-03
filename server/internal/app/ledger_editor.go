package app

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

const ledgerEditorMaxFileBytes = 2_000_000

type LedgerEditorFile struct {
	Path    string `json:"path"`
	Name    string `json:"name"`
	Dir     string `json:"dir"`
	Size    int64  `json:"size"`
	ModTime string `json:"modTime"`
}

type LedgerEditorSaveRequest struct {
	Path         string `json:"path"`
	Content      string `json:"content"`
	PreviousHash string `json:"previousHash,omitempty"`
}

func (input LedgerEditorSaveRequest) Validate() error {
	if strings.TrimSpace(input.Path) == "" {
		return errors.New("path is required")
	}
	if len(input.Content) > ledgerEditorMaxFileBytes {
		return fmt.Errorf("file is too large, max %d bytes", ledgerEditorMaxFileBytes)
	}
	return nil
}

func (s *Server) editorFiles(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	if err := ensureLedgerReady(s.cfg); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	files, err := listLedgerEditorFiles(s.cfg)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"files": files})
}

func (s *Server) editorFile(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	if err := ensureLedgerReady(s.cfg); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	rel, full, err := cleanLedgerEditorPath(s.cfg, c.Query("path"))
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	content, info, hash, err := readLedgerEditorFile(full)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"path": rel, "content": content, "hash": hash, "modTime": info.ModTime().UTC().Format(time.RFC3339Nano), "size": info.Size()})
}

func (s *Server) saveEditorFile(c *gin.Context) {
	if !requireSensitive(c) {
		return
	}
	var input LedgerEditorSaveRequest
	if !bindJSON(c, &input) {
		return
	}
	if err := ensureLedgerReady(s.cfg); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	rel, full, err := cleanLedgerEditorPath(s.cfg, input.Path)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	before, info, currentHash, err := readLedgerEditorFile(full)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if input.PreviousHash != "" && input.PreviousHash != currentHash {
		c.JSON(http.StatusConflict, gin.H{"error": "file changed on disk, reload before saving", "path": rel, "hash": currentHash, "content": before, "modTime": info.ModTime().UTC().Format(time.RFC3339Nano)})
		return
	}
	if err := s.writer.ReplaceLedgerFile(full, []byte(input.Content)); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	_, nextInfo, nextHash, err := readLedgerEditorFile(full)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "path": rel, "hash": nextHash, "modTime": nextInfo.ModTime().UTC().Format(time.RFC3339Nano), "size": nextInfo.Size()})
}

func listLedgerEditorFiles(cfg Config) ([]LedgerEditorFile, error) {
	root, err := filepath.Abs(cfg.LedgerRoot)
	if err != nil {
		return nil, err
	}
	runtimeDir, _ := filepath.Abs(cfg.RuntimeDir)
	files := []LedgerEditorFile{}
	err = filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == root {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if entry.IsDir() {
			if shouldSkipLedgerEditorDir(path, rel, runtimeDir) {
				return filepath.SkipDir
			}
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 || !isLedgerEditorPathAllowed(rel) {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Size() > ledgerEditorMaxFileBytes {
			return nil
		}
		files = append(files, LedgerEditorFile{Path: rel, Name: filepath.Base(rel), Dir: filepath.ToSlash(filepath.Dir(rel)), Size: info.Size(), ModTime: info.ModTime().UTC().Format(time.RFC3339Nano)})
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(files, func(i, j int) bool {
		return editorFileSortKey(files[i].Path) < editorFileSortKey(files[j].Path)
	})
	return files, nil
}

func cleanLedgerEditorPath(cfg Config, rawPath string) (string, string, error) {
	trimmed := strings.TrimSpace(rawPath)
	if trimmed == "" {
		return "", "", errors.New("path is required")
	}
	if strings.Contains(trimmed, "\x00") || filepath.IsAbs(trimmed) {
		return "", "", errors.New("invalid ledger editor path")
	}
	rel := filepath.ToSlash(filepath.Clean(trimmed))
	if rel == "." || strings.HasPrefix(rel, "../") || strings.Contains(rel, "/../") {
		return "", "", errors.New("invalid ledger editor path")
	}
	if strings.Contains(rel, "/.") || strings.HasPrefix(rel, ".") || strings.HasPrefix(rel, "imports/") || rel == "imports" {
		return "", "", errors.New("path is outside editable ledger files")
	}
	if !isLedgerEditorPathAllowed(rel) {
		return "", "", fmt.Errorf("path is not editable: %s", rel)
	}
	root, err := filepath.Abs(cfg.LedgerRoot)
	if err != nil {
		return "", "", err
	}
	full, err := filepath.Abs(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		return "", "", err
	}
	if full != root && !strings.HasPrefix(full, root+string(filepath.Separator)) {
		return "", "", errors.New("path is outside ledger root")
	}
	info, err := os.Lstat(full)
	if err != nil {
		return "", "", err
	}
	if info.Mode()&os.ModeSymlink != 0 || info.IsDir() {
		return "", "", errors.New("path is not a regular editable file")
	}
	return rel, full, nil
}

func readLedgerEditorFile(full string) (string, os.FileInfo, string, error) {
	info, err := os.Stat(full)
	if err != nil {
		return "", nil, "", err
	}
	if !info.Mode().IsRegular() {
		return "", nil, "", errors.New("path is not a regular file")
	}
	if info.Size() > ledgerEditorMaxFileBytes {
		return "", nil, "", fmt.Errorf("file is too large, max %d bytes", ledgerEditorMaxFileBytes)
	}
	content, err := os.ReadFile(full)
	if err != nil {
		return "", nil, "", err
	}
	hash := sha256.Sum256(content)
	return string(content), info, hex.EncodeToString(hash[:])[:16], nil
}

func shouldSkipLedgerEditorDir(path, rel, runtimeDir string) bool {
	base := filepath.Base(path)
	if base == ".git" || base == ".runtime" || strings.HasPrefix(base, ".") || rel == "imports" || strings.HasPrefix(rel, "imports/") {
		return true
	}
	if runtimeDir != "" {
		if full, err := filepath.Abs(path); err == nil && (full == runtimeDir || strings.HasPrefix(full, runtimeDir+string(filepath.Separator))) {
			return true
		}
	}
	return false
}

func isLedgerEditorPathAllowed(rel string) bool {
	base := filepath.Base(rel)
	switch rel {
	case "main.bean", "accounts.bean", "commodities.bean", "prices.bean", "README.md":
		return true
	}
	if strings.HasPrefix(rel, "imports/") || strings.Contains(rel, "/.") || strings.HasPrefix(rel, ".") {
		return false
	}
	switch strings.ToLower(filepath.Ext(base)) {
	case ".bean", ".beancount":
		return true
	default:
		return false
	}
}

func editorFileSortKey(path string) string {
	order := map[string]string{
		"main.bean":        "00-main.bean",
		"commodities.bean": "01-commodities.bean",
		"accounts.bean":    "02-accounts.bean",
		"prices.bean":      "04-prices.bean",
		"README.md":        "98-readme.md",
	}
	if key, ok := order[path]; ok {
		return key
	}
	return "50-" + path
}
