# Privacy model

This app is designed so application code and financial data live separately.

## Recommended setup

- Public application repository: this project.
- Private ledger repository: your real Beancount files.
- Postgres database: app runtime state, passkeys, notifications, web push subscriptions, locks, import preview blobs, and the ledger read model.

Do not commit your real ledger, `.env` files, database dumps, or migration exports to the application repository.

## Data sent to AI providers

If AI parsing is enabled, the server sends the user's input and the active account names to the configured AI provider. When BQL query history is enabled, the server sends the successful BQL text to generate its title. BQL result rows, chart data, and ledger files stay on the application server. Account names, transaction text, and BQL text may still be sensitive.

Disable AI by not configuring provider API keys.

## AI financial advice (/advice)

The on-demand financial review is a privacy-preserving utility page:

- Generation is explicit: opening or navigating to `/advice` never contacts the provider. Only pressing Generate calls the API, and only after the sensitive-data unlock succeeds.
- The server computes all evidence from the ledger first. The provider receives only the canonical review scope and de-identified structured evidence: opaque evidence IDs, typed kinds, directions, ratios, counts, and major-unit decimal aggregates. Exact period dates and anomaly transaction dates or amounts stay on the application server. The provider never receives account names, aliases, payees, narrations, tags, metadata, source file paths, hashes, or any raw ledger or transaction text. Request fields are strictly validated and canonicalized before anything is built or sent.
- The model cannot supply user-visible prose. It returns only closed topic and claim enums plus opaque evidence citations; the server rejects unknown fields, validates every citation and direction, then renders titles and neutral body copy from application-owned templates. Exact displayed facts always come from server evidence.
- Nothing about the review is durably stored: no advice history, responses, or evidence are written to Postgres, browser storage (localStorage, IndexedDB, service-worker caches), runtime stores, notification history, or Agent session history. Results live only in component memory and are cleared on lock, scope or mode change, or navigation away.
- Responses are `no-store`, generation has a dedicated rate limit, and the provider call has a 45-second deadline. Logs contain only the operation name, mode, safe counts, result code, and elapsed time.
- The page discloses that the review structure is model-selected, shows the configured provider and model name only after a validated model result (never base URLs or credentials), displays cited evidence directly under every claim, and provides transaction drill-down links where the evidence supports one.

Rollback is removal of the route, page, nav item, endpoint, and this documentation; the feature stores no state and requires no data migration.

## Runtime state

The stateless `ledger-web` service stores runtime state in Postgres:

- passkeys
- notifications
- web push subscriptions
- distributed locks and rate-limit buckets
- import preview metadata and uploaded files
- encrypted Gmail refresh token, mailbox history cursor, and pending bill-import metadata
- saved BQL query text, generated or manually edited titles, and usage timestamps

Gmail message bodies and attachments are read only for messages carrying the configured bill Label and matching the exact sender allowlist. Raw EML and import files remain in the runtime store while they await Review; committed source documents are archived in the private ledger repository through the existing import flow.

Older filesystem runtime directories can be migrated with `ledger-state-migrate`.
