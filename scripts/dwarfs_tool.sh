#!/usr/bin/env bash
# The DwarFS extractor: the static x86_64 build from the dwarfs releases.
#
# It is what unpacks a DwarFS payload on a machine with no FUSE and no
# kernel module. The upstream AppImage runtime cannot do it for us: it needs
# FUSE, which a CI runner does not have.
#
# The pin is the same one the runtime payload uses (see the supply repo's
# scripts/dwarfs-pin.env), so the extractor that builds the images and the
# one that ships in the payload are the same binary.
DWARFS_VERSION=${DWARFS_VERSION:-0.15.7}
DWARFS_SHA256=${DWARFS_SHA256:-4dc3b756af88ede837eb3f27fbb5f2f0dbb83d7c9933a1d3be9216d2069d2f5f}
DWARFS_URL="https://github.com/mhx/dwarfs/releases/download/v${DWARFS_VERSION}/dwarfs-${DWARFS_VERSION}-Linux-x86_64.tar.xz"

# Fetch the extractor into $TOOLS and echo its path.
fetch_dwarfsextract() {
    local tools=$1
    local dest="$tools/dwarfsextract"
    if [ -x "$dest" ]; then
        echo "$dest"
        return
    fi
    mkdir -p "$tools"
    log "fetching dwarfsextract v${DWARFS_VERSION}"
    curl -sSL -f -o "$tools/dwarfs.tar.xz" "$DWARFS_URL"
    local got
    got=$(sha256sum "$tools/dwarfs.tar.xz" | cut -d' ' -f1)
    if [ "$got" != "$DWARFS_SHA256" ]; then
        echo "checksum mismatch for the dwarfs release: $got" >&2
        rm -f "$tools/dwarfs.tar.xz"
        exit 1
    fi
    tar -C "$tools" -xf "$tools/dwarfs.tar.xz"
    local found
    found=$(find "$tools" -path "*/bin/dwarfsextract" -type f | head -1)
    if [ -z "$found" ]; then
        echo "dwarfsextract not found in the dwarfs release" >&2
        exit 1
    fi
    cp "$found" "$dest"
    chmod +x "$dest"
    rm -f "$tools/dwarfs.tar.xz"
    rm -rf "$tools/dwarfs-${DWARFS_VERSION}-Linux-x86_64"
    echo "$dest"
}
