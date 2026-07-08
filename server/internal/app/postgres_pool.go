package app

import (
	"database/sql"
	"os"
	"strconv"
	"strings"
	"time"
)

type postgresPoolSettings struct {
	maxOpenConns    int
	maxIdleConns    int
	connMaxIdleTime time.Duration
}

func configurePostgresPool(db *sql.DB) {
	settings := postgresPoolSettingsFromEnv()
	db.SetMaxOpenConns(settings.maxOpenConns)
	db.SetMaxIdleConns(settings.maxIdleConns)
	db.SetConnMaxIdleTime(settings.connMaxIdleTime)
}

func postgresPoolSettingsFromEnv() postgresPoolSettings {
	return postgresPoolSettings{
		maxOpenConns:    envNonNegativeInt("POSTGRES_MAX_OPEN_CONNS", 4),
		maxIdleConns:    envNonNegativeInt("POSTGRES_MAX_IDLE_CONNS", 4),
		connMaxIdleTime: time.Duration(envNonNegativeInt("POSTGRES_CONN_MAX_IDLE_SECONDS", 300)) * time.Second,
	}
}

func envNonNegativeInt(key string, fallback int) int {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 0 {
		return fallback
	}
	return value
}
