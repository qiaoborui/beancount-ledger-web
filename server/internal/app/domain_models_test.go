package app

import (
	"reflect"
	"testing"

	ledgermodel "github.com/borui/beancount-ledger-web/server/internal/ledger"
)

var _ ledgermodel.BeanAmount = BeanAmount{}
var _ BeanAmount = ledgermodel.BeanAmount{}
var _ *ledgermodel.MetadataValue = (*MetadataValue)(nil)

func TestDomainModelAliasesRemainIdentical(t *testing.T) {
	tests := []struct {
		name   string
		legacy any
		core   any
	}{
		{name: "BeanAmount", legacy: BeanAmount{}, core: ledgermodel.BeanAmount{}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if reflect.TypeOf(test.legacy) != reflect.TypeOf(test.core) {
				t.Fatalf("legacy type %T differs from core type %T", test.legacy, test.core)
			}
		})
	}
}
