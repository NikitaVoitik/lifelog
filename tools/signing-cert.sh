#!/bin/bash
# Makes sure a long-lived, self-signed code-signing identity for Lifelog exists in the login keychain, and prints its
# SHA-1. macOS ties privacy grants (Screen Recording, Accessibility, Input Monitoring) to the app's signing identity:
# sign every build with the same one and the grants survive rebuilds. Apple Development certs expire every year and
# whichever one the keychain lists first can change, so we don't use those for this local-only app.
set -euo pipefail
NAME="${LIFELOG_SIGN_NAME:-Lifelog Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

find_hash() {  # untrusted self-signed identities don't show with -v, so look without it
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | awk -v n="\"$NAME\"" 'index($0, n) { print $2; exit }'
}

h=$(find_hash)
if [ -z "$h" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CFG
  # /usr/bin/openssl is LibreSSL: its PKCS#12 output is what `security import` understands
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/cfg" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
    -passout pass:lifelog -out "$tmp/id.p12" 2>/dev/null
  # -T: codesign may use the key without a keychain prompt on every build
  security import "$tmp/id.p12" -k "$KEYCHAIN" -P lifelog -T /usr/bin/codesign >/dev/null
  h=$(find_hash)
  [ -n "$h" ] || { echo "could not create the '$NAME' signing identity" >&2; exit 1; }
  echo "created signing identity '$NAME' ($h), valid 20 years" >&2
fi
echo "$h"
