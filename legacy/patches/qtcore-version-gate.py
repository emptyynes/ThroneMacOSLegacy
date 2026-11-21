#!/usr/bin/env python3
"""Neutralise QtCore's hard-coded macOS version gate.

Qt 6.4 (the macOS "legacy" build of Throne) compares the running OS version against
10.14 with QVersionNumber::compare and calls exit(1) with
    Sorry, "<app>" cannot be run on this version of macOS. Qt requires macOS 10.14.0 ...
The gate is a single conditional jump; the rest of Qt works fine on 10.13.

Usage:  ./qtcore-version-gate.py /path/to/Throne.app/Contents/Frameworks/QtCore.framework/Versions/A/QtCore

The patch is located by a unique byte pattern, not by a fixed file offset: on some
binaries the section file offset differs from the disassembly address by a page-sized
constant, and an offset picked from `otool -tv` silently lands in the middle of
another function.
"""
import shutil
import sys

# testl %eax,%eax ; js <fatal-block>   ->   testl %eax,%eax ; nop ; nop
NEEDLE = b"\x85\xc0\x78\x79"
PATCHED = b"\x85\xc0\x90\x90"


def main(path):
    with open(path, "rb") as f:
        data = bytearray(f.read())

    if PATCHED in data and NEEDLE not in data:
        print("already patched: %s" % path)
        return 0

    hits = []
    i = data.find(NEEDLE)
    while i >= 0:
        hits.append(i)
        i = data.find(NEEDLE, i + 1)

    print("matches: %s" % [hex(h) for h in hits])
    if len(hits) != 1:
        print("expected exactly one match, refusing to patch")
        return 1

    shutil.copy2(path, path + ".bak")
    off = hits[0]
    data[off:off + 4] = PATCHED
    with open(path, "wb") as f:
        f.write(data)
    print("patched at 0x%x, backup at %s.bak" % (off, path))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1]))
