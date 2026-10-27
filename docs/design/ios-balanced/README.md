# 结平 / Balanced

A second design language for the Ledger iOS app. It exists alongside the
terminal design in [`../ios-terminal/`](../ios-terminal/) — not as a
replacement, but as an alternative answer to the same product.

- [`index.html`](index.html) — the remaining screens (20 frames, light and dark)
- [`glass.html`](glass.html) — batch 1 with the iOS 26 Liquid Glass control
  layer (draft)
- [`splash.html`](splash.html) — the launch animation, drawn on a canvas
- [`styles.css`](styles.css) — every token and component in this document
- [`batch1/`](batch1/) — the first batch: overview, transactions, analysis,
  accounts, more, sync, date picker, entry and import review. The main tabs
  follow this batch.

---

## The premise

A ledger records two sides of every movement. The two sides must agree. That
single fact is the whole design.

So the interface is built around **the equation**: a direction that adds and a
direction that subtracts, held in balance by a line that says *this column is
closed and verified*. In accounting that mark is a **double rule** — two
hairlines drawn under a total to mean the figures above it have been checked and
will not change. It is the anchor of the splash animation, and it is the same
statement the app already makes when it reports an account as `已核平`.

Two consequences follow, and they decide most of what is in this document:

1. **Chroma is spent on direction, and nothing else.** Exactly two opposed
   colours mean *in* and *out*. Every other surface is ink at one of four
   lightnesses. There is no accent colour, because an accent colour would
   compete with the one signal that carries meaning.
2. **Hierarchy comes from weight and lightness, not from containers.** No cards,
   no shadows, no gradients. A section is separated from its neighbour by space
   and by a change in the weight of the type — the same way a printed ledger
   separates its columns.

### Where this differs from the terminal design

| | Terminal | Balanced |
|---|---|---|
| Metaphor | a terminal session | a printed account book |
| Structure | numbered heads `01 / 流水` | none — the label *is* the heading |
| Amounts | monospaced throughout | proportional with tabular figures |
| Mono | all numerals | account paths and beancount source only |
| Accent | amber, decorative | none — two direction colours, functional |
| Grouping | rules between rows | one sunken well (`.band`), no borders |

The two languages can coexist. They should not be mixed within one screen.

---

## Colour

Ten tokens, four of them ink. Light is the default; `.phone[data-theme='dark']`
overrides every one.

| Token | Light | Dark | Role |
|---|---|---|---|
| `--bg` | `#fbfaf8` | `#121110` | the page |
| `--sunken` | `#f1efe9` | `#1b1918` | the one grouping well; search fields |
| `--ink` | `#14100c` | `#f6f3ee` | primary text, totals, the double rule |
| `--ink-2` | `#453e36` | `#c4bcb0` | labels, secondary text |
| `--ink-3` | `#6f675a` | `#9a9086` | metadata, section heads, account paths |
| `--rule` | `#e2ded4` | `#2b2825` | row separators |
| `--rule-strong` | `#c8c2b4` | `#423c36` | field underlines, day separators, grabber |
| `--edge` | `#88837a` | `#78746e` | **control boundaries** |
| `--in` | `#0d5346` | `#4fbfab` | money arriving |
| `--out` | `#96401f` | `#cf7a52` | money leaving |

### Why `--edge` is separate from `--rule-strong`

`--rule-strong` is a hairline: at 1.70:1 (light) and 1.73:1 (dark) against
`--bg` it is far below the 3:1 that WCAG 1.4.11 requires of a boundary that
makes a *control* exist. It is fine for a divider, which carries no affordance.

So the two jobs are split. `--edge` at `#88837a` / `#78746e` clears 3:1 against
both `--bg` and `--sunken` in both themes, and is applied to every control whose
only affordance is a line — six controls, seven selectors:

`.row .chev` · `.range .field` · `.btn` · `.seg-inline` ·
`.seg-inline button` · `.toggle` · `.imp .box`

`--rule-strong` keeps the decorative jobs: the underline on `.link`, the sheet
grabber and the sheet's top edge, the `.daysep` rule, the unfinished segments of
`.rail`, and the `.field` underline.

