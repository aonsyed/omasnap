#!/usr/bin/env bash
# Creates a self-signed code-signing identity named "omasnap-dev" and trusts it
# for code signing. Run ONCE; then build with -DOMASNAP_SIGN_IDENTITY=omasnap-dev
# (or let cmake/MacPackaging.cmake auto-detect it). A stable identity keeps the
# macOS Screen Recording grant valid across rebuilds.
set -euo pipefail

IDENTITY="omasnap-dev"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "omasnap-dev"; then
  echo "\"omasnap-dev\" already exists in your keychain; nothing to do."
  exit 0
fi

echo "Generating self-signed code-signing certificate \"$IDENTITY\"..."
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj "/CN=$IDENTITY" -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1

# Import the private key and certificate directly; macOS pairs them into an
# identity (PKCS#12 output from OpenSSL 3 trips SecKeychainItemImport).
security import "$WORK/key.pem" -k "$HOME/Library/Keychains/login.keychain-db"
security import "$WORK/cert.pem" -k "$HOME/Library/Keychains/login.keychain-db"

echo "Trusting \"$IDENTITY\" for code signing (approve the dialog if one appears)..."
security add-trusted-cert -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" "$WORK/cert.pem"

security find-identity -v -p codesigning | grep "$IDENTITY" && \
  echo "Done. Rebuild with: cmake -DOMASNAP_SIGN_IDENTITY=$IDENTITY ..."
