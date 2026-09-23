package mobilecore

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/borui/beancount-ledger-web/server/internal/app"
)

type dispatchRequestV1 struct {
	Version   int    `json:"version"`
	Operation string `json:"operation"`
	app.LocalRequest
	StreamFile    string `json:"streamFile,omitempty"`
	SourceVersion string `json:"sourceVersion,omitempty"`
}

type dispatchResponseV1 struct {
	Version     int             `json:"version"`
	Operation   string          `json:"operation"`
	OK          bool            `json:"ok"`
	Status      int             `json:"status"`
	Result      json.RawMessage `json:"result,omitempty"`
	Diagnostics []diagnosticV1  `json:"diagnostics"`
}

// DispatchJSON executes an app-private local ledger request in process.
// Ledger mutation success describes a staged proposal. The Swift workspace
// actor must validate it with canonical Beancount before publishing it.
func DispatchJSON(requestJSON string) (responseJSON string) {
	defer func() {
		if recovered := recover(); recovered != nil {
			responseJSON = encodeDispatchResponse(dispatchResponseV1{Version: 1, Operation: "request", Status: 500,
				Diagnostics: []diagnosticV1{{Code: "local.internal_error", Severity: "error", Message: fmt.Sprint(recovered)}}})
		}
	}()
	var request dispatchRequestV1
	if diagnostic := decodeDispatchRequest(requestJSON, &request); diagnostic != nil {
		return encodeDispatchResponse(dispatchResponseV1{Version: 1, Operation: "request", Status: 400, Diagnostics: []diagnosticV1{*diagnostic}})
	}
	if request.Version == 1 && request.Operation != "request" {
		return dispatchModelOperation(request)
	}
	if request.Version != 1 || request.Operation != "request" {
		return encodeDispatchResponse(dispatchResponseV1{Version: 1, Operation: "request", Status: 400,
			Diagnostics: []diagnosticV1{{Code: "request.unsupported_version", Severity: "error", Message: "supported local request version is 1 and operation is request"}}})
	}
	status, result, err := app.DispatchLocalRequest(request.LocalRequest)
	response := dispatchResponseV1{Version: 1, Operation: "request", OK: status >= 200 && status < 300 && err == nil,
		Status: status, Result: result, Diagnostics: []diagnosticV1{}}
	if err != nil {
		code := "local.request_failed"
		if err == app.ErrLocalModelUnavailable {
			code = "model.unavailable"
		}
		response.Diagnostics = append(response.Diagnostics, diagnosticV1{Code: code, Severity: "error", Message: err.Error()})
		response.Result, _ = json.Marshal(map[string]string{"error": err.Error()})
	}
	return encodeDispatchResponse(response)
}

func decodeDispatchRequest(raw string, request *dispatchRequestV1) *diagnosticV1 {
	// A 10 MiB bill upload expands to roughly 13.4 MiB as base64. Keep the
	// parser's tighter input budget while allowing the documented upload size.
	if len(raw) > 16<<20 {
		return &diagnosticV1{Code: "request.too_large", Severity: "error", Message: "local request exceeds 16 MiB"}
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(request); err != nil {
		return &diagnosticV1{Code: "request.invalid_json", Severity: "error", Message: err.Error()}
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return &diagnosticV1{Code: "request.invalid_json", Severity: "error", Message: "local request contains trailing JSON"}
	}
	return nil
}

func encodeDispatchResponse(response dispatchResponseV1) string {
	encoded, err := json.Marshal(response)
	if err != nil || len(encoded) > maxResponseBytes {
		return `{"version":1,"operation":"request","ok":false,"status":500,"diagnostics":[{"code":"local.response_limit","severity":"error","message":"local response exceeds supported limits"}]}`
	}
	return string(encoded)
}

func dispatchModelOperation(request dispatchRequestV1) string {
	var result any
	var err error
	switch request.Operation {
	case "model-source":
		var version string
		version, err = app.LocalModelSourceVersion(request.LocalRequest)
		result = map[string]string{"sourceVersion": version}
	case "model-register":
		var handle string
		handle, err = app.RegisterLocalModel(request.LocalRequest, request.StreamFile, request.SourceVersion)
		result = map[string]string{"handle": handle}
	case "model-release":
		app.ReleaseLocalModel(request.ModelHandle)
		result = map[string]bool{"released": true}
	default:
		return encodeDispatchResponse(dispatchResponseV1{Version: 1, Operation: request.Operation, Status: 400, Diagnostics: []diagnosticV1{{Code: "request.unsupported_operation", Severity: "error", Message: "unsupported local operation"}}})
	}
	response := dispatchResponseV1{Version: 1, Operation: request.Operation, OK: err == nil, Status: 200, Diagnostics: []diagnosticV1{}}
	if err != nil {
		response.Status = 400
		response.Diagnostics = append(response.Diagnostics, diagnosticV1{Code: "model.operation_failed", Severity: "error", Message: err.Error()})
	} else {
		response.Result, _ = json.Marshal(result)
	}
	return encodeDispatchResponse(response)
}
