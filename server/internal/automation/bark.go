package automation

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Notification is one push to the phone.
type Notification struct {
	Title string
	Body  string
	// URL opens the run in the App.
	URL string
}

// Notifier delivers notifications; nil means none are sent.
type Notifier interface {
	Notify(ctx context.Context, n Notification) error
}

// Bark pushes through a Bark server (https://github.com/Finb/Bark). With
// an encryption key the server only relays ciphertext the App's Bark
// extension decrypts, so the public server never sees ledger details.
type Bark struct {
	// Server is the Bark server, https://api.day.app by default.
	Server string
	// DeviceKey is the key the Bark App shows.
	DeviceKey string
	// EncryptionKey enables AES-CBC encrypted pushes when set: 16, 24 or 32
	// bytes, as configured in the Bark App.
	EncryptionKey string
	// Group collects the pushes in Notification Center.
	Group string
	// Icon is the URL of the image shown on the push (iOS 15+).
	Icon string
	// Sound is one of the Bark App's ringtones, e.g. birdsong.
	Sound  string
	Client *http.Client
}

func (b *Bark) Notify(ctx context.Context, n Notification) error {
	if b == nil || b.DeviceKey == "" {
		return nil
	}
	server := strings.TrimRight(b.Server, "/")
	if server == "" {
		server = "https://api.day.app"
	}
	payload := map[string]string{"title": n.Title, "body": n.Body}
	if n.URL != "" {
		payload["url"] = n.URL
	}
	for key, value := range map[string]string{"group": b.Group, "icon": b.Icon, "sound": b.Sound} {
		if value != "" {
			payload[key] = value
		}
	}
	form := url.Values{}
	if b.EncryptionKey != "" {
		plain, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		ciphertext, iv, err := barkEncrypt([]byte(b.EncryptionKey), plain)
		if err != nil {
			return err
		}
		form.Set("ciphertext", ciphertext)
		form.Set("iv", iv)
	} else {
		for key, value := range payload {
			form.Set(key, value)
		}
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, server+"/"+url.PathEscape(b.DeviceKey),
		strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	client := b.Client
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second}
	}
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Duration(attempt*5) * time.Second):
			}
			request.Body, _ = request.GetBody()
		}
		response, err := client.Do(request)
		if err != nil {
			lastErr = err
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		response.Body.Close()
		if response.StatusCode == http.StatusOK {
			return nil
		}
		lastErr = fmt.Errorf("bark: %s: %s", response.Status, bytes.TrimSpace(body))
		if response.StatusCode < 500 {
			break
		}
	}
	return lastErr
}

// barkEncrypt is AES-CBC with PKCS#7 padding and a random IV, the scheme
// the Bark App decrypts; both values go base64 / plain in the form.
func barkEncrypt(key, plain []byte) (string, string, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", "", errors.New("bark encryption key must be 16, 24 or 32 bytes")
	}
	// Bark takes the IV as 16 printable characters.
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	random := make([]byte, aes.BlockSize)
	if _, err := rand.Read(random); err != nil {
		return "", "", err
	}
	iv := make([]byte, aes.BlockSize)
	for i, value := range random {
		iv[i] = alphabet[int(value)%len(alphabet)]
	}
	padding := aes.BlockSize - len(plain)%aes.BlockSize
	padded := append(append([]byte(nil), plain...), bytes.Repeat([]byte{byte(padding)}, padding)...)
	out := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, padded)
	return base64.StdEncoding.EncodeToString(out), string(iv), nil
}
