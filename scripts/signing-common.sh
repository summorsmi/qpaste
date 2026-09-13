#!/bin/bash
# Sourced by the local build/install tools; never fall back to ad-hoc signing.
SIGNING_DIR="${QPASTE_SIGNING_DIR:-$HOME/Library/Application Support/QpasteSigning}"
SIGNING_KEYCHAIN="${QPASTE_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
SIGNING_CERT="$SIGNING_DIR/certificate.pem"

load_signing_identity() {
    if [[ ! -f "$SIGNING_CERT" ]]; then
        printf 'Qpaste signing certificate missing. Run: bash scripts/setup-signing.sh\n' >&2
        return 1
    fi
    SIGNING_IDENTITY="$(/usr/bin/openssl x509 -in "$SIGNING_CERT" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//; s/://g')"
    if [[ ! "$SIGNING_IDENTITY" =~ ^[0-9A-F]{40}$ ]]; then
        printf 'Invalid Qpaste signing certificate.\n' >&2
        return 1
    fi
    if ! /usr/bin/security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" | /usr/bin/grep -Fq " $SIGNING_IDENTITY "; then
        printf 'Qpaste signing identity is unavailable or untrusted. Unlock the keychain or run scripts/setup-signing.sh to restore the existing identity.\n' >&2
        return 1
    fi
    SIGNING_REQUIREMENT="identifier \"app.qpaste.mac\" and certificate leaf = H\"$SIGNING_IDENTITY\""
}

verify_qpaste_signature() {
    /usr/bin/codesign --verify --strict --verbose=2 --test-requirement "=$SIGNING_REQUIREMENT" "$1"
}
