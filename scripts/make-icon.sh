#!/usr/bin/env bash
# Compiles the Icon Composer icon (Support/Brand/AppIcon.icon) into Support/Icon/, then renders
# Support/Brand/AppIcon.png the way Finder shows it. Needs Xcode; run it after editing the icon and commit the outputs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Support/Icon"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Assets.car carries the layered Liquid Glass icon; AppIcon.icns is the flat fallback for macOS 14 and 15.
mkdir -p "$OUT"
xcrun actool "$ROOT/Support/Brand/AppIcon.icon" --compile "$OUT" \
    --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$WORK/partial.plist" >/dev/null

# Ask the system to draw the compiled icon from a throwaway bundle, so the preview matches what users see.
BUNDLE="$WORK/Preview.app"
mkdir -p "$BUNDLE/Contents/Resources" "$BUNDLE/Contents/MacOS"
cp "$OUT/Assets.car" "$OUT/AppIcon.icns" "$BUNDLE/Contents/Resources/"
cp /usr/bin/true "$BUNDLE/Contents/MacOS/Preview"
cp "$WORK/partial.plist" "$BUNDLE/Contents/Info.plist"
# Without an executable Finder badges the icon as unlaunchable.
plutil -insert CFBundleExecutable -string Preview "$BUNDLE/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$BUNDLE/Contents/Info.plist"
cat > "$WORK/render.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
let icon = NSWorkspace.shared.icon(forFile: args[1])
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
icon.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
SWIFT
swift "$WORK/render.swift" "$BUNDLE" "$ROOT/Support/Brand/AppIcon.png"
echo "Wrote Support/Icon/ and Support/Brand/AppIcon.png"
