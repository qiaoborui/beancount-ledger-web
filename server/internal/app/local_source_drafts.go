package app

import (
	"sync"

	"github.com/borui/beancount-ledger-web/server/internal/ledgercore"
)

// localDeferRawParse lets a registered canonical snapshot skip the full raw
// transaction parse. Hashes come from exact block text; editor drafts and
// source controls are materialized only for the requests that return them.
var localDeferRawParse = true

type localSourceLocator struct {
	file string
	line int
}

// localSourceDrafts holds the unparsed transaction blocks of one immutable
// snapshot. It never mutates the published snapshot: the editable view is a
// separate shallow copy whose Transactions slice carries the drafts.
type localSourceDrafts struct {
	// Plugin/include/scope directives in source order, with their ordinals in
	// the original parse so fallback transactions can be merged back exactly.
	controls       []BeanEntry
	controlIndices []int
	deferred       []ledgercore.DeferredTransaction

	indexOnce sync.Once
	byLocator map[localSourceLocator]int

	editableOnce sync.Once
	editable     *LedgerSnapshot
}

func newLocalSourceDrafts(segments ledgercore.SourceSegments) *localSourceDrafts {
	drafts := &localSourceDrafts{deferred: segments.Deferred}
	for index, entry := range segments.Entries {
		switch entry.Kind {
		case "plugin", "include", "pushtag", "poptag", "pushmeta", "popmeta":
			drafts.controls = append(drafts.controls, entry)
			drafts.controlIndices = append(drafts.controlIndices, index)
		}
	}
	return drafts
}

func (d *localSourceDrafts) lookup(source TransactionSource) (ledgercore.DeferredTransaction, bool) {
	d.indexOnce.Do(func() {
		d.byLocator = make(map[localSourceLocator]int, len(d.deferred))
		for i, block := range d.deferred {
			d.byLocator[localSourceLocator{block.File, block.Line}] = i
		}
	})
	index, ok := d.byLocator[localSourceLocator{source.File, source.Line}]
	if !ok {
		return ledgercore.DeferredTransaction{}, false
	}
	return d.deferred[index], true
}

// entry parses one transaction's editor draft without materializing the rest.
func (d *localSourceDrafts) entry(source TransactionSource) *LedgerEntry {
	if source.Line <= 0 {
		return nil
	}
	block, ok := d.lookup(source)
	if !ok {
		return nil
	}
	return EditableLedgerEntryFromBeanTransaction(block.Parse())
}

func (d *localSourceDrafts) materialize(snapshot *LedgerSnapshot) *LedgerSnapshot {
	d.editableOnce.Do(func() {
		editable := *snapshot
		editable.localSource = nil
		editable.Transactions = make([]Transaction, len(snapshot.Transactions))
		parsed := make(map[localSourceLocator]BeanEntry)
		for i, txn := range snapshot.Transactions {
			if txn.Source.Line > 0 {
				if block, ok := d.lookup(txn.Source); ok {
					raw := block.Parse()
					txn.Entry = EditableLedgerEntryFromBeanTransaction(raw)
					if txn.Entry == nil {
						parsed[localSourceLocator{block.File, block.Line}] = raw
					}
				}
			}
			editable.Transactions[i] = txn
		}
		editable.SourceBeanEntries = d.sourceEntries(parsed)
		d.editable = &editable
	})
	return d.editable
}

// sourceEntries rebuilds compactLocalCanonicalSource's result: controls plus
// transactions whose lossless draft was rejected, in original source order.
func (d *localSourceDrafts) sourceEntries(fallback map[localSourceLocator]BeanEntry) []BeanEntry {
	retained := make([]BeanEntry, 0, len(d.controls)+len(fallback))
	control := 0
	for _, block := range d.deferred {
		raw, ok := fallback[localSourceLocator{block.File, block.Line}]
		if !ok {
			continue
		}
		for control < len(d.controls) && d.controlIndices[control] < block.Index {
			retained = append(retained, d.controls[control])
			control++
		}
		retained = append(retained, raw)
	}
	return append(retained, d.controls[control:]...)
}

// snapshotEditable returns a snapshot whose transactions carry editor drafts
// and whose SourceBeanEntries holds the retained raw source. Read-only paths
// that never return drafts should keep using the cheaper snapshot itself.
func snapshotEditable(snapshot *LedgerSnapshot) *LedgerSnapshot {
	if snapshot == nil || snapshot.localSource == nil {
		return snapshot
	}
	return snapshot.localSource.materialize(snapshot)
}

// snapshotWithDrafts materializes drafts only when the response includes them.
func snapshotWithDrafts(snapshot *LedgerSnapshot, unlocked bool) *LedgerSnapshot {
	if !unlocked {
		return snapshot
	}
	return snapshotEditable(snapshot)
}

// snapshotSourceControls returns the retained plugin/include/scope directives
// without materializing deferred transaction drafts.
func snapshotSourceControls(snapshot *LedgerSnapshot) []BeanEntry {
	if snapshot.localSource != nil {
		return snapshot.localSource.controls
	}
	return snapshot.SourceBeanEntries
}

// snapshotTransactionEntry returns one transaction's editor draft, parsing its
// deferred source block if the snapshot has not materialized drafts.
func snapshotTransactionEntry(snapshot *LedgerSnapshot, txn Transaction) *LedgerEntry {
	if txn.Entry != nil || snapshot == nil || snapshot.localSource == nil {
		return txn.Entry
	}
	return snapshot.localSource.entry(txn.Source)
}
