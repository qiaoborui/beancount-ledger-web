package mobilecore_test

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestMobileCoreUsesOnlyBindingSafeDependencies(t *testing.T) {
	allowed := map[string]bool{
		"encoding/json":                  true,
		"io":                             true,
		"path":                           true,
		"sort":                           true,
		"golang.org/x/text/cases":        true,
		"golang.org/x/text/unicode/norm": true,
		"strings":                        true,
		"github.com/borui/beancount-ledger-web/server/internal/ledgercore": true,
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
				t.Errorf("%s imports binding-unsafe dependency %q", path, importPath)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestMobileCoreExportsOnlyScalarFunctions(t *testing.T) {
	err := filepath.WalkDir(".", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || filepath.Ext(path) != ".go" || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		file, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
		if err != nil {
			return err
		}
		for _, declaration := range file.Decls {
			switch declaration := declaration.(type) {
			case *ast.FuncDecl:
				if declaration.Name.IsExported() {
					assertStringFields(t, declaration.Name.Name+" parameters", declaration.Type.Params)
					assertStringFields(t, declaration.Name.Name+" results", declaration.Type.Results)
				}
			case *ast.GenDecl:
				for _, spec := range declaration.Specs {
					switch spec := spec.(type) {
					case *ast.TypeSpec:
						if spec.Name.IsExported() {
							t.Errorf("%s exports type %s; bindings expose only scalar functions", path, spec.Name.Name)
						}
					case *ast.ValueSpec:
						for _, name := range spec.Names {
							if name.IsExported() {
								t.Errorf("%s exports value %s; bindings expose only scalar functions", path, name.Name)
							}
						}
					}
				}
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func assertStringFields(t *testing.T, name string, fields *ast.FieldList) {
	t.Helper()
	if fields == nil || len(fields.List) != 1 {
		t.Fatalf("%s must contain exactly one string", name)
	}
	identifier, ok := fields.List[0].Type.(*ast.Ident)
	if !ok || identifier.Name != "string" {
		t.Fatalf("%s must use only string, got %#v", name, fields.List[0].Type)
	}
}
