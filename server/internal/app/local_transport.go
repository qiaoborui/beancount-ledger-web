package app

// The mobile transport invokes a closed set of existing application handlers
// directly. It creates no listener, HTTP client, scheduler, or environment-based
// application configuration. Swift owns the app-private workspace and unlock.
import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"

	"github.com/gin-gonic/gin"
)

type localAuthContextKey struct{}

func localRequestAuthenticated(c *gin.Context) bool {
	return c.Request != nil && c.Request.Context().Value(localAuthContextKey{}) == true
}

type LocalRequest struct {
	WorkspaceRoot string               `json:"workspaceRoot"`
	RuntimeRoot   string               `json:"runtimeRoot"`
	Entrypoint    string               `json:"entrypoint"`
	Method        string               `json:"method"`
	Path          string               `json:"path"`
	Query         map[string]string    `json:"query"`
	Body          json.RawMessage      `json:"body"`
	Staging       bool                 `json:"staging"`
	ImportFile    *LocalImportFile     `json:"importFile,omitempty"`
	Canonical     *LocalCanonicalModel `json:"canonical,omitempty"`
	ModelHandle   string               `json:"modelHandle,omitempty"`
}

type LocalImportFile struct {
	Name string `json:"name"`
	Data string `json:"data"`
}

// DispatchLocalRequest returns an endpoint-compatible payload. A successful
// mutation is a staged proposal; canonical validation and publication belong
// to the caller's workspace transaction.
func DispatchLocalRequest(input LocalRequest) (int, json.RawMessage, error) {
	if input.Path == "/api/ledger/overview/categories" && (input.Staging || input.ImportFile != nil) {
		return http.StatusBadRequest, nil, errors.New("overview categories require a committed generation without an import file")
	}
	cfg, err := localConfig(input)
	if err != nil {
		return http.StatusBadRequest, nil, err
	}
	if input.ModelHandle != "" {
		if input.Canonical != nil {
			return http.StatusBadRequest, nil, errors.New("handle and canonical are mutually exclusive")
		}
		cfg, err = resolveLocalModel(cfg, input.ModelHandle, input.Staging)
		if err != nil {
			return http.StatusConflict, nil, err
		}
	}
	// Preserve the preview and runtime receipts until canonical validation has
	// accepted the staged workspace. Swift discards this staging directory.
	if input.Staging {
		stagedRuntime := filepath.Join(filepath.Dir(cfg.LedgerRoot), "runtime")
		if err := copyLocalRuntime(cfg.RuntimeDir, stagedRuntime); err != nil {
			return http.StatusBadRequest, nil, err
		}
		cfg.RuntimeDir = stagedRuntime
	}
	cache, err := localRequestCache(cfg, input.Staging)
	if err != nil {
		return http.StatusBadRequest, nil, err
	}
	if (input.Method == "" || strings.EqualFold(input.Method, http.MethodGet)) && input.Path == "/api/ledger/transactions/detail" {
		snapshot, err := cache.Snapshot()
		if err != nil {
			return http.StatusBadRequest, nil, err
		}
		return localTransactionDetailResponse(cfg, snapshot, input.Query)
	}
	if (input.Method == "" || strings.EqualFold(input.Method, http.MethodGet)) && (input.Path == "/api/ledger/transactions/page" || input.Path == "/api/ledger/transactions/history-page") {
		if input.Staging {
			return http.StatusBadRequest, nil, errors.New("transaction pages require a committed generation")
		}
		snapshot, err := cache.Snapshot()
		if err != nil {
			return http.StatusBadRequest, nil, err
		}
		return localTransactionPageProjection(cfg, snapshot, input.Query, input.Path == "/api/ledger/transactions/history-page")
	}
	if (input.Method == "" || strings.EqualFold(input.Method, http.MethodGet)) && input.Path == "/api/ledger/overview/categories" {
		snapshot, err := cache.Snapshot()
		if err != nil {
			return http.StatusBadRequest, nil, err
		}
		return localOverviewCategoriesResponse(cfg, snapshot, input.Query)
	}
	if strings.EqualFold(input.Method, http.MethodPost) && input.Path == "/api/ledger/bql" {
		if input.ImportFile != nil {
			return http.StatusBadRequest, nil, errors.New("importFile is valid only for import preview")
		}
		if len(input.Body) > bqlMaxRequestBodyLength {
			return http.StatusRequestEntityTooLarge, nil, errors.New("BQL request exceeds byte budget")
		}
		var request BQLRequest
		if err := json.Unmarshal(input.Body, &request); err != nil {
			return http.StatusBadRequest, nil, errors.New("invalid BQL request")
		}
		snapshot, err := cache.Snapshot()
		if err != nil {
			return http.StatusBadRequest, nil, err
		}
		result, err := executeLocalBQL(snapshot, request.Query, request.ValuationCurrency)
		if errors.Is(err, errLocalBQLCapacity) {
			return http.StatusRequestEntityTooLarge, nil, err
		}
		if err != nil {
			return http.StatusBadRequest, nil, err
		}
		raw, err := json.Marshal(result)
		return http.StatusOK, raw, err
	}
	runtime := newFilesystemRuntimeStore(cfg.RuntimeDir)
	writer := NewLedgerWriterWithRuntimeStore(cfg, cache, runtime)
	if input.Staging {
		writer.stagingValidation = func() error {
			_, _, err := localLedgerSource(cfg)
			return err
		}
	}
	reader := NewLedgerReadService(cache)
	s := &Server{cfg: cfg, cache: cache, runtimeStore: runtime, writer: writer,
		queryPort: reader, snapshotPort: reader, limiter: NewRateLimiter(),
		accountService:   NewAccountService(cache, writer),
		txService:        NewTransactionService(cache, writer),
		reconcileService: NewReconciliationService(cache, writer)}
	s.notificationService, err = newNotificationService(NotificationServiceDependencies{
		Config: cfg, RuntimeStore: runtime, SnapshotPort: reader,
	}, newNotificationChannelRegistry())
	if err != nil {
		return http.StatusInternalServerError, nil, err
	}
	method := strings.ToUpper(input.Method)
	if method == "" {
		method = http.MethodGet
	}
	handler, mutation := localHandler(s, method, input.Path)
	if handler == nil {
		return http.StatusNotImplemented, nil, errors.New("此功能需要外部服务，本地账本仅支持设备内功能")
	}
	if mutation && !input.Staging {
		return http.StatusConflict, nil, errors.New("ledger mutations require a staging workspace")
	}
	body, contentType, err := localRequestBody(input, cfg.LedgerRoot)
	if err != nil {
		return http.StatusBadRequest, nil, err
	}
	values := url.Values{}
	for key, value := range input.Query {
		values.Set(key, value)
	}
	requestURL := &url.URL{Path: input.Path, RawQuery: values.Encode()}
	request := &http.Request{Method: method, URL: requestURL, Header: make(http.Header),
		Body: ioNopCloser{bytes.NewReader(body)}, ContentLength: int64(len(body))}
	request.Header.Set("Content-Type", contentType)
	request = request.WithContext(context.WithValue(context.Background(), localAuthContextKey{}, true))
	response := &localResponseWriter{header: make(http.Header)}
	c, _ := gin.CreateTestContext(response)
	c.Request = request
	defer func() {
		if request.MultipartForm != nil {
			_ = request.MultipartForm.RemoveAll()
		}
	}()
	handler(c)
	status := response.status
	if status == 0 {
		status = http.StatusOK
	}
	var payload any
	if err := json.Unmarshal(response.body.Bytes(), &payload); err != nil {
		return http.StatusInternalServerError, nil, errors.New("local endpoint returned an invalid JSON response")
	}
	normalizeLocalSourcePaths(payload, localResponseModel(input.Path), cfg.LedgerRoot, false)
	if status >= 200 && status < 300 {
		payload = normalizeLocalResponseCollections(payload, input.Path)
	}
	encoded, err := json.Marshal(payload)
	return status, encoded, err
}

