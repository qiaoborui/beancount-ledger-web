package app

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestZIPWorkerHandlerFindsUpperAlnumPassword(t *testing.T) {
	archive := encryptedStoredZIP(t, "statement.csv", []byte("date,amount\n2026-07-01,88.00\n"), "00000A")
	request := httptest.NewRequest(http.MethodPost, zipWorkerPasswordPath, bytes.NewReader(archive))
	request.Header.Set("Content-Type", "application/zip")
	response := httptest.NewRecorder()

	NewZIPWorkerHandler(2).ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	var result zipWorkerResponse
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.Password != "00000A" {
		t.Fatalf("password=%q", result.Password)
	}
}

func TestZIPWorkerHandlerRejectsOversizedArchive(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, zipWorkerPasswordPath, bytes.NewReader(make([]byte, maxImportFileBytes+1)))
	request.Header.Set("Content-Type", "application/zip")
	response := httptest.NewRecorder()

	NewZIPWorkerHandler(1).ServeHTTP(response, request)

	if response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestZIPWorkerClientUsesIdentityAudienceAndReturnsPassword(t *testing.T) {
	archive := []byte("encrypted archive")
	worker := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != zipWorkerPasswordPath || request.Method != http.MethodPost {
			t.Errorf("request=%s %s", request.Method, request.URL.Path)
			writeZIPWorkerJSON(writer, http.StatusBadRequest, zipWorkerResponse{Error: "unexpected request"})
			return
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Errorf("read body: %v", err)
			writeZIPWorkerJSON(writer, http.StatusBadRequest, zipWorkerResponse{Error: "read failed"})
			return
		}
		if !bytes.Equal(body, archive) || request.Header.Get("Content-Type") != "application/zip" {
			t.Errorf("body=%q content-type=%q", body, request.Header.Get("Content-Type"))
			writeZIPWorkerJSON(writer, http.StatusBadRequest, zipWorkerResponse{Error: "invalid request"})
			return
		}
		writeZIPWorkerJSON(writer, http.StatusOK, zipWorkerResponse{Password: "00000A"})
	}))
	defer worker.Close()

	originalClientFactory := newZIPWorkerHTTPClient
	var audience string
	newZIPWorkerHTTPClient = func(_ context.Context, value string) (*http.Client, error) {
		audience = value
		return worker.Client(), nil
	}
	t.Cleanup(func() { newZIPWorkerHTTPClient = originalClientFactory })

	server := &Server{cfg: Config{ZIPWorkerURL: worker.URL, ZIPWorkerAudience: "https://worker.example"}}
	password, err := server.searchZIPWorkerPassword(context.Background(), archive)
	if err != nil {
		t.Fatal(err)
	}
	if password != "00000A" || audience != "https://worker.example" {
		t.Fatalf("password=%q audience=%q", password, audience)
	}
}

func TestExtractImportZIPUsesWorkerAfterNumericSearch(t *testing.T) {
	archive := encryptedStoredZIP(t, "statement.csv", []byte("date,amount\n2026-07-01,88.00\n"), "00000A")
	called := false
	upload, password, err := extractImportZIPWithUpperAlnumSearch(context.Background(), archive, nil, func(_ context.Context, received []byte) (string, error) {
		called = true
		if !bytes.Equal(received, archive) {
			t.Fatal("worker received different archive bytes")
		}
		return "00000A", nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !called || password != "00000A" || upload.Filename != "statement.csv" || !strings.Contains(string(upload.Content), "88.00") {
		t.Fatalf("called=%v password=%q upload=%#v", called, password, upload)
	}
}

func TestExtractImportZIPUsesNumericBeforeWorker(t *testing.T) {
	archive := encryptedStoredZIP(t, "statement.csv", []byte("date,amount\n2026-07-01,88.00\n"), "000001")
	called := false
	upload, password, err := extractImportZIPWithUpperAlnumSearch(context.Background(), archive, nil, func(context.Context, []byte) (string, error) {
		called = true
		return "00000A", nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if called || password != "000001" || upload.Filename != "statement.csv" || !strings.Contains(string(upload.Content), "88.00") {
		t.Fatalf("called=%v password=%q upload=%#v", called, password, upload)
	}
}

func TestExtractImportZIPRejectsUnverifiedWorkerPassword(t *testing.T) {
	archive := encryptedStoredZIP(t, "statement.csv", []byte("date,amount\n2026-07-01,88.00\n"), "00000A")
	_, _, err := extractImportZIPWithUpperAlnumSearch(context.Background(), archive, nil, func(context.Context, []byte) (string, error) {
		return "00000B", nil
	})
	if err == nil || !strings.Contains(err.Error(), "未通过压缩包校验") {
		t.Fatalf("error=%v", err)
	}
}
