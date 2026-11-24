#!/bin/bash
# Builds Vendor/GhosttyVt.xcframework (libghostty-vt, macOS slice) from source.
# Pinned: Zig 0.17.0 (sha256 verified) + ghostty tag vt-1.0.1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.tools"
VT_TAG="vt-1.0.1"
VT_COMMIT="108cacb17ed8990840cd14abfce43d8ed8503ca1"
ZIG_VERSION="0.17.0"

case "$(uname -m)" in
  arm64)  ZIG_ARCH="aarch64"; ZIG_SHA="b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a"; ZIG_BIN_SHA="1c5f706db0ed6d55451940f31dc05a6177d05696bc1fa5d853696d04c718b523" ;;
  *) echo "Unsupported CPU: $(uname -m) (its Zig checksum needs adding)" >&2; exit 1 ;;
esac
SRC="$TOOLS/ghostty-src"
OUT="$ROOT/Vendor/GhosttyVt.xcframework"

mkdir -p "$TOOLS"
BUILD_DIR="$(mktemp -d "$TOOLS/build-vt.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
ZIG_DIR="$BUILD_DIR/zig-$ZIG_ARCH-macos-$ZIG_VERSION"
curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-$ZIG_ARCH-macos-$ZIG_VERSION.tar.xz" -o "$BUILD_DIR/zig.tar.xz"
echo "$ZIG_SHA  $BUILD_DIR/zig.tar.xz" | shasum -a 256 -c -
tar -xf "$BUILD_DIR/zig.tar.xz" -C "$BUILD_DIR"
echo "$ZIG_BIN_SHA  $ZIG_DIR/zig" | shasum -a 256 -c -

if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$VT_TAG" https://github.com/ghostty-org/ghostty "$SRC"
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$VT_COMMIT" ] || { echo "Ghostty source does not match pinned commit" >&2; exit 1; }
[ -z "$(git -C "$SRC" -c core.fsmonitor=false status --porcelain --untracked-files=all)" ] || { echo "Ghostty source has local changes" >&2; exit 1; }

export ZIG_GLOBAL_CACHE_DIR="$BUILD_DIR/global-cache"
(cd "$SRC" && "$ZIG_DIR/zig" build -Demit-lib-vt -Demit-xcframework=true -Doptimize=ReleaseFast \
  --cache-dir "$BUILD_DIR/cache" --prefix "$BUILD_DIR/out")

# Keep only the macOS slice; the upstream xcframework also carries iOS slices.
BUILT="$BUILD_DIR/out/lib/ghostty-vt.xcframework/macos-arm64_x86_64"
STAGED="$BUILD_DIR/GhosttyVt.xcframework"
xcodebuild -create-xcframework \
  -library "$BUILT/libghostty-vt.a" -headers "$BUILT/Headers" \
  -output "$STAGED" >/dev/null
if [ -e "$OUT" ]; then
  if ! diff -qr "$STAGED" "$OUT" >/dev/null; then
    BACKUP="$TOOLS/ghostty-vt-backup.$(date +%Y%m%d%H%M%S).$$.xcframework"
    mv "$OUT" "$BACKUP"
    mv "$STAGED" "$OUT" || { mv "$BACKUP" "$OUT"; exit 1; }
    echo "Preserved prior Vendor artifact: $BACKUP"
  fi
else
  mkdir -p "$ROOT/Vendor"
  mv "$STAGED" "$OUT"
fi
if [ -e "$ROOT/Vendor/LICENSE-ghostty" ]; then
  cmp -s "$SRC/LICENSE" "$ROOT/Vendor/LICENSE-ghostty" || { echo "Vendor/LICENSE-ghostty differs from the pinned source" >&2; exit 1; }
else
  cp "$SRC/LICENSE" "$ROOT/Vendor/LICENSE-ghostty"
fi
echo "OK: $OUT"
