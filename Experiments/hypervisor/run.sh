#!/usr/bin/env bash
# Builds oriel-hv and boots an Alpine "virt" aarch64 ISO on it.
#
# Usage: Experiments/hypervisor/run.sh <alpine-virt-aarch64.iso> [--test]
#   Interactive by default (Ctrl-A then x quits). --test logs in, runs a command and powers off.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ISO="${1:?usage: $0 <alpine-virt-aarch64.iso> [--test]}"
OUT="$ROOT/build/hv"
mkdir -p "$OUT"

clang -O2 -Wall -mmacosx-version-min=14.0 -o "$OUT/oriel-hv" "$HERE/main.c" -framework Hypervisor -lz
codesign --force --sign - --entitlements "$HERE/hv.entitlements" "$OUT/oriel-hv"

# The ISO's kernel is an EFI zboot image; oriel-hv inflates it itself.
tar -xOf "$ISO" boot/vmlinuz-virt > "$OUT/vmlinuz-virt"
tar -xOf "$ISO" boot/initramfs-virt > "$OUT/initramfs-virt"

ARGS=(--kernel "$OUT/vmlinuz-virt" --initrd "$OUT/initramfs-virt" --disk "$ISO" --readonly
      --cmdline "modules=loop,squashfs,sd-mod,virtio_blk,virtio_mmio console=ttyAMA0"
      --mem 1024 --cpus 2)

if [[ "${2:-}" == "--test" ]]; then
    exec expect "$HERE/smoke.exp" "$OUT/oriel-hv" "${ARGS[@]}"
fi
exec "$OUT/oriel-hv" "${ARGS[@]}"
