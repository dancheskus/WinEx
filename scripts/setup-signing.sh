#!/bin/bash
# Creates a local self-signed code-signing certificate "WinEx Local Signing" in the login keychain.
#
# Why: an ad-hoc signature changes with every build, and macOS ties privacy permissions (Full Disk
# Access, Desktop / Documents / Downloads, network volumes) to the signature — so each rebuild
# asked for them again. Signed with this certificate, every build is the same app to macOS.
#
# Local only: the certificate never leaves this Mac. Remove it in Keychain Access if not needed.
set -euo pipefail
NAME="WinEx Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "«${NAME}» already exists"
  exit 0
fi

# The system LibreSSL: its .p12 is the format `security import` understands (Homebrew's OpenSSL 3 isn't)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
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
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout "pass:$PASS" 2>/dev/null
# -T: codesign may use the key without asking every time
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created «${NAME}» in the login keychain"
