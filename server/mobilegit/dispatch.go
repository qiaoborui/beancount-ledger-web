// Package mobilegit is the scalar, in-process Git transport for local iOS
// storage providers. It uses go-git's object and smart-HTTPS implementations.
package mobilegit

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/transport"
)

type request struct {
	Version            int     `json:"version"`
	Operation          string  `json:"operation"`
	RequestID          string  `json:"requestID,omitempty"`
	StorageRoot        string  `json:"storageRoot,omitempty"`
	URL                string  `json:"url,omitempty"`
	Branch             string  `json:"branch,omitempty"`
	Username           string  `json:"username,omitempty"`
	Password           string  `json:"password,omitempty"`
	TimeoutSeconds     int     `json:"timeoutSeconds,omitempty"`
	Commit             string  `json:"commit,omitempty"`
	Directory          string  `json:"directory,omitempty"`
	Parent             string  `json:"parent,omitempty"`
	Message            string  `json:"message,omitempty"`
	AuthorName         string  `json:"authorName,omitempty"`
	AuthorEmail        string  `json:"authorEmail,omitempty"`
	ExpectedRemoteHead *string `json:"expectedRemoteHead,omitempty"`
}

type response struct {
	Version   int          `json:"version"`
	Operation string       `json:"operation"`
	OK        bool         `json:"ok"`
	Result    any          `json:"result,omitempty"`
	Error     *bridgeError `json:"error,omitempty"`
}

type bridgeError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *bridgeError) Error() string  { return e.Message }
func fail(code, message string) error { return &bridgeError{Code: "git." + code, Message: message} }

var requestCancellations cancellationRegistry
var storageLocks sync.Map

// DispatchJSON accepts a version-1 fetch/export/commit/push/cancel request.
// Credentials are used for one request and are never stored in Git config.
func DispatchJSON(raw string) (encoded string) {
	input := request{}
	defer func() {
		if recover() != nil {
			encoded = encodeResponse(response{Version: 1, Operation: input.Operation, Error: &bridgeError{Code: "git.failed", Message: "Git operation failed"}})
		}
	}()
	if len(raw) > 1<<20 {
		return encodeFailure(input, fail("invalid_request", "Git request exceeds 1 MiB"))
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		return encodeFailure(input, fail("invalid_request", "Invalid Git request JSON"))
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return encodeFailure(input, fail("invalid_request", "Git request contains trailing JSON"))
	}
	if input.Version != 1 {
		return encodeFailure(input, fail("invalid_request", "Supported Git request version is 1"))
	}
	if input.Operation == "cancel" {
		if input.RequestID == "" || len(input.RequestID) > 128 {
			return encodeFailure(input, fail("invalid_request", "Cancellation requires requestID of 1–128 bytes"))
		}
		if err := requestCancellations.cancel(input.RequestID); err != nil {
			return encodeFailure(input, err)
		}
		return encodeResponse(response{Version: 1, Operation: input.Operation, OK: true, Result: map[string]bool{"cancelled": true}})
	}
	if input.TimeoutSeconds < 0 || input.TimeoutSeconds > 180 || len(input.RequestID) > 128 {
		return encodeFailure(input, fail("invalid_request", "timeoutSeconds must be 1–180 and requestID at most 128 bytes"))
	}
	timeout := input.TimeoutSeconds
	if timeout == 0 {
		timeout = 60
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Second)
	defer cancel()
	if input.RequestID != "" {
		if err := requestCancellations.register(input.RequestID, cancel); err != nil {
			return encodeFailure(input, err)
		}
		defer requestCancellations.finish(input.RequestID)
	}
	result, err := dispatch(ctx, input, false)
	if err != nil {
		return encodeFailure(input, err)
	}
	return encodeResponse(response{Version: 1, Operation: input.Operation, OK: true, Result: result})
}

func dispatch(ctx context.Context, input request, allowFileFixture bool) (any, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	switch input.Operation {
	case "fetch", "export", "commit", "push":
	default:
		return nil, fail("invalid_request", "Unsupported Git operation")
	}
	root, err := privateDirectory(input.StorageRoot)
	if err != nil {
		return nil, err
	}
	input.StorageRoot = root
	if input.Operation == "fetch" || input.Operation == "push" {
		if err := validateRemote(input.URL, input.Branch, allowFileFixture); err != nil {
			return nil, err
		}
	}
	if input.Operation == "push" && input.ExpectedRemoteHead == nil {
		return nil, fail("invalid_request", "Push requires expectedRemoteHead")
	}
	unlock, err := lockStorage(ctx, root)
	if err != nil {
		return nil, err
	}
	defer unlock()
	repository, err := openStorage(root)
	if err != nil {
		return nil, err
	}
	if input.Operation == "fetch" || input.Operation == "push" {
		if err := bindRemote(root, input.URL, input.Branch); err != nil {
			return nil, err
		}
	}
	switch input.Operation {
	case "fetch":
		return fetch(ctx, repository, input)
	case "export":
		return exportCommit(ctx, repository, input)
	case "commit":
		return createCommit(ctx, repository, input)
	case "push":
		return push(ctx, repository, input)
	}
	return nil, fail("invalid_request", "Unsupported Git operation")
}

