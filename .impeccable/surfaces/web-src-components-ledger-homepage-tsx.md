---
version: 1
slug: "web-src-components-ledger-homepage-tsx"
primary_target: "web/src/components/ledger/HomePage.tsx"
related_targets:
  - "web/src/components/ledger/HomeReportCharts.tsx"
  - "server/internal/app/home_report.go"
---

# Surface Brief: Financial Overview Home

## Mode

Operate

## Purpose

Help the user judge the selected period in seconds, identify what deserves attention, and move to the correct specialist workspace without turning Home into another analytics dashboard.

## Information Order

1. Current-period result: net income, expense, income, transaction count, and budget state.
2. One canonical same-period comparison trajectory with income, expense, and net-income modes.
3. Prioritized review signals for budget, category concentration, payment concentration, and record activity.
4. Explicit handoffs to Income and Spending Analysis, Assets and Liabilities, and the Transaction Ledger.

## Interaction

- Privacy control hides every amount, ratio, comparison, chart, and tooltip consistently.
- The comparison switch changes the single trajectory rather than adding more charts.
- Review signals and destination rows route to the workspace that owns the question.

## Responsive Behavior

- Desktop pairs the trajectory with the review queue.
- Tablet and mobile stack the chart, signals, and destinations in decision order.
- Amount rails preserve fixed numeric anchors and never truncate values.

## Exclusions

- No category distribution, category trend, calendar heatmap, payment-account chart, account-balance chart, or net-worth chart on Home.
- No detached KPI cards, decorative category palette, persistent shadows, or oversized empty chart regions.
- Home summarizes and routes; it does not become the place for full diagnosis.