### Measured contrast

Against `--bg` / `--sunken`, light then dark:

| | vs `--bg` | vs `--sunken` |
|---|---|---|
| `--ink` | 18.15 | 17.04 |
| `--ink-2` | 10.09 | 10.03 |
| `--ink-3` | 5.35 | 6.02 |
| `--in` | 8.59 | 8.42 |
| `--out` | 6.60 | 5.89 |
| `--edge` | ≥ 3.0 | ≥ 3.0 |

Every text tone clears AA at body size; `--ink-3` is the floor and is used for
nothing that has to be read at length.

### How the direction colours are rationed

`--in` and `--out` appear in exactly four places, all of them on a number or on
a status that is a number's shadow:

- an amount (`.txn .amt`, `.key .v`, `.row .row-val`)
- a period total, where the direction is the point
- the sync dot (`.iconbtn .dot`) — `--in` for synced, `--out` for pending/failed
- a status tag (`.tag[data-kind]`) — `已核平` in `--in`, `异常` in `--out`

They never colour a background, never colour a button, never colour a heading.

**Pending is not an error.** `未分类` and `待对账` use `--out` only because the
money has not been classified yet — the same colour a subtraction gets. They are
not red, because a red would read as *wrong*, and an unclassified transaction is
not wrong, it is unfinished. The design has no error colour at all; the failure
states in this system are all text.

---

## Type

Two families, with a hard division of labour.

**IBM Plex Sans** — everything. Body, headings, labels, buttons, and all
amounts. Amounts set with `font-variant-numeric: tabular-nums` so columns align
without a monospaced face, which keeps figures at a normal weight and width.

**IBM Plex Mono** — two jobs only:
- account paths (`.acct`, `.tbl .cat .path`)
- beancount source previews, and the repository URL/branch/token fields

If you are about to set a number in mono, don't. That is the terminal design's
rule, not this one.

### Scale

| Role | Size | Weight | Notes |
|---|---|---|---|
| Page title | 17 | 500 | `.appbar .title` |
| Sheet title | 17 | 500 | |
| Row title / payee | 15 | 450 | |
| Amount | 15 | 450 | tabular |
| Period total | 21 | 500 | `.key--total` |
| Widget number | 27 | 500 | tabular, −0.01em |
| Label | 14 | 400 | `--ink-2` |
| Section head | 12.5 | 500 | `--ink-3`, +0.03em |
| Metadata | 12 | 400 | `--ink-3` |
| Account path | 11.5 | 400 | mono |
| Tab label | 10.5 | 400 | |

Weight 450 is the workhorse. It reads as a normal weight on Plex and gives the
row titles just enough presence to sit above their metadata without a second
colour.

**Section heads are not numbered.** The terminal design writes `01 / 流水`.
Here the label carries the heading, at 12.5px in `--ink-3` — deliberately
quieter than the rows beneath it, because it is a signpost, not a title.

---

## Geometry

Four radii, and no more. Each is used for one reason.

| Radius | Used by | Why |
|---|---|---|
| `46px` | `.phone` | the device frame |
| `34px` | `.pill` | the island — it is the system's shape, not ours |
| `22px` | `.widget` | the system's widget container |
| `3px` | `.btn`, `.seg-inline`, `.searchbar` | controls |
| `2px` | `.toggle`, `.imp .box`, `.toolbar button` | square indicators |
| `0` | everything else | |

No shadows on any in-app element. The only `box-shadow` in the system draws the
device bezel.

| | |
|---|---|
| Frame | 393 × 852 |
| Page padding | `--pad: 20px` |
| Minimum hit target | 44 × 44 — every row is `min-height: 44px`, every icon button is exactly 44 |
| Row | 44 min, 9px vertical padding |
| Band | 14 × 16 padding, 18 top for a lead band |
| Divider | 1px `--rule` between rows; 1px `--rule-strong` under a day separator |

