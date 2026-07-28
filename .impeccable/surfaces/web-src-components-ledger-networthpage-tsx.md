---
version: 1
slug: "web-src-components-ledger-networthpage-tsx"
primary_target: "web/src/components/ledger/NetWorthPage.tsx"
---

# Surface Brief: Assets and Liabilities

## Mode

Operate

## Purpose

Present a compact balance-sheet view of what the user owns, owes, and how net worth changes without mixing in income-statement analysis.

## Information Order

1. Current position: total assets, total liabilities, net worth, and debt ratio.
2. Change windows: current period, six months, twelve months, and top-account concentration.
3. Asset structure by purpose and by account concentration.
4. One canonical chart for assets, liabilities, and net worth with daily and month-end modes.

## Interaction

- Privacy control hides amounts, ratios, change percentages, and charts consistently.
- Daily and month-end modes share one chart rather than creating separate trend panels.
- Account labels remain recognizable while values are hidden.

## Responsive Behavior

- Desktop pairs asset-purpose structure with account concentration.
- Mobile stacks position, structure, and movement with horizontal numeric stability.
- Chart heights remain bounded and do not stretch to fill empty space.

## Exclusions

- No income, expense, savings-rate, investment-income, category, merchant, or transaction-behavior metrics.
- No separate liability trend duplicating the canonical wealth chart.
- No card grid, serif display headings, decorative allocation colors, or persistent shadows.
