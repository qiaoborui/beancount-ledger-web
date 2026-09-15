#!/bin/bash
# Xcode post-build phase: package stdlib and code-sign its iOS extension frameworks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/server/.build/beancount-ios"
: "${CODESIGNING_FOLDER_PATH:?Run this script as an Xcode app build phase}"
if [ ! -f "$BUILD/packages/ledger_validator.py" ]; then
    echo "Run bash scripts/build-beancount-ios.sh before building LedgerMobile" >&2
    exit 1
fi
# The upstream converter expects one architecture; simulator extension binaries
# are already fat and may safely be copied from either architecture directory.
ARCHS="${CURRENT_ARCH:-arm64}"
if [ "$ARCHS" = undefined_arch ]; then ARCHS=arm64; fi
export ARCHS
export EXPANDED_CODE_SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
export EXPANDED_CODE_SIGN_IDENTITY_NAME="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-Ad hoc}"
export PLATFORM_FAMILY_NAME=iOS
source "$BUILD/upstream/Python.xcframework/build/utils.sh"
install_python ../../server/.build/beancount-ios/upstream/Python.xcframework
mkdir -p "$CODESIGNING_FOLDER_PATH/python/app_packages"
rsync -a --exclude __pycache__ "$BUILD/packages/" "$CODESIGNING_FOLDER_PATH/python/app_packages/"