**One grouping device.** `.band` is a sunken well with square corners. It is the
only thing in the system that groups content, it is used once or twice per
screen, and it never gets a border, a shadow, or a radius beyond the default.
Cards are the thing this design language is defined against.

---

## Components

### `.settle` — the double rule

The signature. Two 1px `--ink` hairlines with a single pixel of air between them
— 3px overall — drawn edge to edge across the full width of the column:

```css
.settle::after {
  content: '';
  position: absolute; left: 0; right: 0; bottom: 0;
  height: 3px;
  border-top: 1px solid var(--ink);
  border-bottom: 1px solid var(--ink);
}
```

The gap is one pixel on purpose. Any wider and it stops reading as a single
mark that happens to have two strokes; it becomes a box.

It follows a total that has been verified. `.settle--quiet` swaps in
`--rule-strong` for a subtotal that is merely complete rather than checked.

In this batch it appears in three places, each time making the same claim —
*this column is closed*:

| Where | What it asserts |
|---|---|
| 开账向导 · 期初结余 | the balances the user typed sum to their net worth |
| 单账户对账 | the book balance and the counted balance now agree |
| 总账合计 (batch 1) | the column is final and safe to quote |

### `.band` · `.key`

`.key` is a label/value pair on a shared baseline, the value flush right in
tabular figures. `.key--total` steps up to 21px and swaps the currency symbol to
0.62em in `--ink-3`, so `¥108,160.00` reads as a number first and a currency
second.

### `.txn` · `.daysep`

A transaction is two lines, hand-aligned: a 34px time gutter, then payee over
metadata, then the amount right-aligned. `.daysep` opens a day with a
`--rule-strong` rule and a count.

### `.acct`

The account path, in mono at 11.5px, `--ink-3`, wrapping anywhere. It sits under
its human label everywhere the two appear together — `餐饮` over
`Expenses:Food` — because the path is what actually gets written to disk and the
label is only a convenience.

### `.mark` — the selection mark

Tabs, segment filters and the reconciliation status filters all use one shared
device: a 2px `--ink` underline on the active item, `--ink-3` for the rest, and
a 1px `--rule` baseline under the whole strip. No pills, no filled backgrounds,
no moving indicator. `.seg` applies the same mark to a full-width control.

### `.btn`

Full width, 48px minimum, 3px radius, 1px `--edge` border. Three variants:
default (outline), `--primary` (solid `--ink`), `--quiet` (no border, `--ink-2`).
`.btn--risk` uses `--out` for the label. Disabled is `opacity: 0.38` — never a
grey fill.

### `.rail`

Added in this batch. Four equal segments, 2px high: `--ink` for a completed
step, `--rule-strong` for the rest. Used by the onboarding wizard. It replaces a
numbered step indicator because the rail says *where you are* without repeating
it in words, and it says *how much is left* — which a dot row does not.

### `.pill` — the island

The app's only rounded, only dark, only reversed surface. That is deliberate:
the island belongs to the system, so it is the one place this design stops
imposing its own geometry.

224 × 68, radius 34, `#000`. A 34px badge circle, the amount in 15px mono, a
second line in 11px at 60% white, and a 22px outcome ring. Amount colour comes
from the same two direction tokens, lightened for the dark surface —
`#4fbfab` and `#cf7a52`, the dark-theme values, used literally.

### `.widget`

340 × 148-ish, radius 22, `--sunken` fill, and otherwise the same type rules as
the app: 27px tabular number, a label beneath, then income and expense side by
side, then the most recent transaction under a `--rule` hairline.

The widget reads a snapshot the app publishes. It never makes its own request —
which is why it has no loading state and no spinner. It shows the last
successful sync, or it shows nothing.

### Fast entry — 记一笔

The keypad sheet behind the `+` in the 概览 and 流水 app bars. It is the
batch-1 记一笔 draft with a keypad, built from the same parts and nothing new:

- **App bar `+`** is a plain `.iconbtn`: an ink glyph in a 44pt target, beside
  the sync button. Never filled, never circled.
