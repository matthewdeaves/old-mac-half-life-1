#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Prefer the CURRENT gamedir's client library over the base game's.
#
# THE BUG THIS FIXES (found 2026-07-26, shipped broken in v1.2.0):
#
# CL_Init asks for an arch-suffixed client library, cl_dlls/client_ppc.dylib. That
# name goes through FS_FindFile, which walks EVERY mounted searchpath and has no
# gamedir restriction at all. Our mods ship exactly one fat dylib per role, at the
# plain unsuffixed name cl_dlls/client.dylib (see patch-gamedll-plain-name.py for
# why). A mod therefore has no client_ppc.dylib of its own, the search falls
# through to valve's, that load SUCCEEDS, and the plain-name retry below it never
# runs. Every mod was quietly playing with Half-Life's client code: its HUD, its
# weapon prediction, its view code.
#
# The server side was never affected, because liblist.gam names the server dylib
# explicitly (dlls/opfor.dylib) and no other gamedir has that name.
#
# THE FIX: if the suffixed name is not present in the running gamedir but a plain
# client library IS, use the plain one. FS_FileExists( name, true ) restricts the
# search to FS_GAMEDIR_PATH | FS_CUSTOM_PATH | FS_GAMERODIR_PATH, i.e. the mod's
# own directories, so this only fires when the mod really does ship its own client
# code. A mod that deliberately inherits valve's client (neither name present in
# its gamedir) is untouched, and so is plain valve, whose client_<arch>.dylib we
# ship inside the app bundle rather than in a gamedir at all.
#
# Both trees carry the identical call site, so one anchor serves both. Idempotent,
# Python 2.5+ (the Lion build box has no modern python).
import sys

GUARD = 'oldmac: prefer a client library shipped by the CURRENT gamedir'

ANCHOR = '\tCOM_GetCommonLibraryPath( LIBRARY_CLIENT, libpath, sizeof( libpath ));\n'

INSERT = ANCHOR + (
    '\n'
    '\t// oldmac: prefer a client library shipped by the CURRENT gamedir.\n'
    '\t// libpath is arch-suffixed (cl_dlls/client_ppc.dylib) and FS_FindFile searches\n'
    '\t// every mounted searchpath, not just the running mod\'s, so a mod that ships only\n'
    '\t// the plain cl_dlls/client.dylib used to resolve this to VALVE\'s client and run\n'
    '\t// with Half-Life\'s HUD and weapon code. Restricting the probe to the gamedir\n'
    '\t// means we only override when the mod genuinely has client code of its own;\n'
    '\t// a mod that deliberately inherits valve\'s client still gets it.\n'
    '\t{\n'
    '\t\tstring gamedirlib;\n'
    '\n'
    '\t\tQ_snprintf( gamedirlib, sizeof( gamedirlib ), "%s/client." OS_LIB_EXT, GI->dll_path );\n'
    '\n'
    '\t\tif( !FS_FileExists( libpath, true ) && FS_FileExists( gamedirlib, true ))\n'
    '\t\t{\n'
    '\t\t\tCon_Reportf( "%s: using gamedir client library %s\\n", __func__, gamedirlib );\n'
    '\t\t\tQ_strncpy( libpath, gamedirlib, sizeof( libpath ));\n'
    '\t\t}\n'
    '\t}\n')

for f in sys.argv[1:]:
    s = open(f).read()

    if GUARD in s:
        print('already patched:', f)
        continue

    assert s.count(ANCHOR) == 1, ('expected exactly one client-libpath anchor in ' + f)
    s = s.replace(ANCHOR, INSERT, 1)

    open(f, 'w').write(s)
    print('patched:', f)
