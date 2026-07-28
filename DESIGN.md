---
name: Beancount Ledger Web
description: A restrained financial control room with cool light workspaces, dark console surfaces, and a single cobalt functional accent.
colors:
  light-canvas: "oklch(96.5% 0.008 255)"
  light-panel: "oklch(99.5% 0.003 255)"
  cobalt-action: "oklch(43% 0.16 255)"
  control-black: "oklch(10.5% 0 0)"
  console-black: "oklch(13.5% 0 0)"
  panel-charcoal: "oklch(16.5% 0 0)"
  rail-charcoal: "oklch(12% 0 0)"
  divider-steel: "oklch(27% 0 0)"
  primary-text: "oklch(92% 0 0)"
  secondary-text: "oklch(62% 0 0)"
  risk-red: "oklch(70% 0.15 29)"
typography:
  headline:
    fontFamily: "Manrope, Noto Sans SC, PingFang SC, sans-serif"
    fontSize: "24px"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "-0.02em"
  title:
    fontFamily: "Manrope, Noto Sans SC, PingFang SC, sans-serif"
    fontSize: "15px"
    fontWeight: 600
    lineHeight: 1.35
    letterSpacing: "-0.015em"
  body:
    fontFamily: "Manrope, Noto Sans SC, PingFang SC, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "Manrope, Noto Sans SC, PingFang SC, sans-serif"
    fontSize: "11px"
    fontWeight: 600
    lineHeight: 1.35
rounded:
  xs: "4px"
  sm: "6px"
  md: "12px"
  lg: "16px"
  pill: "999px"
spacing:
  1: "4px"
  2: "8px"
  3: "12px"
  4: "16px"
  5: "20px"
---

# Design System: Beancount Ledger Web

## Overview

**Creative North Star: "The Financial Control Room"**

Beancount Ledger Web is a private financial operations console rather than a generic analytics dashboard. The interface turns an auditable text ledger into a precise working surface across both themes: stable columns, explicit states, dense tables, compact controls, and direct movement from financial position to supporting evidence.

The visual language is contemporary and quiet. Light mode uses a cool off-white canvas, near-white working panels, dark ink typography, and one deep cobalt functional accent. Dark mode keeps its near-black console character. Desktop screens prioritize density and horizontal comparison; mobile screens preserve the same hierarchy as focused sequential sections.

**Key Characteristics:**

- Cool off-white canvas and near-white panels in light mode; near-black and charcoal surfaces in dark mode.
- Deep cobalt reserved for navigation, primary actions, selection, links, progress, focus, and the leading chart series.
- Green, amber, and red reserved for success, warning, and destructive or failed states.
- Flat continuous work areas divided by one-pixel rules.
- Tabular figures and persistent numeric alignment.
- Persistent desktop navigation with a central ledger workspace and inspection bench.
- Structural mobile reflow rather than scaled-down desktop composition.

## Colors

The palette is neutral-first rather than achromatic. Value, weight, spacing, and position still carry hierarchy, while a single cobalt accent makes interactive priority and selection immediately legible.

### Primary

- **Cobalt Action** (`cobalt-action`): Primary actions, active navigation, selected rows, links, focus, progress, and the leading chart series in light mode.
- **Primary Text** (`primary-text`): Primary text, amounts, and high-priority information.
- **Control Black** (`control-black`): Dark-mode application background and selected-control grounding.

### Neutral

- **Light Canvas** (`light-canvas`): Light-mode application background, visibly separated from the working surface.
- **Light Panel** (`light-panel`): Light-mode tables, forms, charts, and continuous work areas.
- **Console Black** (`console-black`): Dark-mode main working surface.
- **Panel Charcoal** (`panel-charcoal`): Tool strips, inspection benches, menus, and secondary panels.
- **Rail Charcoal** (`rail-charcoal`): Persistent navigation surface.
- **Divider Steel** (`divider-steel`): One-pixel table, panel, and section rules.
- **Secondary Text** (`secondary-text`): Labels, timestamps, metadata, and supporting explanations.

### Tertiary

- **Semantic Green**: Successful writes, healthy connections, and completed operations.
- **Semantic Amber**: Review warnings, incomplete data, and conditions requiring attention.
- **Risk Red** (`risk-red`): Genuine anomalies, validation failures, destructive actions, and failed operations.

**The Functional Color Rule.** Color must identify interaction priority, selection, a chart series, or a semantic state. Categories and accounts never receive arbitrary decorative colors.

**The Red Means Action Rule.** Every red mark must identify a problem, risk, failure, destructive outcome, or negative alert.

## Typography

**Display Font:** Manrope with Noto Sans SC / PingFang SC fallback