// Retain one read model across native page requests. Source content and the
// canonical plugin output both participate in the key; staging always gets a
// fresh cache. localConfig still validates paths and symlinks on every request.
var localPageCache struct {
	sync.Mutex
	key   localPageCacheKey
	cache *LedgerCache
}

type localPageCacheKey struct {
	root, entrypoint string
	version          LedgerVersion
	canonical        [sha256.Size]byte
}

func localRequestCache(cfg Config, staging bool) (*LedgerCache, error) {
	version, err := ledgerVersion(cfg)
	if err != nil {
		return nil, err
	}
	if cfg.localRegisteredCache != nil {
		return cfg.localRegisteredCache, nil
	}
	if staging || filepath.Base(filepath.Dir(filepath.Dir(cfg.LedgerRoot))) != "generations" {
		return NewLedgerCache(cfg), nil
	}
	canonical, err := json.Marshal(cfg.localCanonical)
	if err != nil {
		return nil, err
	}
	key := localPageCacheKey{root: cfg.LedgerRoot, entrypoint: cfg.localEntrypoint,
		version: version, canonical: sha256.Sum256(canonical)}
	localPageCache.Lock()
	defer localPageCache.Unlock()
	if localPageCache.cache == nil || localPageCache.key != key {
		localPageCache.key = key
		localPageCache.cache = NewLedgerCache(cfg)
	}
	return localPageCache.cache, nil
}

