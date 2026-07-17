package app

import (
	"fmt"
	"net/http"
	"path/filepath"
	"time"

	"github.com/gin-gonic/gin"
)

func (s *Server) importsPreview(c *gin.Context) {
	if !s.limiter.Check(c, "imports.preview", 10, time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	if err := ensureLedgerReady(s.cfg); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	file, header, err := c.Request.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "file is required"})
		return
	}
	_ = file.Close()
	originalFile, originalHeader, err := c.Request.FormFile("originalFile")
	if err == nil {
		_ = originalFile.Close()
	} else {
		originalHeader = nil
	}
	result, err := s.createImportPreview(c.Request.Context(), c.Request.FormValue("provider"), truthyFormValue(c.Request.FormValue("alipayFundRounding")), c.Request.FormValue("archivePassword"), header, originalHeader)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, result)
}

func (s *Server) importsProviders(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	c.JSON(http.StatusOK, gin.H{"providers": s.importerRegistry().Options()})
}

func (s *Server) importsDocuments(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	if err := ensureLedgerReady(s.cfg); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	documents, err := s.listImportDocuments()
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"documents": documents})
}

func (s *Server) importsDocumentFile(c *gin.Context) {
	if !requireAuth(c) {
		return
	}
	if err := ensureLedgerReady(s.cfg); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	path, full, err := cleanImportDocumentPath(s.cfg, c.Query("path"))
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.Header("Content-Disposition", `inline; filename="`+filepath.Base(path)+`"`)
	if githubAPIEnabled(s.cfg) {
		client, clientErr := newGitHubLedgerClient(s.cfg)
		if clientErr != nil {
			errorJSON(c, http.StatusBadRequest, clientErr)
			return
		}
		content, readErr := client.readLedgerFile(c.Request.Context(), path)
		if readErr != nil {
			errorJSON(c, http.StatusBadRequest, readErr)
			return
		}
		c.Data(http.StatusOK, "application/octet-stream", content)
		return
	}
	c.File(full)
}

func (s *Server) importsCommit(c *gin.Context) {
	if !s.limiter.Check(c, "imports.commit", 10, time.Minute) {
		return
	}
	if !requireAuth(c) {
		return
	}
	var input ImportCommitRequest
	if !bindJSON(c, &input) {
		return
	}
	if pending, err := s.isGmailPendingImport(c.Request.Context(), input.ImportID); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	} else if pending && !requireSensitive(c) {
		return
	}
	if err := ensureLedgerReady(s.cfg); err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	claimedPending, err := s.claimGmailPendingImport(c.Request.Context(), input.ImportID)
	if err != nil {
		errorJSON(c, http.StatusConflict, err)
		return
	}
	result, err := s.commitImport(c.Request.Context(), input.ImportID, input.Provider, input.Entries)
	if err != nil {
		if claimedPending {
			if statusErr := s.updateGmailPendingStatus(c.Request.Context(), input.ImportID, "ready", err.Error()); statusErr != nil {
				err = fmt.Errorf("%w; 恢复自动账单状态失败: %v", err, statusErr)
			}
		}
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	if claimedPending {
		if err := s.updateGmailPendingStatus(c.Request.Context(), input.ImportID, "committed", ""); err != nil {
			errorJSON(c, http.StatusInternalServerError, fmt.Errorf("账本已写入，自动账单状态同步失败，请重试: %w", err))
			return
		}
	}
	c.JSON(http.StatusOK, result)
}
