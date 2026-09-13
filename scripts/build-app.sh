#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing-common.sh
load_signing_identity
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/qpaste-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/qpaste-swift-cache"
swift build -c release --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)"
mkdir -p dist
WORK_DIR="$(mktemp -d "$PWD/dist/.build-app.XXXXXX")"
cleanup() {
    if [[ -e "$WORK_DIR/previous.app" && ! -e "$PWD/dist/Qpaste.app" ]]; then
        mv "$WORK_DIR/previous.app" "$PWD/dist/Qpaste.app" || return
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
APP_DIR="$WORK_DIR/Qpaste.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/Qpaste" "$APP_DIR/Contents/MacOS/Qpaste"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
swift scripts/make-icon.swift "$APP_DIR/Contents/Resources"
codesign --force --sign "$SIGNING_IDENTITY" --keychain "$SIGNING_KEYCHAIN" \
    --timestamp=none --identifier app.qpaste.mac \
    --requirements "=designated => $SIGNING_REQUIREMENT" "$APP_DIR"
verify_qpaste_signature "$APP_DIR"
# Publish only a completely signed bundle; do not overwrite a running executable.
if [[ -e dist/Qpaste.app ]]; then mv dist/Qpaste.app "$WORK_DIR/previous.app"; fi
if ! mv "$APP_DIR" dist/Qpaste.app; then
    if [[ -e "$WORK_DIR/previous.app" ]]; then mv "$WORK_DIR/previous.app" dist/Qpaste.app; fi
    exit 1
fi
printf 'Built with stable signing: %s/dist/Qpaste.app\n' "$PWD"
