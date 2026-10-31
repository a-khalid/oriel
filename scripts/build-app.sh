#!/usr/bin/env bash
# Builds Oriel.app from the Swift package and signs it with the virtualization entitlement.
#
# Usage: scripts/build-app.sh [debug|release]
# Env:   SIGN_IDENTITY  codesign identity (default "-" = ad-hoc, fine for local use)
#        ORIEL_VERSION  overrides CFBundleShortVersionString (release builds)
#        ORIEL_BUILD    overrides CFBundleVersion
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
if [[ -n "${ORIEL_VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "$ORIEL_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${ORIEL_BUILD:-}" ]]; then
    plutil -replace CFBundleVersion -string "$ORIEL_BUILD" "$APP/Contents/Info.plist"
fi
cp -R "$ROOT"/Resources/*.lproj "$APP/Contents/Resources/"
cp "$ROOT"/Support/Icon/* "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/Fonts" "$APP/Contents/Resources/Fonts"

# Notarization requires a secure timestamp; ad-hoc signatures can't carry one.
SIGN_FLAGS=(--force --options runtime)
[[ "$IDENTITY" != "-" ]] && SIGN_FLAGS+=(--timestamp)

codesign "${SIGN_FLAGS[@]}" \
    --entitlements "$ROOT/Support/Oriel.entitlements" \
    --sign "$IDENTITY" "$APP"

echo "Built $APP"
