#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

APP_NAME="Margins"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
SOURCE_DIR="$ROOT_DIR/Sources/Margins"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
ICON_FILE="$ROOT_DIR/Resources/AppIcon.icns"

# Optimization level. Defaults to -O (release). Override with SWIFT_OPT=-Onone
# for faster iterative debug builds.
SWIFT_OPT="${SWIFT_OPT:--O}"

mkdir -p "$BIN_DIR" "$RESOURCES_DIR"

# Compile every Swift file in the source directory into a single executable
# (still one binary, zero external dependencies).
shopt -s nullglob
SOURCES=("$SOURCE_DIR"/*.swift)
shopt -u nullglob
if [[ ${#SOURCES[@]} -eq 0 ]]; then
  echo "No Swift sources found in $SOURCE_DIR" >&2
  exit 1
fi

xcrun swiftc \
  "$SWIFT_OPT" \
  -parse-as-library \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  "${SOURCES[@]}" \
  -o "$BIN_DIR/$APP_NAME"

cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
fi
cp "$ROOT_DIR/Resources/margins-cli" "$RESOURCES_DIR/margins-cli"
chmod +x "$RESOURCES_DIR/margins-cli"
chmod +x "$BIN_DIR/$APP_NAME"

# Stamp version/build into the bundled Info.plist (not the source file).
# Derive from git tag (e.g. v1.2.3) and commit count; override via env.
VERSION="${VERSION:-$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
BUILD="${BUILD:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || true)}"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
fi
if [[ -n "${BUILD:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP_DIR/Contents/Info.plist"
fi

echo "Built $APP_DIR (opt=$SWIFT_OPT, version=${VERSION:-unset}, build=${BUILD:-unset})"
