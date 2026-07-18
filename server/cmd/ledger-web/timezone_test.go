package main

import (
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestLedgerWebEmbedsTimezoneDatabase(t *testing.T) {
	output, err := exec.Command("go", "list", "-deps", ".").CombinedOutput()
	if err != nil {
		t.Fatalf("go list dependencies: %v\n%s", err, output)
	}
	dependencies := "\n" + string(output)
	if !strings.Contains(dependencies, "\ntime/tzdata\n") {
		t.Fatal("ledger-web binary must embed time/tzdata for minimal runtime images")
	}
}

func TestLedgerWebLoadsShanghaiTimezone(t *testing.T) {
	location, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		t.Fatal(err)
	}
	if location.String() != "Asia/Shanghai" {
		t.Fatalf("location = %q", location)
	}
}
