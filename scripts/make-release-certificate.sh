#!/bin/bash
# Makes Plum's release signing certificate, once, for whoever makes releases.
#
# Releases are signed with it (release.sh), so every release has the same
# designated requirement: Plum's identifier and this certificate. A terminal
# host started by one release takes the next release as its client only
# because of that (HostIdentity in TerminalHost.swift): lose the certificate,
# and the next update ends every running terminal once.
#
# It is self-signed, not from Apple: macOS still asks users to allow the app
# once, as it does for ad-hoc signatures. It goes into a keychain file of its
# own (empty password, readable by you alone), not the login keychain.
# Back that file up with the update key.
set -euo pipefail
KEYCHAIN="${PLUM_RELEASE_KEYCHAIN:-$HOME/.config/plum/release-signing.keychain-db}"
NAME="Plum Release"
[ -e "$KEYCHAIN" ] && { echo "already there: $KEYCHAIN" >&2; exit 1; }
mkdir -p "$(dirname "$KEYCHAIN")"
chmod 700 "$(dirname "$KEYCHAIN")"
WORK="$(mktemp -d)"
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
openssl req -x509 -newkey rsa:3072 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 36500 -config "$WORK/cert.cnf" 2>/dev/null
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" -passout "pass:$PASS" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" -passout "pass:$PASS"
security create-keychain -p "" "$KEYCHAIN"
chmod 600 "$KEYCHAIN"
security unlock-keychain -p "" "$KEYCHAIN"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
# codesign may use the key without asking.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null
security find-identity -p codesigning "$KEYCHAIN" | grep "$NAME"
echo "OK: $KEYCHAIN (back it up)"
