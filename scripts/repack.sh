#!/usr/bin/env bash
# Repack an upstream AppImage into one whose payload we can unpack on Android.
#
# Why: the anylinux / uruntime family ships DwarFS payloads. DwarFS is
# extracted by libarchive, which creates hard links with link(2) — and Android
# denies apps the link permission, so the extraction dies on the first hard
# link with "Can't create 'sharun'". SquashFS payloads have no such problem:
# unsquashfs recreates hard links itself and the AppImage runtime we ship
# understands both formats.
#
# So: take the upstream image apart, lay the payload out as a plain directory
# tree, turn every hard link into an independent copy, repack that tree as
# SquashFS, and glue it back onto the upstream ELF runtime.
#
# The ELF runtime is kept byte for byte: it already handles SquashFS and
# DwarFS (it is the "Universal RunImage" runtime), and keeping it means the
# result is a normal, runnable AppImage on a desktop Linux too — not
# something only this app understands.
#
# Usage: repack.sh <input.AppImage> <output.AppImage>

set -euo pipefail

IN=${1:?usage: repack.sh <input> <output>}
OUT=${2:?usage: repack.sh <input> <output>}

HERE=$(cd "$(dirname "$0")" && pwd)
PAYLOAD_TOOL=${PAYLOAD_TOOL:-"$HERE/appimage_payload.py"}
DWARFSEXTract=${DWARFSEXTract:-dwarfsextract}

WORK=$(mktemp -d)
# The unpacked tree keeps the archive's modes, and some directories in it are
# read-only. Removing those needs write permission on the parent, so open the
# tree up before anything else touches it. The cleanup is quiet: the removal
# of a read-only tree reports permission errors on macOS even though it
# succeeds (it retries with the permissions raised).
cleanup() {
    chmod -R u+rwX "$WORK" 2>/dev/null || true
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

log() { printf '[repack] %s\n' "$*" >&2; }
die() { printf '[repack] error: %s\n' "$*" >&2; exit 1; }

# The tools this script needs, checked before anything is unpacked: a missing
# tool found halfway through the work leaves a half-built image behind.
for tool in python3 mksquashfs unsquashfs; do
    command -v "$tool" >/dev/null || die "$tool is not installed"
done
[ -f "$PAYLOAD_TOOL" ] || die "the payload tool is missing: $PAYLOAD_TOOL"

# --- 1. where does the payload start, and what is it? -------------------------

read -r FS_TYPE OFFSET < <(python3 "$PAYLOAD_TOOL" INFO "$IN") ||
    die "cannot read the payload of $IN"
log "payload: $FS_TYPE at offset $OFFSET"

case "$FS_TYPE" in
    squashfs)
        log "extracting the SquashFS payload"
        unsquashfs -f -no-xattrs -d "$WORK/tree" -o "$OFFSET" "$IN" >/dev/null
        # The unpacked tree keeps the modes the archive recorded, and some of
        # them are read-only directories. The steps below need to write into
        # that tree, so open it up first. (On Linux the unpacker leaves the
        # directories writable; on macOS it does not.)
        chmod -R u+rwX "$WORK/tree" 2>/dev/null || true
        ;;
    dwarfs)
        log "extracting the DwarFS payload"
        # The extractor is only needed for this payload type, so it is
        # checked here: a wrong path would otherwise fail with the bare
        # "command not found".
        [ -x "$DWARFSEXTract" ] ||
            die "the DwarFS extractor is not usable: $DWARFSEXTract"
        # The extractor wants the output directory to exist: it changes into
        # it before writing anything.
        mkdir -p "$WORK/tree"
        # The extractor writes the archive root into the output directory.
        "$DWARFSEXTract" -i "$IN" -O "$OFFSET" -o "$WORK/tree" --log-level error
        ;;
    *)
        die "unsupported payload type: $FS_TYPE"
        ;;
esac

[ -d "$WORK/tree" ] || die "the payload did not extract into a directory"

# --- 2. break the hard links ----------------------------------------------------
#
# The DwarFS payload of an anylinux build hard links the "sharun" loader onto
# the program binary. SquashFS keeps hard links, so unsquashfs would call
# link(2) again on Android and hit the same denial. Copy the file instead:
# the tree then holds only regular files, and nothing on the device ever has
# to create a link.
#
# cp --reflink=never keeps the copies independent even on a filesystem that
# would otherwise share blocks.

log "replacing hard links with copies"
HARDLINKS=$(find "$WORK/tree" -type f -links +1 | wc -l)
if [ "$HARDLINKS" -gt 0 ]; then
    log "found $HARDLINKS hard-linked file(s)"
    find "$WORK/tree" -type f -links +1 -print0 |
        while IFS= read -r -d '' f; do
            # Copy through a temporary file and move it into place: the copy
            # is a file of its own, so it shares no inode with the name it
            # replaces. cp -p keeps the mode (the executable bit matters for
            # the programs in the tree); the copy is checked against the
            # original's size, because a copy that silently produced an empty
            # file would be worse than the hard link it replaced.
            tmp="$WORK/copy.$$"
            cp -p "$f" "$tmp"
            want=$(wc -c <"$f")
            got=$(wc -c <"$tmp")
            [ "$want" = "$got" ] || die "the copy of $f is $got bytes, not $want"
            mv "$tmp" "$f"
        done
fi

# The extractor leaves the owner as 0:0 (it runs as root in CI, and the
# archive records the original owner). SquashFS stores that as-is; the device
# does not care, but a non-root unpacker cannot chown to 0:0 and complains.
# Store everything as root and let the device side keep it as it is.
log "normalising ownership and modes"
chmod -R u+rwX,go+rX "$WORK/tree" 2>/dev/null || true

# --- 3. repack as SquashFS --------------------------------------------------------

log "building the SquashFS payload"
mksquashfs "$WORK/tree" "$WORK/payload.squashfs" \
    -noappend -comp zstd -no-xattrs -all-root -no-progress >/dev/null

# --- 4. glue the payload back onto the upstream ELF runtime ---------------------

log "attaching the payload to the ELF runtime"
head -c "$OFFSET" "$IN" > "$OUT"
cat "$WORK/payload.squashfs" >> "$OUT"
chmod 0755 "$OUT"

# --- 5. verify ---------------------------------------------------------------------

log "verifying the result"
read -r OUT_TYPE OUT_OFFSET < <(python3 "$PAYLOAD_TOOL" INFO "$OUT") ||
    die "the repacked image has no readable payload"
[ "$OUT_TYPE" = "squashfs" ] || die "the repacked payload is $OUT_TYPE, not squashfs"
[ "$OUT_OFFSET" = "$OFFSET" ] || die "the payload moved: $OFFSET -> $OUT_OFFSET"

rm -rf "$WORK/check"
unsquashfs -f -no-xattrs -d "$WORK/check" -o "$OUT_OFFSET" "$OUT" >/dev/null ||
    die "the repacked payload does not unpack"
[ -e "$WORK/check/AppRun" ] || die "the repacked payload has no AppRun"
LINKS=$(find "$WORK/check" -type f -links +1 | wc -l)
[ "$LINKS" -eq 0 ] || die "the repacked payload still holds $LINKS hard link(s)"

log "ok: $(basename "$OUT") ($OUT_TYPE at $OUT_OFFSET, $(du -h "$OUT" | cut -f1))"