// Keep the allowlist explicit: cloud, AI, Git, push and authentication routes
// can never be reached through a path supplied by the mobile client.
func localHandler(s *Server, method, path string) (gin.HandlerFunc, bool) {
	if method == http.MethodGet {
		return map[string]gin.HandlerFunc{
			"/api/ledger/bootstrap":         s.ledgerBootstrap,
			"/api/ledger/summary":           s.summary,
			"/api/ledger/transactions":      s.transactions,
			"/api/ledger/income-statement":  s.incomeStatement,
			"/api/ledger/dashboard":         s.dashboard,
			"/api/ledger/home-report":       s.homeReport,
			"/api/ledger/reconciliation":    s.reconciliation,
			"/api/ledger/version":           s.ledgerVersion,
			"/api/ledger/entries":           s.ledgerEntries,
			"/api/ledger/balances":          s.balances,
			"/api/ledger/investments":       s.investments,
			"/api/ledger/account-status":    s.accountStatus,
			"/api/ledger/accounts/detail":   s.accountDetail,
			"/api/ledger/accounts":          s.accounts,
			"/api/ledger/insights":          s.insights,
			"/api/ledger/notifications":     s.notifications,
			"/api/ledger/index-info":        s.indexInfo,
			"/api/ledger/bql-history":       s.bqlHistory,
			"/api/ledger/imports/providers": s.importsProviders,
			"/api/ledger/imports/documents": s.importsDocuments,
			"/api/ledger/editor/files":      s.editorFiles,
			"/api/ledger/editor/file":       s.editorFile,
		}[path], false
	}
	if method == http.MethodPost {
		if path == "/api/ledger/bql" {
			return s.bql, false
		}
		if path == "/api/ledger/imports/preview" {
			return s.importsPreview, false
		}
		if path == "/api/ledger/bql-history" {
			return s.saveBQLHistory, false
		}
		return map[string]gin.HandlerFunc{
			"/api/ledger/append":              s.appendEntry,
			"/api/ledger/append-batch":        s.appendBatch,
			"/api/ledger/transactions":        s.reverseTransaction,
			"/api/ledger/transactions/tags":   s.addTransactionTags,
			"/api/ledger/accounts":            s.appendAccount,
			"/api/ledger/accounts/operations": s.applyAccountOperations,
			"/api/ledger/reconciliation":      s.reconcile,
			"/api/ledger/imports/commit":      s.importsCommit,
		}[path], true
	}
	if method == http.MethodPut {
		return map[string]gin.HandlerFunc{
			"/api/ledger/transactions": s.updateTransaction,
			"/api/ledger/editor/file":  s.saveEditorFile,
		}[path], true
	}
	if method == http.MethodDelete && path == "/api/ledger/transactions" {
		return s.deleteTransaction, true
	}
	if method == http.MethodPatch && path == "/api/ledger/notifications" {
		return s.updateNotifications, false
	}
	return nil, false
}

