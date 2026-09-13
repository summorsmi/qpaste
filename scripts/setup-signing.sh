#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing-common.sh
umask 077

# Keep the identity outside the repository and outside clipboard history storage.
mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qpaste-signing.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ ! -f "$SIGNING_CERT" ]]; then
    # Never silently rotate a partially configured or previously backed-up identity.
    if [[ -n "$(ls -A "$SIGNING_DIR")" ]]; then
        printf 'Signing directory is not empty but certificate.pem is missing. Restore the existing certificate instead of generating a new identity.\n' >&2
        exit 1
    fi
    cat > "$WORK_DIR/certificate.cnf" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = codesign
prompt = no
[subject]
CN = Qpaste Local Code Signing
O = Qpaste Local Development
[codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
    /usr/bin/openssl req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
        -config "$WORK_DIR/certificate.cnf" -keyout "$WORK_DIR/private-key.pem" \
        -out "$WORK_DIR/certificate.pem" 2> "$WORK_DIR/generate.log"
    /usr/bin/openssl rand -base64 48 > "$WORK_DIR/backup-password.txt"
    /usr/bin/openssl pkcs12 -export -inkey "$WORK_DIR/private-key.pem" \
        -in "$WORK_DIR/certificate.pem" -name 'Qpaste Local Code Signing' \
        -descert -passout "file:$WORK_DIR/backup-password.txt" -out "$WORK_DIR/identity-backup.p12"
    cp "$WORK_DIR/certificate.pem" "$WORK_DIR/identity-backup.p12" "$WORK_DIR/backup-password.txt" "$SIGNING_DIR/"
    chmod 600 "$SIGNING_DIR/"*
fi

SIGNING_IDENTITY="$(/usr/bin/openssl x509 -in "$SIGNING_CERT" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//; s/://g')"
if ! /usr/bin/security find-identity -p codesigning "$SIGNING_KEYCHAIN" | /usr/bin/grep -Fq " $SIGNING_IDENTITY "; then
    if [[ ! -f "$SIGNING_DIR/identity-backup.p12" || ! -f "$SIGNING_DIR/backup-password.txt" ]]; then
        printf 'Existing identity is missing from the keychain and its local backup is incomplete. Restore the original identity; do not generate a replacement.\n' >&2
        exit 1
    fi
    # Read the encrypted backup directly; no password in argv or unencrypted export.
    export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/qpaste-clang-cache"
    swift scripts/import-signing-identity.swift "$SIGNING_DIR/identity-backup.p12" \
        "$SIGNING_DIR/backup-password.txt" "$SIGNING_KEYCHAIN"
fi

if ! /usr/bin/security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" | /usr/bin/grep -Fq " $SIGNING_IDENTITY "; then
    # Trust only code signing, in this user's trust domain; do not change SSL trust.
    /usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$SIGNING_KEYCHAIN" "$SIGNING_CERT"
fi
load_signing_identity
printf 'Qpaste signing identity ready: %s\n' "$SIGNING_IDENTITY"
printf 'Private local backup (keep both files protected): %s\n' "$SIGNING_DIR"
