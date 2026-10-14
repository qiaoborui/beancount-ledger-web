# Balanced — 结平

A second iOS design language for Beancount Ledger Web, delivered as a local
HTML prototype: [index.html](index.html) plus the rules in
[styles.css](styles.css). It coexists with the terminal design documented in
`docs/design/ios-terminal/README.md`; it does not replace it.

The premise: this is a double-entry ledger, so the interface should be shaped
like the equation rather than decorated like a dashboard. Every place the app
currently reports a balance it instead *shows the arithmetic that produced it* —
rows, a rule, then the total the rows yield. That one decision propagates
through the whole system and is the reason most of the rules below are worded
as prohibitions.

The prototype is a light/dark gallery of 19 frames covering the six core pages
plus overlays and failure states. All amounts are synthetic. All frames are
393 × 852.

---

## Color

Ink is the only chroma in the system except for a single opposed pair. Theme is
carried by the frame's `data-theme` attribute, so both themes are one token set.

| Token | Light | Dark | Role |
| --- | --- | --- | --- |
| `--bg` | `#fbfaf8` | `#121110` | Page ground |
| `--sunken` | `#f1efe9` | `#1b1918` | Wells: settle block, source preview, search field, child rows |
| `--ink` | `#14100c` | `#f6f3ee` | Primary text, rules that end a total, filled buttons |
| `--ink-2` | `#453e36` | `#c4bcb0` | Labels, secondary rows |
| `--ink-3` | `#6f675a` | `#9a9086` | Metadata, headers, hints, shares |
| `--rule` | `#e2ded4` | `#2b2825` | Row separators |
| `--rule-strong` | `#c8c2b4` | `#423c36` | Field underlines, checkbox borders, chevrons |
| `--in` | `#0d5346` | `#4fbfab` | Money in |
| `--out` | `#96401f` | `#cf7a52` | Money out |
| `--press` | `rgba(20,16,12,.05)` | `rgba(246,243,238,.07)` | Pressed state |

Device chrome is theme-independent and sits outside the token set:
`--bezel: #0b0a09`, `--bezel-edge: rgba(255,255,255,.14)`.

**Rationing rules.** These are the constraints that make the palette read as a
design decision rather than a default, and they are the easiest thing to break
when adding a screen:

- `--in` and `--out` mark *direction of value*, never category, never emphasis.
- They appear **only as an opposed pair on the same equation.** A single
  colored amount with no counterpart is a bug: if you cannot name the other
  side of the flow, the amount is ink.
- Nothing else is colored. No category chips, no status colors, no accent for
  links — links are underlined ink (`.link`).
- The one documented exception is the sync indicator's dot, which carries
  repository state and is therefore allowed chroma outside a pair.
- Neutral emphasis is carried by `--ink` weight and by `--sunken` fill. There
  are no shadows, no gradients, and no tinted surfaces anywhere in the system.

### The settle block

The signature device, and the replacement for the "big number + small label"
hero everywhere a balance is reported. A `dl` of equation rows, a heavier rule,
then the total those rows produce.

```
.settle          padding 20/20/18, background --sunken
.settle-head     12.5px, margin-bottom 14
.settle-row      15px, padding 6px 0, dt --ink-2, dd --ink @ 450
.settle-total    10px above, 14px below, border-top 1px --ink
.settle-total dt 13px --ink-3
.settle-total dd 30px / 500 / -0.025em / line-height 1.05
.settle-total dd .cur   0.62em, 450, --ink-3
```

If a screen shows one number with no readable rows above it, that screen is
unfinished, not minimal.

---

## Type

IBM Plex Sans for everything, IBM Plex Mono for exactly two kinds of content.
The family is chosen because it has genuine tabular figures and a Chinese
companion that sits at the same optical weight — not for its associations.

| Role | Size / weight |
| --- | --- |
| Frame total (`.settle-total dd`) | 30 / 500 / -0.025em |
| Metric value (`.metric dd`) | 22 / 500 / -0.02em |
| Retained figure (`.band-head b`) | 21 / 500 / -0.02em |
| App bar title, field value | 17 / 600, 17 / 400 |
| Row primary (`.txn .who`, `.acct .name`, `.row .label`) | 15.5 / 500 |
| Equation row, sheet option | 15 |
| Table body | 14.5 / 400, `.amt` 500 |
| Sheet heading (`.sheet h2`) | 16 / 600 |
| Section head (`.sechead h3`) | 15 / 600 / -0.008em |
| Metadata, hints, captions | 12.5 / 400 `--ink-3` |
| Table header (`.tbl th`) | 12 / 500 `--ink-3` |
| Tab label | 10.5 / 400, letter-spacing 0.02em |
| Account path (`.path`, `.acct .sub`, `.imp .cat`) | 11.5–12 / 400 mono `--ink-3` |

