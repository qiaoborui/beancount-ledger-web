package app

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
)

func parseInt64(value string) (int64, error) { return strconv.ParseInt(value, 10, 64) }
func formatInt(value int) string             { return strconv.Itoa(value) }
func formatInt64(value int64) string         { return strconv.FormatInt(value, 10) }

func bindJSON(c *gin.Context, out any) bool {
	if err := c.ShouldBindJSON(out); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return false
	}
	return true
}

func errorJSON(c *gin.Context, status int, err error) {
	c.JSON(status, gin.H{"error": err.Error()})
}

func readLooseJSON(c *gin.Context) (map[string]any, bool) {
	var out map[string]any
	if err := json.NewDecoder(c.Request.Body).Decode(&out); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return nil, false
	}
	return out, true
}
