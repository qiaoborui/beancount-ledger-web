# Complete self-hosted Compose handoff

## Product decision

Deliver a fully user-operated deployment. The user owns the Beancount files,
Postgres database, credentials, indexer, network exposure, and backups. The
deployment works without a public endpoint and without a GitHub Action.

The intended runtime is:

```text
browser -> Caddy -> frontend + self-hosted API
                         -> user-owned Postgres
                         -> local ledger bind mount
                         -> local recurring indexer
```

## Current branch state

This branch contains an implementation draft for that runtime:

- `server/cmd/ledger-selfhost/` adds a dedicated API executable.
- `LoadSelfHostedConfig` selects filesystem ledger storage plus a strict
  Postgres read model and validates `LEDGER_ROOT`, database, and credentials.
- `docker/docker-compose.selfhost.yml` starts Postgres, API, indexer, frontend,
  and Caddy. The indexer loops inside Compose at
  `LEDGER_INDEX_INTERVAL_SECONDS`.
- `docker/Dockerfile` provides a `selfhost-server` target with `bean-check`.
- `.env.selfhost.example` and `docs/self-hosted-compose.md` document the
  operator path.
- CI parses the Compose file with representative required environment values.

## Verified on this branch

- `go test ./...` from `server/`: 269 tests passed in 34 packages.
- `go build ./cmd/...` from `server/`: passed.
- `pnpm run typecheck`, `pnpm run test`, and `pnpm run build` from `web/`:
  passed after installing the lockfile dependencies.
- `docker compose --env-file .env.selfhost.example -f docker/docker-compose.selfhost.yml config --quiet` with representative secrets: passed.

The local Docker daemon was unavailable during this work. Image construction
and runtime smoke tests remain outstanding. This branch is an implementation
draft rather than a release-ready deployment profile.

## Required follow-through

1. Start Docker, create a disposable example ledger, and run the documented
   Compose command end to end.
2. Confirm API health becomes ready after the first index pass, then test login,
   ledger reads, a manual write, `bean-check` rollback, restart persistence, and
   index refresh after an out-of-band ledger edit.
3. Decide the operator identity model for the writable ledger bind mount. The
   current self-hosted API image inherits the indexer image user and needs an
   explicit non-root or configurable UID/GID policy before release.
4. Resolve the security-review finding before release: the current `8080:80`
   mapping publishes plaintext login traffic on every Docker host interface.
   Bind the default mapping to `127.0.0.1`, make LAN exposure explicit, and
   require TLS for LAN access.
5. Add a cross-process ledger lock shared by filesystem writers and the
   indexer. The current writer lock belongs only to the API process, so an index
   pass can publish an intermediate or rolled-back filesystem transaction as
   the strict Postgres read model.
6. Complete the HTTPS operator path. A Caddy-managed certificate needs the
   host's HTTPS port mapping and an end-to-end passkey test.
7. Replace the indexer loop's broad failure suppression with observable retry
   behavior and a health signal suitable for Compose operators.
8. Add a backup and restore smoke test covering the ledger bind mount and the
   `postgres_data` volume.

## Safety boundaries

- Keep all user ledger data outside this public repository.
- Keep manual writes previewed, validated with `bean-check`, and rollback-safe.
- Keep Postgres unexposed on the Docker host network.
- Keep authentication enabled by default. `AUTH_SECRET`, `APP_PASSWORD`, and
  `POSTGRES_PASSWORD` stay in the operator's ignored `.env.selfhost` file.
- Preserve the existing hosted deployment while the self-hosted profile reaches
  release readiness.

## Suggested next-agent prompt

```text
Continue the complete self-hosted Compose work in this repository. Treat
docs/self-hosted-compose-handoff.md as the source of truth for product scope
and validation gaps. Preserve the existing hosted deployment. First inspect the
current branch diff, then run the Compose stack against examples/preview-ledger
with Docker available. Resolve the listed UID/GID, HTTPS, indexer observability,
and backup/restore gaps. Keep all financial writes previewed, bean-check
validated, and rollback-safe. Finish with go test ./..., go build ./cmd/..., web
typecheck/test/build, Compose config validation, Docker image builds, and an
end-to-end Compose smoke test. Commit only the self-hosted deployment changes.
```
