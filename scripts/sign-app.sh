#!/usr/bin/env bash
# Signs SpaceSweeper.app with the release certificate, innermost code first, so every piece of the
# bundle (Sparkle's helpers, the Sparkle framework, then the app) carries the same signature.
#   scripts/sign-app.sh <SpaceSweeper.app> [identity]     (identity defaults to "SpaceSweeper Release")
#
# No hardened runtime (`--options runtime`). It turns on library validation, which only accepts
# libraries with the app's Apple Team ID. A self-signed certificate has no Team ID, so macOS refused
# to load the bundled Sparkle framework and v1.0.1 crashed at launch, even though both carried this
# same signature. Hardened runtime is only required for Apple notarization, which this free build
# doesn't use; turn it back on when moving to a Developer ID certificate.
#
# Signing inside-out (rather than `codesign --deep`) is what Sparkle's documentation recommends.
set -euo pipefail

APP="${1:?usage: sign-app.sh <SpaceSweeper.app> [identity]}"
IDENTITY="${2:-SpaceSweeper Release}"
[[ -d "$APP" ]] || { echo "No app at $APP" >&2; exit 1; }

sign() { codesign --force --timestamp=none --sign "$IDENTITY" "$@"; }

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  B="$SPARKLE/Versions/B"
  sign "$B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$B/XPCServices/Downloader.xpc"
  sign "$B/Autoupdate"
  sign "$B/Updater.app"
  sign "$SPARKLE"
fi
sign --preserve-metadata=entitlements "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "✔ Signed $APP with \"$IDENTITY\""
