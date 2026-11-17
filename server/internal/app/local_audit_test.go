package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func auditWorkspace(t *testing.T, files map[string]string) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "generations", "g1", "workspace")
	for name, body := range files {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

const auditMain = `include "txn/*.bean"
2026-01-01 open Assets:Card CNY
2026-01-01 open Assets:Cash CNY
2026-01-01 open Assets:Alipay CNY
2026-01-01 open Expenses:Food CNY
2026-01-01 open Expenses:Uncategorized CNY
2026-08-01 balance Assets:Card 0 CNY
2026-11-10 balance Assets:Cash 0 CNY
`

func TestLocalAuditFindsEachProblemOnce(t *testing.T) {
	root := auditWorkspace(t, map[string]string{
		"main.bean": auditMain,
		"txn/bank.bean": `2026-11-12 * "美团" "午饭"
  Expenses:Food  38.50 CNY
  Assets:Card
`,
		"txn/alipay.bean": `2026-11-13 * "美团外卖" "午饭"
  Expenses:Food  38.50 CNY
  Assets:Card
2026-11-14 ! "超市" "TODO 拆分"
  Expenses:Uncategorized  12.00 CNY
  Assets:Cash
`,
		"orphan/2026-10.bean": "2026-10-01 * \"丢了\"\n  Expenses:Food 1 CNY\n  Assets:Cash\n",
		"archive/old.bean":    "; not expected to be included\n",
	})
	report, err := RunLocalAudit(LocalRequest{WorkspaceRoot: root}, AuditOptions{Today: "2026-11-17"})
	if err != nil {
		t.Fatal(err)
	}
	checks := map[string]AuditFinding{}
	for _, finding := range report.Findings {
		if _, dup := checks[finding.Check]; dup {
			t.Fatalf("check %s reported twice: %+v", finding.Check, report.Findings)
		}
		checks[finding.Check] = finding
	}
	for _, want := range []string{"duplicate", "unresolved", "stale-balance", "unincluded"} {
		if _, ok := checks[want]; !ok {
			t.Fatalf("missing %s in %+v", want, report.Findings)
		}
	}
	if refs := checks["duplicate"].Refs; len(refs) != 2 || !strings.HasPrefix(refs[0], "txn/") {
		t.Fatalf("duplicate refs = %v", refs)
	}
	if checks["unincluded"].Refs[0] != "orphan/2026-10.bean" {
		t.Fatalf("unincluded = %+v", checks["unincluded"])
	}
	if !strings.Contains(checks["stale-balance"].Title, "Assets:Card") {
		t.Fatalf("stale = %+v", checks["stale-balance"])
	}
	// Fingerprints are stable across runs and an ignored one stays out.
	again, err := RunLocalAudit(LocalRequest{WorkspaceRoot: root},
		AuditOptions{Today: "2026-11-17", Ignored: []string{checks["duplicate"].ID}})
	if err != nil {
		t.Fatal(err)
	}
	for _, finding := range again.Findings {
		if finding.Check == "duplicate" {
			t.Fatalf("ignored finding came back: %+v", finding)
		}
		if finding.ID != checks[finding.Check].ID {
			t.Fatalf("fingerprint changed for %s", finding.Check)
		}
	}
}

func TestLocalAuditIsQuietOnACleanLedger(t *testing.T) {
	root := auditWorkspace(t, map[string]string{
		"main.bean": auditMain,
		"txn/a.bean": `2026-11-12 * "房东" "房租"
  Expenses:Food  100.00 CNY
  Assets:Cash
`,
	})
	report, err := RunLocalAudit(LocalRequest{WorkspaceRoot: root}, AuditOptions{Today: "2026-11-17"})
	if err != nil {
		t.Fatal(err)
	}
	if len(report.Findings) != 0 {
		t.Fatalf("unexpected findings: %+v", report.Findings)
	}
}
