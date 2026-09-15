package mobilecore

import (
	"path"
	"sort"
	"strings"

	"github.com/borui/beancount-ledger-web/server/internal/ledgercore"
	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

const (
	maxWorkspaceFiles = 1024
	maxIncludeDepth   = 64
	maxIncludeCount   = 4096
)

type workspaceRequestV1 struct {
	Version    int               `json:"version"`
	Entrypoint string            `json:"entrypoint"`
	Files      []workspaceFileV1 `json:"files"`
}

type workspaceFileV1 struct {
	Path string `json:"path"`
	Text string `json:"text"`
}

// CompileWorkspaceJSON expands a version 1 in-memory workspace and runs the
// lightweight ledgercore compiler. Paths are canonical slash-separated relative
// paths. Includes resolve relative to their source, with sorted glob matches;
// each file is loaded once. No filesystem access or plugin execution occurs.
// Canonical Beancount validation remains a separate future integration gate.
func CompileWorkspaceJSON(requestJSON string) string {
	const operation = "compileWorkspace"
	var request workspaceRequestV1
	if diagnostic := decodeRequestJSON(requestJSON, &request); diagnostic != nil {
		return diagnosticResponse(operation, diagnostic)
	}
	if request.Version != parseAPIVersion {
		return diagnosticResponse(operation, limitDiagnostic("request.unsupported_version", "supported workspace request version is 1", "", 0))
	}
	files, diagnostic := validateWorkspace(request)
	if diagnostic != nil {
		return diagnosticResponse(operation, diagnostic)
	}
	expander := workspaceExpander{
		files: files, active: map[string]bool{}, loaded: map[string]bool{},
	}
	for filename := range files {
		expander.paths = append(expander.paths, filename)
	}
	sort.Strings(expander.paths)
	if diagnostic := expander.expand(request.Entrypoint, "", 0); diagnostic != nil {
		return diagnosticResponse(operation, diagnostic)
	}
	if diagnostic := validateScopeLimits(expander.lines); diagnostic != nil {
		return diagnosticResponse(operation, diagnostic)
	}
	parsed := ledgercore.ParseLines(expander.lines)
	compiled := ledgercore.CompileLines(expander.lines)
	diagnostics := make([]diagnosticV1, len(compiled.Errors))
	for index, err := range compiled.Errors {
		code := "beancount.parse_error"
		if index >= len(parsed.Errors) {
			code = compileDiagnosticCode(err.Message)
		}
		diagnostics[index] = diagnosticV1{Code: code, Severity: "error", Message: err.Message, File: err.File, Line: err.Line}
	}
	return encodeResponse(parseResponseV1{
		Version: parseAPIVersion, Operation: operation, OK: len(diagnostics) == 0,
		Result: &parseResultV1{Entries: entriesV1(compiled.Entries)}, Diagnostics: diagnostics,
	})
}

func validateWorkspace(request workspaceRequestV1) (map[string]string, *diagnosticV1) {
	if diagnostic := validateWorkspacePath(request.Entrypoint, false); diagnostic != nil {
		return nil, diagnostic
	}
	if len(request.Files) > maxWorkspaceFiles {
		return nil, limitDiagnostic("request.too_many_files", "workspace exceeds 1024 files", "", 0)
	}
	files := make(map[string]string, len(request.Files))
	type pathIdentity struct {
		path string
		file bool
	}
	identities := make(map[string]pathIdentity, len(request.Files))
	fold := cases.Fold()
	totalBytes, totalLines := 0, 0
	for _, file := range request.Files {
		if diagnostic := validateWorkspacePath(file.Path, false); diagnostic != nil {
			return nil, diagnostic
		}
		// Check every prefix: two distinct filenames can still alias their
		// parent directory on iOS's case/Unicode-normalizing filesystem.
		segments := strings.Split(file.Path, "/")
		for index := range segments {
			prefix := strings.Join(segments[:index+1], "/")
			identity := norm.NFC.String(fold.String(norm.NFC.String(prefix)))
			isFile := index == len(segments)-1
			if previous, exists := identities[identity]; exists {
				if previous.path != prefix || previous.file && isFile {
					return nil, limitDiagnostic("workspace.duplicate_path", "workspace contains duplicate or aliased paths", file.Path, 0)
				}
				if previous.file != isFile {
					return nil, limitDiagnostic("workspace.path_conflict", "workspace path is used as both a file and directory", file.Path, 0)
				}
			}
			identities[identity] = pathIdentity{path: prefix, file: isFile}
		}
		totalBytes += len(file.Text)
		if totalBytes > maxTextBytes {
			return nil, limitDiagnostic("request.text_too_large", "workspace text exceeds 2 MiB cumulatively", file.Path, 0)
		}
		totalLines += strings.Count(file.Text, "\n") + 1
		if totalLines > maxLineCount {
			return nil, limitDiagnostic("request.too_many_lines", "workspace exceeds 100000 lines cumulatively", file.Path, 0)
		}
		if diagnostic := validateRequestLimits(parseRequestV1{Filename: file.Path, Text: file.Text}); diagnostic != nil {
			return nil, diagnostic
		}
		files[file.Path] = file.Text
	}
	if _, exists := files[request.Entrypoint]; !exists {
		return nil, limitDiagnostic("workspace.missing_entrypoint", "workspace entrypoint is missing", request.Entrypoint, 0)
	}
	return files, nil
}

func validateWorkspacePath(filename string, pattern bool) *diagnosticV1 {
	if len(filename) > maxFilenameBytes {
		return limitDiagnostic("request.filename_too_long", "workspace path exceeds 1024 bytes", "", 0)
	}
	invalid := filename == "" || strings.HasPrefix(filename, "/") || strings.ContainsAny(filename, "\\:")
	for _, char := range filename {
		invalid = invalid || char < 32 || char == 127
	}
	for _, segment := range strings.Split(filename, "/") {
		invalid = invalid || segment == "" || segment == "." || segment == ".."
	}
	if !pattern && strings.ContainsAny(filename, "*?[") {
		invalid = true
	}
	if invalid {
		return limitDiagnostic("workspace.invalid_path", "paths must be canonical relative paths without traversal or aliases", filename, 0)
	}
	if pattern {
		if _, err := path.Match(filename, ""); err != nil {
			return limitDiagnostic("workspace.invalid_include", "include glob pattern is malformed", filename, 0)
		}
	}
	return nil
}

type workspaceExpander struct {
	files        map[string]string
	paths        []string
	active       map[string]bool
	loaded       map[string]bool
	lines        []ledgercore.Line
	includeCount int
}

func (expander *workspaceExpander) expand(filename, source string, sourceLine int) *diagnosticV1 {
	if expander.active[filename] {
		return limitDiagnostic("workspace.include_cycle", "include cycle reaches "+filename, source, sourceLine)
	}
	if expander.loaded[filename] {
		return nil
	}
	if len(expander.active) >= maxIncludeDepth {
		return limitDiagnostic("request.include_depth_exceeded", "include depth exceeds 64 files", source, sourceLine)
	}
	expander.active[filename] = true
	defer delete(expander.active, filename)
	for _, line := range sourceLines(filename, expander.files[filename]) {
		expander.lines = append(expander.lines, line)
		if ledgercore.IsIndentedBeanLine(line.Text) {
			continue
		}
		tokens := ledgercore.ScanBeanLine(line.Text)
		if len(tokens) == 0 || tokens[0].Value != "include" {
			continue
		}
		if len(tokens) != 2 || tokens[1].Kind != ledgercore.TokenString || !closedIncludePath(line.Text) {
			return limitDiagnostic("workspace.invalid_include", "include requires exactly one quoted path", filename, line.Line)
		}
		expander.includeCount++
		if expander.includeCount > maxIncludeCount {
			return limitDiagnostic("request.too_many_includes", "workspace exceeds 4096 include directives", filename, line.Line)
		}
		if diagnostic := validateWorkspacePath(tokens[1].Value, true); diagnostic != nil {
			diagnostic.File, diagnostic.Line = filename, line.Line
			return diagnostic
		}
		pattern := path.Join(path.Dir(filename), tokens[1].Value)
		if diagnostic := validateWorkspacePath(pattern, true); diagnostic != nil {
			diagnostic.File, diagnostic.Line = filename, line.Line
			return diagnostic
		}
		matches := 0
		for _, target := range expander.paths {
			matched, _ := path.Match(pattern, target)
			if !matched {
				continue
			}
			matches++
			if diagnostic := expander.expand(target, filename, line.Line); diagnostic != nil {
				return diagnostic
			}
		}
		if matches == 0 {
			return limitDiagnostic("workspace.missing_include", "include has no matching workspace file: "+pattern, filename, line.Line)
		}
	}
	expander.loaded[filename] = true
	return nil
}

func sourceLines(filename, text string) []ledgercore.Line {
	rawLines := strings.Split(text, "\n")
	lines := make([]ledgercore.Line, len(rawLines))
	for index, line := range rawLines {
		lines[index] = ledgercore.Line{File: filename, Line: index + 1, Text: strings.TrimSuffix(line, "\r")}
	}
	return lines
}

func closedIncludePath(line string) bool {
	line = strings.TrimSpace(line)
	if !strings.HasPrefix(line, "include") {
		return false
	}
	line = strings.TrimSpace(strings.TrimPrefix(line, "include"))
	if len(line) == 0 || line[0] != '"' {
		return false
	}
	for index := 1; index < len(line); index++ {
		if line[index] == '\\' {
			index++
			continue
		}
		if line[index] == '"' {
			tail := strings.TrimSpace(line[index+1:])
			return tail == "" || strings.HasPrefix(tail, ";")
		}
	}
	return false
}
