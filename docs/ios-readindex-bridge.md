# Opt-in bounded native transport

This stacks on [the index core](ios-readindex-core.md). It does not select the
bounded engine in the app or change workspace publication.

- `server/mobilereadindex` exposes a gomobile scalar bridge. It starts locked,
  pins a dedicated private derived-data root, rejects symlinks/hardlinks and
  concurrent operations, and invalidates output across cancellation/privacy
  transitions. Build never selects a reader; Open verifies before replacement.
- `BRExportStream` calls `ledger_stream_bridge.export_stream_json` and writes an
  exclusive spool directly. Its result is at most 1024 UTF-8 bytes, with counts
  and digests or a fixed path-free error. Free the result with `BRFree`. The
  caller freezes source, creates/protects the derived directory first, and
  removes the spool after consumption or failure. Python still owns an O(N) AST.
- The runtime packaging scripts include both new Python modules; LedgerCore
  includes the new Go package. The consuming application explicitly links system
  SQLite, since a Go C archive does not propagate `-lsqlite3` to the app linker.
- `EmbeddedBeancountValidator.exportStream` serializes Python calls.
  `BoundedReadIndexClient` caps Swift decoding, preserves decimal strings,
  supplies an injectable test backend and exposes cancellation independently of
  blocking native calls. It is a scalar display projection, **not** full parity
  for tags, links, custom typed values or metadata. These remain in index records.
  Native Swift linkage requires `LEDGER_BOUNDED_READ_INDEX`; without it calls
  fail unavailable, never fall back to the snapshot.

## Validation and limitations

Linux: Go1.25.10 full backend tests/build, bridge/core race tests and vet, pinned
Objective-C binding generation, 72 Python3.14 runtime tests including native C
ABI tests and Go verifier interoperability, seven packaging tests, shell syntax
and diff checks passed. Host C ABI tests substitute Apple registration symbols;
packaging tests stub the Apple installer. Swift tests were added but **not run**:
this host lacks Swift/Xcode. Actual device/simulator linking, protection
inheritance and lock/memory behavior remain required gates. This is not Apple
runtime validation.

Next: coherent immutable source/index publication, revision leases, opt-in UI
and Widget isolation. Reports, BQL, editor/import prechecks, protected spilling,
full parity and physical-device acceptance remain incomplete. Do not enable the
bounded mode by default based on these host results.