Mono is allowed in exactly two places, for the same reason — these strings are
not prose, they are identifiers that must align and must be copied verbatim:

1. **Beancount account paths.** `Assets:Cash:Daily` is the same token a user
   types into `main.bean`.
2. **The write preview.** `.source` renders the literal text that will be
   appended to a `.bean` file, so it uses `white-space: pre` and mono, and
   `overflow-x: auto` rather than wrapping — a wrapped ledger directive is a
   lie about what will be written.

Amounts are **not** mono. They use `--font-sans` with
`font-variant-numeric: tabular-nums` via `.num`, applied to every numeric
readout in the system. This is the single most visible departure from the
terminal design, which sets amounts in mono.

**Do not** use all-caps labels, numbered `01 /` section heads, tracked-out
eyebrows, or a decorative word accented in color. Section heads are a plain
15px/600 line with an optional right-aligned aside (`.sechead .aside`), and
they name the content, not a sequence — the ledger has no step order.

---

## Geometry

| Element | Size |
| --- | --- |
| Frame | 393 × 852, radius 46 |
| Status bar | 54, padding 0 30 0 36 |
| App bar | min-height 52, padding 4 16 10 |
| Tab bar | 62, four columns |
| Home indicator | 22, 134 × 5 bar at 30% ink |
| Content inset | 20 horizontal, throughout |
| Section head | padding 26 20 10 |
| Settle block | padding 20 20 18 |
| Retained band | padding 18 20 20 |
| Table row | padding 11 20 |
| Transaction row | min-height 56, 12 gap |
| Account row | min-height 52, child indent 34 |
| More row | min-height 52 |
| Sheet | max-height 78%, grabber 38 × 4, 48 option rows |
| Chart hit / disclosure | min-height 44 |

Only four radii exist in the whole system: `46px` (frame), `3px` (home bar),
`2px` (grabber, toolbar button), `0` (everything interactive). Zero radius on
buttons, fields, wells and cells is deliberate — a rounded rectangle reads as a
card, and cards would break the ledger-ruled-page premise.

Hit targets are 44pt minimum even where the visual is smaller: `.iconbtn` is a
44 × 44 transparent box, `.period` is 36 tall inside a 52 minimum bar, and the
`.disclose` and `.seg` controls are 44.

---

## Components worth stating explicitly

**`.band` — the retained figure.** Money out is reported against money kept,
with a 10px two-segment bar: `.kept` in `--ink`, `.spent` in `--out`, 2px gap.
The bar is drawn from real proportions and disappears when amounts are hidden.
It is the only bar chart in the system.

**`.key`** — legend chips. Each chip's swatch takes its tone from
`--c` (`background: var(--c, var(--ink))`), with `.k-in` / `.k-out` shorthands
for the two currency colors.

**`.tbl` — the category table.** Right-aligned `.amt` at 500 weight and a
`.share` column at a fixed 62px, `--ink-3`, tabular. The share column is a
proportion readout, not a bar.

**`.txn` + `.daysep`** — transactions group under a day separator whose rule
(`.daysep::after`) is a flex-grown 1px line so the date sits in a real ruled
row rather than a header. A transfer between accounts is drawn with `.flow`
(mono, `--ink-3`, arrow) rather than colored, because a movement is not a cost.

**`.acct`** — account rows. `.acct.child` is the expansion state: 34px indent,
`--sunken` fill, 14.5/400 `--ink-2`. Nesting is expressed by indent and fill,
never by a disclosure triangle alone.

**`.seg` / `.period` / `.tab[aria-current]`** — three different controls, one
shared selection mark: a 2px `--ink` underline. `.seg button[aria-selected]`
draws it at its own baseline, `.tab[aria-current='page'] .icon::after` draws a
16px version under the glyph, `.period` is a plain underlined label with a
caret. No capsules, no filled pills, no plate behind the current tab.

---

## State and interaction

- **Selection** is `aria-selected`, not a class; **current destination** is
  `aria-current="page"`; **toggles** are `aria-pressed`; **expansion** is
  `aria-expanded`; **disabling** is `aria-disabled`, with `.btn` also honoring
  `:disabled`.
- Disabled is `opacity: 0.38`. There is no separate disabled color token.
- **Focus** is visible and inset — `outline: 2px solid var(--ink);
  outline-offset: -4px` on `.iconbtn`, `.period`, `.seg button`, `.tab`,
  `.disclose`, and `.toolbar button`. Inset because the controls are full-bleed
  to a ruled edge and an outset ring would collide with the row's rule.
