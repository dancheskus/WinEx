#!/bin/bash
# The code-signing certificate "WinEx Signing": local builds (build.sh) and GitHub releases are
# all signed with it.
#
# Why: macOS ties privacy permissions (Full Disk Access, Desktop / Documents / Downloads, network
# volumes) to the app's signature. An ad-hoc signature changes with every build, so every update
# asked again; with one certificate every version is the same app to macOS.
#
#   scripts/setup-signing.sh              create the certificate (once) and set up signing
#   scripts/setup-signing.sh file.p12     import an existing one (another Mac) — asks for its password
#
# The identity lives in its own keychain (~/.winex-signing/signing.keychain-db) with a generated
# password, like on the CI: that lets this script allow codesign to use the key ("apple-tool:"
# partition), so builds never ask for the login keychain password.
#
# ~/.winex-signing keeps the certificate (.p12) and the passwords — back up the .p12 and its
# password (a password manager): a new certificate means every user grants permissions once more.
set -euo pipefail
NAME="WinEx Signing"
STORE="$HOME/.winex-signing"
P12="$STORE/WinEx-signing.p12"
PASSFILE="$STORE/password"
KEYCHAIN="$STORE/signing.keychain-db"
KEYCHAIN_PASSFILE="$STORE/keychain-password"
LOGIN="$HOME/Library/Keychains/login.keychain-db"

mkdir -p "$STORE"
chmod 700 "$STORE"

if [ $# -ge 1 ]; then
  cp "$1" "$P12"
  read -r -s -p "Пароль от $1: " PASS; echo
  printf '%s' "$PASS" > "$PASSFILE"
elif [ ! -f "$P12" ]; then
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
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
  /usr/bin/openssl rand -hex 24 | tr -d '\n' > "$PASSFILE"
  /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$P12" -passout "file:$PASSFILE" 2>/dev/null
  echo "Создан сертификат «${NAME}»: $P12 (пароль — $PASSFILE). Сохраните обе вещи в надёжном месте."
fi
chmod 600 "$P12" "$PASSFILE"

# The signing keychain, with a password only this folder knows
if [ ! -f "$KEYCHAIN" ]; then
  /usr/bin/openssl rand -hex 24 | tr -d '\n' > "$KEYCHAIN_PASSFILE"
  chmod 600 "$KEYCHAIN_PASSFILE"
  security create-keychain -p "$(cat "$KEYCHAIN_PASSFILE")" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"   # no auto-lock
fi
security unlock-keychain -p "$(cat "$KEYCHAIN_PASSFILE")" "$KEYCHAIN"
if ! security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  security import "$P12" -k "$KEYCHAIN" -P "$(cat "$PASSFILE")" -T /usr/bin/codesign >/dev/null
fi
# codesign may use the key without a prompt
security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$KEYCHAIN_PASSFILE")" "$KEYCHAIN" >/dev/null

# In the search list, so codesign finds the identity
if ! security list-keychains -d user | grep -q "$KEYCHAIN"; then
  security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KEYCHAIN"
fi

# An older setup kept the identity in the login keychain — that one asks for the login password
while security find-certificate -c "$NAME" "$LOGIN" >/dev/null 2>&1; do
  security delete-identity -c "$NAME" "$LOGIN" >/dev/null 2>&1 || break
done
echo "Подпись «${NAME}» готова: $KEYCHAIN"
