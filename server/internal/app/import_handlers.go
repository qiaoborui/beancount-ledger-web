package app

import (
	"net/http"
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
	result, err := s.createImportPreview(c.Request.FormValue("provider"), truthyFormValue(c.Request.FormValue("alipayFundRounding")), header, originalHeader)
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
	c.JSON(http.StatusOK, gin.H{"providers": importProviderOptions()})
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
	result, err := s.commitImport(input.ImportID, input.Provider, input.Entries)
	if err != nil {
		errorJSON(c, http.StatusBadRequest, err)
		return
	}
	c.JSON(http.StatusOK, result)
}
