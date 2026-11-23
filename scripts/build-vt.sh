#!/bin/bash
# Builds Vendor/GhosttyVt.xcframework (libghostty-vt, macOS slice) from source.
# Pinned: Zig 0.17.0 (sha256 verified) + ghostty tag vt-1.0.1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.tools"
VT_TAG="vt-1.0.1"
ZIG_VERSION="0.17.0"

case "$(uname -m)" in
  arm64)  ZIG_ARCH="aarch64"; ZIG_SHA="b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a" ;;
  *) echo "Unsupported CPU: $(uname -m) (its Zig checksum needs adding)" >&2; exit 1 ;;
esac
ZIG_DIR="$TOOLS/zig-$ZIG_ARCH-macos-$ZIG_VERSION"
SRC="$TOOLS/ghostty-src"
OUT="$ROOT/Vendor/GhosttyVt.xcframework"

mkdir -p "$TOOLS"

if [ ! -x "$ZIG_DIR/zig" ]; then
  curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-$ZIG_ARCH-macos-$ZIG_VERSION.tar.xz" -o "$TOOLS/zig.tar.xz"
  echo "$ZIG_SHA  $TOOLS/zig.tar.xz" | shasum -a 256 -c -
  tar -xf "$TOOLS/zig.tar.xz" -C "$TOOLS"
  rm "$TOOLS/zig.tar.xz"
fi

if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$VT_TAG" https://github.com/ghostty-org/ghostty "$SRC"
fi

BUILT="$SRC/zig-out/lib/ghostty-vt.xcframework/macos-arm64_x86_64"
if [ ! -f "$BUILT/libghostty-vt.a" ]; then
  (cd "$SRC" && "$ZIG_DIR/zig" build -Demit-lib-vt -Demit-xcframework=true -Doptimize=ReleaseFast)
fi

# Keep only the macOS slice; the upstream xcframework also carries iOS slices.
rm -rf "$OUT"
mkdir -p "$ROOT/Vendor"
xcodebuild -create-xcframework \
  -library "$BUILT/libghostty-vt.a" -headers "$BUILT/Headers" \
  -output "$OUT" >/dev/null
cp "$SRC/LICENSE" "$ROOT/Vendor/LICENSE-ghostty"
echo "OK: $OUT"
