package mobilecore

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func TestCompileWorkspaceExpandsIncludesDeterministically(t *testing.T) {
	files := []workspaceFileV1{
		{Path: "parts/b.bean", Text: "2026-09-15 open Assets:Bank CNY"},
		{Path: "main.bean", Text: "pushmeta source: \"ios\"\ninclude \"parts/*.bean\" ; sorted\ninclude \"parts/a.bean\"\npopmeta source:\n2026-09-16 open Assets:After CNY"},
		{Path: "parts/a.bean", Text: "include \"nested/first.bean\"\n2026-09-15 open Assets:Cash CNY"},
		{Path: "parts/nested/first.bean", Text: "; preserved source lines\r\n2026-09-15 open Expenses:Food CNY"},
		{Path: "unused.bean", Text: "2026-09-15 open Assets:Unused CNY"},
	}
	payload := CompileWorkspaceJSON(workspaceJSON(t, "main.bean", files))
	response := decodeResponse(t, payload)
	if !response.OK || response.Operation != "compileWorkspace" || response.Result == nil {
		t.Fatalf("response = %s", payload)
	}
	var accounts []string
	for _, entry := range response.Result.Entries {
		if entry.Kind != "open" {
			continue
		}
		accounts = append(accounts, entry.Account)
		if entry.Account == "Expenses:Food" && (entry.File != "parts/nested/first.bean" || entry.Line != 2) {
			t.Fatalf("source = %#v", entry)
		}
		if entry.Account == "Assets:After" {
			if _, exists := entry.Metadata["source"]; exists {
				t.Fatal("popped scope leaked")
			}
		} else if entry.Metadata["source"] != "ios" {
			t.Fatalf("include scope lost: %#v", entry)
		}
	}
	want := []string{"Expenses:Food", "Assets:Cash", "Assets:Bank", "Assets:After"}
	if !reflect.DeepEqual(accounts, want) {
		t.Fatalf("accounts = %v, want %v", accounts, want)
	}
	for left, right := 0, len(files)-1; left < right; left, right = left+1, right-1 {
		files[left], files[right] = files[right], files[left]
	}
	if reordered := CompileWorkspaceJSON(workspaceJSON(t, "main.bean", files)); reordered != payload {
		t.Fatalf("file input order changed output:\n%s\n%s", payload, reordered)
	}
}

func TestCompileWorkspacePreservesIncludedDiagnostics(t *testing.T) {
	response := decodeResponse(t, CompileWorkspaceJSON(workspaceJSON(t, "main.bean", []workspaceFileV1{
		{Path: "main.bean", Text: "include \"bad.bean\""},
		{Path: "bad.bean", Text: "; line one\noption \"title\"\n2026-09-15 * \"unbalanced\"\n  Assets:Cash 2 CNY\n  Expenses:Food -1 CNY\npoptag #missing"},
	})))
	if response.OK || len(response.Diagnostics) != 3 {
		t.Fatalf("response = %#v", response)
	}
	wantCodes := []string{"beancount.parse_error", "beancount.balance_error", "beancount.compile_error"}
	wantLines := []int{2, 3, 6}
	for index, diagnostic := range response.Diagnostics {
		if diagnostic.Code != wantCodes[index] || diagnostic.Line != wantLines[index] || diagnostic.File != "bad.bean" {
			t.Fatalf("diagnostic = %#v", diagnostic)
		}
	}
}

func TestCompileWorkspaceRejectsUnsafePaths(t *testing.T) {
	for _, filename := range []string{"", "/main.bean", "../main.bean", "a/../main.bean", "./main.bean", "a//main.bean", "a/./main.bean", "C:/main.bean", `a\main.bean`, "a\x00.bean", "*.bean"} {
		t.Run(fmt.Sprintf("%q", filename), func(t *testing.T) {
			response := decodeResponse(t, CompileWorkspaceJSON(workspaceJSON(t, filename, []workspaceFileV1{{Path: filename}})))
			assertDiagnostic(t, response, "workspace.invalid_path", "", 0)
		})
	}
	for _, alias := range []string{"main.bean", "MAIN.bean"} {
		response := decodeResponse(t, CompileWorkspaceJSON(workspaceJSON(t, "main.bean", []workspaceFileV1{{Path: "main.bean"}, {Path: alias}})))
		assertDiagnostic(t, response, "workspace.duplicate_path", alias, 0)
	}
}

