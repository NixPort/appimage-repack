#!/usr/bin/env python3
"""Locate an AppImage's appended payload: its type and its offset.

An AppImage (type 2) is an ELF runtime with a filesystem appended to it. The
payload starts where the ELF's section header table ends — the same rule the
AppImage runtime itself uses, so host and artifact agree on the boundary.

The payload is either squashfs (the classic layout) or DwarFS (what the
anylinux / uruntime family ships). The superblock's magic tells them apart.

Usage:
    appimage_payload.py INFO <image>       # print "type offset"
    appimage_payload.py OFFSET <image>     # print the offset only
    appimage_payload.py EXTRACT <image> <out>   # write the payload to a file
"""

import struct
import sys

SQUASHFS_MAGIC = b"hsqs"
DWARFS_MAGIC = b"DWARFS"
DWARFS_MAJOR = 2
ELF_HEAD_SIZE = 64


def elf_header(f):
    head = f.read(ELF_HEAD_SIZE)
    if len(head) < ELF_HEAD_SIZE:
        raise ValueError("not an ELF file")
    if head[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    little = head[5] == 1
    end = "<" if little else ">"
    if head[4] == 2:  # ELF64
        shoff = struct.unpack_from(end + "Q", head, 0x28)[0]
        shentsize = struct.unpack_from(end + "H", head, 0x3A)[0]
        shnum = struct.unpack_from(end + "H", head, 0x3C)[0]
    elif head[4] == 1:  # ELF32
        shoff = struct.unpack_from(end + "I", head, 0x20)[0]
        shentsize = struct.unpack_from(end + "H", head, 0x2E)[0]
        shnum = struct.unpack_from(end + "H", head, 0x30)[0]
    else:
        raise ValueError("unsupported ELF class")
    # A stripped section header table (shnum == 0) leaves nothing to derive
    # the boundary from.
    if shnum <= 0 or shentsize <= 0:
        raise ValueError("no section header table")
    return head, little, shoff + shnum * shentsize


def payload_type(f, offset):
    f.seek(offset)
    head = f.read(24)
    if head[:4] == SQUASHFS_MAGIC:
        return "squashfs"
    if head[:5] == DWARFS_MAGIC:
        if len(head) < 6:
            raise ValueError("truncated DwarFS superblock")
        if head[5] != DWARFS_MAJOR:
            raise ValueError("unsupported DwarFS major version %d" % head[5])
        return "dwarfs"
    raise ValueError("no known filesystem magic at offset %d" % offset)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    path = sys.argv[2]
    with open(path, "rb") as f:
        _, _, offset = elf_header(f)
        if cmd == "OFFSET":
            print(offset)
            return
        if cmd == "INFO":
            print("%s %d" % (payload_type(f, offset), offset))
            return
        if cmd == "EXTRACT":
            if len(sys.argv) < 4:
                sys.exit("EXTRACT needs an output path")
            f.seek(offset)
            with open(sys.argv[3], "wb") as out:
                while True:
                    chunk = f.read(1 << 20)
                    if not chunk:
                        break
                    out.write(chunk)
            return
    sys.exit("unknown command %s" % cmd)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as e:
        sys.exit("error: %s" % e)
