#!/usr/bin/env bash
# Builds Oriel.app from the Swift package and signs it with the virtualization entitlement.
#
# Usage: scripts/build-app.sh [debug|release]
# Env:   SIGN_IDENTITY  codesign identity (default "-" = ad-hoc, fine for local use)
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Oriel.app"
IDENTITY="${SIGN_IDENTITY:--}"

cd "$ROOT"
swift build -c "$CONFIG" --product Oriel
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Oriel" "$APP/Contents/MacOS/Oriel"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT"/Resources/*.lproj "$APP/Contents/Resources/"
cp "$ROOT"/Support/Icon/* "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/Fonts" "$APP/Contents/Resources/Fonts"

codesign --force --options runtime \
    --entitlements "$ROOT/Support/Oriel.entitlements" \
    --sign "$IDENTITY" "$APP"

echo "Built $APP"
