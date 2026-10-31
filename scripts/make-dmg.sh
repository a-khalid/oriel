#!/usr/bin/env bash
# Packages build/Oriel.app into a drag-to-Applications disk image.
#
# Usage: scripts/make-dmg.sh [output.dmg]   (default build/Oriel-<version>.dmg)
# Env:   SIGN_IDENTITY  codesign identity for the image (skipped when unset or "-")
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Oriel.app"
IDENTITY="${SIGN_IDENTITY:--}"

if [[ ! -d "$APP" ]]; then
    echo "No $APP; run scripts/build-app.sh release first" >&2
    exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
OUT="${1:-$ROOT/build/Oriel-$VERSION.dmg}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ditto keeps the code signature and extended attributes intact.
ditto "$APP" "$STAGE/Oriel.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -volname "Oriel $VERSION" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -ov "$OUT" >/dev/null

if [[ "$IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$OUT"
fi

echo "Built $OUT"
