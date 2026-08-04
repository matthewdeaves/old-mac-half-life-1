#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Load a mod's game code from the PLAIN, unsuffixed dylib name as well as from the
architecture-suffixed one.

Why this exists

Xash names game libraries per architecture: dlls/bshift_amd64.dylib,
cl_dlls/client_ppc.dylib (3rdparty/library_suffix). That forces one file per
architecture, so a single mod folder would need four game dylibs to cover a
fleet of G3, G4, G5 and Intel machines.

Mach-O already solves this: one fat dylib holding every slice. To use one, the
engine has to be willing to open the plain name the mod itself wrote in its
liblist.gam, dlls/bshift.dylib, which is also the name the circulating Mac mod
releases already ship. Then a single fat ppc+x86_64 file drops straight in and
installing a mod is a file copy.

The engine will not do that on either of our architectures.
COM_GenerateServerLibraryPath has a branch that uses the gameinfo name verbatim,
but it is gated on XASH_X86 && XASH_APPLE, and XASH_X86 means i386 only: x86_64
sets XASH_AMD64 instead. So our Intel slice and both PowerPC slices take the
generic branch, which rewrites the name through COM_GenerateCommonLibraryName
and appends the architecture suffix. The client side never had any retry at all:
CL_Init calls Host_Error the moment the first name misses.

So this adds two fallbacks and one leak fix:

  1. SV_InitGame retries the gameinfo name when the suffixed server dylib misses.
  2. CL_Init does the same for the client dylib before it gives up.
  3. CL_LoadProgs frees the two memory pools it allocates before the load on
     every one of its failure exits, which matters only once a retry exists.

Both fallbacks are strictly secondary: the suffixed name is still tried first and
still wins when it is present, so an existing valve/ layout carrying
hl_ppc.dylib and hl_amd64.dylib keeps working untouched. Neither can fire except
after a load has already failed, so no working configuration changes behaviour.

Invoke:
    python patch-gamedll-plain-name.py <engine-tree> [<engine-tree> ...]
where each <engine-tree> is the root of an xash3d-fwgs checkout (the directory
that contains engine/client/cl_main.c).
"""
import os
import sys

# ---------------------------------------------------------------------------
# 1. engine/common/library.h - declare the helper
# ---------------------------------------------------------------------------
HDR_MARKER = 'COM_GameDllNameFromGameInfo'
HDR_ANCHOR = 'void COM_GetCommonLibraryPath( ECommonLibraryType eLibType, char *out, size_t size );\n'
HDR_NEW = (HDR_ANCHOR +
           'const char *COM_GameDllNameFromGameInfo( void );\n')

# ---------------------------------------------------------------------------
# 2. engine/common/lib_common.c - define the helper
#
# It returns a pointer into the gameinfo rather than filling a caller's buffer.
# There is nothing to size and nothing to truncate, and a NULL return says "this
# mod named no library for this platform" in the same test that reads it. The
# callers copy it into their own string before doing anything that could reload
# the gameinfo underneath them.
# ---------------------------------------------------------------------------
LIB_MARKER = 'COM_GameDllNameFromGameInfo'
# Anchor on the closing brace of COM_GetCommonLibraryPath's switch/function.
LIB_ANCHOR = """	default:
		ASSERT( 0 );
		out[0] = 0;
		break;
	}
}
"""
LIB_NEW = LIB_ANCHOR + """
/*
==============
COM_GameDllNameFromGameInfo

The game library path exactly as the mod wrote it in its own liblist.gam or
gameinfo.txt, for the platform we are running on, e.g. dlls/bshift.dylib.

COM_GenerateServerLibraryPath rewrites that name to an architecture-suffixed one
on every target except i386 Apple, which is what stops a single fat Mach-O dylib
from serving a whole fleet. This returns the unsuffixed original so a caller can
retry it when the generated name misses.

Returns NULL when the mod named no library for this platform, so the caller tests
one value and never has to size a buffer. The pointer is into the gameinfo, so
copy it before doing anything that could reload the gameinfo.
==============
*/
const char *COM_GameDllNameFromGameInfo( void )
{
	const char *name;

	if( !GI )
		return NULL;

#if XASH_WIN32
	name = GI->game_dll;
#elif XASH_APPLE
	name = GI->game_dll_osx;
#else
	name = GI->game_dll_linux;
#endif

	return COM_StringEmptyOrNULL( name ) ? NULL : name;
}
"""

# ---------------------------------------------------------------------------
# 3. engine/server/sv_init.c - retry the plain server dylib name
# ---------------------------------------------------------------------------
SV_MARKER = 'COM_GameDllNameFromGameInfo'
SV_ANCHOR = """	if( !SV_LoadProgs( dllpath ))
	{
		if( !silent )
			Sys_Warn( "can't initialize %s: %s\\n", dllpath, COM_GetLibraryError( ));
		else
			Con_Printf( S_ERROR "can't initialize %s: %s\\n", dllpath, COM_GetLibraryError( ));
		return false; // failed to loading server.dll
	}

	// client frames will be allocated in SV_ClientConnect
	return true;
