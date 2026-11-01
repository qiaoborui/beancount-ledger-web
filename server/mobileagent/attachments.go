package mobileagent

import (
	"bytes"
	"encoding/base64"
	"encoding/csv"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/extrame/xls"
	"github.com/xuri/excelize/v2"
	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/encoding/unicode"
)

// Files the user attached to the conversation, such as a bank statement to
// reconcile. The shell copies each into the app's runtime directory and, for
// a PDF or an image, writes the text it recognised beside it; tables are
// parsed here. The model never gets a whole file: it reads bounded slices
// and asks reconcile_attachment to do the comparison.
const (
	maxAttachments         = 12
	maxAttachmentBytes     = 25 << 20
	maxAttachmentTextBytes = 4 << 20
	maxAttachmentImage     = 4 << 20
	maxSheetRows           = 50000
	maxCellRunes           = 60
	// maxToolOutputBytes bounds what one attachment read returns to the model.
	maxToolOutputBytes = 14000
)

type attachmentV1 struct {
	// ID is how the model names the file, for example "a1".
	ID   string `json:"id"`
	Name string `json:"name"`
	// Path is the copied file, inside the runtime directory.
	Path string `json:"path"`
	// TextPath is the text the shell extracted from a PDF or recognised in
	// an image, when it did.
	TextPath string `json:"textPath,omitempty"`
	// ImagePath is a downscaled JPEG of an image, for models that see images.
	ImagePath string `json:"imagePath,omitempty"`
	Pages     int    `json:"pages,omitempty"`
	// New marks the files sent with this turn's question.
	New bool `json:"new,omitempty"`
}

var attachmentIDPattern = regexp.MustCompile(`^[a-z0-9]{1,8}$`)

type attachmentKind string

const (
	kindTable attachmentKind = "table"
	kindText  attachmentKind = "text"
	kindImage attachmentKind = "image"
)

type sheetData struct {
	name string
	rows [][]string
}

type parsedAttachment struct {
	kind   attachmentKind
	sheets []sheetData
	text   string
	bytes  int64
}

// attachments are the files of one turn, parsed on first use.
type attachments struct {
	items  []attachmentV1
	images bool
	mu     sync.Mutex
	parsed map[string]*parsedAttachment
	errs   map[string]error
}

// openAttachments checks the files a request names. Every path must resolve
// inside the runtime directory, so a request cannot make the tools read any
// other file on the device.
func openAttachments(items []attachmentV1, runtimeRoot string, images bool) (*attachments, error) {
	if len(items) == 0 {
		return nil, nil
	}
	if len(items) > maxAttachments {
		return nil, fmt.Errorf("at most %d attachments per conversation", maxAttachments)
	}
	if runtimeRoot == "" {
		return nil, errors.New("attachments need a runtime root")
	}
	root, err := filepath.EvalSymlinks(runtimeRoot)
	if err != nil {
		return nil, fmt.Errorf("runtime root: %w", err)
	}
	seen := map[string]bool{}
	checked := make([]attachmentV1, 0, len(items))
	for _, item := range items {
		if !attachmentIDPattern.MatchString(item.ID) || seen[item.ID] {
			return nil, fmt.Errorf("attachment id %q must be short, lowercase and unique", item.ID)
		}
		seen[item.ID] = true
		for _, path := range []*string{&item.Path, &item.TextPath, &item.ImagePath} {
			if *path == "" {
				continue
			}
			resolved, err := insideRoot(root, *path)
			if err != nil {
				return nil, fmt.Errorf("attachment %s: %w", item.ID, err)
			}
			*path = resolved
		}
		if item.Path == "" {
			return nil, fmt.Errorf("attachment %s has no path", item.ID)
		}
		item.Name = strings.TrimSpace(item.Name)
		if item.Name == "" {
			item.Name = filepath.Base(item.Path)
		}
		checked = append(checked, item)
	}
	return &attachments{items: checked, images: images, parsed: map[string]*parsedAttachment{}, errs: map[string]error{}}, nil
}

func insideRoot(root, path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", errors.New("path must be absolute")
	}
	resolved, err := filepath.EvalSymlinks(filepath.Clean(path))
	if err != nil {
		return "", errors.New("file is missing")
	}
	if !strings.HasPrefix(resolved, root+string(filepath.Separator)) {
		return "", errors.New("file must be inside the app's runtime directory")
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() {
		return "", errors.New("not a regular file")
	}
	return resolved, nil
}

