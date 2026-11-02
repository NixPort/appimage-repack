#!/usr/bin/env bash
# Check a repacked image the way the device will read it.
#
# The device unpacks an AppImage payload with "unsquashfs -o <offset>", where
# the offset comes from the ELF section header table. This script does the
# same thing and asserts the two things that matter on the phone:
#
#   * the payload unpacks, and it has an AppRun to launch;
#   * it holds no hard link, because creating one is what Android forbids.

set -euo pipefail

IMAGE=${1:?usage: check.sh <repacked.AppImage>}
HERE=$(cd "$(dirname "$0")" && pwd)

WORK=$(mktemp -d)
cleanup() { chmod -R u+rwX "$WORK" 2>/dev/null || true; rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

read -r type offset < <(python3 "$HERE/appimage_payload.py" INFO "$IMAGE")
echo "payload: $type at $offset"
[ "$type" = "squashfs" ] || { echo "the payload is $type, not squashfs" >&2; exit 1; }

unsquashfs -f -no-xattrs -d "$WORK/tree" -o "$offset" "$IMAGE" >/dev/null

[ -e "$WORK/tree/AppRun" ] || { echo "no AppRun in the payload" >&2; exit 1; }

links=$(find "$WORK/tree" -type f -links +1 | wc -l)
[ "$links" -eq 0 ] || { echo "the payload holds $links hard link(s)" >&2; exit 1; }

files=$(find "$WORK/tree" -type f | wc -l)
symlinks=$(find "$WORK/tree" -type l | wc -l)
echo "ok: $files files, $symlinks symlinks, no hard links"