func localConfig(input LocalRequest) (Config, error) {
	root := filepath.Clean(input.WorkspaceRoot)
	if !filepath.IsAbs(root) || root == string(filepath.Separator) {
		return Config{}, errors.New("an absolute app-private workspace is required")
	}
	if filepath.Base(root) != "workspace" {
		return Config{}, errors.New("workspace root must be a managed workspace directory")
	}
	container := filepath.Dir(filepath.Dir(root))
	containerName := filepath.Base(container)
	if containerName != "generations" && containerName != "staging" {
		return Config{}, errors.New("workspace must belong to a managed generation or staging directory")
	}
	if input.Staging && containerName != "staging" {
		return Config{}, errors.New("staged mutations require the staging directory")
	}
	ledgerRoot := filepath.Dir(container)
	runtimeRoot := filepath.Join(ledgerRoot, "runtime")
	if input.RuntimeRoot != "" && filepath.Clean(input.RuntimeRoot) != runtimeRoot {
		return Config{}, errors.New("runtime root must belong to the same local ledger")
	}
	entrypoint := input.Entrypoint
	if entrypoint == "" {
		entrypoint = "main.bean"
	}
	if filepath.IsAbs(entrypoint) || !fs.ValidPath(filepath.ToSlash(entrypoint)) {
		return Config{}, errors.New("entrypoint must be a relative workspace path")
	}
	// The selected generation is pinned by the caller. Sync candidates, old
	// generations and Git objects have independent lifetimes and must never be
	// traversed while validating this request.
	for _, directory := range []string{ledgerRoot, container, filepath.Dir(root), root} {
		if err := validateLocalDirectory(directory, false); err != nil {
			return Config{}, err
		}
	}
	if err := rejectLocalSymlinks(root); err != nil {
		return Config{}, err
	}
	runtimeRoots := []string{runtimeRoot}
	if input.Staging {
		runtimeRoots = append(runtimeRoots, filepath.Join(filepath.Dir(root), "runtime"))
	}
	for _, directory := range runtimeRoots {
		if err := validateLocalDirectory(directory, true); err != nil {
			return Config{}, err
		}
		if err := scanLocalTree(directory, true); err != nil {
			return Config{}, err
		}
	}
	return Config{localTransport: true, localEntrypoint: entrypoint, localCanonical: input.Canonical, LedgerRoot: root,
		RuntimeDir: runtimeRoot, LedgerStorage: "filesystem", LedgerReadModel: "files",
		LedgerClusterID: "local:" + ledgerRoot, NotificationRefreshInterval: "off"}, nil
}

func rejectLocalSymlinks(root string) error {
	return scanLocalTree(root, false)
}

func validateLocalDirectory(path string, allowMissing bool) error {
	info, err := os.Lstat(path)
	if allowMissing && errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("local workspace ancestors must be regular directories")
	}
	return nil
}

func scanLocalTree(root string, allowDisappearing bool) error {
	return filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		// Import preview cleanup can remove runtime entries during enumeration.
		// The immutable workspace and all mandatory ancestors remain strict.
		if allowDisappearing && errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return errors.New("local workspaces must contain regular files and directories")
		}
		if !entry.IsDir() && !entry.Type().IsRegular() {
			return errors.New("unsupported local workspace file type")
		}
		return nil
	})
}

func copyLocalRuntime(source, destination string) error {
	if _, err := os.Stat(source); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return filepath.WalkDir(source, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		// Canonical export is scratch owned by the serialized native bridge,
		// never an import receipt. Do not copy/read orphaned huge stream files.
		if relative == "canonical-stream" && entry.IsDir() {
			return filepath.SkipDir
		}
		target := filepath.Join(destination, relative)
		if entry.IsDir() {
			return os.MkdirAll(target, 0o700)
		}
		if !entry.Type().IsRegular() {
			return errors.New("invalid runtime file type")
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, content, 0o600)
	})
}

