---
version: 1
slug: "web-src-components-ledger-homepage-tsx"
primary_target: "web/src/components/ledger/HomePage.tsx"
related_targets:
  - "web/src/components/ledger/HomeReportCharts.tsx"
  - "server/internal/app/home_report.go"
---

# Surface Brief: Financial Brief Home

## Mode

Operate

## Purpose

Turn the selected period into one continuous financial brief: first judge the result, then locate spending drivers, then inspect the accounts carrying the movement.

## Information Order

1. Period status: net income, expense, income, transaction count, and budget availability.
2. Cash-flow evidence: period and cumulative trends, followed by same-period year-over-year comparison.
3. Spending drivers: category distribution, ranking, selected-category comparison, and expense calendar heatmap.
4. Funds control: primary payment accounts and selected account balance movement.

## Data Contract

- `GET /api/ledger/home-report` supplies current and previous-year period summaries from one ledger snapshot.
- Sensitive report data loads only after the existing unlock path succeeds.
- The selected global time range controls the report; the root route defaults to the current calendar year.

## Interaction

- Privacy control hides every sensitive amount and chart consistently.
- Comparison mode switches among income, expense, and net income.
- Category ranking drills into the existing transaction route.
- Category and account selectors update their attached trend charts without opening overlays.

## Responsive Behavior

- Desktop keeps paired charts and five-column metric rails.
- Tablet stacks paired workfields while preserving shared borders.
- Mobile turns each chapter into a linear sequence and allows horizontal heatmap scrolling without shrinking touch targets.

## Constraints

- No detached KPI cards, decorative category palette, persistent shadows, or oversized empty chart regions.
- Section numbers are functional report chapters rather than decorative eyebrows.
- Empty, loading, locked, and failed states remain compact and actionable.
