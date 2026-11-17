package automation

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestBarkSendsAnEncryptedPush(t *testing.T) {
	key := "0123456789abcdef0123456789abcdef"
	var got map[string]string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/device-key" {
			t.Errorf("path = %s", r.URL.Path)
		}
		_ = r.ParseForm()
		if r.Form.Get("title") != "" || r.Form.Get("body") != "" {
			t.Errorf("plain text leaked: %v", r.Form)
		}
		data, _ := base64.StdEncoding.DecodeString(r.Form.Get("ciphertext"))
		block, _ := aes.NewCipher([]byte(key))
		plain := make([]byte, len(data))
		cipher.NewCBCDecrypter(block, []byte(r.Form.Get("iv"))).CryptBlocks(plain, data)
		plain = plain[:len(plain)-int(plain[len(plain)-1])]
		if err := json.Unmarshal(plain, &got); err != nil {
			t.Errorf("decrypt: %v (%q)", err, plain)
		}
		w.Write([]byte(`{"code":200}`))
	}))
	defer server.Close()
	bark := &Bark{Server: server.URL, DeviceKey: "device-key", EncryptionKey: key, Group: "账本",
		Icon: "https://example.com/icon.png", Sound: "birdsong"}
	if err := bark.Notify(context.Background(), Notification{Title: "每日巡检", Body: "发现 1 个问题", URL: "ledger://automation/run?id=x"}); err != nil {
		t.Fatal(err)
	}
	if got["title"] != "每日巡检" || got["body"] != "发现 1 个问题" || got["url"] != "ledger://automation/run?id=x" || got["group"] != "账本" ||
		got["icon"] != "https://example.com/icon.png" || got["sound"] != "birdsong" {
		t.Fatalf("payload = %v", got)
	}
}
