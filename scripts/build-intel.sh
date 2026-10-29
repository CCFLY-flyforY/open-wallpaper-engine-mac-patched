#!/bin/bash
#
# build-intel.sh — build Open Wallpaper Engine as an x86_64 app on an Intel Mac,
# without Xcode. Only the Command Line Tools are needed.
#
#   ./scripts/build-intel.sh                 # -> ~/Desktop/Open-Wallpaper-Engine-x86_64.app
#   ./scripts/build-intel.sh /path/out.app   # custom output
#   TARGET=x86_64-apple-macos13.0 ./scripts/build-intel.sh    # older deployment target
#
# Why this exists: the prebuilt macOS builds circulating online are arm64-only, and an
# Intel Mac refuses them with `Bad CPU type in executable`. The Xcode project also pins a
# signing team. This script produces an x86_64 binary and an ad-hoc signed bundle instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$HOME/Desktop/Open-Wallpaper-Engine-x86_64.app}"
SOURCES_DIR="$ROOT/Open Wallpaper Engine"
TARGET="${TARGET:-x86_64-apple-macos$(sw_vers -productVersion | cut -d. -f1).0}"
BUILD="$ROOT/.build-intel"
BIN="$BUILD/Open Wallpaper Engine"

command -v swiftc >/dev/null || { echo "swiftc not found — install the Command Line Tools: xcode-select --install"; exit 1; }

echo "==> target   $TARGET"
echo "==> output   $APP"
mkdir -p "$BUILD"

# Collect sources into an array: the tree contains a space in its name, so this cannot be
# a word-split list.
SRC=()
while IFS= read -r -d "" f; do SRC+=("$f"); done < <(find "$SOURCES_DIR" -name "*.swift" -not -path "*Preview Content*" -print0)
echo "==> swift    ${#SRC[@]} files"

# The four -Xfrontend flags matter: without them the SwiftUI view bodies blow the type
# checker budget and the build fails with "unable to type-check this expression in
# reasonable time". Each flag needs its own -Xfrontend; -Xfrontend -foo=bar silently does
# nothing. No -parse-as-library: this target has a main.swift, not an @main type.
swiftc \
  -Onone \
  -target "$TARGET" \
  -Xfrontend -solver-memory-threshold -Xfrontend 1073741824 \
  -Xfrontend -solver-expression-time-threshold=120000 \
  -I "$SOURCES_DIR/Services" \
  -import-objc-header "$SOURCES_DIR/Open Wallpaper Engine-Bridging-Header.h" \
  -o "$BIN" \
  "$SOURCES_DIR/Services/ObjCExceptionCatcher.m" \
  "${SRC[@]}"

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Open Wallpaper Engine"
cp -R "$SOURCES_DIR/Resources/." "$APP/Contents/Resources/"
cp "$ROOT/Open-Wallpaper-Engine-Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature. macOS keys TCC grants (desktop folder access, system audio capture) to
# the code identity, so every rebuild asks again — expected, not a bug.
echo "==> sign"
codesign --force --deep --sign - "$APP" >/dev/null

echo "==> arch   $(lipo -archs "$APP/Contents/MacOS/Open Wallpaper Engine")"
echo "==> done"
echo
echo "Next: apply it as the system wallpaper from the app UI."
echo "First launch needs two permission prompts: Desktop folder access (wallpapers live there)"
echo "and, for audio-reactive scene wallpapers, System Audio Recording."