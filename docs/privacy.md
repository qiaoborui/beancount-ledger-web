# Privacy model

This app is designed so application code and financial data live separately.

## Recommended setup

- Public application repository: this project.
- Private ledger repository: your real Beancount files.
- Runtime directory: passkeys, notifications, web push subscriptions, locks.

Do not commit your real ledger or runtime files to the application repository.

## Data sent to AI providers

If AI parsing is enabled, the server sends the user's input and the active account names to the configured AI provider. The provider does not need direct access to your ledger files, but account names and transaction text may still be sensitive.

Disable AI by not configuring provider API keys.

## Runtime state

The following files should be treated as private runtime state:

- `passkeys.json`
- `notifications.json`
- `webpush-subscriptions.json`
- `ledger-write.lock`

Set `RUNTIME_DIR` to a directory outside the application repository in production.
