package app

import (
	"log"
	"time"
)

func logDuration(name string, start time.Time, fields map[string]any) {
	if truthyEnv("LEDGER_TIMING_LOGS_DISABLED") {
		return
	}
	if fields == nil {
		fields = map[string]any{}
	}
	fields["elapsedMs"] = time.Since(start).Milliseconds()
	log.Printf("[ledger] %s %+v", name, fields)
}
