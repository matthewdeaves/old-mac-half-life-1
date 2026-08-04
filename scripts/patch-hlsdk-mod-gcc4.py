#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
patch-hlsdk-mod-gcc4.py - fix mod source that only compiles on a modern C++
compiler, so the PowerPC build (Apple gcc-4.0) can build it too.

The x86_64 slice is built with a 2013 clang, which accepts a lot that gcc-4.0
rejects. These are the differences that actually showed up across the mod set -
each is a genuine standards issue, not a compiler quirk, so the fixes are correct
C++ rather than workarounds.

  1) Spirit-of-Half-Life derived mods (echoes, halloween, ...), dlls/plats.cpp:

         if (m_pfnThink == &CFuncTrackChange::LinearMoveNow)

     m_pfnThink is `void (CBaseEntity::*)()`; LinearMoveNow is inherited from
     CBaseToggle, so the right-hand side is `void (CBaseToggle::*)()`. The
     standard implicit conversion for pointers-to-member goes Base::* -> Derived::*
     (contravariance), NOT the direction needed here, so the two operands have no
     common type and gcc-4.0 refuses:

         error: invalid operands of types 'void (CBaseEntity::*)()' and
                'void (CBaseToggle::*)()' to binary 'operator=='

     static_cast explicitly permits the Derived::* -> Base::* direction, so naming
     the base type makes the comparison well-formed everywhere.

  2) dmc, ministl/bstring.h:

         typedef basic_string<charT>::baggage_type baggage_type;

     basic_string<charT> is a dependent type, so baggage_type needs `typename`.
     Modern compilers accept the omission as an extension; gcc-4.0 reports
     "expected initializer before 'baggage_type'" at each of the five sites.

Applied to the PPC tree only - the Intel tree already builds, and there is no
reason to perturb a working build.

Idempotent, and a no-op for mods that need neither fix. Python 2.5+.

Invoke:
    python patch-hlsdk-mod-gcc4.py <hlsdk-tree> [<hlsdk-tree> ...]
"""
import os
import sys

# (relative path, old text, new text, replace-all?, description)
FIXES = [
    (os.path.join("dlls", "plats.cpp"),
     "if (m_pfnThink == &CFuncTrackChange::LinearMoveNow)",
     "if (m_pfnThink == static_cast<void (CBaseEntity::*)()>(&CFuncTrackChange::LinearMoveNow))",
     True,
     "plats.cpp: cast member-fn pointer to its base type"),

    (os.path.join("ministl", "bstring.h"),
     "typedef  basic_string<charT>::baggage_type  baggage_type;",
     "typedef  typename basic_string<charT>::baggage_type  baggage_type;",
     True,
     "bstring.h: typename on dependent baggage_type"),
]


def patch_tree(tree):
    applied = 0
    for relpath, old, new, all_occurrences, what in FIXES:
        path = os.path.join(tree, relpath)
        if not os.path.isfile(path):
            continue

        f = open(path, "r")
        src = f.read()
        f.close()

        if new in src:
            print("  already patched (%s)" % what)
            applied += 1
            continue
        if old not in src:
            continue    # this mod doesn't have the construct; nothing to do

        count = src.count(old)
        src = src.replace(old, new) if all_occurrences else src.replace(old, new, 1)

        f = open(path, "w")
        f.write(src)
        f.close()
        print("  patched (%s) x%d" % (what, count))
        applied += 1

    if applied == 0:
        print("  no gcc-4.0 fixes needed")
    return True


def main():
    trees = sys.argv[1:]
    if not trees:
        print(__doc__)
        sys.exit(2)
    for tree in trees:
        print("== %s ==" % tree)
        patch_tree(tree)
    sys.exit(0)


if __name__ == "__main__":
    main()
