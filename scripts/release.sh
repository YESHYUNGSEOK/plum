#!/bin/bash
# Builds build/Plum.app and packs it as build/Plum-<version>-<arch>.zip.
#
# Without options the app keeps bundle.sh's ad-hoc signature: users have to
# allow it once (README, "Install"). To ship a build macOS opens directly:
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
  codesign --verify --strict --verbose=1 "$APP"
fi

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
if [ -f "$KEY" ]; then
  swift scripts/update-signing.swift sign "$ZIP" "$KEY" > "$ZIP.sig"
else
  echo "warning: no update key at $KEY: copies already out won't install this release themselves" >&2
fi

echo "OK: $ZIP"
shasum -a 256 "$ZIP"
[ -f "$ZIP.sig" ] && echo "OK: $ZIP.sig (upload it with the zip)"
