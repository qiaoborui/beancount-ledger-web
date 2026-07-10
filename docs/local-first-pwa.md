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
- Ledger snapshots are stored in IndexedDB after a successful unlocked load.
- New manual entries and balance assertions can be saved while offline.
- Transaction edits and deletes are queued locally and projected into the cached
  transaction list.
- When the browser is online again, the app retries the queue against the local
  Go server.

The browser is not the source of truth. Every queued write still goes through the
Go API and GitHub API ledger writer. The scheduled indexer validates and parses
the ledger checkout before publishing a new Postgres read-model revision.

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
3. Unlock sensitive data if you want cached balance and net-worth views.
4. Install the PWA from the browser.
5. Go offline and confirm the app shell and cached ledger load.
6. Create a manual entry offline and confirm the pending sync badge appears.
7. Reconnect and confirm the entry syncs through the server.
8. For edits/deletes, change the ledger from another device before reconnecting
   and confirm the stale operation stays queued for review.
