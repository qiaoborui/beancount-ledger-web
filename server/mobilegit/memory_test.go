package mobilegit

import (
	"os"
	"path/filepath"
	"testing"

	git "github.com/go-git/go-git/v5"

	"github.com/borui/beancount-ledger-web/server/agentmemory"
)

func TestSyncMemoryMergesTwoDevicesThroughTheBranch(t *testing.T) {
	root := t.TempDir()
	remotePath := filepath.Join(root, "remote.git")
	if _, err := git.PlainInit(remotePath, true); err != nil {
		t.Fatal(err)
	}
	sync := func(device string) map[string]any {
		return call(t, request{Operation: "syncMemory", StorageRoot: filepath.Join(root, device, "cache"),
			Directory: filepath.Join(root, device, "agent-memory"), URL: fileRemote(remotePath), Branch: agentmemory.BranchName})
	}
	read := func(device, path string) string {
		data, err := os.ReadFile(filepath.Join(root, device, "agent-memory", path))
		if err != nil {
			return ""
		}
		return string(data)
	}

	// An empty memory and an absent branch: nothing to push.
	if result := sync("phone"); result["remoteHead"] != "" {
		t.Fatalf("empty sync pushed: %v", result)
	}

	// The phone still has the single memory.md of an older version.
	write(t, filepath.Join(root, "phone"), "agent-memory.md", "## 偏好\n- 金额保留两位小数\n")
	write(t, filepath.Join(root, "phone"), "agent-memory/merchants.md", "---\ndescription: 商户\n---\n\n- 美团记 Food\n")
	first := sync("phone")
	if first["remoteHead"] == "" || first["pushed"].(float64) != 2 {
		t.Fatalf("first push: %v", first)
	}
	if result := sync("pad"); result["pulled"].(float64) != 2 || read("pad", "MEMORY.md") != "## 偏好\n- 金额保留两位小数\n" {
		t.Fatalf("pad did not pull: %v %q", result, read("pad", "MEMORY.md"))
	}

	// Both edit MEMORY.md, the pad deletes merchants.md while the phone
	// edits it, and the pad adds a file.
	write(t, filepath.Join(root, "phone"), "agent-memory/MEMORY.md", "## 偏好\n- 金额保留两位小数\n- 这个月指自然月\n")
	write(t, filepath.Join(root, "phone"), "agent-memory/merchants.md", "---\ndescription: 商户\n---\n\n- 美团记 Food\n- 滴滴记 Taxi\n")
	write(t, filepath.Join(root, "pad"), "agent-memory/MEMORY.md", "## 偏好\n- 金额保留两位小数\n- 回答用表格\n")
	if err := os.Remove(filepath.Join(root, "pad", "agent-memory", "merchants.md")); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(root, "pad"), "agent-memory/accounts/credit-cards.md", "---\ndescription: 信用卡\n---\n\n- 招行 5 号出账\n")
	sync("phone")
	sync("pad")
	sync("phone")
	wantIndex := "## 偏好\n- 金额保留两位小数\n- 回答用表格\n- 这个月指自然月\n"
	for _, device := range []string{"phone", "pad"} {
		if got := read(device, "MEMORY.md"); got != wantIndex && got != "## 偏好\n- 金额保留两位小数\n- 这个月指自然月\n- 回答用表格\n" {
			t.Errorf("%s MEMORY.md = %q", device, got)
		}
		if got := read(device, "merchants.md"); got != "---\ndescription: 商户\n---\n\n- 美团记 Food\n- 滴滴记 Taxi\n" {
			t.Errorf("%s merchants.md = %q (an edit beats a deletion)", device, got)
		}
		if got := read(device, "accounts/credit-cards.md"); got == "" {
			t.Errorf("%s is missing the new file", device)
		}
	}
	if read("phone", "MEMORY.md") != read("pad", "MEMORY.md") {
		t.Fatal("the devices did not converge")
	}

	// A file deleted on one side only goes everywhere.
	if err := os.Remove(filepath.Join(root, "phone", "agent-memory", "accounts", "credit-cards.md")); err != nil {
		t.Fatal(err)
	}
	sync("phone")
	sync("pad")
	if read("pad", "accounts/credit-cards.md") != "" {
		t.Fatal("the deletion did not reach the pad")
	}
	// Nothing changed: no new commit.
	before := sync("pad")["remoteHead"]
	if after := sync("pad"); after["remoteHead"] != before || after["pushed"].(float64) != 0 {
		t.Fatalf("an unchanged sync pushed: %v", after)
	}
	// The branch carries a README for people, which never reaches the folder.
	if _, err := os.Stat(filepath.Join(root, "pad", "agent-memory", "README.md")); !os.IsNotExist(err) {
		t.Fatal("README.md was pulled into the memory folder")
	}
}
