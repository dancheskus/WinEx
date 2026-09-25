#!/bin/bash
# The code-signing certificate "WinEx Signing": local builds (build.sh) and GitHub releases are
# all signed with it.
#
# Why: macOS ties privacy permissions (Full Disk Access, Desktop / Documents / Downloads, network
# volumes) to the app's signature. An ad-hoc signature changes with every build, so every update
# asked again; with one certificate every version is the same app to macOS.
#
#   scripts/setup-signing.sh              create the certificate (once) and put it in the keychain
#   scripts/setup-signing.sh file.p12     import an existing one (another Mac) — asks for its password
#
# The certificate and its password are kept in ~/.winex-signing — back them up (a password
# manager): a new certificate means every user grants the permissions once more.
set -euo pipefail
NAME="WinEx Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
STORE="$HOME/.winex-signing"
P12="$STORE/WinEx-signing.p12"
PASSFILE="$STORE/password"

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

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "«${NAME}» уже в связке ключей"
else
  # -T: codesign may use the key without asking every time
  security import "$P12" -k "$KEYCHAIN" -P "$(cat "$PASSFILE")" -T /usr/bin/codesign >/dev/null
  echo "«${NAME}» добавлен в связку ключей «вход»"
fi
