# Native ledger design

## Theme
A compact device-local ledger with aligned amounts, visible categories, quiet continuous lists, and native Liquid Glass controls. Mail informs scannable two-line rows; Wallet informs balance-to-history hierarchy; Settings informs editing forms only. The library starts with local creation and folder import. Storage and optional synchronization remain separate from everyday reading, calculation, editing, and bill import, which run on device.

## Palette
Reading pages use systemBackground as one uninterrupted canvas, with semantic label colors and separators. Forms retain the system grouped style. Light mode, dark mode, and increased contrast follow the device. Preserve Ledger cobalt for actions and income, expense, and warning colors for financial meaning.

## Typography
Use Apple's system text styles and Dynamic Type. Main row text and amounts use subheadline (15pt at the default setting), category and note use caption (12pt), and the main summary uses title2. Prefer regular/medium text and semibold amounts. Amounts use monospaced digits and adaptive compact notation. Keep full account paths in details/search and as a fallback when account labels are unavailable. Preserve system accessibility scaling.

## Components
NavigationStack owns push/pop and the back gesture. TabView owns compact navigation; NavigationSplitView and a sidebar List own regular navigation. List and Form own row selection, separators, grouped sections, and scrolling. Use native toolbar buttons, search fields, pickers, date fields, and confirmation actions.

The shared trailing toolbar control shows a static 10pt status dot in one fixed-size slot: green synced, cobalt syncing, amber pending, red failure/conflict, secondary gray device-only or paused automatic sync. Preserve a spoken status label and a 44pt tap target. Tapping a configured Git ledger synchronizes immediately; device-only storage and conflicts open storage settings. The active execution slot disables duplicate taps without a spinner. Authentication and background privacy shielding remain independent of this control.

## Layout
Every page uses an inline system navigation title, independent of whether it is a tab root or a pushed destination. Shared reading lists and scroll pages use an 8pt top content inset. Range-scoped pages place one calendar-and-period button in the navigation bar, with search collapsed into a glass button on iOS 26 and later. iPhone reserves a bottom safe-area inset above the tab bar for search and expands the field above the keyboard; iPad adapts native search to the toolbar. Older systems keep the navigation search drawer. Its compact title preserves cross-year context; exact dates remain in its accessibility value and picker. Previous/next period edits the picker draft and applies only on confirmation. Ordinary transactions use two lines: merchant/amount, then category/note with a supplementary tag indicator. Multiple categories are explicit; transfers show outgoing and incoming account labels. Use 10pt transaction vertical padding, 6pt for ordinary account rows, and at least 44pt touch targets. Lists may grow at accessibility sizes.

## Depth
Reading pages group through alignment, compact headings, and fine separators. Avoid a separate rounded card around each date or transaction. Forms retain grouped surfaces. Let system navigation, tab bars, and sheets render their own materials, including in transaction and account details. The iPhone tab bar minimizes on scroll. Tag selection and import commit controls use one inset glass surface above the safe area; Reduce Transparency uses an opaque semantic surface. Keep glass in the control layer and preserve an uninterrupted reading canvas.

## Interaction rules
Each compact tab retains its own navigation stack. Overflow destinations push within More. Sidebar selection changes the detail stack while preserving sidebar visibility. Search, date filters, tag selection, transaction editing, import review, and privacy concealment remain available. Transaction bulk selection lives in the actions menu; selection mode exposes Done directly. Financial writes use explicit confirmation and canonical Beancount validation inside the app. Changes stay in a staging generation until validation succeeds and the committed generation is published atomically. Transaction deletion is available by swipe and in details; its review sheet shows the transaction and optional reason. The local writer comments out the original transaction. Pending deletion retains the row; a confirmed local write hides it across stale refreshes, and a failed write preserves it for retry. Use local or neutral status text for validation, saving, and refresh.

Sheets preserve the privacy cover; keyboard dismissal remains available on decimal fields. Honor Reduce Motion. Cold launch and opening a local ledger request device-owner authentication through Face ID, Touch ID, or the device passcode. Returning after the lock interval requires unlock again. Canceling keeps the ledger locked and exposes manual retry. Only a real background visit rearms automatic authentication. Settings describes device protection and local files; automatic Gmail and cloud-service setup stay outside the current app's navigation.

Widget timelines read the local snapshot published by the app. This boundary applies to first launch after an upgrade, stale or missing snapshots, and forced refreshes, including when an older enabled remote credential remains in Keychain. The production timeline composition creates no HTTP client; app updates and WidgetKit scheduling refresh the presentation.

## Responsive behavior
Account groups start collapsed and expose one Expand All / Collapse All action in a compact section header alongside the group count. All groups form one continuous section. Search maintains separate expansion state so clearing it restores the browsing state. Transaction selection uses a subtle full-row tint and checkmark, with no rounded outline against the text edge.

Accounts always show all available groups with no category segmented picker. Import starts with a Files-style action row and continues through system List/Form surfaces. Channel coverage and parsing details expand on demand; transaction review retains explicit inclusion, editing, and confirmation before writing. Warm local unlock restores the same authenticated ledger's in-memory presentation while version checks run separately, preserving a quiet opening transition.

Use the horizontal size class for iPad navigation and existing chart layouts. Lists adapt to the available width. Accessibility text sizes may stack row labels and values. Avoid hardcoded tab-bar clearance; the system owns safe-area insets.

## Future changes
Add destinations to the shared destination model and render them inside the shell's existing stack. Use a Form Section for preferences, a List Section for collections, and a navigation destination for drill-down. Reuse semantic colors, financial formatters, and the embedded repository contracts. Keep fixed action surfaces in safe-area insets so the final transaction row can scroll fully above them; UI automation must reveal covered rows before tapping.
