---
version: 1
slug: "web-src-components-ledger-homepage-tsx"
primary_target: "web/src/components/ledger/HomePage.tsx"
related_targets: []
---

# Surface Brief: Financial Control Room Home

## Mode

Operate

## Purpose

Answer three questions in the first desktop viewport: What is the current period position, what changed over time, and what requires inspection. Transactions remain available after the first screen as evidence, not as the opening content.

## First Viewport

- The compact command row provides page context, sync/privacy state, and time controls without a duplicate global header.
- A five-cell position strip carries net result, income, expense, daily pace, and recent seven-day movement.
- The main working field uses two adjacent monochrome charts: daily rhythm and cumulative position.
- A right inspection bench summarizes the largest spend day, top category, weekly change, and top category ledger rows.
- Recent transactions start below the opening workfield.

## Information Order

1. Net position and period context.
2. Income-versus-expense relationship and spending pace.
3. Daily and cumulative trend evidence.
4. Inspection bench for anomalies and category concentration.
5. Transaction evidence after scroll.

## Interaction

- Privacy control changes sensitive values consistently.
- Category rows drill into the existing transaction route.
- Desktop rows remain table-like and keyboard focusable.
- The inspection bench is structurally attached to the chart workfield.

## Responsive Behavior

- Desktop: navigation rail, position strip, dual chart workfield, right inspection bench.
- Tablet: charts and inspection bench stack while preserving compact rows.
- Mobile: metrics, charts, inspection, and transaction evidence become sequential touch-sized sections.

## Exclusions

- No KPI card grid.
- No decorative category colors.
- No duplicate desktop top bar.
- No recent transaction table in the first home viewport.
