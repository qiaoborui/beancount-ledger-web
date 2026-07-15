package app

import (
	"context"
	"errors"
	"reflect"
	"testing"
)

type testModule struct {
	name     string
	requires []string
	register func(*ModuleRegistry) error
	start    func(context.Context) error
	close    func() error
}

func (m testModule) Name() string { return m.name }

func (m testModule) RequiresModules() []string { return append([]string(nil), m.requires...) }

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

func TestModuleRegistryNamesFollowResolvedOrder(t *testing.T) {
	modules, err := enabledBuiltinModules([]string{"notifications", "importers"})
	if err != nil {
		t.Fatal(err)
	}
	registry, err := NewModuleRegistry(modules...)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := registry.Names(), []string{"web-push", "notifications", "importers"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("module names = %#v, want %#v", got, want)
	}
}

func TestEnabledBuiltinModules(t *testing.T) {
	all, err := enabledBuiltinModules(nil)
	if err != nil {
		t.Fatal(err)
	}
	selected, err := enabledBuiltinModules(moduleNames(all))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(moduleNames(all), moduleNames(selected)) {
		t.Fatalf("selected modules = %#v, want %#v", moduleNames(selected), moduleNames(all))
	}
	if _, err := enabledBuiltinModules([]string{"missing"}); err == nil {
		t.Fatal("unknown module should fail")
	}
	if _, err := enabledBuiltinModules([]string{"importers", "importers"}); err == nil {
		t.Fatal("duplicate module should fail")
	}
	notifications, err := enabledBuiltinModules([]string{"notifications"})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := moduleNames(notifications), []string{"web-push", "notifications"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("notification modules = %#v, want %#v", got, want)
	}
}

func TestSelectModulesResolvesDependenciesBeforeDependents(t *testing.T) {
	storage := testModule{name: "storage"}
	notifications := testModule{name: "notifications", requires: []string{"storage"}}
	selected, err := selectModules([]Module{notifications, storage}, []string{"notifications"})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := moduleNames(selected), []string{"storage", "notifications"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("selected modules = %#v, want %#v", got, want)
	}
}

func TestSelectModulesRejectsUnknownAndCyclicDependencies(t *testing.T) {
	if _, err := selectModules([]Module{testModule{name: "notifications", requires: []string{"storage"}}}, []string{"notifications"}); err == nil {
		t.Fatal("unknown dependency should fail")
	}
	first := testModule{name: "first", requires: []string{"second"}}
	second := testModule{name: "second", requires: []string{"first"}}
	if _, err := selectModules([]Module{first, second}, []string{"first"}); err == nil {
		t.Fatal("cyclic dependency should fail")
	}
}

func TestModuleRegistryBuildsNotificationServiceOnce(t *testing.T) {
	registry, err := NewModuleRegistry(builtinModules()...)
	if err != nil {
		t.Fatal(err)
	}
	dependencies := NotificationServiceDependencies{
		Config:       Config{NotificationRefreshInterval: "off"},
		RuntimeStore: newFilesystemRuntimeStore(t.TempDir()),
		SnapshotPort: &failingNotificationSnapshotPort{},
	}
	first, err := registry.BuildNotificationService(dependencies)
	if err != nil {
		t.Fatal(err)
	}
	second, err := registry.BuildNotificationService(dependencies)
	if err != nil {
		t.Fatal(err)
	}
	if first == nil || first != second {
		t.Fatal("notification service should build once")
	}
	if _, ok := first.WebPushChannel(); !ok {
		t.Fatal("notification service should include the web push channel")
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
