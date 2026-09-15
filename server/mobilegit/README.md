# Mobile Git bridge

`DispatchJSON(string) string` is the only exported bridge function. Gomobile
generates `MobilegitDispatchJSON` in `LedgerCore.xcframework`.

Every request includes `version: 1`, `operation`, and an absolute
`storageRoot` identifying a provider-private bare cache. The caller owns the
cache lifecycle and platform data protection. An existing empty cache directory
is accepted. The first network operation binds its cache to one URL and branch.

| Operation | Additional request fields | Result fields |
| --- | --- | --- |
| `fetch` | `url`, `branch`, optional `username`, `password` | `remoteHead`, `branchExists` |
| `export` | `commit`, `directory` (absent candidate, existing parent) | `commit`, `directory`, `fileCount` |
| `commit` | `directory` (snapshot), `parent` (empty for root), `message`, optional `authorName`, `authorEmail` | `commit`, `parent` |
| `push` | `url`, `branch`, `commit`, required `expectedRemoteHead`, optional credentials | `remoteHead` |
| `cancel` | `requestID` only | `cancelled` |

Success uses `{"version":1,"operation":"...","ok":true,"result":{...}}`.
Failure uses `ok:false` and `error:{code,message}`. Codes include
`git.invalid_request`, `git.unsafe_path`, `git.limit_exceeded`,
`git.remote_changed`, `git.non_fast_forward`, `git.cancelled`, `git.timeout`,
and `git.failed`.

Optional `requestID` (maximum 128 bytes) supports cancellation from a concurrent
bridge call. `timeoutSeconds` defaults to 60 and accepts values through 180.
Operations sharing a canonical cache path run serially and honor cancellation
while waiting for the cache lock.

Use a fresh UUID for every request. A successful `cancel` returns
`cancelled:true` when cancellation has been accepted, including before the
worker registers its request. Such early cancellations remain effective for
three minutes, with at most 256 pending IDs and automatic expiration; additional
unknown IDs receive `git.limit_exceeded` while that budget is full.

## Transport and publication boundaries

- Production URLs use HTTPS, with credentials passed separately for each call.
  Credentials remain in memory and are omitted from cache config. Redirects stay
  on the original HTTPS host and port. Plaintext and subprocess-backed Git
  transports are disabled.
- Push checks `expectedRemoteHead` against the receive-pack advertisement and
  uses the protocol's old/new hash comparison. Empty expectation asserts an
  absent branch. Existing branches require fast-forward ancestry; branch
  creation requires a root commit. A concurrent change requires fetch and
  reconciliation before retry.
- A push timeout or cancellation can occur after the server accepted a commit.
  Fetch the remote head before deciding whether to retry publication.
- Export writes only a newly created candidate and removes that candidate on
  failure. Swift owns three-way merging, canonical Beancount validation, user
  conflict decisions, and atomic workspace publication.

## Resource and path limits

Snapshots accept at most 10,000 entries, depth 32, 64 MiB per file, and 256 MiB
total. Export and commit reject symlinks, submodules, special files, traversal,
Git control-directory aliases, and case/Unicode-normalized sibling collisions.
Cache and snapshot directories must be disjoint.

Fetch caps compressed packs at 256 MiB, object count at 100,000, each expanded
object at 64 MiB, aggregate expanded objects at 256 MiB, and cache intake against
a 512 MiB existing-cache budget. HTTP metadata responses are capped at 8 MiB.
Incoming packs are staged privately, checked against declared and actual
inflated byte counts before object parsing, and
removed after parsing. Failed fetches may retain unreferenced objects; remote
tracking refs advance only after a successful fetch. Full object history is
retained; cache cleanup belongs to the provider lifecycle.

Run `go test ./mobilegit` for two-replica, in-process bare-remote sync and safety
tests. Fixtures use only synthetic temporary ledgers and an embedded test
transport. `go test -race ./mobilegit` checks the concurrent bridge registry.
