package app

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

const ledgerMobileAppID = "H92F889YBH.com.qiaoborui.ledger.mobile"

func (s *Server) appleAppSiteAssociation(c *gin.Context) {
	c.Header("Cache-Control", "public, max-age=3600")
	c.JSON(http.StatusOK, gin.H{
		"webcredentials": gin.H{
			"apps": []string{ledgerMobileAppID},
		},
	})
}
