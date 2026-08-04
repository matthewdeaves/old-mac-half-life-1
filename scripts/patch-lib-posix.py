#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Idempotently patch engine/platform/posix/lib_posix.c so engine dylibs load when the
# app is launched from Finder (cwd = "/"). macOS dyld will not resolve a bare leaf name
# (no slash) against the cwd, only against DYLD paths, so filesystem_stdio / ref_gl /
# ref_soft / menu - which live next to the executable - fail to dlopen by name.
#
# This script ALSO carries the task#41 save/restore fix (edit C): normalize a Mach-O
# "__ZN..." symbol to ELF-style "_ZN..." in COM_NameForFunction. On macOS 10.3 Panther,
# dladdr() KEEPS the leading '_' that Mach-O prepends to every symbol (10.4/10.5/Intel
# strip it), so COM_DetectMangleType - which only recognizes "_ZN" - treats "__ZN..." as
# unknown, and the dlsym round-trip on restore fails -> every carried-across-transition
# entity's think/touch/use pointer comes back NULL (the G3 intro-guard freeze). The edit
# is a runtime no-op wherever dladdr already strips the underscore, so it is safe for the
# shared universal engine and applied to every slice. Tolerant: skips if the anchor is
# absent (upstream drift), never fails the build over that.
#
# COM_LoadLibrary has TWO dlopen sites and BOTH need the exe-relative retry:
#   A) the `!hInst` branch: FS_FindLibrary returned NULL (fs up, couldn't find it) and
#      the code falls back to a bare dlopen( dllname ).
#   B) the resolved-path branch: FS_FindLibrary returned a stub whose fullPath is the
#      bare name (this is the "no fs loaded yet" path taken for filesystem_stdio itself,
#      see engine/common/lib_common.c) and the code does dlopen( hInst->fullPath ).
#
# Safe to re-run on a pristine tree or on one already carrying an earlier version of
# this patch: see "Revision guarding" below. Python 2.5+.
import re
import sys

# ------------------------------------------------------------------ revision --
#
# Revision guarding, issue #39. Each edit carries TWO markers.
#
#   *_GUARD  matches ANY body this script has ever written at that site.
#   *_REV    matches only the CURRENT body, and is what "already patched" tests.
#
# The loose guard keeps the job the original comment gave it, "a tree already
# carrying an earlier patch keeps its block instead of duplicating", and that job
# is a correctness requirement rather than a nicety. Edits A and INCL INSERT a
# block, they do not replace an anchor, so their anchors survive the edit: a
# guard that only matched the current revision would find the anchor still there
# and insert a SECOND copy of the block beside the first. Two exepath
# declarations in one scope do not compile, and if they did, the pair would be
# two retries of the same dlopen. So the naive "bump the marker and error on the
# old one" shape used by patch-net-no-blocking-resolve.py cannot be used here as
# it stands: it would turn a working re-run into a duplicate insertion.
#
# What the revision changes is what happens when a prior body IS found. It used
# to be kept, unexamined, which is exactly the failure in #39: a superseded fix
# pinned in place by its own guard, reported as "already patched", exit 0. Now
# the prior body is REPLACED with the current one, in place. The region to
# replace is located structurally, from upstream's own code either side of it, so
# it does not depend on knowing which older body is there. Only if the region
# cannot be identified does the script fail, loudly, and the tree has to be reset
# to its pin. It never skips a superseded body and it never duplicates a block.
#
# Bump REV whenever the emitted C changes. Every *_REV string must contain its
# *_GUARD as a substring, or a tree carrying the new body will not be recognised
# as carrying any body at all.
REV = "rev 1"

# --- edit INCL: the whereami.h include ---------------------------------------
INCL_GUARD = '#include "whereami.h"'
INCL_REV = 'oldmac fix (include), ' + REV
INCL_ANCHOR = '#include "server.h"\n'
INCL_BLOCK = (
    '#if XASH_APPLE\n'
    '#include "whereami.h" // wai_getExecutablePath: resolve engine dylibs next to the\n'
    '                      // executable when launched from a .app (cwd = "/").\n'
    '                      // ' + INCL_REV + '.\n'
    '#endif\n')

