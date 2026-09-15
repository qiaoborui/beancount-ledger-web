package ledgercore_test

import (
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestLedgerCoreHasInfrastructureFreeImports(t *testing.T) {
	allowed := map[string]bool{
		"fmt": true, "math": true, "math/big": true, "strconv": true,
		"strings": true, "time": true, "unicode": true, "unicode/utf8": true,
		"github.com/borui/beancount-ledger-web/server/internal/ledger": true,
	}
	err := filepath.WalkDir(".", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || filepath.Ext(path) != ".go" || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
		if err != nil {
			return err
		}
		for _, spec := range file.Imports {
			importPath, err := strconv.Unquote(spec.Path.Value)
			if err != nil {
				return err
			}
			if !allowed[importPath] {
				t.Errorf("%s imports infrastructure dependency %q", path, importPath)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
