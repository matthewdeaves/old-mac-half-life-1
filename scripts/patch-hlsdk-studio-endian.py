#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
patch-hlsdk-studio-endian.py - fix big-endian (PPC) studio-model animation in
hlsdk-portable's client renderer.

There are TWO independent faults in cl_dll/StudioModelRenderer.cpp, and they need
opposite treatment. Getting that wrong is not a subtle failure: swapping in the
wrong place produces models that fly around the room turned inside out.

Why this file is the only one left
----------------------------------
Most of hlsdk-portable's big-endian handling is already in mainline:
dlls/util.cpp, dlls/nodes.cpp, dlls/nodes_compat.h and dlls/saverestore.h all
swap, and the save/restore path does it centrally in CSave::BufferData via the
`typesize` parameter. cl_dll/StudioModelRenderer.cpp swaps nothing, and every
one of the 57 branches in hlsdk-portable inherits it that way.


FAULT 1 - the animation VALUES are never swapped (fixed everywhere)
-------------------------------------------------------------------
The compressed animation values are read through `Unaligned()`:

    angle1[j] = Unaligned( panimvalue[k + 1].value );

`Unaligned()` (common/byteswap.h) is a memcpy-based read that fixes ALIGNMENT but
does NOT byteswap. Nothing else swaps these - the engine leaves the animvalue
blocks exactly as they came off disk - so on PPC every value comes out
byte-reversed. The correct helper is `ULittleToHost()`, the unaligned read *with*
the swap on big-endian:

    #define ULittleToHost( x )   UByteswap( x )    // XASH_BIG_ENDIAN
    #define ULittleToHost( x )   LittleToHost( x ) // little-endian: identity

Every `Unaligned(` use in this file is an `Unaligned( panimvalue ... )` read, so
the substitution is blanket and complete.


FAULT 2 - the animation OFFSETS are swapped for some sequences and not others
-----------------------------------------------------------------------------
`panim->offset[j]` is a short, straight off the little-endian .mdl, and it locates
the value block that FAULT 1 then reads. Whether it has already been swapped by
the time the client sees it depends entirely on which sequence group it came from:

  seqgroup == 0   Animations live inside the main .mdl. The engine swaps these in
                  place in R_StudioLoadHeader (mod_studio.c, the
                  `if( pseqdesc[i].seqgroup == 0 )` block). ALREADY HOST-ENDIAN -
                  the client must NOT touch them.

  seqgroup != 0   Animations live in an external <model>NN.mdl. The ENGINE swaps
                  these too, in its own R_StudioGetAnim, right after FS_LoadFile
                  and before caching. But the client never calls that function:
                  CStudioModelRenderer::StudioGetAnim is a private reimplementation
                  that calls IEngineStudio.LoadCacheFile, a raw file load with no
                  byteswapping anywhere in it. STILL LITTLE-ENDIAN - and the
                  pointer arithmetic in StudioCalcBonePosition then walks off the
                  model and segfaults.

So a blanket swap of the offsets is wrong (it double-swaps seqgroup 0), and no
swap at all is wrong (it leaves the external groups reversed). Both were observed
on the G5: unpatched, Escape from the Darkness crashed in
StudioCalcBonePosition; blanket-patched, a security guard rendered warped and
flying before crashing anyway.

The fix is to swap in the one place that knows which case it is: the client's own
StudioGetAnim, on the branch that actually loaded the external file. That is
where the engine does it too, in its own R_StudioGetAnim.

The helper is `LittleToHostSW( x )` from common/byteswap.h, defined as
`( x = Byteswap( x ) )` on big-endian and as an empty macro on little-endian.
Byteswap is templated, so it picks up the short correctly. Do not reach for
`LittleShortSW`: no such name exists in that header.

The Cache_Check that guards the load also guarantees the swap runs exactly once
per seqgroup. If the engine loaded the group first it swapped it and populated the
same cache_user_t array (model_t::submodels), so Cache_Check is already true and
this code does not run. There is no path that swaps twice.


Note for other platforms: on a little-endian target `ULittleToHost(x)` expands to
a plain read, so it loses the unaligned-safety `Unaligned()` gave. That is fine
for the only targets we build (ppc and x86_64, the latter tolerating unaligned
access in hardware) but is why this stays a local patch and is not something to
send upstream. The seqgroup swap is compiled out entirely on little-endian.

Idempotent: each fix has its own marker, so a tree carrying one but not the other
still gets completed. Re-running on a fully patched tree is a no-op.

Invoke:
    python patch-hlsdk-studio-endian.py <hlsdk-tree> [<hlsdk-tree> ...]