# --- edit A: bare-dlopen fallback in the !hInst branch -----------------------
# A_GUARD deliberately matches any prior variant of this block. It must not
# appear anywhere else in the file above edit A's site, which is what the
# "oldmac fix (include)" wording above keeps true: it says "oldmac fix", not
# "oldmac .app fix", so the include block cannot be mistaken for this one.
A_GUARD = 'oldmac .app fix'
A_REV = 'oldmac .app fix (bare), ' + REV
A_MARKER = 'Q_snprintf( buf, sizeof( buf ), "Failed to find library %s", dllname );'
A_BLOCK = (
    '#if XASH_APPLE\n'
    '\t\t// A Finder-launched .app runs with cwd = "/", and dyld never resolves a bare\n'
    '\t\t// leaf name against the cwd. Retry next to the executable. (' + A_REV + '.)\n'
    '\t\t{\n'
    '\t\t\tchar exepath[MAX_SYSPATH], fullpath[MAX_SYSPATH];\n'
    '\t\t\tint dirlen = 0;\n'
    '\t\t\tint exelen = wai_getExecutablePath( exepath, sizeof( exepath ) - 1, &dirlen );\n'
    '\n'
    '\t\t\tif( exelen > 0 && dirlen > 0 && dirlen < (int)sizeof( exepath ))\n'
    '\t\t\t{\n'
    '\t\t\t\texepath[dirlen] = \'\\0\';\n'
    '\t\t\t\tQ_snprintf( fullpath, sizeof( fullpath ), "%s/%s", exepath, COM_FileWithoutPath( dllname ));\n'
    '\t\t\t\tvoid *pHandleApple = dlopen( fullpath, RTLD_NOW );\n'
    '\t\t\t\tif( pHandleApple )\n'
    '\t\t\t\t\treturn pHandleApple;\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '#endif\n')

# --- edit B: exe-relative retry at the resolved-path dlopen site -------------
B_GUARD = 'oldmac .app fix (resolved)'
B_REV = 'oldmac .app fix (resolved), ' + REV
B_ANCHOR = (
    '\tif( !( hInst->hInstance = dlopen( hInst->fullPath, RTLD_NOW ) ) )\n'
    '\t{\n'
    '\t\tCOM_PushLibraryError( dlerror() );\n'
    '\t\tMem_Free( hInst );\n'
    '\t\treturn NULL;\n'
    '\t}\n')
# The first line this edit writes, and upstream's error block, which every
# revision of the edit has kept verbatim at the end of it. Together they bracket
# the region to replace on a tree that already carries some revision.
B_HEAD = '\thInst->hInstance = dlopen( hInst->fullPath, RTLD_NOW );\n'
B_TAIL = (
    '\tif( !hInst->hInstance )\n'
    '\t{\n'
    '\t\tCOM_PushLibraryError( dlerror() );\n'
    '\t\tMem_Free( hInst );\n'
    '\t\treturn NULL;\n'
    '\t}\n')
B_NEW = (
    B_HEAD +
    '#if XASH_APPLE\n'
    '\tif( !hInst->hInstance )\n'
    '\t{\n'
    '\t\t// FS_FindLibrary hands back a bare leaf name before the filesystem is up\n'
    '\t\t// (filesystem_stdio), which dyld can\'t resolve from a Finder .app (cwd="/").\n'
    '\t\t// Retry next to the executable. (' + B_REV + '.)\n'
    '\t\tchar exepath[MAX_SYSPATH], fullpath[MAX_SYSPATH];\n'
    '\t\tint dirlen = 0;\n'
    '\t\tint exelen = wai_getExecutablePath( exepath, sizeof( exepath ) - 1, &dirlen );\n'
    '\t\tif( exelen > 0 && dirlen > 0 && dirlen < (int)sizeof( exepath ))\n'
    '\t\t{\n'
    '\t\t\texepath[dirlen] = \'\\0\';\n'
    '\t\t\tQ_snprintf( fullpath, sizeof( fullpath ), "%s/%s", exepath, COM_FileWithoutPath( hInst->fullPath ));\n'
    '\t\t\thInst->hInstance = dlopen( fullpath, RTLD_NOW );\n'
    '\t\t}\n'
    '\t}\n'
    '#endif\n' +
    B_TAIL)

# --- edit C: Mach-O "__ZN..." -> "_ZN..." in COM_NameForFunction (task#41) --------
C_GUARD = 'oldmac-macho-underscore'
C_REV = C_GUARD + ' (task#41, ' + REV + ')'
C_HEAD = '\tint ret = dladdr( (void*)function, &info );\n'
C_ANCHOR = (
    C_HEAD +
    '\tif( ret && info.dli_sname )\n'
    '\t\treturn COM_GetPlatformNeutralName( info.dli_sname );\n')
C_NEW = (
    C_HEAD +
    '\tif( ret && info.dli_sname )\n'
    '\t{\n'
    '\t\tconst char *name = info.dli_sname; // ' + C_REV + '\n'
    "\t\t// Mach-O prepends '_' to symbols; on 10.3 dladdr returns it (\"__ZN...\").\n"
    '\t\t// Normalize to the ELF-style "_ZN..." that COM_DetectMangleType expects\n'
    '\t\t// so save/restore of function pointers round-trips. No-op elsewhere.\n'
    "\t\tif( name[0] == '_' && name[1] == '_' && name[2] == 'Z' )\n"
    '\t\t\tname++;\n'
    '\t\treturn COM_GetPlatformNeutralName( name );\n'
    '\t}\n')


class Unrepairable(Exception):
    """A prior body of an edit is here and its extent cannot be established."""
    pass


def _line_bounds(s, i):
    """(start, end) of the whole line containing offset i, end past the \\n."""
    return s.rfind('\n', 0, i) + 1, s.index('\n', i) + 1


def _indent_at(s, pos):
    return re.match(r'[ \t]*', s[pos:]).group(0)


def _brace_block_end(s, start):
    """End offset of the line closing the first braced block at or after start."""
    depth = 0
    i = s.index('{', start)
    while i < len(s):
        if s[i] == '{':
            depth += 1
        elif s[i] == '}':
            depth -= 1
            if depth == 0:
                return s.index('\n', i) + 1
        i += 1
    raise Unrepairable('unbalanced braces after offset %d' % start)


# ------------------------------------------------------------------- edits --

def edit_incl(s):
    """The whereami.h include, in its own XASH_APPLE block."""
    if INCL_REV in s:
        return s, False
    if INCL_GUARD in s:
        # Some revision is here. Replace the whole #if XASH_APPLE block it sits in.
        i = s.index(INCL_GUARD)
        line_start = _line_bounds(s, i)[0]
        open_at = s.rfind('#if XASH_APPLE\n', 0, line_start)
        if open_at < 0 or open_at + len('#if XASH_APPLE\n') != line_start:
            raise Unrepairable('the whereami.h include is not the first line of an '
                               '#if XASH_APPLE block')
        close_at = s.find('#endif\n', i)
        if close_at < 0:
            raise Unrepairable('no #endif closes the whereami.h include block')
        end = close_at + len('#endif\n')
        return s[:open_at] + INCL_BLOCK + s[end:], True
    if INCL_ANCHOR not in s:
        raise Unrepairable('include anchor (%s) not found' % INCL_ANCHOR.strip())
    return s.replace(INCL_ANCHOR, INCL_ANCHOR + INCL_BLOCK, 1), True


def edit_a(s):
    """The bare-dlopen fallback, inserted above the "Failed to find library" line.

    The block is bounded below by that line and above by its own #endif, so its
    extent is known without knowing its content.
    """
    if A_REV in s:
        return s, False
    if A_MARKER not in s:
        raise Unrepairable('edit-A marker (%s) not found' % A_MARKER)
    i = s.index(A_MARKER)
    line_start, line_end = _line_bounds(s, i)

    start = line_start
    if s[:line_start].endswith('#endif\n'):
        open_at = s.rfind('#if XASH_APPLE\n', 0, line_start)
        if open_at >= 0 and A_GUARD in s[open_at:line_start]:
            start = open_at
    if start == line_start and A_GUARD in s[:line_start]:
        raise Unrepairable('a prior edit-A block is above the marker line but is '
                           'not an #if XASH_APPLE ... #endif block ending at it')

    # Re-indent the marker line from the line below it, which is
    # COM_PushLibraryError( buf ) at the same depth in both engine trees and is
    # never touched by us. Deriving it rather than reusing what is in front of
    # the marker is what makes a replaced block byte identical to a freshly
    # applied one: before #39 this script inserted the block with that
    # indentation duplicated, so on a tree carrying an old block the whitespace
    # in front of the marker is two indents, not one.
    indent = _indent_at(s, line_end)
    return s[:start] + A_BLOCK + indent + s[line_start:line_end].lstrip() + s[line_end:], True


def edit_b(s):
    """The exe-relative retry at the resolved-path dlopen.

    This edit rewrites upstream's `if( !( hInst->hInstance = dlopen(...)))` into
    a plain assignment plus two tests. Every revision of it has begun with that
    assignment and ended with upstream's error block, unchanged, so those two
    bracket the region to replace.
    """
    if B_REV in s:
        return s, False
    if B_HEAD in s:
        start = s.index(B_HEAD)
        tail_at = s.find(B_TAIL, start)
        if tail_at < 0:
            raise Unrepairable('a prior edit-B block is here but upstream\'s error '
                               'block does not follow it')
        end = tail_at + len(B_TAIL)
        if B_GUARD not in s[start:end]:
            raise Unrepairable('the resolved-path dlopen is already an assignment '
                               'but carries no edit-B block')
        return s[:start] + B_NEW + s[end:], True
    if B_GUARD in s:
        raise Unrepairable('an edit-B block is here but does not start with the '
                           'assignment every revision writes')
    if B_ANCHOR not in s:
        raise Unrepairable('edit-B anchor not found')
    return s.replace(B_ANCHOR, B_NEW, 1), True


def edit_c(s):
    """The Mach-O leading-underscore normalization in COM_NameForFunction.

    Tolerant of upstream drift, as before: if neither a prior block nor the
    anchor is there, say so and leave the file alone. A prior block that cannot
    be delimited is NOT tolerated, because this is the fix the G3's save/restore
    depends on and a superseded one has to be seen.
    """
    if C_REV in s:
        return s, False
    if C_GUARD in s:
        if C_HEAD not in s:
            raise Unrepairable('an edit-C block is here but the dladdr call above '
                               'it has changed')
        start = s.index(C_HEAD)
        end = _brace_block_end(s, start)
        if C_GUARD not in s[start:end]:
            raise Unrepairable('the dladdr result is handled in a braced block '
                               'that is not ours')
        return s[:start] + C_NEW + s[end:], True
    if C_ANCHOR not in s:
        print('note: edit-C anchor absent in this file, macho-underscore skipped')
        return s, False
    return s.replace(C_ANCHOR, C_NEW, 1), True


EDITS = (
    (edit_incl, 'whereami.h include'),
    (edit_a, 'bare-dlopen fallback'),
    (edit_b, 'resolved-path retry'),
    (edit_c, 'macho-underscore normalization'),
)


def patch(path):
    s = open(path).read()
    original = s
    applied = []
    for fn, what in EDITS:
        try:
            s, changed = fn(s)
        except Unrepairable:
            # Nothing is written: the file on disk is still whatever it was, and
            # an edit that "applied" into the string above never reached it.
            info = sys.exc_info()[1]
            print('ERROR: %s: cannot apply the %s edit: %s' % (path, what, info))
            print('       This file holds a body of this fix that cannot be')
            print('       replaced in place, and nothing has been written. Reset')
            print('       the tree to its pinned commit (vendor/MANIFEST.md) and')
            print('       re-run the driver.')
            return False
        if changed:
            applied.append(what)

    if s == original:
        print('already patched: ' + path)
        return True
    open(path, 'w').write(s)
    for what in applied:
        print('  applied: ' + what)
    print('patched: ' + path)
    return True


def main():
    if len(sys.argv) < 2:
        print('usage: patch-lib-posix.py <engine>/engine/platform/posix/lib_posix.c ...')
        return 2
    ok = True
    for f in sys.argv[1:]:
        ok = patch(f) and ok
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
