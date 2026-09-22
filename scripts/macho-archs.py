#!/usr/bin/env python3
"""Print the architectures in a Mach-O file, read from its own header.

usage: scripts/macho-archs.py FILE

Prints one line of space-separated slice names in file order, e.g.
"ppc750 ppc7400 x86_64 i386 arm64". A thin file prints its one name. Exits 1
if FILE is not Mach-O.

Why not lipo: which slices a lipo can NAME depends on how old or new it is.
Tiger's and Lion's print x86_64 and arm64 as raw cputypes, and Xcode 27's
drops PowerPC entirely: measured 2026-09-22 on the dev box, `lipo -archs` on a
correct five-slice xash3d.bin printed "x86_64 i386 arm64" and
`lipo -detailed_info` said "unknown cputype" for both PowerPC slices and for
i386. The header is the ground truth, and it also carries the exact PowerPC
subtype (ppc750 / ppc7400 / generic ppc) that dyld grades on.
"""
import struct
import sys

CPU_ARCH_ABI64 = 0x01000000
NAMES = {
    (18, 0): "ppc",               # CPU_TYPE_POWERPC, SUBTYPE_ALL
    (18, 9): "ppc750",
    (18, 10): "ppc7400",
    (18, 11): "ppc7450",
    (18, 100): "ppc970",
    (18 | CPU_ARCH_ABI64, 0): "ppc64",
    (7, 3): "i386",               # CPU_TYPE_X86, SUBTYPE_I386_ALL
    (7 | CPU_ARCH_ABI64, 3): "x86_64",
    (7 | CPU_ARCH_ABI64, 8): "x86_64h",
    (12 | CPU_ARCH_ABI64, 0): "arm64",
    (12 | CPU_ARCH_ABI64, 2): "arm64e",
}


def name(cputype, cpusubtype):
    sub = cpusubtype & 0x00FFFFFF   # strip capability bits (e.g. LIB64)
    return NAMES.get((cputype, sub), "cputype%d/%d" % (cputype, sub))


def archs(path):
    with open(path, "rb") as f:
        head = f.read(8)
        if len(head) < 8:
            return None
        magic = struct.unpack(">I", head[:4])[0]
        if magic in (0xCAFEBABE, 0xCAFEBABF):   # fat, always big-endian
            n = struct.unpack(">I", head[4:8])[0]
            size = 20 if magic == 0xCAFEBABE else 32
            table = f.read(n * size)
            out = []
            for i in range(n):
                ct, st = struct.unpack(">ii", table[i * size:i * size + 8])
                out.append(name(ct, st))
            return out
        for endian, magics in (("<", (0xCEFAEDFE, 0xCFFAEDFE)),
                               (">", (0xFEEDFACE, 0xFEEDFACF))):
            if magic in magics:
                ct, st = struct.unpack(endian + "ii", head[4:8])
                return [name(ct, st)]
    return None


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: macho-archs.py FILE\n")
        sys.exit(2)
    try:
        got = archs(sys.argv[1])
    except OSError as e:
        sys.stderr.write("macho-archs.py: %s\n" % e)
        sys.exit(1)
    if not got:
        sys.stderr.write("macho-archs.py: not a Mach-O file: %s\n" % sys.argv[1])
        sys.exit(1)
    print(" ".join(got))
