# Privacy model

This app is designed so application code and financial data live separately.

## Recommended setup

- Public application repository: this project.
- Private ledger repository: your real Beancount files.
- Postgres database: app runtime state, passkeys, notifications, web push subscriptions, locks, import preview blobs, and the ledger read model.

Do not commit your real ledger, `.env` files, database dumps, or migration exports to the application repository.

## Data sent to AI providers

If AI parsing is enabled, the server sends the user's input and the active account names to the configured AI provider. The provider does not need direct access to your ledger files, but account names and transaction text may still be sensitive.

Disable AI by not configuring provider API keys.

## Runtime state

The stateless `ledger-web` service stores runtime state in Postgres:

- passkeys
- notifications
- web push subscriptions
- distributed locks and rate-limit buckets
- import preview metadata and uploaded files

Older filesystem runtime directories can be migrated with `ledger-state-migrate`.
