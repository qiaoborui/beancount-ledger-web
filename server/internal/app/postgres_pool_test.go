package app

import (
	"testing"
	"time"
)

func TestPostgresPoolSettingsDefaults(t *testing.T) {
	settings := postgresPoolSettingsFromEnv()

	if settings.maxOpenConns != 4 || settings.maxIdleConns != 4 || settings.connMaxIdleTime != 5*time.Minute {
		t.Fatalf("settings=%#v, want 4/4/5m", settings)
	}
}

func TestPostgresPoolSettingsFromEnv(t *testing.T) {
	t.Setenv("POSTGRES_MAX_OPEN_CONNS", "2")
	t.Setenv("POSTGRES_MAX_IDLE_CONNS", "1")
	t.Setenv("POSTGRES_CONN_MAX_IDLE_SECONDS", "60")

	settings := postgresPoolSettingsFromEnv()

	if settings.maxOpenConns != 2 || settings.maxIdleConns != 1 || settings.connMaxIdleTime != time.Minute {
		t.Fatalf("settings=%#v, want 2/1/1m", settings)
	}
}

func TestPostgresPoolSettingsIgnoreInvalidEnv(t *testing.T) {
	t.Setenv("POSTGRES_MAX_OPEN_CONNS", "-1")
	t.Setenv("POSTGRES_MAX_IDLE_CONNS", "bad")
	t.Setenv("POSTGRES_CONN_MAX_IDLE_SECONDS", "-30")

	settings := postgresPoolSettingsFromEnv()

	if settings.maxOpenConns != 4 || settings.maxIdleConns != 4 || settings.connMaxIdleTime != 5*time.Minute {
		t.Fatalf("settings=%#v, want fallback defaults", settings)
	}
}
