# 20261115-ios-built-in-linux

- Status: active
- Last updated: 2026-11-15 (UTC+8)
- Branch: `claude/project-thread-itgbao`, PR #710 (design doc + phase 0)

## Goal

Phase 0 of `docs/plans/20261115-local-cloud-agent.md`: the on-device 账本助手
gets a `bash` tool that runs in a built-in Alpine Linux (iSH AArch64 engine,
lollipopkit/ShellBox v1.0.55), with the conversation's draft at /workspace.

## Done

- Go: `server/mobileagent/linux.go` (LinuxRunner callback, bash tool, draft
  fingerprint/cleanup, `ExtractRootfsJSON`), tests in `linux_test.go`.
- C glue: `App/LedgerMobile/Linux/LedgerLinux.{h,c}` over the engine's kernel
  API; syntax-checked against the v1.0.55 headers on Linux, not yet compiled
  for iOS.
- Build: `scripts/build-linux-ios.sh` → `server/.build/linux-ios/`
  (LedgerLinux.xcframework, alpine-minirootfs.tar.gz, licenses). Wired into
  `ios-app-check.sh`, `build-ios-ipa.sh`, `project.yml`, the CI planner.
- Swift: `LedgerLinuxMachine.swift` (install, boot, run, cancel, reset),
  settings page under 助手设置 → 能力 → 内置 Linux.

## Remaining

1. Get the iOS app CI job green (first real compile of the C and Swift).
2. Pin `ALPINE_SHA256` in the build script from the CI log line.
3. Device test: first command unpacks and boots; `apk add python3`; timeout and
   stop kill the command; the app survives a guest crash; background turns.
4. Then: decide release (`需要发版：新增内置 Linux（助手 bash 工具）`).

## Risks

- Engine signal handling inside the Go/CPython process (SIGSEGV chaining,
  SIGUSR1, SIGPIPE ignored). Memory use of large guest programs.
- GPL terms of the engine (see `App/LedgerMobile/Runtime/THIRD_PARTY.md`).
