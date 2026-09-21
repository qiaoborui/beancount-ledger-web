#!/bin/bash
# Build the canonical native parser and regex extension for iOS in-process use.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/server/.build/beancount-ios"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
BISON="${BISON:-$(brew --prefix bison)/bin/bison}"
FLEX="${FLEX:-$(brew --prefix flex)/bin/flex}"
mkdir -p "$BUILD/downloads" "$BUILD/upstream" "$BUILD/generated/beancount/parser" "$BUILD/packages"

fetch() {
    local name="$1" url="$2" hash="$3"
    if [ ! -f "$BUILD/downloads/$name" ]; then
        # Failed transfers remain temporary and cannot poison the next build's
        # cache. Retry transient TLS/HTTP transport errors as well as HTTP 5xx.
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
fetch python.tar.gz https://github.com/beeware/Python-Apple-support/releases/download/3.14-b11/Python-3.14-iOS-support.b11.tar.gz b591f3301bd22a4f423c49c746cac9e55558b909fd14d6eb8327ccc62234ab7b
fetch beancount.tar.gz https://files.pythonhosted.org/packages/eb/21/ed48e671a5e474c620762a7ea9c6b7f402f847d74dd2b73ceb5d2dec79a3/beancount-3.2.3.tar.gz f52c4d237bcb092cbf02a29373d3e59d95349c2828a91491818ae437ee220f74
fetch regex.tar.gz https://files.pythonhosted.org/packages/cc/a9/546676f25e573a4cf00fe8e119b78a37b6a8fe2dc95cda877b30889c9c45/regex-2025.11.3.tar.gz 1fedc720f9bb2494ce31a58a1631f9c82df6a09b49c19517ea5cc280b4541e01
fetch Python-Apple-support-LICENSE https://raw.githubusercontent.com/beeware/Python-Apple-support/3.14-b11/LICENSE 3cfe3712fcd6d53d5055b49d1f2f7e6ad64434b90208bc98c1cbbda126b6dbc6
for archive in python beancount regex; do
    tar -xzf "$BUILD/downloads/$archive.tar.gz" -C "$BUILD/upstream"
done
PYTHON="$BUILD/upstream/Python.xcframework"
BEAN="$BUILD/upstream/beancount-3.2.3"
REGEX="$BUILD/upstream/regex-2025.11.3"
GENERATED="$BUILD/generated/beancount/parser"
"$BISON" --report=itemset --verbose -Wall -Werror -o "$GENERATED/grammar.c" "$BEAN/beancount/parser/grammar.y"
"$FLEX" --outfile="$GENERATED/lexer.c" --header-file="$GENERATED/lexer.h" "$BEAN/beancount/parser/lexer.l"
PARSER_HASH="$(PYTHONPATH="$BEAN/beancount/parser" python3 -c 'from hashsrc import hash_parser_source_files; print(hash_parser_source_files())')"
rsync -a --exclude '*_test.py' --exclude tests --exclude __pycache__ "$BEAN/beancount" "$BUILD/packages/"
rsync -a --exclude tests --exclude __pycache__ "$REGEX/regex" "$BUILD/packages/"
for module in ledger_validator ledger_stream ledger_stream_bridge; do
    cp "$ROOT/App/LedgerMobile/Runtime/$module.py" "$BUILD/packages/"
done
mkdir -p "$BUILD/packages/licenses"
cp "$BEAN/COPYING" "$BUILD/packages/licenses/Beancount-GPL-2.0.txt"
cp "$REGEX/LICENSE.txt" "$BUILD/packages/licenses/regex.txt"
cp "$PYTHON/lib/python3.14/LICENSE.txt" "$BUILD/packages/licenses/CPython.txt"
cp "$BUILD/downloads/Python-Apple-support-LICENSE" "$BUILD/packages/licenses/Python-Apple-support.txt"
cp "$ROOT/App/LedgerMobile/Runtime/THIRD_PARTY.md" "$BUILD/packages/licenses/THIRD_PARTY.md"

build_arch() {
    local sdk="$1" arch="$2" slice="$3" target="$4"
    local out="$BUILD/$sdk-$arch"
    local sysroot
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    mkdir -p "$out/objects" "$out/Headers"
    local flags=(-target "$target" -isysroot "$sysroot" -O2 -fPIC
        -I"$PYTHON/$slice/include/python3.14" -I"$PYTHON/$slice/Python.framework/Headers"
        -I"$BEAN" -I"$BUILD/generated" -I"$REGEX/src"
        -DPARSER_SOURCE_HASH="$PARSER_HASH" -DBEANCOUNT_VERSION=3.2.3)
    local sources=("$BEAN/beancount/parser/decimal.c" "$BEAN/beancount/parser/parser.c"
        "$BEAN/beancount/parser/tokens.c" "$GENERATED/lexer.c" "$GENERATED/grammar.c"
        "$REGEX/src/_regex.c" "$REGEX/src/_regex_unicode.c"
        "$ROOT/App/LedgerMobile/Runtime/BeancountRuntime.c")
    local objects=()
    for source in "${sources[@]}"; do
        local object="$out/objects/$(basename "$source" .c).o"
        xcrun --sdk "$sdk" clang "${flags[@]}" -c "$source" -o "$object"
        objects+=("$object")
    done
    xcrun libtool -static -o "$out/libBeancountRuntime.a" "${objects[@]}"
    cp "$ROOT/App/LedgerMobile/Runtime/BeancountRuntime.h" "$out/Headers/"
    cp "$ROOT/App/LedgerMobile/Runtime/module.modulemap" "$out/Headers/"
}
build_arch iphoneos arm64 ios-arm64 arm64-apple-ios17.0
build_arch iphonesimulator arm64 ios-arm64_x86_64-simulator arm64-apple-ios17.0-simulator
build_arch iphonesimulator x86_64 ios-arm64_x86_64-simulator x86_64-apple-ios17.0-simulator
mkdir -p "$BUILD/iphonesimulator-universal"
xcrun lipo -create "$BUILD/iphonesimulator-arm64/libBeancountRuntime.a" "$BUILD/iphonesimulator-x86_64/libBeancountRuntime.a" -output "$BUILD/iphonesimulator-universal/libBeancountRuntime.a"
# xcodebuild requires a fresh destination. Only this reproducible generated
# artifact is replaced; downloaded sources and other build outputs are retained.
if [ -d "$BUILD/BeancountRuntime.xcframework" ]; then
    rm -r "$BUILD/BeancountRuntime.xcframework"
fi
xcodebuild -create-xcframework \
    -library "$BUILD/iphoneos-arm64/libBeancountRuntime.a" -headers "$BUILD/iphoneos-arm64/Headers" \
    -library "$BUILD/iphonesimulator-universal/libBeancountRuntime.a" -headers "$BUILD/iphonesimulator-arm64/Headers" \
    -output "$BUILD/BeancountRuntime.xcframework"
echo "Built $BUILD/BeancountRuntime.xcframework"