func TestCompileWorkspaceRejectsInvalidIncludes(t *testing.T) {
	tests := []struct{ text, code string }{
		{`include "../child.bean"`, "workspace.invalid_path"},
		{`include "/child.bean"`, "workspace.invalid_path"},
		{`include "./child.bean"`, "workspace.invalid_path"},
		{`include "a//child.bean"`, "workspace.invalid_path"},
		{`include "C:/child.bean"`, "workspace.invalid_path"},
		{`include "missing.bean"`, "workspace.missing_include"},
		{`include "missing/*.bean"`, "workspace.missing_include"},
		{`include "main.bean"`, "workspace.include_cycle"},
		{`include "[broken.bean"`, "workspace.invalid_include"},
		{`include "child.bean`, "workspace.invalid_include"},
		{`include "child.bean" "extra"`, "workspace.invalid_include"},
		{`include child.bean`, "workspace.invalid_include"},
	}
	for _, test := range tests {
		t.Run(test.text, func(t *testing.T) {
			response := decodeResponse(t, CompileWorkspaceJSON(workspaceJSON(t, "main.bean", []workspaceFileV1{
				{Path: "main.bean", Text: "; header\n" + test.text}, {Path: "child.bean"},
			})))
			assertDiagnostic(t, response, test.code, "main.bean", 2)
		})
	}
	response := decodeResponse(t, CompileWorkspaceJSON(workspaceJSON(t, "main.bean", []workspaceFileV1{
		{Path: "main.bean", Text: `include "a.bean"`},
		{Path: "a.bean", Text: "; header\ninclude \"main.bean\""},
	})))
	assertDiagnostic(t, response, "workspace.include_cycle", "a.bean", 2)
}

func TestCompileWorkspaceRejectsFilesystemAliases(t *testing.T) {
	for _, test := range []struct{ first, second, code string }{
		{"Accounts/a.bean", "accounts/b.bean", "workspace.duplicate_path"},
		{"café.bean", "cafe\u0301.bean", "workspace.duplicate_path"},
		{"café/a.bean", "cafe\u0301/b.bean", "workspace.duplicate_path"},
		{"straße.bean", "STRASSE.bean", "workspace.duplicate_path"},
		{"a", "a/b.bean", "workspace.path_conflict"},
		{"a/b.bean", "a", "workspace.path_conflict"},
	} {
		t.Run(test.first+"/"+test.second, func(t *testing.T) {
			files := []workspaceFileV1{{Path: "main.bean"}, {Path: test.first}, {Path: test.second}}
			assertDiagnostic(t, decodeResponse(t, CompileWorkspaceJSON(workspaceJSON(t, "main.bean", files))), test.code, test.second, 0)
		})
	}
}

func TestCompileWorkspaceRequestValidation(t *testing.T) {
	for _, test := range []struct{ request, code string }{
		{`{`, "request.invalid_json"},
		{`null`, "request.unsupported_version"},
		{`{"version":2}`, "request.unsupported_version"},
		{`{"version":1,"entrypoint":"main.bean","files":[],"extra":true}`, "request.invalid_json"},
		{`{"version":1,"entrypoint":"main.bean","files":[{"path":"main.bean","extra":true}]}`, "request.invalid_json"},
		{`{"version":1,"entrypoint":"main.bean","files":[]} {}`, "request.invalid_json"},
		{`{"version":1,"entrypoint":"main.bean","files":[]}`, "workspace.missing_entrypoint"},
		{strings.Repeat(" ", maxRequestBytes+1), "request.too_large"},
	} {
		assertDiagnostic(t, decodeResponse(t, CompileWorkspaceJSON(test.request)), test.code, "", 0)
	}
}

