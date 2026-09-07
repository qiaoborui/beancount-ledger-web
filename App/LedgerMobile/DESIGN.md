# Native ledger design

## Theme
A compact everyday ledger with aligned amounts, visible categories, and quiet continuous lists. Mail informs scannable two-line rows; Wallet informs balance-to-history hierarchy; Settings informs editing forms only.

## Palette
Reading pages use systemBackground as one uninterrupted canvas, with semantic label colors and separators. Forms retain the system grouped style. Light mode, dark mode, and increased contrast follow the device. Preserve Ledger cobalt for actions and income, expense, and warning colors for financial meaning.

## Typography
Use Apple's system text styles and Dynamic Type. Main row text and amounts use subheadline (15pt at the default setting), category and note use caption (12pt), and the main summary uses title2. Prefer regular/medium text and semibold amounts. Amounts use monospaced digits and adaptive compact notation. Keep full account paths in details/search and as a fallback when account labels are unavailable. Preserve system accessibility scaling.

## Components
NavigationStack owns push/pop and the back gesture. TabView owns compact navigation; NavigationSplitView and a sidebar List own regular navigation. List and Form own row selection, separators, grouped sections, and scrolling. Use native toolbar buttons, search fields, pickers, date fields, and confirmation actions.

## Layout
Every page uses an inline system navigation title, independent of whether it is a tab root or a pushed destination. Shared reading lists and scroll pages use an 8pt top content inset. Range-scoped pages place one calendar-and-period button in the navigation bar, above native search. Its compact title preserves cross-year context; exact dates remain in its accessibility value and picker. Previous/next period edits the picker draft and applies only on confirmation. Ordinary transactions use two lines: merchant/amount, then category/note with a supplementary tag indicator. Multiple categories are explicit; transfers show outgoing and incoming account labels. Use 10pt transaction vertical padding, 6pt for ordinary account rows, and at least 44pt touch targets. Lists may grow at accessibility sizes.

## Depth
Reading pages group through alignment, compact headings, and fine separators. Avoid a separate rounded card around each date or transaction. Forms retain grouped surfaces. Let system navigation and tab bars render their own materials.

## Interaction rules
Each compact tab retains its own navigation stack. Overflow destinations push within More. Sidebar selection changes the detail stack while preserving sidebar visibility. Search, date filters, tag selection, transaction editing, import review, and privacy concealment remain available. Transaction bulk selection lives in the actions menu; selection mode exposes Done directly. Financial writes retain server validation and explicit confirmation. Sheets preserve the privacy cover; keyboard dismissal remains available on decimal fields. Honor Reduce Motion.

## Responsive behavior
Use the horizontal size class for iPad navigation and existing chart layouts. Lists adapt to the available width. Accessibility text sizes may stack row labels and values. Avoid hardcoded tab-bar clearance; the system owns safe-area insets.

## Future changes
Add destinations to the shared destination model and render them inside the shell's existing stack. Use a Form Section for preferences, a List Section for collections, and a navigation destination for drill-down. Reuse semantic colors, financial formatters, and existing server contracts.
