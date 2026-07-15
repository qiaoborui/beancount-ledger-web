package app

import (
	"context"
	"errors"
	"reflect"
	"testing"
)

type testModule struct {
	name     string
	register func(*ModuleRegistry) error
	start    func(context.Context) error
	close    func() error
}

func (m testModule) Name() string { return m.name }

func (m testModule) Register(registry *ModuleRegistry) error {
	if m.register != nil {
		return m.register(registry)
	}
	return nil
}

func (m testModule) Start(ctx context.Context) error {
	if m.start != nil {
		return m.start(ctx)
	}
	return nil
}

func (m testModule) Close() error {
	if m.close != nil {
		return m.close()
	}
	return nil
}

func TestBuiltinModulesRegisterAllImporters(t *testing.T) {
	registry, err := NewModuleRegistry(builtinModules()...)
	if err != nil {
		t.Fatal(err)
	}
	ids := registry.Importers().IDs()
	if !reflect.DeepEqual(ids, importProviderIDs()) {
		t.Fatalf("module importer IDs = %#v, want %#v", ids, importProviderIDs())
	}
	for _, id := range ids {
		if _, ok := registry.Importers().Lookup(id); !ok {
			t.Fatalf("module registry missing importer %q", id)
		}
	}
}

func TestModuleRegistryRejectsDuplicateNamesAndImporterIDs(t *testing.T) {
	first := testModule{name: "first"}
	registry, err := NewModuleRegistry(first)
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.Register(first); err == nil {
		t.Fatal("duplicate module name should fail")
	}
	if err := registry.RegisterImporter(staticBillImporter{id: "test"}); err != nil {
		t.Fatal(err)
	}
	if err := registry.RegisterImporter(staticBillImporter{id: "test"}); err == nil {
		t.Fatal("duplicate importer ID should fail")
	}
}

func TestModuleRegistryClosesLifecyclesInReverseOrder(t *testing.T) {
	var calls []string
	first := testModule{
		name: "first",
		start: func(context.Context) error {
			calls = append(calls, "start:first")
			return nil
		},
		close: func() error {
			calls = append(calls, "close:first")
			return nil
		},
	}
	second := testModule{
		name: "second",
		start: func(context.Context) error {
			calls = append(calls, "start:second")
			return nil
		},
		close: func() error {
			calls = append(calls, "close:second")
			return nil
		},
	}
	registry, err := NewModuleRegistry(first, second)
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := registry.Close(); err != nil {
		t.Fatal(err)
	}
	want := []string{"start:first", "start:second", "close:second", "close:first"}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("module lifecycle calls = %#v, want %#v", calls, want)
	}
}

func TestModuleRegistryClosesStartedModulesAfterStartFailure(t *testing.T) {
	var closed bool
	registry, err := NewModuleRegistry(
		testModule{name: "started", close: func() error { closed = true; return nil }},
		testModule{name: "failing", start: func(context.Context) error { return errors.New("start failure") }},
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.Start(context.Background()); err == nil {
		t.Fatal("module start failure should be returned")
	}
	if !closed {
		t.Fatal("started module should close after a later start failure")
	}
}
