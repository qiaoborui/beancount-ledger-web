# Local-first PWA deployment

Beancount Ledger Web is designed to run best as a local-first app: the Go server
stays close to the private ledger, and the browser installs the React client as
a PWA for fast launch, cached reads, and offline draft writes.

## Recommended topology

```text
phone / laptop PWA
  -> HTTPS origin
  -> ledger-web Go server
  -> Postgres read model + runtime state
  -> GitHub API private Beancount repo writes
  -> scheduled ledger-indexer job
```

`ledger-web` itself is stateless: it does not keep a local ledger checkout or a
runtime directory. The private Beancount repository remains the source of truth,
Postgres stores app runtime state and the active read model, and a separately
scheduled `ledger-indexer` job refreshes Postgres from an existing local checkout
or mounted ledger copy.

## What works offline

- The PWA app shell, manifest, icons, and visited static assets are cached by the
  service worker.
- Privacy-masked ledger snapshots are stored in IndexedDB after a successful
  load. Balances, net worth, income, and other sensitive fields are not stored
  offline.
- New manual entries and balance assertions can be saved while offline.
- Transaction edits and deletes are queued locally and projected into the cached
  transaction list.
- When the browser is online again, the app retries the queue against the local
  Go server.

Every queued write goes through the Go API and GitHub API ledger writer. Before
committing, the writer stages the candidate ledger at its fixed Git revision and
runs `bean-check`. The scheduled indexer validates and parses the committed
ledger before publishing a new Postgres read-model revision.

## Reliable append retries

Each confirmed entry receives a stable operation ID before its first network
request. Single appends send it in `Idempotency-Key`; batches send one ID per
entry in `operationIds`. A batch that loses its response reuses those IDs when
replaying individual entries from the offline queue.

The writer commits a receipt under `.ledger-write-receipts/` in the private ledger
in the same transaction as each appended entry. Receipts contain a content hash,
with hashed operation IDs in their filenames. Repeating the same ID and content
returns success without another append; reusing the ID for different content
returns HTTP 409. Preserve this directory with the ledger, including after
editing or deleting the original entry: these records keep a delayed retry from
recreating an old transaction. GitHub commits keep receipts and entries atomic;
filesystem writes roll both back when validation fails.

Clients that omit operation IDs still work. The server generates IDs for its own
internal commit retry; clients need stable IDs to deduplicate separate HTTP
requests.

## Queue failures

Authentication, lock, conflict, and validation errors pause automatic retries and
keep the operation available for review. Network failures, HTTP 408/429 and server
errors use exponential backoff from one second up to one minute. Manual retry
can resume an operation immediately after the underlying issue is resolved.

The UI closes a queued draft only after browser storage confirms the save. When
storage is unavailable, the draft and the current page's in-memory operation
remain available with a recovery message. Keep that page open until storage is
available or the entry has synced successfully.

## Conflict behavior

Queued appends can be retried after the ledger changes because they create new
entries. Queued edits and deletes record the ledger version they were based on.
If the server ledger version has changed before sync, the operation stays in the
local queue with a conflict status instead of falling back to a file-and-line
write that might overwrite someone else's change.

Resolve a conflict by refreshing the ledger, reviewing the current transaction,
and applying the intended edit again.

## Browser storage

The app uses IndexedDB as the primary browser store for:

- cached ledger snapshots;
- pending ledger operations;
- retry and conflict metadata.

`localStorage` remains a compatibility mirror for older pending writes and small
UI preferences. Do not treat browser storage as a backup of the private ledger.
Pending queues use versioned complete snapshots in both stores. The newest
successful snapshot wins, including an empty queue, so a stale copy left by a
failed store cannot restore a discarded or completed operation. Legacy array
queues migrate when read.
Browsers with Web Locks serialize the whole queue read/modify/write operation
across tabs for the same ledger.

## HTTPS and passkeys

Passkeys require a stable web origin. For phone installs, serve the local Go app
through HTTPS on a stable hostname, reverse proxy, or tunnel that you intend to
keep. If the browser-facing origin changes, configure `PUBLIC_ORIGIN`,
`WEBAUTHN_PUBLIC_ORIGIN`, and `WEBAUTHN_RP_ID` deliberately so existing passkeys
continue to match the registration domain.

## Local and LAN access options

Choose the browser-facing origin based on where you use the app most:

- Single machine: `http://localhost:<port>` is enough for local development, but
  phones cannot use another machine's `localhost`.
- Home LAN: run `ledger-web` on a NAS, Mac mini, or Raspberry Pi and expose it
  through a stable LAN hostname. Add HTTPS before relying on passkeys or web
  push.
- Private mesh: use Tailscale or a similar private network when you want phone
  access away from home without exposing the ledger app publicly.
- Public tunnel: use Cloudflare Tunnel, Caddy with a real domain, or another
  HTTPS reverse proxy when you need a stable public origin. Keep
  `WEBAUTHN_RP_ID` on the long-lived domain so passkeys survive server moves.

Avoid changing the installed PWA origin casually. Browsers scope service worker
cache, IndexedDB, and passkeys to the origin, so moving from `localhost` to a LAN
IP or from one domain to another creates a separate browser app state.

## Validation checklist

1. Start `ledger-web` with `DATABASE_URL` and GitHub repository credentials.
2. Open the app once while online and sign in.
3. Confirm that locking sensitive data hides balances and net-worth views.
4. Install the PWA from the browser.
5. Go offline and confirm the app shell and privacy-masked cached ledger load.
6. Create a manual entry offline and confirm the pending sync badge appears.
7. Reconnect and confirm the entry syncs through the server.
8. For edits/deletes, change the ledger from another device before reconnecting
   and confirm the stale operation stays queued for review.
