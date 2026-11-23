#!/bin/bash
# Builds build/Plum.app (release, ad-hoc signed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -d Vendor/GhosttyVt.xcframework ] || ./scripts/build-vt.sh
swift build -c release

APP="$ROOT/build/Plum.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Plum" "$APP/Contents/MacOS/Plum"
strip -x "$APP/Contents/MacOS/Plum"
cp Vendor/LICENSE-ghostty "$APP/Contents/Resources/LICENSE-ghostty.txt"
# Resources/AppIcon.icns is prebuilt by scripts/make-icon.sh.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# UI text: Korean is the source language, English is translated. Other
# languages fall back to English (the development region below).
cp -R Resources/en.lproj Resources/ko.lproj "$APP/Contents/Resources/"

# Precompile the shader so the app doesn't run the Metal compiler at launch.
if xcrun -sdk macosx -f metal >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  "$APP/Contents/MacOS/Plum" --print-shader > "$TMP/shader.metal"
  xcrun -sdk macosx metal -c "$TMP/shader.metal" -o "$TMP/shader.air"
  xcrun -sdk macosx metallib "$TMP/shader.air" -o "$APP/Contents/Resources/default.metallib"
  rm -rf "$TMP"
else
  echo "No metal compiler; the shaders will be compiled at launch." >&2
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Plum</string>
    <key>CFBundleDisplayName</key><string>Plum</string>
    <key>CFBundleIdentifier</key><string>dev.plum.Plum</string>
    <key>CFBundleExecutable</key><string>Plum</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.3</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMultipleInstancesProhibited</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null
echo "OK: $APP ($(du -sh "$APP" | cut -f1))"
