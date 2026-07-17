package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"google.golang.org/api/idtoken"
)

const zipWorkerPasswordPath = "/v1/zip-password"

type zipWorkerResponse struct {
	Password string `json:"password,omitempty"`
	Error    string `json:"error,omitempty"`
}

var newZIPWorkerHTTPClient = func(ctx context.Context, audience string) (*http.Client, error) {
	return idtoken.NewClient(ctx, audience)
}

func (s *Server) extractImportZIP(ctx context.Context, archive []byte, passwordCandidates []string) (importUpload, string, error) {
	var upperAlnumSearch zipUpperAlnumPasswordSearch
	if strings.TrimSpace(s.cfg.ZIPWorkerURL) != "" {
		upperAlnumSearch = s.searchZIPWorkerPassword
	}
	return extractImportZIPWithUpperAlnumSearch(ctx, archive, passwordCandidates, upperAlnumSearch)
}

func (s *Server) searchZIPWorkerPassword(ctx context.Context, archive []byte) (string, error) {
	if len(archive) > maxImportFileBytes {
		return "", errors.New("压缩包超过 10MB")
	}
	workerURL := strings.TrimRight(strings.TrimSpace(s.cfg.ZIPWorkerURL), "/")
	if workerURL == "" {
		return "", errors.New("ZIP Worker URL 未配置")
	}
	audience := strings.TrimSpace(s.cfg.ZIPWorkerAudience)
	if audience == "" {
		audience = workerURL
	}
	client, err := newZIPWorkerHTTPClient(ctx, audience)
	if err != nil {
		return "", fmt.Errorf("创建 ZIP Worker 身份客户端: %w", err)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, workerURL+zipWorkerPasswordPath, bytes.NewReader(archive))
	if err != nil {
		return "", err
	}
	request.Header.Set("Content-Type", "application/zip")
	response, err := client.Do(request)
	if err != nil {
		return "", fmt.Errorf("调用 ZIP Worker: %w", err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 16*1024+1))
	if err != nil {
		return "", fmt.Errorf("读取 ZIP Worker 响应: %w", err)
	}
	if len(body) > 16*1024 {
		return "", errors.New("ZIP Worker 响应超过 16KB")
	}
	var result zipWorkerResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return "", errors.New("ZIP Worker 返回了无效 JSON")
	}
	if response.StatusCode != http.StatusOK {
		message := strings.TrimSpace(result.Error)
		if message == "" {
			message = http.StatusText(response.StatusCode)
		}
		return "", fmt.Errorf("ZIP Worker 返回 %d: %s", response.StatusCode, message)
	}
	if !validZIPWorkerPassword(result.Password) {
		return "", errors.New("ZIP Worker 返回了无效密码格式")
	}
	return result.Password, nil
}

func validZIPWorkerPassword(password string) bool {
	if len(password) != zipPasswordLength {
		return false
	}
	for index := range password {
		value := password[index]
		if (value < '0' || value > '9') && (value < 'A' || value > 'Z') {
			return false
		}
	}
	return true
}
