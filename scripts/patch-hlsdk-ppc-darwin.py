#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
patch-hlsdk-ppc-darwin.py - make hlsdk-portable configurable with Apple's gcc on
a PowerPC darwin target.

Two upstream assumptions break our PPC cross-build, both because hlsdk expects
"darwin implies clang":

 1) wscript - `-Wl,--no-undefined` is added for the 'gcc' compiler
    (scripts/waifulib/compiler_optimizations.py) and only removed again for
    nswitch, psvita and irix. We build darwin/ppc with gcc-4.0, so we get the GNU
    flag and Apple's ld rejects it outright:

        ld: unknown option: --no-undefined

    which surfaces as a bare "Checking for required C flags : no" and a failed
    configure. Dropping it is safe: GoldSrc game dylibs resolve engine symbols at
    load time through the function-pointer handoff, so link-time
    undefined-symbol checking buys nothing here.

 2) public/build.h - architecture detection tests only `__PPC__` and
    `__powerpc__`. Apple's compilers also spell it `__ppc__` / `__POWERPC__`, and
    which of these is predefined varies between gcc-4.0 and gcc-4.2. If none
    match, build.h falls through to its #error and the tree cannot compile.
    Widening the test costs nothing and removes the version dependency.

Both edits are carried in the vendored PPC tree as hand-edits
(patches/vendor/hlsdk-portable-ppc.handedits.diff); this script applies the same
two changes to any mod branch we build, so nothing depends on that one checkout.

Idempotent. Python 2.5+ (the build minis run 2.7).

Invoke:
    python patch-hlsdk-ppc-darwin.py <hlsdk-tree> [<hlsdk-tree> ...]
"""
import os
import sys

# --- 1) wscript: drop -Wl,--no-undefined on darwin ---------------------------
WS_MARKER = "oldmac: Apple ld (ld64) has no GNU '--no-undefined'"
WS_ANCHOR = ("\tcxxflags = list(cflags) # optimization flags are common between "
             "C and C++ but we need a copy\n")
WS_NEW = WS_ANCHOR + (
    "\n"
    "\t# " + WS_MARKER + "; it's only added for the gcc\n"
    "\t# path (our PowerPC gcc cross-build). GoldSrc game dylibs resolve engine symbols\n"
    "\t# at load via the function-pointer handoff, so undefined-symbol checking isn't needed.\n"
    "\tif conf.env.DEST_OS == 'darwin' and '-Wl,--no-undefined' in linkflags:\n"
    "\t\tlinkflags.remove('-Wl,--no-undefined')\n")

# --- 2) public/build.h: accept Apple's spellings of the PPC macro ------------
BH_MARKER = "oldmac: Apple gcc spells it __ppc__/__POWERPC__"
BH_ANCHOR = "#elif defined __PPC__ || defined __powerpc__\n"
BH_NEW = ("#elif defined __PPC__ || defined __powerpc__ || defined __ppc__ || "
          "defined __POWERPC__ // " + BH_MARKER + "\n")

EDITS = [
    ("wscript", WS_MARKER, WS_ANCHOR, WS_NEW, "drop -Wl,--no-undefined on darwin"),
    (os.path.join("public", "build.h"), BH_MARKER, BH_ANCHOR, BH_NEW,
     "accept __ppc__/__POWERPC__"),
]


def patch_file(tree, relpath, marker, anchor, new, what):
    path = os.path.join(tree, relpath)
    if not os.path.isfile(path):
        print("  ERROR: not found: %s" % path)
        return False

    f = open(path, "r")
    src = f.read()
    f.close()

    if marker in src:
        print("  already patched (%s): %s" % (what, relpath))
        return True

    if anchor not in src:
        print("  ERROR: anchor for '%s' not found in %s" % (what, relpath))
        return False

    src = src.replace(anchor, new, 1)

    f = open(path, "w")
    f.write(src)
    f.close()
    print("  patched (%s): %s" % (what, relpath))
    return True


def main():
    trees = sys.argv[1:]
    if not trees:
        print(__doc__)
        sys.exit(2)
    ok = True
    for tree in trees:
        print("== %s ==" % tree)
        for relpath, marker, anchor, new, what in EDITS:
            ok = patch_file(tree, relpath, marker, anchor, new, what) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
