#!/bin/bash
# Builds build/Plum.app and packs it as build/Plum-<version>-<arch>.zip.
#
# It is signed with Plum's release certificate (make-release-certificate.sh,
# in PLUM_RELEASE_KEYCHAIN, by default ~/.config/plum/release-signing.keychain-db):
# every release then has the same designated requirement, which is what lets
# the terminal hosts of the release before take this one (HostIdentity).
# Users still allow it once (README, "Install"). The release's cdhash is added
# to Resources/released-code-hashes.txt: commit that with the release, so the
# next one attaches to this one's hosts.
#
# To ship a build macOS opens directly instead (this changes the designated
# requirement: the update to it ends running terminals once):
#   PLUM_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"  signs with the hardened runtime
#   PLUM_NOTARY_PROFILE=<profile>  then notarizes and staples the ticket
#                                  (profile made once with `xcrun notarytool store-credentials`)
#
# Copies already out install a release themselves only with its signature,
# <zip>.sig, made here with the update key (PLUM_UPDATE_KEY, by default
# ~/.config/plum/update-signing-key; scripts/update-signing.swift). Upload
# both files to the GitHub release; the version is the one in bundle.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./scripts/bundle.sh
APP=build/Plum.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="build/Plum-$VERSION-$(uname -m).zip"

if [ -n "${PLUM_SIGN_IDENTITY:-}" ]; then
  # A secure timestamp is required for notarization; an ad-hoc identity ("-") can't have one.
  TIMESTAMP=$([ "$PLUM_SIGN_IDENTITY" = "-" ] && echo "--timestamp=none" || echo "--timestamp")
  codesign --force --options runtime "$TIMESTAMP" --sign "$PLUM_SIGN_IDENTITY" "$APP"
else
  KEYCHAIN="${PLUM_RELEASE_KEYCHAIN:-$HOME/.config/plum/release-signing.keychain-db}"
  [ -f "$KEYCHAIN" ] || { echo "no release certificate at $KEYCHAIN (scripts/make-release-certificate.sh); without it the update to this release ends running terminals" >&2; exit 1; }
  IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" | sed -n 's/.*) \([0-9A-F]\{40\}\) "Plum Release".*/\1/p' | head -1)"
  [ -n "$IDENTITY" ] || { echo "no \"Plum Release\" identity in $KEYCHAIN" >&2; exit 1; }
  # codesign finds identities only in the search list: add the keychain for the signing, then put the list back.
  SEARCH=()
  while IFS= read -r line; do SEARCH+=("$(echo "$line" | sed 's/^ *"\(.*\)"$/\1/')"); done < <(security list-keychains -d user)
  security unlock-keychain -p "" "$KEYCHAIN"
  security list-keychains -d user -s "${SEARCH[@]}" "$KEYCHAIN"
  trap 'security list-keychains -d user -s "${SEARCH[@]}"' EXIT
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
  security list-keychains -d user -s "${SEARCH[@]}"
  trap - EXIT
fi
codesign --verify --strict --verbose=1 "$APP"
# What lets the hosts of the release before take this one: a certificate, not a cdhash.
codesign -d -r- "$APP" 2>&1 | grep -q "certificate leaf" || { echo "not signed with a certificate: the update to it would end running terminals" >&2; exit 1; }

pack() {
  rm -f "$ZIP"
  # ditto keeps the bundle's symlinks, permissions and signature intact.
  ditto -c -k --keepParent "$APP" "$ZIP"
}
pack

if [ -n "${PLUM_NOTARY_PROFILE:-}" ]; then
  [ -n "${PLUM_SIGN_IDENTITY:-}" ] && [ "$PLUM_SIGN_IDENTITY" != "-" ] || { echo "notarizing needs PLUM_SIGN_IDENTITY (a Developer ID)" >&2; exit 1; }
  xcrun notarytool submit "$ZIP" --keychain-profile "$PLUM_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  pack # again, with the ticket stapled inside
fi

KEY="${PLUM_UPDATE_KEY:-$HOME/.config/plum/update-signing-key}"
rm -f "$ZIP.sig" # never one left from an earlier build
if [ -f "$KEY" ]; then
  swift scripts/update-signing.swift sign "$ZIP" "$KEY" > "$ZIP.sig"
else
  echo "warning: no update key at $KEY: copies already out won't install this release themselves" >&2
fi

# The next release attaches to this one's terminal hosts by this cdhash.
HASH="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p')"
LIST=Resources/released-code-hashes.txt
grep -v " $VERSION\$" "$LIST" > "$LIST.new" || true
echo "$HASH $VERSION" >> "$LIST.new"
mv "$LIST.new" "$LIST"
echo "OK: $HASH $VERSION added to $LIST (commit it with the release)"

echo "OK: $ZIP"
shasum -a 256 "$ZIP"
if [ -f "$ZIP.sig" ]; then echo "OK: $ZIP.sig (upload it with the zip)"; fi
