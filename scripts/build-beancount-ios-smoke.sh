#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/server/.build/beancount-ios"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
APP="$BUILD/BeancountSmoke.app"
PYTHON="$BUILD/upstream/Python.xcframework/ios-arm64_x86_64-simulator"
mkdir -p "$APP/Frameworks"
cp "$ROOT/App/LedgerMobile/Runtime/Smoke/Info.plist" "$APP/Info.plist"
rsync -a "$PYTHON/Python.framework" "$APP/Frameworks/"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator \
    -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" -fobjc-arc \
    -I"$ROOT/App/LedgerMobile/Runtime" -F"$PYTHON" \
    "$ROOT/App/LedgerMobile/Runtime/Smoke/main.m" \
    "$BUILD/iphonesimulator-arm64/libBeancountRuntime.a" -framework Foundation -framework Python \
    -Wl,-rpath,@executable_path/Frameworks -o "$APP/BeancountSmoke"
PROJECT_DIR="$ROOT/App/LedgerMobile" CODESIGNING_FOLDER_PATH="$APP" \
    EFFECTIVE_PLATFORM_NAME=-iphonesimulator CURRENT_ARCH=arm64 \
    PRODUCT_BUNDLE_IDENTIFIER=com.qiaoborui.ledger.runtime-smoke \
    bash "$ROOT/scripts/build-beancount-ios-resources.sh"
codesign --force --sign - "$APP/Frameworks/Python.framework"
codesign --force --sign - "$APP"
xcrun simctl install booted "$APP"
xcrun simctl launch --console booted com.qiaoborui.ledger.runtime-smoke
CONTAINER="$(xcrun simctl get_app_container booted com.qiaoborui.ledger.runtime-smoke data)"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert len(r)==5 and all(x["passed"] for x in r), r; print("Embedded iOS simulator: all 5 canonical smoke cases passed")' "$CONTAINER/Documents/runtime-smoke.json"
