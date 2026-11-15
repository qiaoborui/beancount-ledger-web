#!/bin/bash
# Build the App's built-in Linux: the iSH AArch64 engine (lollipopkit/ShellBox,
# prebuilt static libraries of a pinned release) with the App's own glue in
# App/LedgerMobile/Linux, as LedgerLinux.xcframework, and fetch the Alpine
# mini root filesystem the App bundles and unpacks on first use.
#
# The engine has no x86_64 build, so the x86_64 simulator slice holds only the
# glue's stubs and reports the engine as unavailable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/server/.build/linux-ios"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
GLUE="$ROOT/App/LedgerMobile/Linux"

ENGINE_TAG=v1.0.55
ENGINE_COMMIT=5dfc962fe5e03fe5bc6b869b8744312ebe6af627
ENGINE_DEVICE_SHA256=1546d78c660c15c083fc69753a1725f85e00a4d681435dc115427609c64d6b5e
ENGINE_SIMULATOR_SHA256=d0805eef5facfb9eb3f03c0552470131dce54ea73c3ffe45cd9381d129b3decc
ALPINE_VERSION=3.22.8
ALPINE_BRANCH=v3.22
# From the release's alpine-minirootfs-3.22.8-aarch64.tar.gz.sha256. Emptied,
# the build checks against that file fetched from the mirror and prints it.
ALPINE_SHA256="${ALPINE_SHA256-36091efacd083c1cf5a8c837272530bff4fc72db1fbfdef559f52de0d890bca4}"

mkdir -p "$BUILD/downloads" "$BUILD/upstream"

fetch() {
    local name="$1" url="$2" hash="$3"
    if [ ! -f "$BUILD/downloads/$name" ]; then
        local partial
        partial="$(mktemp "$BUILD/downloads/$name.XXXXXX")"
        if ! curl --fail --location --retry 3 --retry-all-errors \
            --connect-timeout 20 --max-time 600 "$url" -o "$partial"; then
            rm -f "$partial"
            return 1
        fi
        if ! echo "$hash  $partial" | shasum -a 256 --check; then
            rm -f "$partial"
            return 1
        fi
        mv "$partial" "$BUILD/downloads/$name"
    fi
    echo "$hash  $BUILD/downloads/$name" | shasum -a 256 --check
}

# Engine headers: the glue is compiled against the revision the libraries
# were built from.
ENGINE="$BUILD/upstream/ShellBox"
if [ ! -d "$ENGINE/.git" ] || [ "$(git -C "$ENGINE" rev-parse HEAD)" != "$ENGINE_COMMIT" ]; then
    rm -rf "$ENGINE"
    git clone --quiet --depth 1 --branch "$ENGINE_TAG" https://github.com/lollipopkit/ShellBox.git "$ENGINE"
fi
if [ "$(git -C "$ENGINE" rev-parse HEAD)" != "$ENGINE_COMMIT" ]; then
    echo "ShellBox $ENGINE_TAG is not $ENGINE_COMMIT" >&2
    exit 1
fi
release="https://github.com/lollipopkit/ShellBox/releases/download/$ENGINE_TAG"
fetch ish-ios-arm64.tar.gz "$release/ish-ios-arm64.tar.gz" "$ENGINE_DEVICE_SHA256"
fetch ish-iossim-arm64.tar.gz "$release/ish-iossim-arm64.tar.gz" "$ENGINE_SIMULATOR_SHA256"

# Alpine mini root filesystem.
alpine_name="alpine-minirootfs-$ALPINE_VERSION-aarch64.tar.gz"
alpine_url="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/releases/aarch64/$alpine_name"
if [ -z "$ALPINE_SHA256" ]; then
    ALPINE_SHA256="$(curl --fail --location --retry 3 --retry-all-errors --connect-timeout 20 \
        --max-time 60 "$alpine_url.sha256" | awk '{print $1}')"
    [[ "$ALPINE_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "No sha256 for $alpine_name" >&2; exit 1; }
    echo "Alpine $ALPINE_VERSION aarch64 sha256: $ALPINE_SHA256"
fi
fetch "$alpine_name" "$alpine_url" "$ALPINE_SHA256"
install -m 644 "$BUILD/downloads/$alpine_name" "$BUILD/alpine-minirootfs.tar.gz"
mkdir -p "$BUILD/licenses"
cp "$ENGINE/LICENSE.md" "$BUILD/licenses/ShellBox-LICENSE.md"
cp "$ENGINE/LICENSE.IOS" "$BUILD/licenses/ShellBox-LICENSE.IOS"

build_slice() {
    local sdk="$1" arch="$2" target="$3" engine_archive="$4"
    local out="$BUILD/$sdk-$arch"
    rm -rf "$out"
    mkdir -p "$out/objects" "$out/Headers" "$out/engine"
    local sysroot
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    local flags=(-target "$target" -isysroot "$sysroot" -O2 -fPIC -std=gnu11 -Wall -I"$GLUE")
    local libraries=()
    if [ -n "$engine_archive" ]; then
        flags+=(-DLEDGER_LINUX_ENGINE=1 -DGUEST_ARM64=1 -DLOG_HANDLER_DPRINTF=1
            -I"$ENGINE" -I"$ENGINE/vdso/arm64")
        tar -xzf "$BUILD/downloads/$engine_archive" -C "$out/engine"
        libraries=("$out/engine/libish.a" "$out/engine/libish_emu.a" "$out/engine/libfakefs.a")
    fi
    xcrun --sdk "$sdk" clang "${flags[@]}" -c "$GLUE/LedgerLinux.c" -o "$out/objects/LedgerLinux.o"
    xcrun libtool -static -o "$out/libLedgerLinux.a" "$out/objects/LedgerLinux.o" ${libraries[@]+"${libraries[@]}"}
    cp "$GLUE/LedgerLinux.h" "$GLUE/module.modulemap" "$out/Headers/"
}
build_slice iphoneos arm64 arm64-apple-ios17.0 ish-ios-arm64.tar.gz
build_slice iphonesimulator arm64 arm64-apple-ios17.0-simulator ish-iossim-arm64.tar.gz
build_slice iphonesimulator x86_64 x86_64-apple-ios17.0-simulator ""
mkdir -p "$BUILD/iphonesimulator-universal"
xcrun lipo -create "$BUILD/iphonesimulator-arm64/libLedgerLinux.a" "$BUILD/iphonesimulator-x86_64/libLedgerLinux.a" \
    -output "$BUILD/iphonesimulator-universal/libLedgerLinux.a"
if [ -d "$BUILD/LedgerLinux.xcframework" ]; then
    rm -r "$BUILD/LedgerLinux.xcframework"
fi
xcodebuild -create-xcframework \
    -library "$BUILD/iphoneos-arm64/libLedgerLinux.a" -headers "$BUILD/iphoneos-arm64/Headers" \
    -library "$BUILD/iphonesimulator-universal/libLedgerLinux.a" -headers "$BUILD/iphonesimulator-arm64/Headers" \
    -output "$BUILD/LedgerLinux.xcframework"
echo "Built $BUILD/LedgerLinux.xcframework and $BUILD/alpine-minirootfs.tar.gz"
