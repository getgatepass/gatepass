#!/bin/bash
# Creates a self-signed code-signing identity "GatePass Self-Signed" in the login keychain.
#
# Why: ad-hoc signatures change on every build, so macOS treats each new gatepass-engine as a
# different program and asks for the Keychain password. A stable certificate keeps the same
# "designated requirement" across builds and updates, so the prompt never appears.
# The certificate is NOT trusted system-wide; it only gives the app a stable identity.
# Keep it private and back it up (Keychain Access → export) — releases must use the same one.
set -euo pipefail

NAME="${1:-GatePass Self-Signed}"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "✓ \"$NAME\" already exists"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OPENSSL=/usr/bin/openssl   # LibreSSL: its .p12 format is the one `security import` accepts
PASS="$(uuidgen)"

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "✓ Created code-signing identity \"$NAME\""
