package app

import (
	"context"
	"reflect"
	"testing"
)

type testLedgerIndexPort struct {
	revision LedgerIndexRevision
	snapshot *LedgerSnapshot
}

func TestLedgerReadServiceKeepsIndexDependencyAsPort(t *testing.T) {
	field, ok := reflect.TypeOf(LedgerReadService{}).FieldByName("indexStore")
	if !ok {
		t.Fatal("LedgerReadService indexStore field is missing")
	}
	if want := reflect.TypeOf((*LedgerIndexPort)(nil)).Elem(); field.Type != want {
		t.Fatalf("indexStore type = %v, want %v", field.Type, want)
	}
}

func (p testLedgerIndexPort) ActiveRevision(context.Context) (LedgerIndexRevision, bool, error) {
	return p.revision, true, nil
}

func (p testLedgerIndexPort) ActiveSnapshot(context.Context) (*LedgerSnapshot, bool, error) {
	return p.snapshot, true, nil
}

func (p testLedgerIndexPort) ActiveSnapshotLite(context.Context) (*LedgerSnapshot, bool, error) {
	return p.snapshot, true, nil
}

func (testLedgerIndexPort) TransactionsForRevision(context.Context, int64, string, string) ([]Transaction, error) {
	return nil, nil
}

func (testLedgerIndexPort) BalancesForRevision(context.Context, int64) (map[string]int, []BalanceAssertion, error) {
	return nil, nil, nil
}

func TestLedgerReadServiceUsesLedgerIndexPort(t *testing.T) {
	snapshot := &LedgerSnapshot{LedgerVersion: LedgerVersion{Version: "indexed"}}
	index := testLedgerIndexPort{revision: LedgerIndexRevision{ID: 1, LedgerVersion: snapshot.LedgerVersion}, snapshot: snapshot}
	service := NewLedgerReadServiceWithIndex(nil, index, nil, true)

	got, err := service.SnapshotLite(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got != snapshot {
		t.Fatal("read service did not use the injected index port")
	}
}

func TestOpenApplicationStorageAdaptersUsesFilesystemPorts(t *testing.T) {
	adapters, err := openApplicationStorageAdapters(testLedger(t))
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := adapters.runtimeStore.(*filesystemRuntimeStore); !ok {
		t.Fatalf("runtime store = %T, want filesystem adapter", adapters.runtimeStore)
	}
	if adapters.indexStore != nil || adapters.limiter == nil || len(adapters.closers) != 0 {
		t.Fatalf("unexpected filesystem adapters: %#v", adapters)
	}
}
