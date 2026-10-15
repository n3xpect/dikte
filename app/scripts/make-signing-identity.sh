#!/usr/bin/env bash
# Create a self-signed code-signing identity in the login keychain (one time).
# A stable identity keeps the app's designated requirement constant, so macOS does not
# ask for microphone permission again after every rebuild. Remove with:
#   security delete-identity -c "Dikte Local Signing" ~/Library/Keychains/login.keychain-db
set -euo pipefail
NAME="${1:-Dikte Local Signing}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<EOF
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
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="dikte-$(openssl rand -hex 8)"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" \
  -T /usr/bin/codesign >/dev/null
echo "Oluşturuldu: $NAME"
security find-identity -p codesigning | grep "$NAME" || true
