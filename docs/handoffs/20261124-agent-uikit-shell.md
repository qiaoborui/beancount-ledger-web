# 20261124-agent-uikit-shell

- Status: active
- Last updated: 2026-11-24 20:05 +08:00
- Branch: `claude/project-thread-5189p2` (no PR yet)

## Goal

Rewrite the iOS assistant's history drawer shell and conversation list in
UIKit, after FlowDown (Lakr233/FlowDown, AGPL: structure and numbers only,
no copied code), so opening/closing the drawer, the keyboard, scrolling and
returning from pushed pages are smooth on a device. Also fix: 概览 recomputing
under the assistant, first-time CJK/emoji font fallback, keychain read on send.
Iterate by dev-installing on the maintainer's iPhone; no release tags.

## Done

- `LedgerAgentDrawerShell.swift`: UIKit container; page and drawer in their own
  hosting controllers; open/close moves layers only (translate + scale into a
  28pt card, 20pt inside the safe area, 40pt showing, 10% shadow; drawer slides
  70pt; 100pt drag commits; spring 0.5 s / 0.9). Children get the container's
  safe area (`safeAreaRegions = .keyboard` + `safeAreaPadding`), because UIKit
  recomputes a moved view's safe area and that relaid the page out.
  `LedgerAgentDrawerShellTests` checks the page keeps its size and safe area.
- Drawer built 0.8 s after the page appears and kept drawn under the card.
- `LedgerAgentMessageList.swift`: UICollectionView of hosting-configuration
  rows with Equatable tokens; only changed rows redraw; following the reply is
  done after each layout (FlowDown's MessageListView approach).
- 概览 (`OverviewView`) redraws only when its inputs change
  (`LedgerSession.overviewGeneration`).
- `LedgerFontWarmup`, keychain key cache in `LedgerAgentSettings`.
- `LedgerMotionProbe` (compiled in only with `LEDGER_PERF_PROBE`).

## Validation

- `xcodebuild test` LedgerMobileTests: 1274 passed (7 skipped).
- `swift build --build-tests` in `App/LedgerMobile`: OK.
- Simulator: chat, failure row, drawer drag/tap-close, pushed 定时任务 and back.
- Device run 1 (drawer only): later opens/closes 0 dropped frames; first open
  dropped 10 (list build), one later open 7 (redraw from hidden) — fixed since.

## Next

1. Second device run: long conversation scrolling, streaming follow, jump
   button, keyboard. Read the probe log, fix what it shows.
2. Open the PR (body: `需要发版：账本助手侧栏与对话列表改为 UIKit`).
