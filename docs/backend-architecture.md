# Backend architecture

The Go backend is a modularizing monolith with an explicit application
lifecycle, a Gin HTTP layer, request schemas, and domain-oriented services. Most
code still lives under `server/internal/app`; the composition root now separates
resource wiring from route construction so later package extraction can proceed
without changing the process entry point.

## Runtime flow

```text
cmd/ledger-web
  -> LoadWebConfig
  -> NewApplication
      -> buildApplicationDependencies
          -> runtime store / database / rate limiter
          -> ledger cache / read service / writer
          -> account / transaction / reconciliation services
      -> newRouter
          -> Server handlers
  -> http.Server
      -> graceful shutdown
      -> Application.Close
```

## Composition and lifecycle

- `application.go` owns the transitional composition root. `NewApplication`
  creates infrastructure and services explicitly, exposes an `http.Handler`,
  and records every opened resource.
- `Application.Close` closes resources once in reverse construction order and
  joins close errors so one failure does not skip later cleanup.
- `cmd/ledger-web` owns the `http.Server`. `SIGINT` and `SIGTERM` trigger a
  bounded graceful shutdown before application resources are closed.
- Process entry points construct `Application` directly so resource ownership
  remains explicit. Tests use a helper that registers `Application.Close` with
  `testing.T.Cleanup`.

## HTTP layer

- `application.go` constructs the current service graph and owns its resources.
- `server.go` owns the transitional `Server`, Gin setup, route registration,
  health, and static fallback selection.
- `*_handlers.go` files own route handlers by API area: auth, ledger, imports,
  and AI.
- `util.go` owns JSON binding and response helpers.
- `schemas.go` owns named request DTOs and semantic validation.

Handlers should stay small: authenticate, bind/validate, call domain logic, and
return the response. New request bodies should be named DTOs in `schemas.go` or
a feature-specific schema file, not anonymous structs inside handlers.

Read services return typed application results instead of Gin maps as each
query is migrated. Bootstrap, summary, transaction, and income statement feeds
use typed results; their handlers own HTTP status and JSON serialization while
the services own range, privacy, and read-model selection. The ledger read
service implementation and interface expose no Gin response types.

`LedgerQueryPort` is the transport-facing application read boundary.
`LedgerSnapshotPort` isolates legacy consumers that still require raw ledger
snapshots, so typed query consumers do not inherit snapshot coupling.

Statically linked extensions implement `Module` and register capabilities with
`ModuleRegistry` during application composition. Modules with background
resources may implement `ModuleLifecycle`; startup follows registration order
and shutdown runs in reverse order. Importers are the first extension point:
the built-in importer module registers `billImporter` implementations with the
application-local `BillImporterRegistry`.
The `web-push` module contributes a notification channel factory and the
`notifications` module depends on it to build the notification service after
runtime storage and the ledger snapshot port are available. That service owns
notification state, channel fan-out, and an optional periodic refresh worker;
its lifecycle closes before the backing stores. Set
`LEDGER_NOTIFICATION_REFRESH_INTERVAL` to a positive Go duration to run the
worker, or leave it at `off` for request-driven refreshes.
`LEDGER_ENABLED_MODULES` accepts a comma-separated allowlist of statically
linked module names. An empty value enables every built-in module; an unknown
or duplicate name stops application startup. Modules may declare dependencies;
the registry resolves dependencies before dependents and rejects cycles.

## Domain and infrastructure files

- `server/internal/ledger` owns infrastructure-free ledger value types. The
  first extracted values are exact Beancount amounts and metadata values. Its
  architecture test recursively scans the package tree and permits only an
  explicit set of pure standard-library dependencies.
- `server/internal/app/domain_models.go` provides temporary type aliases so the
  existing application keeps its current contract while code moves package by
  package.
- `ledger.go`, `cache.go`, `writer.go`, and `money.go` continue to parse, cache,
  render, and validate ledger writes.
- `analytics.go`, `diagnostics.go`, and `notifications.go` are read-model and
  notification logic.
- `imports.go`, `import_parsing.go`, and `cmb_pdf.go` own import preview,
  commit, provider parsing, and CMB PDF helpers.
- `ai.go`, `github_ledger.go`, `auth.go`, `passkeys.go`, `push.go`, and
  `rate_limit.go` own external integrations and support services.

The next extraction step separates transport DTOs from canonical transactions
and accounts before moving those entities into the ledger package. Feature
modules can then depend on consumer-owned ports while filesystem, GitHub,
Postgres, AI, and Web Push become adapters wired only by the composition root.

## Validation

`bindJSON` calls `Validate()` automatically for request types that implement it.
The validation layer covers:

- Required fields for auth, AI, imports, Git, and ledger mutations.
- `YYYY-MM-DD` dates with real calendar parsing.
- Beancount account names rooted at `Assets`, `Liabilities`, `Equity`, `Income`,
  or `Expenses`.
- Decimal amounts with at most two places.
- Mutation currencies must be valid Beancount commodity tokens; write paths also
  validate them against the ledger commodities when the current snapshot is
  available.
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
