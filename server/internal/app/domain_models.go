package app

import "github.com/borui/beancount-ledger-web/server/internal/ledger"

// These aliases preserve the app package contract while domain ownership moves
// into internal/ledger one slice at a time.
type MetadataValue = ledger.MetadataValue
type BeanAmount = ledger.BeanAmount
