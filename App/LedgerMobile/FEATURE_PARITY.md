# iOS and mobile web feature parity

The mobile web routes in `web/src/components/AppShell.tsx` and the Go routes in
`server/internal/app/server.go` are the source of truth. Native screens keep the
same data meaning and use iOS navigation, controls, accessibility, and privacy
behavior.

| Product area | Web API surface | Native status | Access | Priority |
| --- | --- | --- | --- | --- |
| Home | `GET /api/ledger/home-report`, bootstrap | Available as Overview, metric coverage is partial | Read | P0 |
| Transactions | bootstrap, `GET /api/ledger/transactions`, `PUT /api/ledger/transactions`, `POST /api/ledger/transactions/tags` | List, search, type/account/tag filters, detail, source-safe editing, cross-filter selection, atomic bulk tagging | Read and validated write | P0 |
| Accounts | bootstrap, `GET /api/ledger/accounts/detail` | Grouped balances, detail, related transactions | Read | P0 |
| Settings and privacy | auth, passkey, quick unlock | Face ID/Touch ID, lock interval, sessions, and device-local compact tab customization; passkey implementation requires paid-team signing | Device/auth | P0 |
| Home Screen widgets | `GET /api/ledger/home-report`, bootstrap, `GET /api/ledger/imports/documents` | Monthly expense overview, expense calendar, configurable asset/liability balance, and import-status widgets | Read-only snapshot | P0 |
| Assets | bootstrap balance and net-worth data | Web-aligned asset/liability positions, net-worth windows and trend | Read | P1 |
| Income statement | `GET /api/ledger/income-statement` | Web-aligned period totals, category analysis, payee and payment-account ranks | Read | P1 |
| Investments | `GET /api/ledger/investments` | Market value, realized P&L, holding cost and return | Read | P1 |
| Agent | `POST /api/ai/agent/turn`, session timeline | Planned | Read and write tools | P2 |
| Query | `POST /api/ledger/bql`, BQL history | Multi-statement editor, examples, table/chart results, warnings, history rename/run/delete | Read plus runtime history | P2 |
| Currencies | bootstrap commodities, prices, balances and valuation data | Current, inverse and CNY-cross rates, 90-point trends, missing-rate warnings, persistent valuation currency | Read | P2 |
| Imports | `GET /api/ledger/imports/documents`, `GET /api/ledger/imports/providers`, `POST /api/ledger/imports/preview`, `POST /api/ledger/imports/commit` | Native file selection, provider override, ZIP password, server preview and dedup review, candidate selection, per-entry and bulk tag editing, confirmation, commit result, channel freshness, and archive history | Preview-confirmed write | P3 |
| Reconcile | `GET/POST /api/ledger/reconciliation` | Planned after read-only parity | Write with preview | P3 |
| Ledger editor | `/api/ledger/editor/*` | Planned last | Write | P3 |
| Add, reverse, delete transaction | `/api/ledger/append*`, `/api/ledger/transactions` | Planned | Write with confirmation | P3 |

Navigation parity:

- iPhone defaults to Overview, Transactions, Accounts, and More. Users can select and reorder up to four primary destinations; More remains fixed.
- iPad uses `NavigationSplitView`; destinations move into the sidebar as each
  native screen becomes functional. Compact tab customization does not change
  the iPad sidebar.
- BQL is available from iPhone More and as a first-class iPad sidebar
  destination. Money result columns follow the global privacy toggle.
- Currencies is available from iPhone More and the iPad sidebar. Valuation
  currency changes reload the current ledger range and persist per server origin.
- Imports are available from iPhone More and the iPad sidebar. The native flow
  selects files through Files, delegates parsing and validation to the server,
  lets the user exclude candidate transactions, confirms the write, and refreshes
  channel freshness and archived bill metadata after completion.
- Write features retain the web app's preview, validation, confirmation, and
  rollback boundaries.