func readConfiguredLedgerLines(cfg Config) ([]BeanLine, error) {
	if cfg.localTransport {
		lines, _, err := localLedgerSource(cfg)
		return lines, err
	}
	return ReadLedgerLines(mainBeanPath(cfg), map[string]bool{})
}

func localLedgerSource(cfg Config) ([]BeanLine, []fileStat, error) {
	return walkLocalLedgerSource(cfg, true)
}

// Version checks use the same include traversal and content hashes as source
// loading, but must not retain every line of the ledger just to discard it.
func walkLocalLedgerSource(cfg Config, collectLines bool) ([]BeanLine, []fileStat, error) {
	seen := map[string]bool{}
	var lines []BeanLine
	var stats []fileStat
	totalBytes := 0
	var visit func(string) error
	visit = func(full string) error {
		relative, err := filepath.Rel(cfg.LedgerRoot, full)
		if err != nil || !fs.ValidPath(filepath.ToSlash(relative)) {
			return errors.New("ledger include escapes the workspace")
		}
		if seen[full] {
			return nil
		}
		seen[full] = true
		if len(seen) > 4096 {
			return errors.New("local ledger exceeds 4096 included files")
		}
		info, err := os.Lstat(full)
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Size() > 8<<20 {
			return errors.New("ledger include must be a regular file of at most 8 MiB")
		}
		raw, err := os.ReadFile(full)
		if err != nil {
			return err
		}
		totalBytes += len(raw)
		if totalBytes > 64<<20 {
			return errors.New("local ledger exceeds 64 MiB")
		}
		stats = append(stats, fileStat{relative: filepath.ToSlash(relative), contentHash: sha256.Sum256(raw), mtimeMs: info.ModTime().UnixMilli()})
		index := 0
		for line := range strings.SplitSeq(string(raw), "\n") {
			index++
			line = strings.TrimSuffix(line, "\r")
			if collectLines {
				lines = append(lines, BeanLine{File: full, Line: index, Text: line})
			}
			match := includeRe.FindStringSubmatch(strings.TrimSpace(line))
			if match == nil {
				continue
			}
			if filepath.IsAbs(match[1]) {
				return errors.New("absolute ledger includes are unsupported in local workspaces")
			}
			pattern := filepath.Join(filepath.Dir(full), match[1])
			rel, err := filepath.Rel(cfg.LedgerRoot, pattern)
			if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
				return errors.New("ledger include escapes the workspace")
			}
			matches, err := filepath.Glob(pattern)
			if err != nil {
				return err
			}
			if len(matches) == 0 {
				return fmt.Errorf("ledger include has no matching files: %s", match[1])
			}
			for _, file := range matches {
				if err := visit(file); err != nil {
					return err
				}
			}
		}
		return nil
	}
	err := visit(mainBeanPath(cfg))
	return lines, stats, err
}

func localRequestBody(input LocalRequest, root string) ([]byte, string, error) {
	if input.ImportFile == nil {
		if len(input.Body) == 0 {
			return nil, "application/json", nil
		}
		var body any
		if err := json.Unmarshal(input.Body, &body); err != nil {
			return nil, "", err
		}
		normalizeLocalSourcePaths(body, localSourceRequestModel(input), root, true)
		encoded, err := json.Marshal(body)
		return encoded, "application/json", err
	}
	if input.Path != "/api/ledger/imports/preview" {
		return nil, "", errors.New("importFile is valid only for import preview")
	}
	content, err := base64.StdEncoding.DecodeString(input.ImportFile.Data)
	if err != nil {
		return nil, "", errors.New("invalid base64 import file")
	}
	if len(content) > 10<<20 {
		return nil, "", errors.New("import file exceeds 10 MiB")
	}
	filename := filepath.Base(input.ImportFile.Name)
	if filename == "." || filename == "" {
		return nil, "", errors.New("import filename is required")
	}
	var buffer bytes.Buffer
	writer := multipart.NewWriter(&buffer)
	part, err := writer.CreateFormFile("file", filename)
	if err != nil {
		return nil, "", err
	}
	if _, err := part.Write(content); err != nil {
		return nil, "", err
	}
	var fields map[string]any
	if len(input.Body) > 0 {
		if err := json.Unmarshal(input.Body, &fields); err != nil {
			return nil, "", err
		}
	}
	for _, key := range []string{"provider", "alipayFundRounding", "archivePassword"} {
		if value, ok := fields[key]; ok {
			if err := writer.WriteField(key, fmt.Sprint(value)); err != nil {
				return nil, "", err
			}
		}
	}
	if err := writer.Close(); err != nil {
		return nil, "", err
	}
	return buffer.Bytes(), writer.FormDataContentType(), nil
}

