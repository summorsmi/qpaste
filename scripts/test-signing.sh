#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing-common.sh
load_signing_identity
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qpaste-signing-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# Two different executable payloads, neither is launched or registered with TCC.
for version in 1 2; do
    app="$WORK_DIR/v$version.app"
    mkdir -p "$app/Contents/MacOS"
    cp Resources/Info.plist "$app/Contents/Info.plist"
    printf 'int main(void) { return %s; }\n' "$version" > "$WORK_DIR/main.c"
    xcrun clang "$WORK_DIR/main.c" -o "$app/Contents/MacOS/Qpaste"
    codesign --force --sign "$SIGNING_IDENTITY" --keychain "$SIGNING_KEYCHAIN" \
        --timestamp=none --identifier app.qpaste.mac \
        --requirements "=designated => $SIGNING_REQUIREMENT" "$app"
    verify_qpaste_signature "$app"
    codesign -dr - "$app" 2>/dev/null > "$WORK_DIR/requirement-$version.txt"
    codesign -dv --verbose=4 "$app" 2> "$WORK_DIR/signature-$version.txt"
done
cmp "$WORK_DIR/requirement-1.txt" "$WORK_DIR/requirement-2.txt"
old_requirement="$(sed -n 's/^designated => //p' "$WORK_DIR/requirement-1.txt")"
[[ -n "$old_requirement" ]]
codesign --verify --strict --test-requirement "=$old_requirement" "$WORK_DIR/v2.app"
hash1="$(sed -n 's/^CDHash=//p' "$WORK_DIR/signature-1.txt")"
hash2="$(sed -n 's/^CDHash=//p' "$WORK_DIR/signature-2.txt")"
[[ -n "$hash1" && -n "$hash2" && "$hash1" != "$hash2" ]]
printf 'PASS: changed executable/hash preserves identity and satisfies the previous version requirement.\n'

ditto "$WORK_DIR/v2.app" "$WORK_DIR/adhoc.app"
codesign --force --sign - --identifier app.qpaste.mac \
    --requirements "=designated => $SIGNING_REQUIREMENT" "$WORK_DIR/adhoc.app"
if verify_qpaste_signature "$WORK_DIR/adhoc.app" 2> "$WORK_DIR/negative.log"; then
    printf 'FAIL: accepted an ad-hoc signature without the pinned certificate.\n' >&2
    exit 1
fi
printf 'PASS: copying the identifier and requirement without the certificate cannot impersonate Qpaste.\n'

printf 'tampered' >> "$WORK_DIR/v2.app/Contents/Info.plist"
if verify_qpaste_signature "$WORK_DIR/v2.app" 2> "$WORK_DIR/tampered.log"; then
    printf 'FAIL: accepted modified bundle contents.\n' >&2
    exit 1
fi
printf 'PASS: modified signed contents are rejected.\n'

mkdir "$WORK_DIR/missing"
if QPASTE_SIGNING_DIR="$WORK_DIR/missing" bash scripts/build-app.sh > "$WORK_DIR/missing.log" 2>&1; then
    printf 'FAIL: build succeeded without the signing certificate.\n' >&2
    exit 1
fi
grep -q 'certificate missing' "$WORK_DIR/missing.log"
printf 'PASS: missing certificate stops the build without an ad-hoc fallback.\n'
