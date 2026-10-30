#!/usr/bin/env bash
# Builds nafitha-smoke, signs it with the virtualization entitlement and boots the given ISO headlessly.
#
# Usage: scripts/smoke.sh <linux-arm64.iso> [--expect TEXT] [--timeout SECONDS] [--keep]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build --product nafitha-smoke
BIN="$(swift build --show-bin-path)/nafitha-smoke"
codesign --force --entitlements "$ROOT/Support/Nafitha.entitlements" --sign - "$BIN"
exec "$BIN" "$@"