// announcement tells the model which files came with the question.
func (a *attachments) announcement() string {
	if a == nil {
		return ""
	}
	var names []string
	for _, item := range a.items {
		if item.New {
			names = append(names, fmt.Sprintf("%s「%s」", item.ID, item.Name))
		}
	}
	if len(names) == 0 {
		return ""
	}
	return "（用户随这条消息上传了附件：" + strings.Join(names, "、") + "。用 list_attachments 查看。）\n\n"
}

func (a *attachments) find(id string) (attachmentV1, error) {
	id = strings.TrimSpace(id)
	for _, item := range a.items {
		if item.ID == id {
			return item, nil
		}
	}
	ids := make([]string, 0, len(a.items))
	for _, item := range a.items {
		ids = append(ids, item.ID)
	}
	return attachmentV1{}, fmt.Errorf("没有附件 %q；可用的附件：%s", id, strings.Join(ids, ", "))
}

func (a *attachments) load(id string) (attachmentV1, *parsedAttachment, error) {
	item, err := a.find(id)
	if err != nil {
		return item, nil, err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if parsed, ok := a.parsed[item.ID]; ok {
		return item, parsed, nil
	}
	if err, ok := a.errs[item.ID]; ok {
		return item, nil, err
	}
	parsed, err := parseAttachment(item)
	if err != nil {
		a.errs[item.ID] = err
		return item, nil, err
	}
	a.parsed[item.ID] = parsed
	return item, parsed, nil
}

func attachmentExt(item attachmentV1) string {
	ext := strings.ToLower(filepath.Ext(item.Name))
	if ext == "" {
		ext = strings.ToLower(filepath.Ext(item.Path))
	}
	return ext
}

var imageExts = map[string]bool{".png": true, ".jpg": true, ".jpeg": true, ".heic": true, ".heif": true, ".webp": true, ".gif": true, ".bmp": true, ".tif": true, ".tiff": true}

func parseAttachment(item attachmentV1) (*parsedAttachment, error) {
	info, err := os.Stat(item.Path)
	if err != nil {
		return nil, err
	}
	if info.Size() > maxAttachmentBytes {
		return nil, fmt.Errorf("附件 %s 超过 25 MB", item.Name)
	}
	ext := attachmentExt(item)
	if ext == ".pdf" || imageExts[ext] {
		kind := kindText
		if imageExts[ext] {
			kind = kindImage
		}
		text, err := readShellText(item)
		if err != nil {
			return nil, err
		}
		return &parsedAttachment{kind: kind, text: text, bytes: info.Size()}, nil
	}
	data, err := os.ReadFile(item.Path)
	if err != nil {
		return nil, err
	}
	parsed := &parsedAttachment{kind: kindTable, bytes: info.Size()}
	switch {
	case bytes.HasPrefix(data, []byte("PK\x03\x04")):
		parsed.sheets, err = parseXLSX(data)
	case bytes.HasPrefix(data, []byte{0xD0, 0xCF, 0x11, 0xE0}):
		parsed.sheets, err = parseXLS(data)
	case ext == ".xlsx" || ext == ".xls" || ext == ".xlsm":
		// Some banks export HTML or CSV under an Excel name.
		text := decodeText(data)
		if looksLikeHTML(text) {
			parsed.sheets = []sheetData{{name: "表格", rows: htmlTableRows(text)}}
		} else {
			parsed.sheets = []sheetData{{name: "表格", rows: parseDelimited(text)}}
		}
	case ext == ".csv" || ext == ".tsv":
		parsed.sheets = []sheetData{{name: "表格", rows: parseDelimited(decodeText(data))}}
	case ext == ".html" || ext == ".htm":
		parsed.sheets = []sheetData{{name: "表格", rows: htmlTableRows(decodeText(data))}}
	default:
		text := decodeText(data)
		if !utf8.ValidString(text) {
			return nil, fmt.Errorf("附件 %s 的格式不支持；支持 CSV、Excel、PDF 和图片", item.Name)
		}
		parsed.kind, parsed.text = kindText, text
		return parsed, nil
	}
	if err != nil {
		return nil, fmt.Errorf("读取附件 %s 失败：%w", item.Name, err)
	}
	for index := range parsed.sheets {
		parsed.sheets[index].rows = tidyRows(parsed.sheets[index].rows)
	}
	return parsed, nil
}

func readShellText(item attachmentV1) (string, error) {
	if item.TextPath == "" {
		return "", nil
	}
	info, err := os.Stat(item.TextPath)
	if err != nil {
		return "", err
	}
	if info.Size() > maxAttachmentTextBytes {
		return "", fmt.Errorf("附件 %s 的识别文字超过 4 MB", item.Name)
	}
	data, err := os.ReadFile(item.TextPath)
	if err != nil {
		return "", err
	}
	return strings.ToValidUTF8(string(data), ""), nil
}

// decodeText reads UTF-8 (with or without BOM), UTF-16 with BOM, and the
// GB18030 family Chinese banks still export.
func decodeText(data []byte) string {
	switch {
	case bytes.HasPrefix(data, []byte{0xEF, 0xBB, 0xBF}):
		return string(data[3:])
	case bytes.HasPrefix(data, []byte{0xFF, 0xFE}), bytes.HasPrefix(data, []byte{0xFE, 0xFF}):
		decoded, err := unicode.UTF16(unicode.LittleEndian, unicode.ExpectBOM).NewDecoder().Bytes(data)
		if err == nil {
			return string(decoded)
		}
	case utf8.Valid(data):
		return string(data)
	}
	if decoded, err := simplifiedchinese.GB18030.NewDecoder().Bytes(data); err == nil && utf8.Valid(decoded) {
		return string(decoded)
	}
	return strings.ToValidUTF8(string(data), "�")
}

func parseDelimited(text string) [][]string {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	lines := strings.SplitN(text, "\n", 40)
	commas, tabs := 0, 0
	for _, line := range lines[:min(len(lines), 30)] {
		commas += strings.Count(line, ",")
		tabs += strings.Count(line, "\t")
	}
	reader := csv.NewReader(strings.NewReader(text))
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true
	if tabs > commas {
		reader.Comma = '\t'
	}
	var rows [][]string
	for len(rows) < maxSheetRows {
		record, err := reader.Read()
		if err != nil {
			if errors.Is(err, csv.ErrFieldCount) || isCSVParseError(err) {
				continue
			}
			break
		}
		rows = append(rows, record)
	}
	return rows
}

func isCSVParseError(err error) bool {
	var parseErr *csv.ParseError
	return errors.As(err, &parseErr)
}

func parseXLSX(data []byte) ([]sheetData, error) {
	book, err := excelize.OpenReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	defer book.Close()
	var sheets []sheetData
	for _, name := range book.GetSheetList() {
		rows, err := book.GetRows(name)
		if err != nil {
			return nil, err
		}
		if len(rows) > maxSheetRows {
			rows = rows[:maxSheetRows]
		}
		sheets = append(sheets, sheetData{name: name, rows: rows})
	}
	return sheets, nil
}

func parseXLS(data []byte) (sheets []sheetData, err error) {
	// The legacy reader panics on some malformed files.
	defer func() {
		if recovered := recover(); recovered != nil {
			sheets, err = nil, fmt.Errorf("无法解析的 xls 文件：%v", recovered)
		}
	}()
	book, err := xls.OpenReader(bytes.NewReader(data), "utf-8")
	if err != nil {
		return nil, err
	}
	for index := 0; index < book.NumSheets(); index++ {
		sheet := book.GetSheet(index)
		if sheet == nil {
			continue
		}
		var rows [][]string
		for r := 0; r <= int(sheet.MaxRow) && len(rows) < maxSheetRows; r++ {
			row := sheet.Row(r)
			if row == nil {
				rows = append(rows, nil)
				continue
			}
			cells := make([]string, 0, row.LastCol()+1)
			for c := 0; c <= row.LastCol(); c++ {
				cells = append(cells, row.Col(c))
			}
			rows = append(rows, cells)
		}
		sheets = append(sheets, sheetData{name: sheet.Name, rows: rows})
	}
	return sheets, nil
}

func looksLikeHTML(text string) bool {
	head := strings.ToLower(text[:min(len(text), 2048)])
	return strings.Contains(head, "<html") || strings.Contains(head, "<table")
}

var (
	htmlRowPattern  = regexp.MustCompile(`(?is)<tr[^>]*>(.*?)</tr>`)
	htmlCellPattern = regexp.MustCompile(`(?is)<t[dh][^>]*>(.*?)</t[dh]>`)
	htmlTagPattern  = regexp.MustCompile(`(?s)<[^>]*>`)
)

// htmlTableRows reads the cells of an HTML table, which is what several
// "Excel" exports really are.
func htmlTableRows(text string) [][]string {
	var rows [][]string
	for _, row := range htmlRowPattern.FindAllStringSubmatch(text, maxSheetRows) {
		var cells []string
		for _, cell := range htmlCellPattern.FindAllStringSubmatch(row[1], -1) {
			value := htmlTagPattern.ReplaceAllString(cell[1], "")
			value = strings.NewReplacer("&nbsp;", " ", "&amp;", "&", "&lt;", "<", "&gt;", ">", "&quot;", `"`).Replace(value)
			cells = append(cells, strings.TrimSpace(value))
		}
		rows = append(rows, cells)
	}
	return rows
}

// tidyRows trims cells, drops trailing empty cells and trailing empty rows.
// Leading rows stay, so row numbers match what the user sees in the file.
func tidyRows(rows [][]string) [][]string {
	for index, row := range rows {
		end := len(row)
		for i := range row {
			row[i] = strings.TrimSpace(strings.Trim(row[i], "\t\u00a0\ufeff"))
		}
		for end > 0 && row[end-1] == "" {
			end--
		}
		rows[index] = row[:end]
	}
	end := len(rows)
	for end > 0 && len(rows[end-1]) == 0 {
		end--
	}
	return rows[:end]
}

func (p *parsedAttachment) sheet(name string) (sheetData, error) {
	if len(p.sheets) == 0 {
		return sheetData{}, errors.New("这个附件不是表格；用 read_attachment 读取文字")
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return p.sheets[0], nil
	}
	for _, sheet := range p.sheets {
		if sheet.name == name {
			return sheet, nil
		}
	}
	names := make([]string, 0, len(p.sheets))
	for _, sheet := range p.sheets {
		names = append(names, sheet.name)
	}
	return sheetData{}, fmt.Errorf("没有工作表 %q；可用：%s", name, strings.Join(names, ", "))
}

func clip(value string, limit int) string {
	if utf8.RuneCountInString(value) <= limit {
		return value
	}
	runes := []rune(value)
	return string(runes[:limit]) + "…"
}

func rowLine(number int, row []string) string {
	cells := make([]string, len(row))
	for i, cell := range row {
		cells[i] = clip(strings.ReplaceAll(strings.ReplaceAll(cell, "\n", " "), "\t", " "), maxCellRunes)
	}
	return strconv.Itoa(number) + "\t" + strings.Join(cells, "\t")
}

func columnCount(rows [][]string) int {
	count := 0
	for _, row := range rows {
		count = max(count, len(row))
	}
	return count
}

// listAttachments describes each file with a short preview, so the model
// can usually pick the header row and columns without another read.
func (a *attachments) listAttachments() (any, error) {
	type sheetV1 struct {
		Name    string   `json:"name"`
		Rows    int      `json:"rows"`
		Columns int      `json:"columns"`
		Preview []string `json:"preview"`
	}
	type itemV1 struct {
		ID        string    `json:"id"`
		Name      string    `json:"name"`
		Kind      string    `json:"kind"`
		Bytes     int64     `json:"bytes"`
		Pages     int       `json:"pages,omitempty"`
		Sheets    []sheetV1 `json:"sheets,omitempty"`
		TextChars int       `json:"textChars,omitempty"`
		Preview   string    `json:"preview,omitempty"`
		CanView   bool      `json:"canViewImage,omitempty"`
		Error     string    `json:"error,omitempty"`
	}
	items := make([]itemV1, 0, len(a.items))
	for _, item := range a.items {
		entry := itemV1{ID: item.ID, Name: item.Name, Pages: item.Pages}
		_, parsed, err := a.load(item.ID)
		if err != nil {
			entry.Error = err.Error()
			items = append(items, entry)
			continue
		}
		entry.Kind, entry.Bytes = string(parsed.kind), parsed.bytes
		entry.CanView = parsed.kind == kindImage && a.images && item.ImagePath != ""
		previewSheets := 3
		for _, sheet := range parsed.sheets {
			described := sheetV1{Name: sheet.name, Rows: len(sheet.rows), Columns: columnCount(sheet.rows), Preview: []string{}}
			if previewSheets > 0 {
				previewSheets--
				shown := 0
				for index, row := range sheet.rows {
					if shown >= 12 {
						break
					}
					if len(row) == 0 {
						continue
					}
					described.Preview = append(described.Preview, rowLine(index+1, row))
					shown++
				}
			}
			entry.Sheets = append(entry.Sheets, described)
		}
		if parsed.kind != kindTable {
			entry.TextChars = utf8.RuneCountInString(parsed.text)
			entry.Preview = clip(parsed.text, 600)
			if strings.TrimSpace(parsed.text) == "" {
				entry.Error = "没有识别出文字"
			}
		}
		items = append(items, entry)
	}
	return map[string]any{"attachments": items,
		"note": "表格预览每行以行号开头，列用制表符分隔。"}, nil
}

func (a *attachments) readAttachment(raw []byte) (any, error) {
	var input struct {
		ID       string `json:"id"`
		Sheet    string `json:"sheet"`
		Start    int    `json:"start"`
		Limit    int    `json:"limit"`
		Contains string `json:"contains"`
	}
	if err := decodeStrict(raw, &input); err != nil {
		return nil, err
	}
	item, parsed, err := a.load(input.ID)
	if err != nil {
		return nil, err
	}
	if parsed.kind != kindTable {
		return readText(item, parsed.text, input.Start, input.Limit, input.Contains), nil
	}
	sheet, err := parsed.sheet(input.Sheet)
	if err != nil {
		return nil, err
	}
	start := max(input.Start, 1)
	limit := input.Limit
	if limit <= 0 {
		limit = 60
	}
	limit = min(limit, 200)
	needle := strings.ToLower(strings.TrimSpace(input.Contains))
	var lines []string
	size, next := 0, 0
	for index := start - 1; index < len(sheet.rows); index++ {
		row := sheet.rows[index]
		if len(row) == 0 {
			continue
		}
		if needle != "" && !strings.Contains(strings.ToLower(strings.Join(row, " ")), needle) {
			continue
		}
		line := rowLine(index+1, row)
		if len(lines) >= limit || size+len(line) > maxToolOutputBytes {
			next = index + 1
			break
		}
		lines = append(lines, line)
		size += len(line) + 1
	}
	result := map[string]any{"id": item.ID, "sheet": sheet.name, "totalRows": len(sheet.rows), "rows": strings.Join(lines, "\n")}
	if next > 0 {
		result["nextStart"] = next
	}
	return result, nil
}

func readText(item attachmentV1, text string, start, limit int, contains string) map[string]any {
	if needle := strings.ToLower(strings.TrimSpace(contains)); needle != "" {
		var hits []string
		size := 0
		for number, line := range strings.Split(text, "\n") {
			if !strings.Contains(strings.ToLower(line), needle) {
				continue
			}
			hit := strconv.Itoa(number+1) + "\t" + clip(line, 200)
			if len(hits) >= 80 || size+len(hit) > maxToolOutputBytes {
				break
			}
			hits = append(hits, hit)
			size += len(hit) + 1
		}
		return map[string]any{"id": item.ID, "matches": strings.Join(hits, "\n"), "matchCount": len(hits)}
	}
	runes := []rune(text)
	start = max(start, 0)
	if limit <= 0 {
		limit = 6000
	}
	limit = min(limit, 12000)
	if start > len(runes) {
		start = len(runes)
	}
	end := min(start+limit, len(runes))
	result := map[string]any{"id": item.ID, "totalChars": len(runes), "start": start, "text": string(runes[start:end])}
	if end < len(runes) {
		result["nextStart"] = end
	}
	if strings.TrimSpace(text) == "" {
		result["note"] = "这个附件没有识别出文字。"
	}
	return result
}

// viewImage returns the downscaled image for a model that sees images. The
// transcript drops it after the turn (see stripImages), so a picture costs
// its tokens once.
func (a *attachments) viewImage(raw []byte) ([]byte, string, error) {
	var input struct {
		ID string `json:"id"`
	}
	if err := decodeStrict(raw, &input); err != nil {
		return nil, "", err
	}
	item, err := a.find(input.ID)
	if err != nil {
		return nil, "", err
	}
	if item.ImagePath == "" {
		return nil, "", errors.New("这个附件没有可查看的图片；用 read_attachment 读取识别出的文字")
	}
	info, err := os.Stat(item.ImagePath)
	if err != nil {
		return nil, "", err
	}
	if info.Size() > maxAttachmentImage {
		return nil, "", errors.New("图片太大")
	}
	data, err := os.ReadFile(item.ImagePath)
	if err != nil {
		return nil, "", err
	}
	mime := "image/jpeg"
	if bytes.HasPrefix(data, []byte("\x89PNG")) {
		mime = "image/png"
	}
	return []byte(base64.StdEncoding.EncodeToString(data)), mime, nil
}