- **Direction** is a `.mark` strip — 支出 / 收入 / 转账.
- **Amount** is the `.key--total` treatment at 40px: tabular figures, the
  currency symbol at 0.62em in `--ink-3`, the code (`CNY ⌄`) as a quiet menu on
  the label line. The figure takes `--out` for 支出 and `--in` for 收入 — an
  amount is one of the four places direction colour is allowed. Transfers and
  splits stay ink. A 1px `--rule-strong` underline closes it; no double rule,
  because a draft is not verified.
- **Categories are words.** Four columns of labels at 14px, the active one
  carrying the `.mark` underline; no icons, no circles, no per-category colour.
  The last cell is 更多…, and shows the custom account's name once one is picked.
- **Fields** are `.field-row`s: 付款账户 / 收款账户 (or 转出 + 转入), 日期,
  商户, 备注 — label in `--ink-2`, value flush right, `--edge` chevron on rows
  that open a picker.
- **Footer links** — 用一句话记账 and 拆分成多条分录 — are `.link`s.
- **Keypad** is the screen's one `.band`: square cells on `--sunken`, split by
  1px `--rule` hairlines, edge to edge. The commit key is the only solid ink
  cell. It still opens the preview → bean-check → append flow.
- **Splits** are ledger rows (label over mono path, amount right). The posting
  the keypad edits has a 2px ink edge bar and the `.mark` under its amount.
  Balance shows as an `已配平` tag in `--in`, or `差额` in `--out` with a 配平
  link.

### `.empty`

Centred, generous vertical padding, a 1px-stroke glyph in `--ink-3`, an h3 at
16px, one sentence at 13.5px capped to 30 characters, and at most one button.
The sentence says what to do, not how the system feels about it.

---

## State and interaction

- **Selection** is `aria-selected` / `aria-pressed` on a `.mark`, or
  `aria-current="page"` on a tab bar item. Never a class.
- **Checked** is `aria-checked` on `.imp .box` and `.toggle`; the CSS keys off
  the attribute, so the visual and the state cannot drift.
- **Disabled** is `opacity: 0.38`. Not a colour change — a colour change would
  imply a different kind of thing.
- **Focus** is `outline: 2px solid var(--ink); outline-offset: -2px` — an inset
  ring. A halo would break the flatness of the page and read as a shadow.
- **Expand** is `aria-expanded` on `.disclose`; the caret rotates 90° on a
  0.18s `settle-in`.
- **Motion** is one orchestrated entrance, `.enter` → `.enter-4` on a 0.06s
  stagger, 6px rise, 0.42s on `cubic-bezier(0.2, 0.7, 0.3, 1)`. There is no
  other motion in the system except the `.disclose` caret and the `active` state
  on `.row--tap`.

`prefers-reduced-motion: reduce` disables all animation and transition
wholesale.

### The one thing that animates

The splash. Two accounting sides share a vertical spine and draw a standalone
`B`-shaped Balanced mark; its internal double rule settles, then the Chinese
wordmark and `BEANCOUNT LEDGER` subtitle appear. A few faint ruled lines follow
as context, and a second double rule lands below the mark in two strokes — the
second drawn 80ms after the first, which is what makes it read as a *decision*
rather than a flourish. Then it holds, and loops.

**The splash carries no ledger data.** It draws ruled lines, never amounts. The
splash renders before the unlock gate, so any figure on it would be readable by
anyone holding the phone — and at that moment no ledger has been loaded, so the
figure would not be a real period total in the first place. This is the same
rule as the locked state: no amounts, no account names, no counts. A splash
showing 「收入 / 支出 / 结余」 violates both the privacy model and the design's
own claim to show only true figures.

Timings live in `splash.html` as a single `T` table; the entrance easing is the
same `cubic-bezier(0.2, 0.7, 0.3, 1)` the app uses. Reduced motion draws the
final frame directly.

---

## Accessibility requirements

Non-negotiable, and enforced by the tokens rather than by per-screen care:

1. All text meets AA at its size. The floor is `--ink-3` at 5.35:1.
2. Every control boundary meets 3:1 via `--edge`. If you add a bordered control,
   `--edge` is its border colour; `--rule` and `--rule-strong` are never a
   control's only affordance.