func TestCompileWorkspaceCumulativeLimits(t *testing.T) {
	t.Run("text", func(t *testing.T) {
		text := strings.Repeat(";"+strings.Repeat("x", 126)+"\n", maxTextBytes/256+1)
		files := []workspaceFileV1{{Path: "main.bean", Text: text}, {Path: "unused.bean", Text: text}}
		assertDiagnostic(t, decodeResponse(t, CompileWorkspaceJSON(workspaceJSON(t, "main.bean", files))), "request.text_too_large", "unused.bean", 0)
	})
	t.Run("lines", func(t *testing.T) {
		text := strings.Repeat("\n", maxLineCount/2)
		files := []workspaceFileV1{{Path: "main.bean", Text: text}, {Path: "unused.bean", Text: text}}
		assertDiagnostic(t, decodeResponse(t, CompileWorkspaceJSON(workspaceJSON(t, "main.bean", files))), "request.too_many_lines", "unused.bean", 0)
	})
	t.Run("files", func(t *testing.T) {
		files := make([]workspaceFileV1, maxWorkspaceFiles+1)
		assertDiagnostic(t, decodeResponse(t, CompileWorkspaceJSON(workspaceJSON(t, "main.bean", files))), "request.too_many_files", "", 0)
	})
	t.Run("depth", func(t *testing.T) {
		files := make([]workspaceFileV1, maxIncludeDepth+1)
		for index := range files {
			files[index] = workspaceFileV1{Path: fmt.Sprintf("%d.bean", index)}
			if index < len(files)-1 {
				files[index].Text = fmt.Sprintf("include \"%d.bean\"", index+1)
			}
		}
		assertDiagnostic(t, decodeResponse(t, CompileWorkspaceJSON(workspaceJSON(t, "0.bean", files))), "request.include_depth_exceeded", "63.bean", 1)
	})
	t.Run("include count", func(t *testing.T) {
		files := []workspaceFileV1{{Path: "main.bean", Text: strings.Repeat("include \"child.bean\"\n", maxIncludeCount+1)}, {Path: "child.bean"}}
		assertDiagnostic(t, decodeResponse(t, CompileWorkspaceJSON(workspaceJSON(t, "main.bean", files))), "request.too_many_includes", "main.bean", maxIncludeCount+1)
	})
	t.Run("cross-file scope expansion", func(t *testing.T) {
		files := []workspaceFileV1{
			{Path: "main.bean", Text: "pushmeta large: \"" + strings.Repeat("x", 4096) + "\"\ninclude \"child.bean\""},
			{Path: "child.bean", Text: strings.Repeat("2026-09-15 open Assets:Cash CNY\n", 500)},
		}
		response := decodeResponse(t, CompileWorkspaceJSON(workspaceJSON(t, "main.bean", files)))
		assertDiagnostic(t, response, "request.scope_expansion_too_large", "child.bean", 0)
	})
}

func workspaceJSON(t *testing.T, entrypoint string, files []workspaceFileV1) string {
	t.Helper()
	payload, err := json.Marshal(workspaceRequestV1{Version: 1, Entrypoint: entrypoint, Files: files})
	if err != nil {
		t.Fatal(err)
	}
	return string(payload)
}

func decodeResponse(t *testing.T, payload string) parseResponseV1 {
	t.Helper()
	var response parseResponseV1
	if err := json.Unmarshal([]byte(payload), &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func assertDiagnostic(t *testing.T, response parseResponseV1, code, file string, line int) {
	t.Helper()
	if response.OK || len(response.Diagnostics) != 1 || response.Diagnostics[0].Code != code ||
		(file != "" && response.Diagnostics[0].File != file) || (line != 0 && response.Diagnostics[0].Line != line) {
		t.Fatalf("response = %#v; want %s at %s:%d", response, code, file, line)
	}
}

func TestMobileEntryPointsBoundNumericAndScopedWork(t *testing.T) {
	entrypoints := map[string]func(string) string{"parse": ParseTextJSON, "compile": CompileTextJSON}
	for name, entrypoint := range entrypoints {
		t.Run(name, func(t *testing.T) {
			for _, number := range []string{".5e999999999", "-.5e999999999", "0x1p999999999", "1e6_5", "." + strings.Repeat("5", maxNumericTokenBytes)} {
				response := decodeResponse(t, entrypoint(requestJSON(t, "number.bean", "2026-09-15 price USD "+number+" CNY")))
				assertDiagnostic(t, response, "request.numeric_token_too_complex", "number.bean", 1)
			}
			expression := "2026-09-15 price USD " + strings.Repeat(".5 + ", maxNumericTokensPerLine) + ".5 CNY"
			assertDiagnostic(t, decodeResponse(t, entrypoint(requestJSON(t, "number.bean", expression))), "request.numeric_expression_too_complex", "number.bean", 1)
			for _, text := range []string{
				"pushmeta large: \"" + strings.Repeat("x", 4096) + "\"\n" + strings.Repeat("2026-09-15 open Assets:Cash CNY\n", 500),
				"pushmeta large: \"" + strings.Repeat("x", 4096) + "\"\npopmeta large\n" + strings.Repeat("2026-09-15 open Assets:Cash CNY\n", 500),
				scopeFlood("pushmeta k%d: \"v\"\n", maxActiveScopes+1),
				scopeFlood("pushtag #t%d\n", 200) + strings.Repeat("2026-09-15 * \"tags\"\n", 100),
				scopeFlood("pushmeta k%d: \"v\"\n", 200) + strings.Repeat("2026-09-15 open Assets:Cash CNY\n", 1000),
			} {
				assertDiagnostic(t, decodeResponse(t, entrypoint(requestJSON(t, "scopes.bean", text))), "request.scope_expansion_too_large", "scopes.bean", 0)
			}
		})
	}
}

func scopeFlood(format string, count int) string {
	var builder strings.Builder
	for index := 0; index < count; index++ {
		fmt.Fprintf(&builder, format, index)
	}
	return builder.String()
}
