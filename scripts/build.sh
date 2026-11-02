#!/usr/bin/env bash
# Download the upstream assets named by the recipes and repack each of them.
#
# Usage: build.sh <recipe.yml>... [--outdir DIR]
#
# Prints one line per built asset: "<output path> <sha256>". The caller
# (the release workflow) turns those into release assets.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

OUTDIR="$HERE/../out"
RECIPES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --outdir) OUTDIR=$2; shift 2 ;;
        *) RECIPES+=("$1"); shift ;;
    esac
done
[ ${#RECIPES[@]} -gt 0 ] || { echo "usage: build.sh <recipe.yml>..." >&2; exit 1; }

mkdir -p "$OUTDIR"

log() { printf '[build] %s\n' "$*" >&2; }

# shellcheck source=scripts/dwarfs_tool.sh
source "$HERE/dwarfs_tool.sh"
DWARFSEXTract=$(fetch_dwarfsextract "$HERE/../.tools")

# Read one field of a recipe. The recipes are flat "key: value" lists, so a
# plain grep is enough and keeps the pipeline free of a YAML dependency.
recipe_field() {
    local file=$1 key=$2
    sed -n "s/^[[:space:]]*${key}:[[:space:]]*//p" "$file" | head -1 | sed 's/^["'\'']//; s/["'\'']$//'
}

for recipe in "${RECIPES[@]}"; do
    [ -f "$recipe" ] || { echo "no such recipe: $recipe" >&2; exit 1; }
    name=$(recipe_field "$recipe" name)
    repo=$(recipe_field "$recipe" repo)
    version=$(recipe_field "$recipe" version)
    asset=$(recipe_field "$recipe" asset)
    arch=$(recipe_field "$recipe" arch)
    sha=$(recipe_field "$recipe" sha256)

    [ -n "$name" ] && [ -n "$repo" ] && [ -n "$version" ] && [ -n "$asset" ] &&
        [ -n "$arch" ] || { echo "incomplete recipe: $recipe" >&2; exit 1; }

    work=$(mktemp -d)
    url="https://github.com/${repo}/releases/download/${version}/${asset}"
    log "downloading $url"
    curl -sSL -f -o "$work/upstream.AppImage" "$url" ||
        { echo "download failed: $url" >&2; rm -rf "$work"; exit 1; }

    if [ -n "$sha" ]; then
        got=$(sha256sum "$work/upstream.AppImage" | cut -d' ' -f1)
        [ "$got" = "$sha" ] ||
            { echo "checksum mismatch for $asset" >&2; rm -rf "$work"; exit 1; }
        log "checksum verified"
    else
        log "no pinned checksum for $asset"
    fi

    out="$OUTDIR/${name}-${version}-${arch}.AppImage"
    log "repacking -> $(basename "$out")"
    DWARFSEXTract="$DWARFSEXTract" "$HERE/repack.sh" "$work/upstream.AppImage" "$out"

    sum=$(sha256sum "$out" | cut -d' ' -f1)
    echo "$out $sum"
    rm -rf "$work"
done
