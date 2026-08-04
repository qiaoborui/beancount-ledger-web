# Beancount Ledger Web

A private web app for a personal [Beancount](https://beancount.github.io/) ledger.

It keeps your real ledger outside this repository and gives you a browser UI
for browsing, reviewing, and safely updating it.

## What it does

- Browse accounts, transactions, balances, budgets, and reports
- Draft transactions from natural language, then preview before writing
- Validate each ledger write with `bean-check` before its GitHub commit
- Review imports from supported payment statements before committing them
- Use password login, passkeys on secure origins, and optional web push
- Run entirely on your own Docker host, or use the hosted GitHub-backed setup

## Self-hosted Compose

The complete self-hosted stack includes Postgres, API, indexer, frontend, and
Caddy. Your private GitHub ledger remains the source of truth: the API writes
through the GitHub API, while only the indexer has a local checkout for
publishing the Postgres read model.

```bash
cp .env.selfhost.example .env.selfhost
# Set the checkout path, UID/GID, Postgres password, AUTH_SECRET,
# and the internal indexer identity token.
docker compose --env-file .env.selfhost -f docker/docker-compose.selfhost.yml up -d --build
```

Read the one-time installation code from `docker compose ... logs server`,
then open the browser installer to configure the private GitHub repository,
separate write/read tokens, administrator password, AI, and indexer timing.
The default browser endpoint is `http://127.0.0.1:8080`. See the
[self-hosted guide](docs/self-hosted-compose.md) for LAN TLS, backups,
restores, image updates, and the full configuration reference.

## Development

```bash
cd server && go test ./... && go build ./cmd/...
cd web && pnpm install && pnpm run typecheck && pnpm run test && pnpm run build
```

Use the ledgers in `examples/` for local development and tests. Keep your real
ledger, secrets, imports, and runtime data outside this repository.

## Documentation

- [Self-hosted Compose](docs/self-hosted-compose.md)
- [Hosted Google Cloud deployment](docs/google-cloud-run.md)
- [Local-first PWA](docs/local-first-pwa.md)
- [Ledger layout](docs/ledger-layout.md)
- [Privacy](docs/privacy.md)
- [Backend architecture](docs/backend-architecture.md)

## License

[MIT](LICENSE)