- **Motion** is one orchestrated moment: `settle-in` (fade + 6px rise, 0.42s,
  `cubic-bezier(.2,.7,.3,1)`, 0.12s delay) on `.settle-total dd`. It animates
  the number the rows produced, which is the one thing on the screen whose
  arrival is worth marking. Nothing else animates except the `.disclose`
  chevron's 0.18s rotate.
- `@media (prefers-reduced-motion: reduce)` neutralizes all transitions and
  animations globally, and removes `settle-in` explicitly.

---

## Accessibility requirements

- **Contrast.** All text meets WCAG AA at its rendered size against both `--bg`
  and `--sunken`. `--ink-3` is the lightest permitted text tone and is used
  only at 11.5–13px for metadata; it is never the sole carrier of a value.
- **Color is never the only signal.** `--in` / `--out` always appear as a
  signed pair on the same equation, and a `.flow` transfer is distinguished by
  glyph and mono, not hue.
- **Tabular figures** via `.num` so column values align for reading and
  VoiceOver announces digits without reflow.
- **Account paths** break with `overflow-wrap: anywhere` rather than
  overflowing the frame; a long `Assets:Investments:GlobalIndex` wraps inside
  its cell.
- **44pt targets** everywhere, listed above.
- **Focus visible** on every interactive control, listed above.
- **Dynamic Type.** The prototype is fixed-size HTML and does not scale; the
  native implementation must let `.settle-row`, `.txn .who`, `.metric dd` and
  `.tbl` body text scale, and must stack the `.metrics` grid to one column and
  the `.settle-total` to a vertical layout at accessibility sizes.
- **Charts expose their numbers.** The `.disclose` row is the mechanism; a
  chart without one is incomplete.

---

## Behavioral rules

These are product constraints inherited from the existing app and they survive
the redesign unchanged:

- **Local-only ledgers show no sync indicator at all.** A Git-configured ledger
  shows its actual repository state; tapping the indicator opens storage
  details and does not begin synchronization. Server mode keeps an explicitly
  labeled refresh action.
- **No fabricated counts or timestamps.** The prototype's synthetic figures are
  sample data only.
- **Amounts and every derived proportion obey the privacy setting.** When
  amounts are hidden the `.band` bar, `.tbl .share` column, charts and all
  ratios disappear rather than render as redacted rectangles — a proportion is
  as revealing as the number it came from.
- **Category aggregation uses the full local period aggregate**, not the
  currently loaded page of transactions.
- **Writes stay manual-first.** The 记一笔 flow previews the exact `.bean`
  source, requires an explicit confirmation checkbox, and gates its write
  button on both. Nothing in this design language changes the preview →
  validate → append sequence.
- **Account paths are shown verbatim.** Do not prettify `Expenses:Books` into
  a display name in the places where the path is the payload — the write
  preview and the import review.

---

## Migration checklist

The design is a second language, not an edit. Each row is a page that exists in
the terminal implementation and what it becomes here.

| Screen | Terminal | Balanced |
| --- | --- | --- |
| 概览 | Summary block, 28pt medium net | `.settle` equation: opening, in, out, closing + 30pt total; `.band` retained figure |
| 流水 | Date-column list, 36pt date column | `.daysep` ruled day groups + `.txn` rows; transfers drawn with `.flow` |
| 收支分析 | Numbered section heads, two-column metric grid | `.metrics` grid without numbering; `.tbl` category table with shares |
| 资产分析 | Historical values, composition | `.tbl` + `.key` legend with `--c` swatches; value labeled as current valuation |
| 账户 | Ruled net-worth summary, expandable groups | `.settle` summary + `.acct` rows, `.acct.child` expansion |
| 更多 | Compact numbered menu rows | `.group` + `.row` with a `.search` field, sentence-case labels |
| 记一笔 | Draft sheet | `.field-row` / `.seg-inline` / `.source` preview / `.confirm` gate |
| 导入复核 | Row list | `.imp` rows with `.box` checkbox, live selected-count and write-button text |
| 空态与异常 | Text states | `.empty` (action-oriented, ≤30ch) and `.warn` (facts, no apology) |
| Chrome | 56pt header, 60pt strip, 18pt icons | 52pt app bar, 62pt tab bar, 20pt icons with 2px underline mark |

Migration order: tokens and `.settle` first (it is referenced by three pages),
then 概览, then 账户 and 流水 which share its primitives, then the two analysis
pages, then More and the overlay flows.

---

## Reviewing the prototype

The gallery has three toolbar toggles: 浅色 / 深色 for the shell, and 全长,
which releases each frame to its natural content height so a whole page can be
read without scrolling inside the device. **The 852pt frame is the deliverable;
全长 is a review aid only.**

All frames use synthetic data. No real ledger entry, account path belonging to
a real person, or live figure appears anywhere in this directory.
