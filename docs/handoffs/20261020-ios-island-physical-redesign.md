# 20261020-ios-island-physical-redesign

- Status: completed
- Updated: 2026-10-20 (Asia/Shanghai)
- Branch: codex/ios-island-layout-polish (on top of dd0012a); PR https://github.com/qiaoborui/beancount-ledger-web/pull/524

## Goal
Redesign the in-app Dynamic Island entry notice so the hardware camera cutout is a
fixed keep-out region: no content under or beside it at the wrong height, and the
expanded shape grows out of the physical island.

## Decisions
- Shape top == camera top; the camera is a fixed rect (cover pill size) at top centre
  (`LedgerIslandStage.cameraRect`, `band`).
- Camera band: status caption in the leading flank, amount in the trailing flank, both on
  the camera's centre line, `cameraGap` from the camera and `inset` from the edge.
  They are anchored to the camera (revealed by the clipping shape), never scaled under it.
- Body below the camera: badge + ring, then title/subtitle across the full width. Body
  rows map only into the part of the live shape below the band.
- The 44pt ring no longer rides beside the camera (it is taller than the 37pt band).
- Caption placement (inline/below) removed; `TextRows` carries only title lines.
- `LedgerIslandStage.flank(screenWidth:cutoutWidth:)` is shared by the window manager and
  the stage default, so phones without a hardware island also get usable flanks
  (previously flank width was 0 there).
- `foldedLines` no longer leaves a trailing space at a fold.

## Validation
- `xcodebuild test -only-testing:LedgerMobileTests` on iPhone 17 Pro simulator: all passed.
- New test asserts no content rect intersects the camera for 1179/1206/unknown panels and
  the no-hardware pill, and the ring stays inside the bottom-leading corner.
- Simulator run (iPhone 17 Pro, \`--preview-island --safe-preview\`, recorded with \`simctl io recordVideo\`): expense, import and long-title income notices all keep the camera rect clear in expanded and compact states.
- Not done: a physical device.

## Next
- Optional: check on a physical Dynamic Island phone with the \`--preview-island\` launch argument.
