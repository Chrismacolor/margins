#!/usr/bin/env bash
#
# Build, sign, notarize, and package Margins for direct distribution.
#
# Produces a Gatekeeper-clean, stapled .dmg in dist/ plus its sha256 (for the
# Homebrew cask). Requires an Apple Developer ID Application certificate in the
# keychain and (unless SKIP_NOTARIZE=1) notarization credentials.
#
# Configuration (environment variables):
#   DEVELOPER_ID    "Developer ID Application: NAME (TEAMID)".
#                   Auto-detected from the keychain if unset.
#   VERSION         Release version, e.g. 1.2.3. Defaults to the latest git tag.
#   NOTARY_PROFILE  Name of a notarytool keychain profile created with:
#                     xcrun notarytool store-credentials <profile> \
#                       --apple-id <id> --team-id <TEAMID> --password <app-pw>
#                   OR provide an App Store Connect API key instead:
#   NOTARY_KEY      Path to the .p8 API key
#   NOTARY_KEY_ID   API key ID
#   NOTARY_ISSUER   API issuer UUID
#   SKIP_NOTARIZE=1 Sign only (for local testing); skips notarize + staple.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

APP_NAME="Margins"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
ENTITLEMENTS="$ROOT_DIR/Resources/Margins.entitlements"
# Nested Quick Look preview extension — signed inside-out (before the app) with
# its own sandbox entitlements. See the signing step below.
APPEX_DIR="$APP_DIR/Contents/PlugIns/MarginsQuickLook.appex"
APPEX_ENTITLEMENTS="$ROOT_DIR/Resources/QuickLook/MarginsQuickLook.entitlements"

VERSION="${VERSION:-$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"

# --- Resolve signing identity ---
if [[ -z "${DEVELOPER_ID:-}" ]]; then
  DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)"
fi
if [[ -z "${DEVELOPER_ID:-}" ]]; then
  echo "ERROR: No Developer ID Application identity found. Set DEVELOPER_ID." >&2
  exit 1
fi
echo "Signing identity: $DEVELOPER_ID"

# --- 1. Optimized build with version stamped in ---
echo "==> Building optimized release (v$VERSION)"
VERSION="$VERSION" "$SCRIPT_DIR/build_app.sh"

# --- 2. Code sign with Hardened Runtime (inside-out) ---
# Nested code must be signed BEFORE its container: the app's signature seals a
# hash of the .appex, so signing the app first (or with --deep) would either
# leave the extension unsigned or produce a signature that notarization rejects.
# Sign the extension with its sandbox entitlements, then the app with its own.
echo "==> Signing Quick Look extension"
codesign --force --options runtime --timestamp \
  --entitlements "$APPEX_ENTITLEMENTS" \
  --sign "$DEVELOPER_ID" \
  "$APPEX_DIR"

echo "==> Signing app"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$DEVELOPER_ID" \
  "$APP_DIR"

# --deep re-verifies the nested extension's signature as part of the app's.
codesign --verify --strict --deep --verbose=2 "$APP_DIR"

mkdir -p "$DIST_DIR"

notarize() { # $1 = path to submit (zip or dmg)
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  elif [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER" --wait
  else
    echo "ERROR: No notarization credentials (set NOTARY_PROFILE or NOTARY_KEY*)." >&2
    exit 1
  fi
}

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  # --- 3. Notarize the app (via zip) and staple it ---
  echo "==> Notarizing app"
  /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
  notarize "$ZIP_PATH"
  xcrun stapler staple "$APP_DIR"
  rm -f "$ZIP_PATH"
else
  echo "==> SKIP_NOTARIZE=1: signing only, not notarizing"
fi

# --- 4. Build the DMG (drag-to-Applications layout) ---
echo "==> Packaging DMG"
STAGE="$(mktemp -d)"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGE"

# Sign the disk image itself so Gatekeeper has a usable signature on the
# downloaded artifact (the app inside is already signed). Without this, spctl
# reports "no usable signature" for the .dmg even after notarization.
echo "==> Signing DMG"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG_PATH"

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  # --- 5. Notarize + staple the DMG itself ---
  echo "==> Notarizing DMG"
  notarize "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  echo "==> Validating"
  xcrun stapler validate "$DMG_PATH"
  # A .dmg is assessed under the "open" rule (the operation when a user
  # double-clicks it), not "install" (which is for .pkg installers).
  spctl -a -vvv --type open --context context:primary-signature "$DMG_PATH" || true
fi

SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo
echo "Done: $DMG_PATH"
echo "sha256: $SHA"
echo "(use this sha256 + version $VERSION in the Homebrew cask)"
