# Native ledger design

## Theme
An everyday personal ledger with clear balances, readable transactions, and familiar iOS navigation. Wallet informs the balance-to-history hierarchy; Settings informs forms; Health informs summary-to-analysis navigation.

## Palette
Use UIKit semantic grouped backgrounds, label colors, and separators so light mode, dark mode, and increased contrast follow the device. Preserve Ledger cobalt for actions and the existing income, expense, and warning colors for financial meaning.

## Typography
Use Apple's system text styles and Dynamic Type. Amounts use monospaced digits and adaptive compact notation. Body rows use body/subheadline; supporting context uses footnote/caption. Full account paths belong in detail and search.

## Components
NavigationStack owns push/pop and the back gesture. TabView owns compact navigation; NavigationSplitView and a sidebar List own regular navigation. List and Form own row selection, separators, grouped sections, and scrolling. Use native toolbar buttons, search fields, pickers, date fields, and confirmation actions.

## Layout
One navigation title per screen. Put current period beside the content it affects, keep filters available in empty states, and use content safe areas for bottom actions. Use 8/12/16/20/24 point spacing and at least 44 point touch targets.

## Depth
Grouped system surfaces communicate hierarchy. Financial charts may use a rounded grouped surface. Let system navigation and tab bars render their own materials.

## Interaction rules
Each compact tab retains its own navigation stack. Overflow destinations push within More. Sidebar selection changes the detail stack while preserving sidebar visibility. Search, date filters, tag selection, transaction editing, import review, and privacy concealment remain available. Financial writes retain server validation and explicit confirmation. Sheets preserve the privacy cover; keyboard dismissal remains available on decimal fields. Honor Reduce Motion.

## Responsive behavior
Use the horizontal size class for iPad navigation and existing chart layouts. Lists adapt to the available width. Accessibility text sizes may stack row labels and values. Avoid hardcoded tab-bar clearance; the system owns safe-area insets.

## Future changes
Add destinations to the shared destination model and render them inside the shell's existing stack. Use a Form Section for preferences, a List Section for collections, and a navigation destination for drill-down. Reuse semantic colors, financial formatters, and existing server contracts.
