# Beancount Ledger Web App

This is the Next.js application for Beancount Ledger Web.

For project overview and self-hosting instructions, see the root [README.md](../README.md) and [docs/self-hosting.md](../docs/self-hosting.md).

## Local development

```bash
npm install
cp .env.example .env.local
npm run dev
```

The app defaults to the example ledger at `../examples/minimal-ledger` when `LEDGER_ROOT` is not configured.

To use a private ledger repository:

```bash
LEDGER_ROOT=/absolute/path/to/private-ledger
RUNTIME_DIR=/absolute/path/to/runtime-dir
```

## Scripts

```bash
npm run typecheck
npm run build
npm run start
```
