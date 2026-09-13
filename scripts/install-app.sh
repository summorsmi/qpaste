#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing-common.sh
load_signing_identity
verify_qpaste_signature "$PWD/dist/Qpaste.app"

APP_DIR="/Applications/Qpaste.app"
WORK_DIR="$(mktemp -d /Applications/.qpaste-install.XXXXXX)"
cleanup() {
    if [[ -e "$WORK_DIR/previous.app" && ! -e "$APP_DIR" ]]; then
        mv "$WORK_DIR/previous.app" "$APP_DIR" || return
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
ditto "$PWD/dist/Qpaste.app" "$WORK_DIR/Qpaste.app"
verify_qpaste_signature "$WORK_DIR/Qpaste.app"

# Ask all instances to quit normally, allowing pending history writes to finish.
# Refuse to replace the app if an instance does not quit; never force-kill it.
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/qpaste-clang-cache"
swift - <<'SWIFT'
import AppKit
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "app.qpaste.mac")
for application in applications { application.terminate() }
let deadline = Date().addingTimeInterval(10)
while applications.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
if applications.contains(where: { !$0.isTerminated }) {
    fputs("Qpaste did not quit. Close it normally, then run the installer again.\n", stderr)
    exit(1)
}
SWIFT

if [[ -e "$APP_DIR" ]]; then
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")" != app.qpaste.mac ]]; then
        printf 'Refusing to replace an unrelated application at %s\n' "$APP_DIR" >&2
        exit 1
    fi
    mv "$APP_DIR" "$WORK_DIR/previous.app"
fi
if ! mv "$WORK_DIR/Qpaste.app" "$APP_DIR"; then
    if [[ -e "$WORK_DIR/previous.app" ]]; then mv "$WORK_DIR/previous.app" "$APP_DIR"; fi
    exit 1
fi
open "$APP_DIR"
printf 'Installed and opened: %s\n' "$APP_DIR"