"""
SV_NEW = """	if( SV_LoadProgs( dllpath ))
	{
		// client frames will be allocated in SV_ClientConnect
		return true;
	}

	// oldmac: the name above is architecture-suffixed (dlls/bshift_amd64.dylib). Mods
	// ship the plain name from their own liblist.gam (dlls/bshift.dylib), which lets
	// ONE fat ppc+x86_64 dylib serve the whole fleet. Retry it before giving up.
	if( COM_StringEmpty( host.gamedll ))
	{
		const char *plain = COM_GameDllNameFromGameInfo();

		if( plain && Q_stricmp( plain, dllpath ) != 0 )
		{
			string retry;

			// copy first: SV_LoadProgs can reach the filesystem, and plain points
			// into the gameinfo it would be reloading.
			Q_strncpy( retry, plain, sizeof( retry ));

			if( SV_LoadProgs( retry ))
				return true;
		}
	}

	if( !silent )
		Sys_Warn( "can't initialize %s: %s\\n", dllpath, COM_GetLibraryError( ));
	else
		Con_Printf( S_ERROR "can't initialize %s: %s\\n", dllpath, COM_GetLibraryError( ));
	return false; // failed to loading server.dll
"""

# ---------------------------------------------------------------------------
# 4. engine/client/cl_main.c - retry the plain client dylib name
#    (identical snippet in both trees, so one anchor covers them)
# ---------------------------------------------------------------------------
CL_MARKER = 'oldmac: plain client dylib fallback'
CL_ANCHOR = """	if( !CL_LoadProgs( libpath ))
		Host_Error( "can't initialize %s: %s\\n", libpath, COM_GetLibraryError( ));
"""
CL_NEW = """	if( !CL_LoadProgs( libpath ))
	{
		// oldmac: plain client dylib fallback. libpath above is arch-suffixed
		// (cl_dlls/client_amd64.dylib); mods ship the unsuffixed cl_dlls/client.dylib
		// that GoldSrc and the existing Mac ports use, so ONE fat ppc+x86_64 dylib can
		// serve every slice. Mirrors the server-side retry in SV_InitGame().
		string plainpath;

		Q_snprintf( plainpath, sizeof( plainpath ), "%s/client." OS_LIB_EXT, GI->dll_path );

		if( !Q_stricmp( plainpath, libpath ) || !CL_LoadProgs( plainpath ))
			Host_Error( "can't initialize %s (nor %s): %s\\n", libpath, plainpath, COM_GetLibraryError( ));
	}
"""

# ---------------------------------------------------------------------------
# 5. engine/client/.../cl_game.c - don't strand memory pools on a failed load
#
# CL_LoadProgs() allocates cls.mempool and clgame.mempool up front, before it
# tries to dlopen the client library. It then has THREE failure exits, and each
# leaves clgame.hInstance NULL:
#     a) COM_LoadLibrary() returned NULL         (dylib missing / wrong arch)
#     b) missed_exports                          (loaded, essential exports absent)
#     c) pfnInitialize() returned false          (loaded, refused to start)
# CL_UnloadProgs() is what normally frees exactly those two pools, and it returns
# early when hInstance is NULL - so on all three paths nothing can reclaim them.
#
# Upstream this is invisible: the sole caller answers a false return with
# Host_Error, and the process is on its way down. Our plain-name fallback retries
# instead, so without this every mod launch that misses the arch-suffixed name
# strands a pair of pools. (b) and (c) matter most in practice: they are what a
# mod dylib that loads but is built wrong will hit.
#
# Freeing is safe here. VGui_Startup() may have run just before the load, but
# VGui allocates from neither pool.
# ---------------------------------------------------------------------------
POOL_MARKER = 'CL_FreeProgsPools'

POOL_HELPER_ANCHOR = """qboolean CL_LoadProgs( const char *name )
{
"""
POOL_HELPER_NEW = """/*
=================
CL_FreeProgsPools

oldmac: release the two pools CL_LoadProgs allocates before it tries to load the
library. Every failure exit from CL_LoadProgs leaves clgame.hInstance NULL, and
the normal teardown that frees exactly these two, CL_UnloadProgs(), bails out on
a NULL hInstance, so nothing else can reclaim them. Upstream that never shows,
because a false return is followed by Host_Error. Our plain-name fallback retries
instead, so each attempt would otherwise strand another pair.
=================
*/
static void CL_FreeProgsPools( void )
{
	Mem_FreePool( &cls.mempool );
	Mem_FreePool( &clgame.mempool );
}

""" + POOL_HELPER_ANCHOR

# (a) the library itself would not load
POOL_A_ANCHOR = """	if( !clgame.hInstance )
		return false;
"""
POOL_A_NEW = """	if( !clgame.hInstance )
	{
		CL_FreeProgsPools();
		return false;
	}
"""

# (b) loaded, but essential exports are missing
POOL_B_ANCHOR = """		COM_FreeLibrary( clgame.hInstance );
		clgame.hInstance = NULL;
		return false;
	}

	// it may be loaded through 'GetClientAPI' so we don't need to clear them
