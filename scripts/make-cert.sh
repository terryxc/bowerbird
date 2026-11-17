#!/bin/zsh
# Creates the local self-signed code-signing certificate "Bowerbird Dev". Only needs to run once.
# Purpose: gives codesign a stable identity so the Accessibility permission isn't lost on every rebuild.
set -euo pipefail
NAME="Bowerbird Dev"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Certificate already exists: $NAME"
  exit 0
fi
TMP=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"
# OpenSSL 3 needs -legacy to write a .p12 the keychain can read; the LibreSSL that ships with macOS
# writes that format already and doesn't know the flag.
LEGACY=()
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY=(-legacy); fi
openssl pkcs12 -export "${LEGACY[@]}" -out "$TMP/dev.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout pass:bowerbird -name "$NAME"
security import "$TMP/dev.p12" -k ~/Library/Keychains/login.keychain-db -P bowerbird \
  -T /usr/bin/codesign -T /usr/bin/security
# Trust this certificate for code signing. The system may ask for your password once here.
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"
rm -rf "$TMP"
security find-identity -v -p codesigning | grep "$NAME"
