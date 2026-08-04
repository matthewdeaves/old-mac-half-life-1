#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Stop the pre-flight library check calling our own mod dylibs "foreign".
#
# THE BUG THIS FIXES (found 2026-07-26 on mini-intel, shipped broken in v1.2.0):
#
# Launching ANY mod on Intel puts up a modal dialog before the game starts:
#
#     Xash3D: missing game library
#     Required : apple-amd64
#     Missing  : client, server
#     Found 32-bit libraries for these operating systems:
#         client : macOS
#         server : macOS
#
# Dismiss it and the mod plays perfectly, so it is a nag rather than a failure -
# but it appears on every single launch and what it says is not true.
#
# WHY IT FIRES. Host_CollectX86Libraries is a DIAGNOSTIC, meant to catch "you
# installed the Windows build" or "you installed a 32-bit build". It short-circuits
# only on COM_GetCommonLibraryPath's ARCH-SUFFIXED name (cl_dlls/client_amd64.dylib).
# Our mods deliberately do not use that name: each ships ONE fat dylib at the plain
# name from the mod's own liblist.gam (dlls/hl.dylib, cl_dlls/client.dylib), which
# is the whole point of patch-gamedll-plain-name.py and patch-cl-gamedir-client.py.
# So the suffixed probe misses, execution falls through to the macOS branch, that
# branch finds the plain dylib, and reports it as a foreign 32-bit library.
#
# The upstream guard on that branch is `#if !( XASH_APPLE && XASH_X86 )`, i.e. it
# only declines to flag macOS dylibs when the ENGINE is a 32-bit x86 Apple build.
# That framing is the actual mistake: on an Apple host a .dylib at the mod's own
# declared macOS path is the normal, correct thing to find, whatever the engine's
# architecture. It is evidence of a correct install, not a foreign one.
#
# THE FIX: on Apple, accept the mod's declared macOS path as satisfying the check.
#
# WHAT WE GIVE UP, stated plainly: a user who hand-copies a mod out of an i386
# original disk image, bypassing our installer and so keeping its i386-only dylibs,
# no longer gets this early warning. They now get a dlopen failure with a real error
# message instead, one step later. That is a fair trade - the pre-flight is advisory,
# it cannot tell the two cases apart anyway (Platform_LibraryExists is a bare
# FileExists, with an upstream FIXME saying exactly that), and the supported path is
# the one that should be quiet.
#
# APPLIES TO EVERY SLICE. Host_CheckGameLibraries is in every engine tree we
# build, so PowerPC and Intel both need this. The edit is inside `#if XASH_APPLE`,
# so it cannot affect any other platform.
#
# Idempotent, Python 2.5+ (the Lion build box has no modern python).
import sys

GUARD = 'oldmac: on Apple, a dylib at the mod'

ANCHOR = (
    '\tCOM_GetCommonLibraryPath( lib_type, native_path, sizeof( native_path ));\n'
    '\tif( Platform_LibraryExists( native_path, true ))\n'
    '\t\treturn 0;\n')

INSERT = ANCHOR + (
    '\n'
    '#if XASH_APPLE\n'
    '\t// oldmac: on Apple, a dylib at the mod\'s own declared macOS path is a correct\n'
    '\t// install, not a foreign one. Our mods ship ONE fat dylib per role at the plain\n'
    '\t// name from liblist.gam (dlls/hl.dylib, cl_dlls/client.dylib) rather than the\n'
    '\t// arch-suffixed name probed above, so without this every mod launch warned that\n'
    '\t// its own game code was a "32-bit macOS library".\n'
    '\tif( !COM_StringEmpty( osx_path ) && FS_FileExists( osx_path, true ))\n'
    '\t\treturn 0;\n'
    '#endif\n')

for f in sys.argv[1:]:
    s = open(f).read()

    if GUARD in s:
        print('already patched:', f)
        continue

    if s.count(ANCHOR) != 1:
        print('no anchor, skipped:', f)
        continue

    s = s.replace(ANCHOR, INSERT, 1)

    open(f, 'w').write(s)
    print('patched:', f)
