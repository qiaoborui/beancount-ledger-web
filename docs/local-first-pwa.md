# Local-first PWA deployment

Beancount Ledger Web is designed to run best as a local-first app: the Go server
stays close to the private ledger, and the browser installs the React client as
a PWA for fast launch, cached reads, and offline draft writes.

## Recommended topology

```text
phone / laptop PWA
  -> local HTTPS origin
  -> ledger-web Go server
  -> LEDGER_ROOT private Beancount repo
  -> RUNTIME_DIR passkeys, notifications, locks
```

Use Vercel for pull-request previews or hosted experiments when useful, but keep
the personal production ledger behind a self-hosted `ledger-web` server. This
avoids tying day-to-day ledger access to serverless quotas while preserving the
existing Beancount validation and rollback behavior.

## What works offline

- The PWA app shell, manifest, icons, and visited static assets are cached by the
  service worker.
- Ledger snapshots are stored in IndexedDB after a successful unlocked load.
- New manual entries and balance assertions can be saved while offline.
- Transaction edits and deletes are queued locally and projected into the cached
  transaction list.
- When the browser is online again, the app retries the queue against the local
  Go server.

The browser is not the source of truth. Every queued write still goes through the
Go API, `LedgerWriter`, `bean-check`, rollback handling, and optional Git sync.

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

## HTTPS and passkeys

Passkeys require a stable web origin. For phone installs, serve the local Go app
through HTTPS on a stable hostname, reverse proxy, or tunnel that you intend to
keep. If the browser-facing origin changes, configure `PUBLIC_ORIGIN`,
`WEBAUTHN_PUBLIC_ORIGIN`, and `WEBAUTHN_RP_ID` deliberately so existing passkeys
continue to match the registration domain.

## Validation checklist

1. Start `ledger-web` with `LEDGER_ROOT` pointing outside this repository and
   `RUNTIME_DIR` pointing to private runtime storage.
2. Open the app once while online and sign in.
3. Unlock sensitive data if you want cached balance and net-worth views.
4. Install the PWA from the browser.
5. Go offline and confirm the app shell and cached ledger load.
6. Create a manual entry offline and confirm the pending sync badge appears.
7. Reconnect and confirm the entry syncs through the server.
8. For edits/deletes, change the ledger from another device before reconnecting
   and confirm the stale operation stays queued for review.