"""
POOL_B_NEW = """		COM_FreeLibrary( clgame.hInstance );
		clgame.hInstance = NULL;
		CL_FreeProgsPools();
		return false;
	}

	// it may be loaded through 'GetClientAPI' so we don't need to clear them
"""

# (c) loaded, but the client API refused to initialize
POOL_C_ANCHOR = """		COM_PushLibraryError( "can't init client API" );
		COM_FreeLibrary( clgame.hInstance );
		Con_Reportf( "%s: can't init client API\\n", __func__ );
		clgame.hInstance = NULL;
		return false;
"""
POOL_C_NEW = """		COM_PushLibraryError( "can't init client API" );
		COM_FreeLibrary( clgame.hInstance );
		Con_Reportf( "%s: can't init client API\\n", __func__ );
		clgame.hInstance = NULL;
		CL_FreeProgsPools();
		return false;
"""

CL_GAME_CANDIDATES = [
    os.path.join("engine", "client", "dll_int", "cl_game.c"),
]

# (relative path, marker, anchor, replacement, human description)
EDITS = [
    (os.path.join("engine", "common", "library.h"),
     HDR_MARKER, HDR_ANCHOR, HDR_NEW, "declare COM_GameDllNameFromGameInfo"),
    (os.path.join("engine", "common", "lib_common.c"),
     LIB_MARKER, LIB_ANCHOR, LIB_NEW, "define COM_GameDllNameFromGameInfo"),
    (os.path.join("engine", "server", "sv_init.c"),
     SV_MARKER, SV_ANCHOR, SV_NEW, "server plain-name retry"),
    (os.path.join("engine", "client", "cl_main.c"),
     CL_MARKER, CL_ANCHOR, CL_NEW, "client plain-name retry"),
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


def patch_pools(tree):
    """The four cl_game.c edits, applied as one unit under a single marker.

    Kept separate from EDITS because they share a marker and a file whose path
    differs between the two engine vintages, and because it is all-or-nothing:
    the helper is dead code unless every call site lands.
    """
    path = None
    for cand in CL_GAME_CANDIDATES:
        p = os.path.join(tree, cand)
        if os.path.isfile(p):
            path = p
            break
    if path is None:
        print("  ERROR: cl_game.c not found (looked in %s)"
              % ", ".join(CL_GAME_CANDIDATES))
        return False

    rel = path[len(tree):].lstrip(os.sep)

    f = open(path, "r")
    src = f.read()
    f.close()

    if POOL_MARKER in src:
        print("  already patched (pool cleanup): %s" % rel)
        return True

    edits = [
        (POOL_HELPER_ANCHOR, POOL_HELPER_NEW, "CL_FreeProgsPools helper"),
        (POOL_A_ANCHOR, POOL_A_NEW, "free pools: library would not load"),
        (POOL_B_ANCHOR, POOL_B_NEW, "free pools: essential exports missing"),
        (POOL_C_ANCHOR, POOL_C_NEW, "free pools: client API init failed"),
    ]

    # Check every anchor before writing anything, and insist each is unique -
    # a silent second match would put the cleanup call in the wrong function.
    for anchor, _new, what in edits:
        n = src.count(anchor)
        if n != 1:
            print("  ERROR: anchor for '%s' matched %d times in %s (want 1)"
                  % (what, n, rel))
            return False

    for anchor, new, what in edits:
        src = src.replace(anchor, new, 1)
        print("  patched (%s): %s" % (what, rel))

    f = open(path, "w")
    f.write(src)
    f.close()
    return True


def patch_tree(tree):
    ok = True
    for relpath, marker, anchor, new, what in EDITS:
        ok = patch_file(tree, relpath, marker, anchor, new, what) and ok
    ok = patch_pools(tree) and ok
    return ok


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