**Body Font:** Manrope with system sans-serif fallback

**Data Voice:** Tabular figures through `font-variant-numeric: tabular-nums`

The hierarchy is compact and fixed. Headings identify working regions rather than acting as marketing display copy, while amounts and dates remain vertically scannable.

### Hierarchy

- **Headline** (600, 24px, 1.2): Rare page-level or modal titles only.
- **Title** (600, 15px, 1.35): Page context, workbench sections, and table regions.
- **Body** (400, 14px, 1.5): Controls, rows, descriptions, and form content.
- **Label** (600, 11px, 1.35): Table heads, metric labels, timestamps, metadata, and counts.

**The No Hero Type Rule.** Authenticated product screens prove value with real data and structure, never oversized display type.

**The Numeric Rail Rule.** Amounts, dates, ratios, and counts use tabular figures and preserve column anchors.

## Layout

Desktop uses a 240px navigation rail, a full-width scrollable workspace, and optional inspection regions attached to the data they explain. The global desktop top bar is removed; page context and time controls occupy a single compact local command row.

The three primary financial surfaces have separate jobs. Home is a short decision brief with current position, one comparison trajectory, prioritized review signals, and explicit handoffs. Dashboard is a filter-driven income and spending analysis workspace for rhythm, categories, payees, payment sources, and anomalous transactions; it never repeats asset or net-worth analysis. Net worth is a balance-sheet workspace for current assets, liabilities, concentration, allocation, and one canonical wealth trend. All three use full-width workfields and shared rules rather than detached cards. Transaction rows preserve fixed date, description, amount, account, and metadata columns.

At widths below 768px, the desktop rail becomes a mobile header and configurable bottom navigation. Horizontal workbench regions stack into ordered sections, while controls retain touch-sized targets.

## Elevation & Depth

Persistent content is flat. Hierarchy comes from tonal bands, one-pixel rules, sticky regions, and grid alignment. The only substantial shadow is the overlay shadow (`0 18px 48px oklch(20% 0.012 255 / 0.16)`) used for sheets, dialogs, menus, and floating actions.

**The Flat-by-Default Rule.** Do not add shadows to ordinary summaries, charts, tables, filters, or account panels.

## Shapes

Dense workbench controls use 4–6px corners. Larger 12–16px radii are reserved for modal surfaces, mobile sheets, and touch-oriented containers. Pills are limited to compact statuses, filter chips, and count labels. Data regions remain rectangular and share borders with neighboring regions.

## Components

### Navigation Rail

- 240px expanded and 56px collapsed.
- Rail-charcoal background with one-pixel right rule.
- Active items use a quiet charcoal band and a small light state dot.
- Brand, theme, and privacy controls live inside the rail; no desktop global header is added.

### Context Row

- Single-line desktop row containing current page, synchronization state, privacy state, and time controls.
- Uses a bottom rule rather than a card or shadow.
- Mobile wraps status and time controls into separate full-width rows.

### Position Strip

- Five aligned cells with shared borders and tabular figures.
- The primary balance is larger but never becomes a hero card.
- Negative or anomalous values may use risk red; normal movement remains black or gray.

### Workbench Panel

- Header and body share one rectangular grid cell.
- Adjacent panels share dividers and avoid independent outer radii.
- Charts, rankings, and inspection rows inherit the same column rhythm.

### Transaction Table

- Fixed desktop columns for date, transaction, amount, category/account, and metadata.
- Compact rows use 10px vertical padding and clear hover/selection bands.
- Mobile uses touch-sized summaries and opens detailed editing in a sheet.

### Buttons and Inputs

- Desktop controls are generally 28–36px high with 4–6px corners.
- Primary actions use deep cobalt with white text in light mode and decisive light-on-dark contrast in dark mode.
- Secondary actions use white surfaces, divider borders, and gray hover bands.
- Focus uses a visible inset or external neutral ring; destructive actions use risk red.

## Do / Don't

### Do

- Use rules, alignment, fixed columns, and tonal bands to establish hierarchy.
- Keep the first desktop viewport dense enough for position, trend, anomalies, and supporting evidence.
- Keep privacy and lock state explicit without revealing sensitive values.
- Preserve mobile touch targets while structurally stacking desktop workbench regions.
- Use red only when the user should investigate or take care.

### Don't

- Don't use brown, bronze, bone, or a different decorative color for every category or account.
- Don't construct pages from repeated rounded KPI cards.
- Don't add a duplicate desktop top bar or repeated English eyebrow labels.
- Don't simulate CRT terminals, scanlines, phosphor glow, or hacker aesthetics.
- Don't use shadows on persistent data surfaces.
- Don't use red for ordinary expense values or neutral financial movement.
