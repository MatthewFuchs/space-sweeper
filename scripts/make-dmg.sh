#!/usr/bin/env bash
# Packages SpaceSweeper.app into a disk image with an Applications shortcut, so installing is a single drag.
#   scripts/make-dmg.sh <path/to/SpaceSweeper.app> <output.dmg>
set -euo pipefail

APP="${1:?usage: make-dmg.sh <SpaceSweeper.app> <output.dmg>}"
OUT="${2:?usage: make-dmg.sh <SpaceSweeper.app> <output.dmg>}"
[[ -d "$APP" ]] || { echo "No app at $APP" >&2; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# The app plus a shortcut to /Applications: the Finder window shows both side by side.
ditto "$APP" "$STAGING/SpaceSweeper.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$OUT"
hdiutil create -volname "SpaceSweeper" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
echo "✔ Created $OUT ($(du -h "$OUT" | cut -f1))"