3. Direction is never the *only* encoding of a value. An amount carries its sign
   and its position; colour reinforces it. This matters for `--in`/`--out` on
   deuteranopia, where `#0d5346` and `#96401f` are close in hue but far apart in
   lightness — which is why they were chosen.
4. Hit targets are ≥ 44 × 44.
5. Focus is always visible, and never simulated by a border colour change alone.
6. The cover (`PrivacyCover`) is `accessibilityLabel("敏感数据已隐藏")` and hides
   its subtree. Hidden content is not merely invisible; it is removed from the
   accessibility tree.
7. Motion respects `prefers-reduced-motion`.

---

## Behavioural rules the design assumes

These are shipped behaviours in the app, and the design depends on them:

- **Writes are manual-first.** Preview, validate, then append. Every screen that
  writes shows the resulting beancount source before the button that commits it
  — see the wizard's `accounts.bean` preview and the reconciliation's `balance`
  assertion.
- **`bean-check` gates the write.** A change that fails validation does not
  reach disk, and the previous generation stays published.
- **Rollback stays intact.** The files screen states this plainly rather than
  hiding it behind a reassuring tone.
- **Secrets are hidden until unlock.** The locked state shows no ledger content
  at all — not amounts, not account names, not counts.
- **The widget and island show published snapshots**, never live queries.

---

## Migration checklist

Per screen, from the terminal design to this one:

- [ ] Remove the `NN /` prefix from section heads. The label is the heading.
- [ ] Replace any `LinearGradient` or `.shadow` with `--sunken` or nothing.
      *(The shipped `LedgerLibraryView` hero card uses a blue→indigo gradient;
      it becomes a `.band--lead` with an outline button.)*
- [ ] Replace numbered step indicators with `.rail`.
- [ ] Convert monospaced amounts to IBM Plex Sans with `tabular-nums`. Keep
      mono on account paths and beancount source.
- [ ] Replace decorative amber with nothing, or with `--in`/`--out` where the
      value genuinely has a direction.
- [ ] Collapse card-per-item lists into one `.band` plus `.row` separators.
- [ ] Move any bordered control's border to `--edge`.
- [ ] Confirm the screen has at most one `.settle`, and that it means *verified*.

Two screens currently contradict the rules and are corrected in this batch:
the gradient hero in `LedgerLibraryView`, and the numbered rows in `MoreView`.

---

## Reviewing the prototype

Open [`index.html`](index.html) directly in a browser — it needs no server. The
toolbar toggles the gallery between light and dark; each frame keeps its own
theme, so the dark section stays dark either way.

The frames are static HTML, not a running app. Interaction is wired only where
it demonstrates a state that matters: the theme toggle, tab and segment
selection, checkboxes, and toggles. Everything else is the appearance of a
state, and is meant to be read rather than clicked.

---

## Liquid Glass (iOS 26)

[`glass.html`](glass.html) is batch 1 with one material added on top. Every
frame is taken from [`batch1/index.html`](batch1/index.html) unchanged: the
page content (settlement blocks, retention bar, category table, recent
transactions, filters, search) stays exactly as designed. Only the **control
layer** becomes glass, in the spirit of the Claude iOS app: controls float as
glass circles and capsules over full-bleed content.

- Top bar: the title stays on the paper; the period control is one glass
  capsule, status and action icons share a second; pushed pages get a 44pt
  glass back circle.
- Tab bar (概览 / 流水 / 账户 / 更多): the system glass capsule, floating.
- Search field and filter segment: glass capsules in their original places.
- Sheets: system glass shell with inset corners; the reading area stays paper.
- Docked actions (import review): a floating glass panel; primary stays solid.
- **No occlusion:** at rest the first content starts below the top bar; the
  scroll content's bottom inset equals the floating stack's height + 12pt, so
  the last row scrolls fully clear. Fixed content never sits under glass.
- Glass is never tinted. Below iOS 26 (deployment target iOS 17) the app keeps
  batch 1's flat surfaces and does not imitate glass with material blur.
