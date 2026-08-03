# Complete self-hosted Compose handoff

## Product decision

Deliver a fully user-operated deployment. The user owns the Beancount files,
Postgres database, credentials, indexer, network exposure, and backups. The
deployment works without a public endpoint and without a GitHub Action.

The intended runtime is:

```text
browser -> Caddy -> frontend + self-hosted API -> GitHub Contents API ledger writes
                         -> user-owned Postgres read model
local recurring indexer -> dedicated Git checkout -> Postgres read model
```

## Current branch state

This branch contains an implementation draft for that runtime:

- `server/cmd/ledger-selfhost/` adds a dedicated API executable.
- `LoadSelfHostedConfig` selects the stateless GitHub API writer plus a strict
  Postgres read model. The API does not receive a ledger bind mount.
- `docker/docker-compose.selfhost.yml` starts Postgres, API, indexer, frontend,
  and Caddy. The indexer loops inside Compose at
  `LEDGER_INDEX_INTERVAL_SECONDS`.
- The indexer is the only service with the local Git checkout. It clones or
  fast-forwards it using a separate read-only GitHub token before indexing.
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
   ledger reads, a manual GitHub API write/import, restart persistence, and
   index refresh after the indexer fetches the committed revision.
3. Confirm the indexer checkout identity model and dirty-worktree failure path.
4. Resolve the security-review finding before release: the current `8080:80`
   mapping publishes plaintext login traffic on every Docker host interface.
   Bind the default mapping to `127.0.0.1`, make LAN exposure explicit, and
   require TLS for LAN access.
5. Preserve the separation: no API container may receive the checkout bind
   mount or an indexer read token. The API uses its write token only through
   the GitHub API; the indexer receives only the read token.
6. Complete the HTTPS operator path. A Caddy-managed certificate needs the
   host's HTTPS port mapping and an end-to-end passkey test.
7. Replace the indexer loop's broad failure suppression with observable retry
   behavior and a health signal suitable for Compose operators.
8. Add a backup and restore smoke test covering the ledger bind mount and the
   `postgres_data` volume.

## Safety boundaries

- Keep all user ledger data outside this public repository.
- Keep manual writes previewed and GitHub-transaction protected; the GitHub
  write path continues to validate with `bean-check` before commit.
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
