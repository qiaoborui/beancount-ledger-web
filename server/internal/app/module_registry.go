package app

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
)

// Module is a statically linked application extension registered at startup.
type Module interface {
	Name() string
	Register(*ModuleRegistry) error
}

// ModuleLifecycle is optional for modules that own background resources.
type ModuleLifecycle interface {
	Start(context.Context) error
	Close() error
}

// ModuleRegistry owns application extension points and module lifecycle order.
type ModuleRegistry struct {
	modules    map[string]Module
	importers  *BillImporterRegistry
	lifecycles []ModuleLifecycle
}

func NewModuleRegistry(modules ...Module) (*ModuleRegistry, error) {
	registry := &ModuleRegistry{
		modules:   make(map[string]Module, len(modules)),
		importers: newBillImporterRegistry(),
	}
	for _, module := range modules {
		if err := registry.Register(module); err != nil {
			return nil, err
		}
	}
	return registry, nil
}

func (r *ModuleRegistry) Register(module Module) error {
	if module == nil {
		return errors.New("module is required")
	}
	name := strings.TrimSpace(module.Name())
	if name == "" {
		return errors.New("module name is required")
	}
	if _, exists := r.modules[name]; exists {
		return fmt.Errorf("module %q is already registered", name)
	}
	if err := module.Register(r); err != nil {
		return fmt.Errorf("register module %q: %w", name, err)
	}
	r.modules[name] = module
	if lifecycle, ok := module.(ModuleLifecycle); ok {
		r.lifecycles = append(r.lifecycles, lifecycle)
	}
	return nil
}

func (r *ModuleRegistry) Start(ctx context.Context) error {
	started := make([]ModuleLifecycle, 0, len(r.lifecycles))
	for _, lifecycle := range r.lifecycles {
		if err := lifecycle.Start(ctx); err != nil {
			return errors.Join(fmt.Errorf("start module: %w", err), closeModuleLifecycles(started))
		}
		started = append(started, lifecycle)
	}
	return nil
}

func (r *ModuleRegistry) Close() error {
	if r == nil {
		return nil
	}
	return closeModuleLifecycles(r.lifecycles)
}

func closeModuleLifecycles(lifecycles []ModuleLifecycle) error {
	errs := make([]error, 0, len(lifecycles))
	for index := len(lifecycles) - 1; index >= 0; index-- {
		if err := lifecycles[index].Close(); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

func (r *ModuleRegistry) Importers() *BillImporterRegistry {
	return r.importers
}

func (r *ModuleRegistry) RegisterImporter(importer billImporter) error {
	return r.importers.Register(importer)
}

// BillImporterRegistry is the importer extension point used by import flows.
type BillImporterRegistry struct {
	byID    map[string]billImporter
	ordered []billImporter
}

func newBillImporterRegistry(importers ...billImporter) *BillImporterRegistry {
	registry := &BillImporterRegistry{byID: make(map[string]billImporter, len(importers))}
	for _, importer := range importers {
		if err := registry.Register(importer); err != nil {
			panic(err)
		}
	}
	return registry
}

func (r *BillImporterRegistry) Register(importer billImporter) error {
	if importer == nil {
		return errors.New("importer is required")
	}
	id := strings.TrimSpace(importer.ProviderID())
	if id == "" {
		return errors.New("importer provider ID is required")
	}
	if _, exists := r.byID[id]; exists {
		return fmt.Errorf("importer %q is already registered", id)
	}
	r.byID[id] = importer
	r.ordered = append(r.ordered, importer)
	return nil
}

func (r *BillImporterRegistry) Lookup(provider string) (billImporter, bool) {
	importer, ok := r.byID[provider]
	return importer, ok
}

func (r *BillImporterRegistry) IDs() []string {
	ids := make([]string, 0, len(r.ordered))
	for _, importer := range r.ordered {
		ids = append(ids, importer.ProviderID())
	}
	return ids
}

func (r *BillImporterRegistry) Config(provider string) (importProviderConfig, bool) {
	importer, ok := r.Lookup(provider)
	if !ok {
		return importProviderConfig{}, false
	}
	return importer.ProviderConfig(), true
}

func (r *BillImporterRegistry) Options() []importProviderOption {
	ordered := append([]billImporter(nil), r.ordered...)
	sort.SliceStable(ordered, func(i, j int) bool {
		return ordered[i].DisplayOrder() < ordered[j].DisplayOrder()
	})
	options := make([]importProviderOption, 0, len(ordered))
	for _, importer := range ordered {
		cfg := importer.ProviderConfig()
		options = append(options, importProviderOption{
			ID:         importer.ProviderID(),
			Label:      cfg.Label,
			Detail:     cfg.Detail,
			Extensions: append([]string(nil), cfg.Extensions...),
			Accept:     strings.Join(cfg.Extensions, " / "),
			Engine:     importer.ImportEngine().ID(),
		})
	}
	return options
}

func (r *BillImporterRegistry) Detect(filename string, content []byte, override string) (providerDetection, error) {
	if override != "" {
		if importer, ok := r.Lookup(override); ok {
			return providerDetection{Provider: importer.ProviderID(), Reason: "手动指定", Confidence: "high"}, nil
		}
		return providerDetection{}, fmt.Errorf("provider must be %s", strings.Join(r.IDs(), ", "))
	}
	ext := strings.ToLower(filepath.Ext(filename))
	sample := string(content)
	if len(content) > 32768 {
		sample = string(content[:32768])
	}
	for _, importer := range r.ordered {
		if detection, ok := importer.Detect(filename, sample, ext); ok {
			return detection, nil
		}
	}
	return providerDetection{}, errorsUnsupportedBillType()
}

type importerModule struct{}

func (importerModule) Name() string { return "importers" }

func (importerModule) Register(registry *ModuleRegistry) error {
	for _, importer := range billImporters {
		if err := registry.RegisterImporter(importer); err != nil {
			return err
		}
	}
	return nil
}

func builtinModules() []Module {
	return []Module{importerModule{}}
}

func enabledBuiltinModules(enabled []string) ([]Module, error) {
	available := builtinModules()
	if len(enabled) == 0 {
		return available, nil
	}
	byName := make(map[string]Module, len(available))
	for _, module := range available {
		byName[module.Name()] = module
	}
	selected := make([]Module, 0, len(enabled))
	seen := make(map[string]bool, len(enabled))
	for _, name := range enabled {
		if seen[name] {
			return nil, fmt.Errorf("module %q is configured more than once", name)
		}
		module, ok := byName[name]
		if !ok {
			return nil, fmt.Errorf("unknown enabled module %q; available modules: %s", name, strings.Join(moduleNames(available), ", "))
		}
		seen[name] = true
		selected = append(selected, module)
	}
	return selected, nil
}

func moduleNames(modules []Module) []string {
	names := make([]string, 0, len(modules))
	for _, module := range modules {
		names = append(names, module.Name())
	}
	return names
}

func defaultBillImporters() *BillImporterRegistry {
	return newBillImporterRegistry(billImporters...)
}

func (s *Server) importerRegistry() *BillImporterRegistry {
	if s != nil && s.importers != nil {
		return s.importers
	}
	return defaultBillImporterRegistry
}
