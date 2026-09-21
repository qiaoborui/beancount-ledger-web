// ledger-stream-check independently verifies a bounded-v1 file. Output contains
// only nonfinancial counts/digests, never a record value or an input path.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/borui/beancount-ledger-web/server/internal/boundedstream"
)

func main() { os.Exit(run()) }

func run() int {
	if len(os.Args) != 2 || os.Args[1] == "" || os.Args[1][0] == '-' {
		fmt.Fprintln(os.Stderr, "usage: ledger-stream-check STREAM_PATH")
		return 2
	}
	input, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "cannot open stream")
		return 1
	}
	defer input.Close()
	info, err := input.Stat()
	if err != nil || !info.Mode().IsRegular() {
		fmt.Fprintln(os.Stderr, "stream must be a readable regular file")
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	summary, err := boundedstream.Verify(ctx, input, nil)
	if err != nil {
		fmt.Fprintln(os.Stderr, "verification failed:", err)
		return 1
	}
	if err := json.NewEncoder(os.Stdout).Encode(summary); err != nil {
		fmt.Fprintln(os.Stderr, "cannot write verification summary")
		return 1
	}
	return 0
}
