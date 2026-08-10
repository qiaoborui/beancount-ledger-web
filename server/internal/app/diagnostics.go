package app

import (
	"time"
)

func (s *Server) logDuration(name string, start time.Time, fields map[string]any) {
	if truthyEnv("LEDGER_TIMING_LOGS_DISABLED") {
		return
	}
	if fields == nil {
		fields = map[string]any{}
	}
	fields["elapsed_ms"] = time.Since(start).Milliseconds()
	s.loggerOr().Info(name, slogFields(fields)...)
}

// slogFields flattens a field map into alternating key/value slog args. Keys
// are fixed strings, so the resulting log entries stay JSON-safe.
func slogFields(fields map[string]any) []any {
	args := make([]any, 0, len(fields)*2)
	for key, value := range fields {
		args = append(args, key, value)
	}
	return args
}
