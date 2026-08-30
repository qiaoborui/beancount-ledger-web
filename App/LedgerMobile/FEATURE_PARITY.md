# iOS and mobile web feature parity

The mobile web routes in `web/src/components/AppShell.tsx` and the Go routes in
`server/internal/app/server.go` are the source of truth. Native screens keep the
same data meaning and use iOS navigation, controls, accessibility, and privacy
behavior.

| Product area | Web API surface | Native status | Access | Priority |
| --- | --- | --- | --- | --- |
| Home | `GET /api/ledger/home-report`, bootstrap | Available as Overview, metric coverage is partial | Read | P0 |
| Transactions | bootstrap, `GET /api/ledger/transactions` | List, search, type/account filters, detail | Read | P0 |
| Accounts | bootstrap, `GET /api/ledger/accounts/detail` | Grouped balances, detail, related transactions | Read | P0 |
| Settings and privacy | auth, passkey, quick unlock | Passkey login, Face ID/Touch ID, lock interval, sessions | Device/auth | P0 |
| Dashboard | `GET /api/ledger/dashboard` | KPIs, cashflow trend, spending rank, anomalies | Read | P1 |
| Net worth | dashboard balance history data | Position metrics, trend, recent observations | Read | P1 |
| Income statement | `GET /api/ledger/income-statement` | Period totals and hierarchical income/expense rows | Read | P1 |
| Investments | `GET /api/ledger/investments` | Market value, realized P&L, holding cost and return | Read | P1 |
| Agent | `POST /api/ai/agent/turn`, session timeline | Planned | Read and write tools | P2 |
| Query | `POST /api/ledger/bql`, BQL history | Planned | Read | P2 |
| Currencies | bootstrap balances and valuation data | Planned | Read | P2 |
| Imports | `/api/ledger/imports/*` | Planned after read-only parity | Write with preview | P3 |
| Reconcile | `GET/POST /api/ledger/reconciliation` | Planned after read-only parity | Write with preview | P3 |
| Ledger editor | `/api/ledger/editor/*` | Planned last | Write | P3 |
| Add, edit, reverse, delete transaction | `/api/ledger/append*`, `/api/ledger/transactions` | Planned after read-only parity | Write with confirmation | P3 |

Navigation parity:

- iPhone uses Overview, Transactions, Accounts, and More as the stable shell.
- iPad uses `NavigationSplitView`; destinations move into the sidebar as each
  native screen becomes functional.
- Write features retain the web app's preview, validation, confirmation, and
  rollback boundaries.
