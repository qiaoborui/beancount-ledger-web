package logging

import (
	"log/slog"
	"testing"
)

func TestParseLevel(t *testing.T) {
	tests := []struct {
		value string
		want  slog.Level
	}{
		{"debug", slog.LevelDebug},
		{"DEBUG", slog.LevelDebug},
		{"info", slog.LevelInfo},
		{"Info", slog.LevelInfo},
		{"", slog.LevelInfo},
		{"warn", slog.LevelWarn},
		{"warning", slog.LevelWarn},
		{"error", slog.LevelError},
		{"ERROR", slog.LevelError},
	}
	for _, test := range tests {
		got, err := ParseLevel(test.value)
		if err != nil {
			t.Errorf("ParseLevel(%q) unexpected error: %v", test.value, err)
			continue
		}
		if got != test.want {
			t.Errorf("ParseLevel(%q) = %v, want %v", test.value, got, test.want)
		}
	}
}

func TestParseLevelRejectsUnknown(t *testing.T) {
	for _, value := range []string{"verbose", "trace", "fatal", "  notice "} {
		if _, err := ParseLevel(value); err == nil {
			t.Errorf("ParseLevel(%q) expected error", value)
		}
	}
}

func TestParseFormat(t *testing.T) {
	tests := []struct {
		value string
		want  Format
	}{
		{"json", FormatJSON},
		{"JSON", FormatJSON},
		{"", FormatJSON},
		{"text", FormatText},
		{"TEXT", FormatText},
	}
	for _, test := range tests {
		got, err := ParseFormat(test.value)
		if err != nil {
			t.Errorf("ParseFormat(%q) unexpected error: %v", test.value, err)
			continue
		}
		if got != test.want {
			t.Errorf("ParseFormat(%q) = %q, want %q", test.value, got, test.want)
		}
	}
}

func TestParseFormatRejectsUnknown(t *testing.T) {
	if _, err := ParseFormat("yaml"); err == nil {
		t.Error("ParseFormat(\"yaml\") expected error")
	}
}

func TestLoadConfigAppliesEnvironment(t *testing.T) {
	t.Setenv(envLevel, "warn")
	t.Setenv(envFormat, "text")
	config := LoadConfig()
	if config.Level != slog.LevelWarn {
		t.Errorf("LoadConfig level = %v, want %v", config.Level, slog.LevelWarn)
	}
	if config.Format != FormatText {
		t.Errorf("LoadConfig format = %q, want %q", config.Format, FormatText)
	}
}

func TestLoadConfigFallsBackToDefaults(t *testing.T) {
	t.Setenv(envLevel, "bogus")
	t.Setenv(envFormat, "bogus")
	config := LoadConfig()
	if config.Level != slog.LevelInfo {
		t.Errorf("LoadConfig level = %v, want %v", config.Level, slog.LevelInfo)
	}
	if config.Format != FormatJSON {
		t.Errorf("LoadConfig format = %q, want %q", config.Format, FormatJSON)
	}
}

func TestNewBuildsLogger(t *testing.T) {
	logger := New(Config{Level: slog.LevelDebug, Format: FormatJSON})
	if logger == nil {
		t.Fatal("New returned nil logger")
	}
	logger.Info("hello")
}
