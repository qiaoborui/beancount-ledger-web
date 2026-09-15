#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || "$1" == "--help" ]]; then
  printf 'Usage: bash scripts/test-ledgercore-simulator.sh <booted-simulator-udid>\n'
  printf 'Build LedgerCore with scripts/build-ledgercore-xcframework.sh first.\n'
  [[ "${1:-}" == "--help" ]] && exit 0
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
framework_root="${repo_root}/server/.build/ledgercore/LedgerCore.xcframework/ios-arm64_x86_64-simulator"
if [[ ! -d "${framework_root}/LedgerCore.framework" ]]; then
  printf 'LedgerCore.xcframework is missing; run the framework builder first.\n' >&2
  exit 1
fi

smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/ledgercore-smoke.XXXXXX")"
trap 'rm -rf "${smoke_dir}"' EXIT
architecture="$(uname -m)"
xcrun --sdk iphonesimulator clang \
  -target "${architecture}-apple-ios17.0-simulator" -fobjc-arc -fmodules \
  -F "${framework_root}" -framework LedgerCore -framework Foundation \
  "${repo_root}/server/mobilecore/testdata/ios_smoke.m" \
  -o "${smoke_dir}/ledgercore-smoke"
xcrun simctl spawn "$1" "${smoke_dir}/ledgercore-smoke"