func privateDirectory(raw string) (string, error) {
	if !filepath.IsAbs(raw) || filepath.Clean(raw) == string(filepath.Separator) {
		return "", fail("unsafe_path", "An absolute provider-private directory is required")
	}
	root := filepath.Clean(raw)
	if info, err := os.Lstat(root); err == nil {
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return "", fail("unsafe_path", "Provider directory must be a regular directory")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	// Resolve platform aliases such as /var -> /private/var so cache/snapshot
	// separation and per-cache locks compare the actual filesystem paths.
	ancestor := root
	var missing []string
	for {
		if _, err := os.Lstat(ancestor); err == nil {
			break
		} else if !errors.Is(err, os.ErrNotExist) {
			return "", err
		}
		missing = append(missing, filepath.Base(ancestor))
		ancestor = filepath.Dir(ancestor)
	}
	resolved, err := filepath.EvalSymlinks(ancestor)
	if err != nil {
		return "", err
	}
	for index := len(missing) - 1; index >= 0; index-- {
		resolved = filepath.Join(resolved, missing[index])
	}
	return resolved, nil
}

func lockStorage(ctx context.Context, root string) (func(), error) {
	semaphore := make(chan struct{}, 1)
	semaphore <- struct{}{}
	actual, _ := storageLocks.LoadOrStore(root, semaphore)
	lock := actual.(chan struct{})
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-lock:
		return func() { lock <- struct{}{} }, nil
	}
}

func openStorage(root string) (*git.Repository, error) {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	if len(entries) == 0 {
		return git.PlainInit(root, true)
	}
	if err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.Type()&os.ModeSymlink != 0 || (!entry.IsDir() && !entry.Type().IsRegular()) {
			return fail("unsafe_path", "Git cache contains an unsupported file type")
		}
		return nil
	}); err != nil {
		return nil, err
	}
	repository, err := git.PlainOpen(root)
	if err != nil {
		return nil, fail("invalid_request", "Provider cache is not a Git repository")
	}
	configuration, err := repository.Config()
	if err != nil {
		return nil, err
	}
	if !configuration.Core.IsBare {
		return nil, fail("unsafe_path", "Provider cache must be a bare repository")
	}
	return repository, nil
}

func bindRemote(root, remoteURL, branch string) error {
	type binding struct {
		URL    string `json:"url"`
		Branch string `json:"branch"`
	}
	path := filepath.Join(root, "mobilegit-provider.json")
	if raw, err := os.ReadFile(path); err == nil {
		var previous binding
		if json.Unmarshal(raw, &previous) != nil || previous.URL != remoteURL || previous.Branch != branch {
			return fail("invalid_request", "Git cache belongs to a different remote or branch")
		}
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	raw, _ := json.Marshal(binding{URL: remoteURL, Branch: branch})
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(raw)
	closeErr := file.Close()
	return errors.Join(writeErr, closeErr)
}

func encodeFailure(input request, err error) string {
	detail := &bridgeError{Code: "git.failed", Message: "Git operation failed"}
	var known *bridgeError
	switch {
	case errors.Is(err, transport.ErrAuthenticationRequired):
		detail = &bridgeError{Code: "git.authentication", Message: "Git authentication failed; update the repository access token"}
	case errors.Is(err, transport.ErrAuthorizationFailed):
		detail = &bridgeError{Code: "git.authorization", Message: "Git access denied; check the token repository permissions"}
	case errors.Is(err, context.Canceled):
		detail = &bridgeError{Code: "git.cancelled", Message: "Git operation cancelled"}
	case errors.Is(err, context.DeadlineExceeded):
		detail = &bridgeError{Code: "git.timeout", Message: "Git operation timed out"}
	case errors.As(err, &known):
		detail = &bridgeError{Code: known.Code, Message: known.Message}
	default:
		detail.Message = fmt.Sprintf("Git operation failed: %v", err)
	}
	for _, secret := range []string{input.Password, input.Username} {
		if secret != "" {
			detail.Message = strings.ReplaceAll(detail.Message, secret, "[redacted]")
		}
	}
	return encodeResponse(response{Version: 1, Operation: input.Operation, Error: detail})
}

func encodeResponse(value response) string {
	encoded, err := json.Marshal(value)
	if err != nil {
		return `{"version":1,"ok":false,"error":{"code":"git.failed","message":"Could not encode Git response"}}`
	}
	return string(encoded)
}
