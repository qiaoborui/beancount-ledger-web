package agentmemory

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCleanPath(t *testing.T) {
	for raw, want := range map[string]string{
		"":                         IndexName,
		"memory":                   IndexName,
		"/MEMORY.md":               IndexName,
		"merchants":                "merchants.md",
		"./accounts/credit-cards":  "accounts/credit-cards.md",
		"accounts/credit-cards.md": "accounts/credit-cards.md",
	} {
		got, err := CleanPath(raw)
		if err != nil || got != want {
			t.Errorf("CleanPath(%q) = %q, %v; want %q", raw, got, err, want)
		}
	}
	for _, bad := range []string{"../x", "a/b/c/d", "Merchants", "商户", "a/MEMORY.md", ".hidden", "a//b", "-x"} {
		if got, err := CleanPath(bad); err == nil {
			t.Errorf("CleanPath(%q) = %q, want an error", bad, got)
		}
	}
}

func TestDescriptionAndFrontMatter(t *testing.T) {
	content := WithDescription("# 信用卡\n- 招行 5 号出账", "信用卡账单日")
	if !strings.HasPrefix(content, "---\ndescription: 信用卡账单日\n---\n\n# 信用卡") {
		t.Fatalf("front matter: %q", content)
	}
	if got := Description(content); got != "信用卡账单日" {
		t.Errorf("description = %q", got)
	}
	again := WithDescription(content, "信用卡账单日和还款")
	if strings.Count(again, "description:") != 1 || Description(again) != "信用卡账单日和还款" {
		t.Errorf("replaced front matter: %q", again)
	}
	if got := Description("# 商户\n- 美团"); got != "商户" {
		t.Errorf("fallback description = %q", got)
	}
}

func TestFolderMigratesLegacyMemory(t *testing.T) {
	runtime := t.TempDir()
	legacy := filepath.Join(runtime, "agent-memory.md")
	if err := os.WriteFile(legacy, []byte("## 偏好\n- 金额保留两位小数\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	folder, err := Open(legacy) // an old shell names the file
	if err != nil {
		t.Fatal(err)
	}
	if folder.Root() != filepath.Join(runtime, "agent-memory") {
		t.Fatalf("root = %s", folder.Root())
	}
	got, err := folder.Read(IndexName)
	if err != nil || got != "## 偏好\n- 金额保留两位小数\n" {
		t.Fatalf("MEMORY.md = %q, %v", got, err)
	}
	if _, err := os.Stat(legacy); !os.IsNotExist(err) {
		t.Fatal("legacy memory.md is still there")
	}

	// An older device writes memory.md again: its new lines are kept.
	if err := os.WriteFile(legacy, []byte("## 偏好\n- 金额保留两位小数\n- 星巴克记 Coffee\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(folder.Root()); err != nil {
		t.Fatal(err)
	}
	got, _ = folder.Read(IndexName)
	if got != "## 偏好\n- 金额保留两位小数\n- 星巴克记 Coffee\n" {
		t.Fatalf("merged legacy = %q", got)
	}
}

func TestFolderWriteDeleteAndCatalog(t *testing.T) {
	folder, err := Open(filepath.Join(t.TempDir(), "agent-memory"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := folder.Write("MEMORY.md", "- 说这个月指自然月"); err != nil {
		t.Fatal(err)
	}
	if _, err := folder.Write("accounts/credit-cards", WithDescription("- 招行 5 号出账", "信用卡账单日")); err != nil {
		t.Fatal(err)
	}
	if _, err := folder.Write("merchants.md", "# 常见商户\n- 美团外卖记 Food:Delivery"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder.Root(), ".memory-123"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	snapshot, err := folder.Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot) != 3 {
		t.Fatalf("snapshot = %v", snapshot)
	}
	index := IndexText(snapshot.Catalog())
	want := "- accounts/credit-cards.md — 信用卡账单日（"
	if !strings.HasPrefix(index, want) || !strings.Contains(index, "- merchants.md — 常见商户（") {
		t.Fatalf("index = %q", index)
	}
	if _, err := folder.Write("big", strings.Repeat("x", MaxFileBytes+1)); err == nil {
		t.Error("an oversized file was written")
	}
	if _, err := folder.Delete("accounts/credit-cards"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(folder.Root(), "accounts")); !os.IsNotExist(err) {
		t.Error("the emptied folder is still there")
	}
}

func TestReplaceRefusesAChangedFolder(t *testing.T) {
	folder, _ := Open(filepath.Join(t.TempDir(), "m"))
	_, _ = folder.Write(IndexName, "- a")
	before, _ := folder.Load()
	_, _ = folder.Write(IndexName, "- b")
	if _, err := folder.Replace(before, Snapshot{IndexName: "- c\n"}); err != ErrChanged {
		t.Fatalf("err = %v", err)
	}
	now, _ := folder.Load()
	changed, err := folder.Replace(now, Snapshot{"x.md": "- x\n"})
	if err != nil || !changed {
		t.Fatal(changed, err)
	}
	after, _ := folder.Load()
	if !after.Equal(Snapshot{"x.md": "- x\n"}) {
		t.Fatalf("after = %v", after)
	}
}

func TestMerge(t *testing.T) {
	base := Snapshot{
		IndexName:      "## 分类\n- 美团记 Food\n- 滴滴记 Taxi\n",
		"old.md":       "- old\n",
		"edited.md":    "- one\n",
		"deleted.md":   "- gone\n",
		"untouched.md": "- same\n",
	}
	local := Snapshot{
		IndexName:      "## 分类\n- 美团记 Food\n- 滴滴记 Taxi\n- 星巴克记 Coffee\n",
		"old.md":       "- old\n",
		"edited.md":    "- one, edited here\n",
		"untouched.md": "- same\n",
		"new-here.md":  "- here\n",
	}
	remote := Snapshot{
		IndexName:      "## 分类\n- 美团记 Food\n- 房租每月 1 号\n",
		"edited.md":    "- one\n",
		"deleted.md":   "- gone, but edited there\n",
		"untouched.md": "- same\n",
		"new-there.md": "- there\n",
	}
	got := Merge(base, local, remote)
	want := Snapshot{
		IndexName:      "## 分类\n- 美团记 Food\n- 房租每月 1 号\n- 星巴克记 Coffee\n",
		"edited.md":    "- one, edited here\n",
		"deleted.md":   "- gone, but edited there\n",
		"untouched.md": "- same\n",
		"new-here.md":  "- here\n",
		"new-there.md": "- there\n",
	}
	if !got.Equal(want) {
		t.Fatalf("merge =\n%v\nwant\n%v", got, want)
	}
}

func TestMergeLinesKeepsFrontMatter(t *testing.T) {
	base := "---\ndescription: 卡\n---\n\n- a\n"
	local := "---\ndescription: 卡\n---\n\n- a\n- b\n"
	remote := "---\ndescription: 信用卡\n---\n\n- a\n- c\n"
	got := MergeLines(base, local, remote)
	if !strings.HasPrefix(got, "---\ndescription: 信用卡\n---\n") || !strings.Contains(got, "- b\n") || !strings.Contains(got, "- c\n") {
		t.Fatalf("merged = %q", got)
	}
}
