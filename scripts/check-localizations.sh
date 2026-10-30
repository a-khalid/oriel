#!/usr/bin/env bash
# Fails if any user-facing string in Sources/ is missing from a translation in Resources/.
# Uses the Swift compiler's own string extraction, so LocalizedStringKey and String(localized:) are both covered.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
swift build --scratch-path "$WORK/build" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings" >/dev/null

python3 -I - "$WORK/strings" "$ROOT/Resources" <<'EOF'
import json, os, subprocess, sys

strings_dir, resources = sys.argv[1], sys.argv[2]
keys = set()
for name in os.listdir(strings_dir):
    with open(os.path.join(strings_dir, name)) as f:
        for entries in json.load(f).get("tables", {}).values():
            keys.update(entry["key"] for entry in entries)

failed = False
for lproj in sorted(os.listdir(resources)):
    path = os.path.join(resources, lproj, "Localizable.strings")
    if lproj == "en.lproj" or not os.path.exists(path):
        continue
    converted = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], check=True, capture_output=True)
    translated = set(json.loads(converted.stdout).keys())
    missing, unused = sorted(keys - translated), sorted(translated - keys)
    for key in missing:
        print(f"{lproj}: missing {key!r}")
    for key in unused:
        print(f"{lproj}: unused {key!r}")
    failed |= bool(missing)

print(f"{len(keys)} source strings checked")
sys.exit(1 if failed else 0)
EOF