// Only these request schemas carry transaction locators. Ledger metadata,
// importer payloads and arbitrary BQL cells remain opaque user data.
func localSourceRequestModel(input LocalRequest) reflect.Type {
	switch strings.ToUpper(input.Method) + " " + input.Path {
	case "PUT /api/ledger/transactions":
		return reflect.TypeOf(UpdateTransactionRequest{})
	case "DELETE /api/ledger/transactions":
		return reflect.TypeOf(DeleteTransactionRequest{})
	case "POST /api/ledger/transactions":
		return reflect.TypeOf(ReverseTransactionRequest{})
	case "POST /api/ledger/transactions/tags":
		return reflect.TypeOf(AddTransactionTagsRequest{})
	default:
		return nil
	}
}

func normalizeLocalSourcePaths(value any, model reflect.Type, root string, incoming bool) {
	if model == nil || value == nil {
		return
	}
	for model.Kind() == reflect.Pointer {
		model = model.Elem()
	}
	switch model.Kind() {
	case reflect.Struct:
		values, ok := value.(map[string]any)
		if !ok {
			return
		}
		// Parse errors also expose a source file, while their message remains
		// untouched. Match concrete types instead of matching arbitrary keys.
		if model == reflect.TypeOf(TransactionSource{}) || (!incoming && model == reflect.TypeOf(BeanParseError{})) {
			if file, ok := values["file"].(string); ok {
				if incoming && !filepath.IsAbs(file) && fs.ValidPath(filepath.ToSlash(file)) {
					values["file"] = filepath.Join(root, filepath.FromSlash(file))
				} else if !incoming && strings.HasPrefix(file, root+string(filepath.Separator)) {
					values["file"] = filepath.ToSlash(strings.TrimPrefix(file, root+string(filepath.Separator)))
				}
			}
			return
		}
		for index := 0; index < model.NumField(); index++ {
			field := model.Field(index)
			if !field.IsExported() {
				continue
			}
			name := strings.Split(field.Tag.Get("json"), ",")[0]
			if name == "-" {
				continue
			}
			if field.Anonymous && name == "" {
				normalizeLocalSourcePaths(values, field.Type, root, incoming)
				continue
			}
			if name == "" {
				name = field.Name
			}
			if child, exists := values[name]; exists {
				normalizeLocalSourcePaths(child, field.Type, root, incoming)
			}
		}
	case reflect.Slice, reflect.Array:
		if values, ok := value.([]any); ok {
			for _, child := range values {
				normalizeLocalSourcePaths(child, model.Elem(), root, incoming)
			}
		}
	case reflect.Map:
		if values, ok := value.(map[string]any); ok {
			for _, child := range values {
				normalizeLocalSourcePaths(child, model.Elem(), root, incoming)
			}
		}
	}
}

type ioNopCloser struct{ *bytes.Reader }

func (ioNopCloser) Close() error { return nil }

type localResponseWriter struct {
	header http.Header
	body   bytes.Buffer
	status int
}

func (w *localResponseWriter) Header() http.Header { return w.header }
func (w *localResponseWriter) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
}
func (w *localResponseWriter) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.body.Write(p)
}
