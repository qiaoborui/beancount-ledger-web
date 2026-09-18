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
# The application-owned bridge changes independently of compiled extensions.
# Always package its current source, including incremental Xcode builds.
install -m 644 "$ROOT/App/LedgerMobile/Runtime/ledger_validator.py" \
    "$CODESIGNING_FOLDER_PATH/python/app_packages/ledger_validator.py"

# ---------------------------------------------------------------------------
# Prune the embedded Python environment to keep only what Beancount needs.
# The full CPython stdlib + test suite adds ~80 MB uncompressed (~40 MB in the
# IPA). Beancount and its ledger_validator bridge use a small subset.
# ---------------------------------------------------------------------------
PYTHON_LIB="$CODESIGNING_FOLDER_PATH/python/lib"
PYTHON_VER=$(ls -1 "$PYTHON_LIB" | grep -E "^python3\.[0-9]+$" | head -1)

if [ -n "$PYTHON_VER" ]; then
    STDLIB="$PYTHON_LIB/$PYTHON_VER"
    echo "Pruning unused stdlib modules from $STDLIB ..."

    # 1. Remove the CPython test suite (largest single item, ~36 MB).
    rm -rf "$STDLIB/test"

    # 2. Remove stdlib packages that are never used on iOS.
    PRUNE_DIRS=(
        idlelib          # IDLE editor GUI
        tkinter          # Tk GUI bindings
        turtledemo       # Turtle graphics demos
        ensurepip        # pip bootstrapper
        pydoc_data       # pydoc HTML templates
        lib2to3          # Python 2→3 converter
        _pyrepl          # REPL readline alternative
        xmlrpc           # XML-RPC client/server
        doctest          # doctest framework (not needed at runtime)
        sqlite3          # sqlite3 pure-Python layer (unused by beancount)
        curses           # terminal UI (unused on iOS)
        dbm              # DBM database (unused)
        multiprocessing  # not available on iOS
        concurrent       # relies on multiprocessing
        venv             # virtual environments
        distutils        # deprecated packaging
        tomllib          # TOML parser (unused by beancount)
        _osx_support.py  # macOS compiler support
        turtle.py        # turtle graphics
        pydoc.py         # documentation browser
        antigravity.py   # Easter egg
        this.py          # Easter egg
    )
    for target in "${PRUNE_DIRS[@]}"; do
        rm -rf "$STDLIB/$target"
    done

    # 3. Remove .pyi type stubs (not needed at runtime).
    find "$STDLIB" -name "*.pyi" -delete 2>/dev/null || true

    echo "Stdlib pruning complete."
fi

# 4. Remove CPython test extension frameworks from Frameworks/.
#    These are only used by CPython's own test suite.
FRAMEWORKS_DIR="$CODESIGNING_FOLDER_PATH/Frameworks"
if [ -d "$FRAMEWORKS_DIR" ]; then
    PRUNE_FRAMEWORKS=(
        _ctypes_test
        _testbuffer
        _testcapi
        _testclinic
        _testclinic_limited
        _testimportmultiple
        _testinternalcapi
        _testlimitedcapi
        _testmultiphase
        _testsinglephase
        _xxtestfuzz
        xxlimited
        xxlimited_35
        xxsubtype
        _ssl
        _hashlib
        _zstd
        _lzma
        _bz2
        _sqlite3
    )
    for fw in "${PRUNE_FRAMEWORKS[@]}"; do
        rm -rf "$FRAMEWORKS_DIR/$fw.framework"
    done

    # Also remove .fwork references in lib-dynload so Python doesn't try to load them.
    DYNLOAD="$PYTHON_LIB/$PYTHON_VER/lib-dynload"
    if [ -d "$DYNLOAD" ]; then
        for fw in "${PRUNE_FRAMEWORKS[@]}"; do
            rm -f "$DYNLOAD/$fw"*.fwork 2>/dev/null || true
        done
    fi

    remaining=$(ls -1d "$FRAMEWORKS_DIR"/*.framework 2>/dev/null | wc -l | tr -d ' ')
    echo "Pruned ${#PRUNE_FRAMEWORKS[@]} test frameworks; $remaining frameworks remain."
fi
