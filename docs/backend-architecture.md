# Backend architecture

The Go backend is organized around a thin HTTP layer, explicit request schemas,
and domain-oriented services. It still lives under `server/internal/app` today,
but files are split by responsibility so future package extraction is mechanical.

## Runtime flow

```text
cmd/ledger-web
  -> LoadConfig
  -> StartLedgerScheduler
  -> NewRouter
      -> handlers
          -> ledger cache/writer
          -> analytics/imports/ai/git/passkey/push services
```

## HTTP layer

- `server.go` owns `Server`, Gin setup, route registration, health, and static
  fallback selection.
- `*_handlers.go` files own route handlers by API area: auth, ledger, imports,
  AI, and Git.
- `util.go` owns JSON binding and response helpers.
- `schemas.go` owns named request DTOs and semantic validation.

Handlers should stay small: authenticate, bind/validate, call domain logic, and
return the response. New request bodies should be named DTOs in `schemas.go` or
a feature-specific schema file, not anonymous structs inside handlers.

## Domain and infrastructure files

- `ledger.go`, `cache.go`, `writer.go`, and `money.go` parse, cache, render, and
  validate ledger writes.
- `analytics.go`, `diagnostics.go`, and `notifications.go` are read-model and
  notification logic.
- `imports.go`, `import_parsing.go`, and `cmb_pdf.go` own import preview,
  commit, provider parsing, and CMB PDF helpers.
- `ai.go`, `git.go`, `auth.go`, `passkeys.go`, `push.go`, `scheduler.go`, and
  `rate_limit.go` own external integrations and support services.

## Validation

`bindJSON` calls `Validate()` automatically for request types that implement it.
The validation layer covers:

- Required fields for auth, AI, imports, Git, and ledger mutations.
- `YYYY-MM-DD` dates with real calendar parsing.
- Beancount account names rooted at `Assets`, `Liabilities`, `Equity`, `Income`,
  or `Expenses`.
- Decimal amounts with at most two places.
- CNY-only mutation currency, matching the frontend Zod schemas.
- Transaction posting count, metadata keys, tags, confidence, and source identity.

Frontend Zod schemas remain useful for client UX, but the Go schemas are the
authority for API writes.

## Tests

Tests are split by responsibility:

- `test_helpers_test.go` provides fixture ledgers and HTTP helpers.
- `ledger_storage_test.go` covers parser/cache/writer behavior.
- `http_routes_test.go` covers route inventory and smoke behavior.
- `ledger_handlers_test.go`, `ai_test.go`, `imports_test.go`, and
  `services_test.go` cover feature-specific behavior.
- `schemas_test.go` covers request validation.

Keep broad router smoke tests light. Prefer focused tests beside the feature
when adding business logic.