"""
import io
import os
import sys

RELPATH = os.path.join("cl_dll", "StudioModelRenderer.cpp")
INCLUDE = '#include "byteswap.h"'

# ---------------------------------------------------------------- fault 1 --
VALUE_OLD = "Unaligned("
VALUE_NEW = "ULittleToHost("
VALUE_MARKER = "// oldmac: ULittleToHost = unaligned read + big-endian swap"
VALUE_BANNER = (
    VALUE_MARKER + " (see scripts/patch-hlsdk-studio-endian.py).\n"
    "// Upstream reads these through Unaligned(), which fixes alignment but does NOT\n"
    "// byteswap, so studio animation values are garbage on PPC.\n"
)

# ---------------------------------------------------------------- fault 2 --
# Anchor on the raw cache load inside CStudioModelRenderer::StudioGetAnim. This
# line is byte-identical across all 25 branches we ship (verified against the
# mirror); anything that does not match it is reported rather than patched
# silently.
SEQGROUP_ANCHOR = (
    "\t\tIEngineStudio.LoadCacheFile( pseqgroup->name,"
    " (struct cache_user_s *)&paSequences[pseqdesc->seqgroup] );\n"
)
SEQGROUP_MARKER = "// oldmac: swap this seqgroup's anim offsets"
SEQGROUP_CODE = """
\t\t""" + SEQGROUP_MARKER + """ (see scripts/patch-hlsdk-studio-endian.py).
\t\t// LoadCacheFile is a raw read: nothing in it byteswaps. The engine swaps
\t\t// seqgroup 0 in R_StudioLoadHeader and external groups in its OWN
\t\t// R_StudioGetAnim, but the client never calls that - it has this copy. So
\t\t// these offsets are still little-endian, and the pointer arithmetic in
\t\t// StudioCalcBonePosition walks off the model and faults.
\t\t// The Cache_Check above means this runs exactly once per seqgroup.
#ifdef XASH_BIG_ENDIAN
\t\t{
\t\t\tmstudioseqdesc_t *pseqdesc2 = (mstudioseqdesc_t *)((byte *)m_pStudioHeader + m_pStudioHeader->seqindex);

\t\t\tfor( int i = 0; i < m_pStudioHeader->numseq; i++ )
\t\t\t{
\t\t\t\tif( pseqdesc2[i].seqgroup != pseqdesc->seqgroup )
\t\t\t\t\tcontinue;

\t\t\t\tmstudioanim_t *panim = (mstudioanim_t *)((byte *)paSequences[pseqdesc->seqgroup].data + pseqdesc2[i].animindex);

\t\t\t\tfor( int j = 0; j < pseqdesc2[i].numblends; j++ )
\t\t\t\t{
\t\t\t\t\tfor( int k = 0; k < m_pStudioHeader->numbones; k++ )
\t\t\t\t\t{
\t\t\t\t\t\tfor( int l = 0; l < 6; l++ )
\t\t\t\t\t\t\tLittleToHostSW( panim->offset[l] );
\t\t\t\t\t\tpanim++;
\t\t\t\t\t}
\t\t\t\t}
\t\t\t}
\t\t}
#endif
"""


def patch_values(src):
    """Fault 1. Returns (src, message, ok)."""
    if VALUE_MARKER in src:
        return src, "values: already patched", True

    if VALUE_OLD not in src:
        # Either a branch that predates upstream's endian work, with no
        # Unaligned() call anywhere and needing the legacy graft instead, or
        # upstream renamed the helper. Either way this script must not silently
        # claim success.
        return src, ("values: ERROR no '%s' call sites - this branch predates"
                     " upstream's endian work; graft-ppc-endian.sh should take"
                     " the legacy path" % VALUE_OLD), False

    if INCLUDE not in src:
        return src, "values: ERROR file does not include byteswap.h", False

    count = src.count(VALUE_OLD)
    src = src.replace(VALUE_OLD, VALUE_NEW)
    # Drop the explanatory banner just after the byteswap.h include so the reason
    # is visible near the call sites, and give us an idempotency marker.
    src = src.replace(INCLUDE, INCLUDE + "\n\n" + VALUE_BANNER, 1)
    return src, "values: patched %d call site(s)" % count, True


def patch_seqgroup(src):
    """Fault 2. Returns (src, message, ok)."""
    if SEQGROUP_MARKER in src:
        return src, "seqgroup: already patched", True

    if src.count(SEQGROUP_ANCHOR) != 1:
        return src, ("seqgroup: ERROR expected exactly one LoadCacheFile anchor in"
                     " StudioGetAnim, found %d - the branch has rewritten this"
                     " function and needs looking at by hand"
                     % src.count(SEQGROUP_ANCHOR)), False

    src = src.replace(SEQGROUP_ANCHOR, SEQGROUP_ANCHOR + SEQGROUP_CODE, 1)
    return src, "seqgroup: patched StudioGetAnim", True


def patch_tree(tree):
    path = os.path.join(tree, RELPATH)
    if not os.path.isfile(path):
        print("  ERROR: not found: %s" % path)
        return False

    f = io.open(path, "r", encoding="latin-1")
    src = f.read()
    f.close()
    original = src

    ok = True
    for fn in (patch_values, patch_seqgroup):
        src, msg, good = fn(src)
        print("  %s" % msg)
        ok = good and ok

    if not ok:
        # Write nothing on failure: a half-patched file is worse than an
        # unpatched one, because the next run would see one marker and skip.
        return False

    if src != original:
        f = io.open(path, "w", encoding="latin-1")
        f.write(src)
        f.close()
    return True


def main():
    trees = sys.argv[1:]
    if not trees:
        print(__doc__)
        sys.exit(2)
    ok = True
    for tree in trees:
        print("== %s ==" % tree)
        ok = patch_tree(tree) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
