// Package logging provides the shared structured logger setup used by every
// server entry point. It reads level and format from the environment, so all
// commands produce consistent, queryable JSON output by default.
package logging

import (
	"fmt"
	"log/slog"
	"os"
	"strings"
)

// Format selects the log output encoding.
type Format string

const (
	// FormatJSON writes one JSON object per log line.
	FormatJSON Format = "json"
	// FormatText writes human-friendly key=value lines.
	FormatText Format = "text"
)

const (
	envLevel  = "LEDGER_LOG_LEVEL"
	envFormat = "LEDGER_LOG_FORMAT"
)

// Config describes how the process logger should behave.
type Config struct {
	Level  slog.Level
	Format Format
}

// LoadConfig reads logger settings from the environment. Absent or invalid
// values fall back to the defaults: info level and JSON output.
func LoadConfig() Config {
	return Config{
		Level:  parseLevelOr(os.Getenv(envLevel), slog.LevelInfo),
		Format: parseFormatOr(os.Getenv(envFormat), FormatJSON),
	}
}

// ParseLevel converts a level name (debug|info|warn|error) to a slog.Level.
func ParseLevel(value string) (slog.Level, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "debug":
		return slog.LevelDebug, nil
	case "info", "":
		return slog.LevelInfo, nil
	case "warn", "warning":
		return slog.LevelWarn, nil
	case "error":
		return slog.LevelError, nil
	}
	return 0, fmt.Errorf("unknown log level %q (want debug|info|warn|error)", value)
}

// ParseFormat converts a format name (json|text) to a Format.
func ParseFormat(value string) (Format, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "json", "":
		return FormatJSON, nil
	case "text":
		return FormatText, nil
	}
	return "", fmt.Errorf("unknown log format %q (want json|text)", value)
}

// New builds the process logger from config, writing to standard error so that
// stdout stays reserved for command output.
func New(config Config) *slog.Logger {
	options := &slog.HandlerOptions{Level: config.Level}
	var handler slog.Handler
	if config.Format == FormatText {
		handler = slog.NewTextHandler(os.Stderr, options)
	} else {
		handler = slog.NewJSONHandler(os.Stderr, options)
	}
	return slog.New(handler)
}

func parseLevelOr(value string, fallback slog.Level) slog.Level {
	level, err := ParseLevel(value)
	if err != nil {
		return fallback
	}
	return level
}

func parseFormatOr(value string, fallback Format) Format {
	format, err := ParseFormat(value)
	if err != nil {
		return fallback
	}
	return format
}
