package app

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
)

type zipPasswordCracker func(context.Context, []byte, int) (string, error)

func NewZIPWorkerHandler(workers int) http.Handler {
	return newZIPWorkerHandler(workers, CrackUpperAlnumZIPPassword)
}

func newZIPWorkerHandler(workers int, crack zipPasswordCracker) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(writer http.ResponseWriter, _ *http.Request) {
		writeZIPWorkerJSON(writer, http.StatusOK, zipWorkerResponse{})
	})
	mux.HandleFunc("POST "+zipWorkerPasswordPath, func(writer http.ResponseWriter, request *http.Request) {
		contentType := strings.ToLower(strings.TrimSpace(strings.Split(request.Header.Get("Content-Type"), ";")[0]))
		if contentType != "application/zip" && contentType != "application/octet-stream" {
			writeZIPWorkerJSON(writer, http.StatusUnsupportedMediaType, zipWorkerResponse{Error: "Content-Type must be application/zip"})
			return
		}
		if request.ContentLength > maxImportFileBytes {
			writeZIPWorkerJSON(writer, http.StatusRequestEntityTooLarge, zipWorkerResponse{Error: "archive exceeds 10MB"})
			return
		}
		archive, err := io.ReadAll(io.LimitReader(request.Body, maxImportFileBytes+1))
		if err != nil {
			writeZIPWorkerJSON(writer, http.StatusBadRequest, zipWorkerResponse{Error: "failed to read archive"})
			return
		}
		if len(archive) > maxImportFileBytes {
			writeZIPWorkerJSON(writer, http.StatusRequestEntityTooLarge, zipWorkerResponse{Error: "archive exceeds 10MB"})
			return
		}
		password, err := crack(request.Context(), archive, workers)
		if err != nil {
			switch {
			case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
				writeZIPWorkerJSON(writer, http.StatusGatewayTimeout, zipWorkerResponse{Error: "password search timed out"})
			case errors.Is(err, ErrZIPPasswordNotFound):
				writeZIPWorkerJSON(writer, http.StatusNotFound, zipWorkerResponse{Error: "password not found"})
			default:
				writeZIPWorkerJSON(writer, http.StatusBadRequest, zipWorkerResponse{Error: err.Error()})
			}
			return
		}
		writeZIPWorkerJSON(writer, http.StatusOK, zipWorkerResponse{Password: password})
	})
	return mux
}

func writeZIPWorkerJSON(writer http.ResponseWriter, status int, value zipWorkerResponse) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}
