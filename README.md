# appimage-repack

Turns upstream AppImages into ones that can be unpacked on Android.

## The problem

The anylinux / uruntime family (PPSSPP, and others built the same way)
ships AppImages whose payload is **DwarFS**, not the classic SquashFS. The
DwarFS extractor builds the payload with libarchive, and libarchive creates
hard links with `link(2)`.

Android denies apps the `link` permission (SELinux), so that call fails with
`EACCES` and libarchive gives up:

```
E 12:22:47 dwarfs::filesystem_extractor: Can't create 'sharun'
dwarfs::runtime_error: extraction aborted
```

The extraction has already laid out every other file at that point, so the
image is *almost* unpacked — but the tool exits with an error, and the
program directory is one entry short.

## The fix

Repack the payload as SquashFS, which stores no links and unpacks with
`unsquashfs` alone:

```
upstream AppImage  ──unpack──▶  directory tree  ──break links──▶  SquashFS
                                                                            │
upstream ELF runtime ◀──────────────────── glue ─────────────────────────┘
```

The ELF runtime of the upstream image is kept byte for byte. It is the
"Universal RunImage" runtime, which understands both SquashFS and DwarFS, so
the result is a normal AppImage: it runs on a desktop Linux as it is, and it
unpacks on Android without anything special.

Two properties make the result usable on a phone:

* **No hard links.** Every hard-linked file becomes an independent copy
  before the tree is packed, so nothing on the device ever has to create a
  link. (The hard link in the anylinux payloads is the `sharun` loader
  linked onto the program binary.)
* **The payload starts at the same offset.** The ELF runtime finds the
  payload where its own section header table ends, and that boundary is
  unchanged by the repack.

## Usage

Add a recipe under `recipes/`, then run the pipeline:

```yaml
- name: ppsspp
  repo: hrydgard/ppsspp
  version: v1.20.4
  asset: PPSSPP-v1.20.4-anylinux-aarch64.AppImage
  arch: aarch64
  sha256: ...
```

```console
$ scripts/build.sh recipes/ppsspp.yml --outdir out
```

The script prints one line per built asset: `<path> <sha256>`.

The GitHub workflow (`.github/workflows/release.yml`) does the same thing on
a schedule and publishes the result as a release asset, together with its
checksum.

## Requirements

* `mksquashfs` and `unsquashfs` (squashfs-tools)
* `python3`
* On Linux: the DwarFS extractor, fetched and checksum-verified by
  `scripts/dwarfs_tool.sh`. It is only needed for DwarFS payloads; a
  SquashFS payload is unpacked with `unsquashfs`.

## Layout

| Path | What it is |
| --- | --- |
| `scripts/appimage_payload.py` | Finds the payload of an AppImage: its type and offset |
| `scripts/repack.sh` | The repack itself |
| `scripts/dwarfs_tool.sh` | Fetches and verifies the DwarFS extractor |
| `scripts/build.sh` | Downloads the upstream assets and repacks them |
| `recipes/*.yml` | What to build |
