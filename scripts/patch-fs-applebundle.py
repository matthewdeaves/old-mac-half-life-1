#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Give a double-clicked .app a read-only game root inside its own bundle.
#
# THE PROBLEM
#
# Finder starts an application with the working directory set to "/", so nothing
# the engine derives from the cwd is any use. FS_DetermineRootDirectory already
# does the right thing for the WRITABLE root inside a bundle - it takes the
# Application Support path - but FS_DetermineReadOnlyRootDirectory has no Apple
# case at all. It honours -rodir and XASH3D_RODIR, has a branch for iOS, and then
# returns false. A user who double-clicks the app passes no arguments, so the
# engine comes up with no game directory and reports that valve does not exist.
#
# Our payload lives inside the bundle at Contents/Resources/Half-Life, with the
# gamedir directly beneath it (docs/adr/0006). So the fix is to point the
# read-only root there when we are running from a bundle.
#
# HOW THIS ONE DECIDES, AND WHY
#
# Two things are easy to get wrong here, and both are avoided deliberately.
#
# 1. Find the bundle from the EXECUTABLE, not from the working directory and not
#    from a substring test. _NSGetExecutablePath gives the absolute path of the
#    running binary whatever the cwd is, and we then require the real bundle
#    shape: the executable's parent must be MacOS and its grandparent Contents.
#    A test like "does the path contain .app" would also accept /Users/x.apps/y
#    and any directory a user happened to name that way.
#
# 2. Accept the candidate on EXISTENCE, and nothing more. The path is inside our
#    own bundle, so if the directory is there it is ours.
#
#    Testing for a gamedir marker underneath, a liblist.gam or a gameinfo.txt,
#    looks more principled and is wrong here. It was tried and it broke the
#    Intel build outright. Our payload carries no marker on purpose:
#    FS_ParseGameInfo registers any directory holding one as a Custom Game, and
#    listdirectory does not skip dotted names, so a marker in the read-only root
#    is what used to produce a phantom Custom Game entry. A test for something
#    we deliberately do not ship can only ever fail, and it fails silently, as
#    "missing game library" while the dylibs sit unread inside the bundle.
#
# The 10.3.9 SDK declares _NSGetExecutablePath with an unsigned long * length,
# 10.4 and later with a uint32_t *. Same width on ppc32, distinct types, so the
# older prototype gets a cast and everything else takes the plain path.
#
# Idempotent. Python 2.5+.
import sys

GUARD = 'FS_MacBundleReadOnlyRoot'

FUNC_ANCHOR = 'static qboolean FS_DetermineReadOnlyRootDirectory( char *out, size_t size )\n'

FUNC = (
	'#if XASH_APPLE && !XASH_IOS\n'
	'#include <AvailabilityMacros.h> // MAC_OS_X_VERSION_MAX_ALLOWED, for the SDK test below.\n'
	'                               // Nothing else in this file pulls it in, and an\n'
	'                               // undefined macro here would silently pick the wrong\n'
	'                               // _NSGetExecutablePath prototype on the 10.3 SDK.\n'
	'#include <mach-o/dyld.h> // _NSGetExecutablePath\n'
	'#include <sys/stat.h>    // stat, S_ISREG\n'
	'\n'
	'/*\n'
	'================\n'
	'FS_MacBundleHasPayload\n'
	'\n'
	'True when dir exists and is a directory.\n'
	'\n'
	'That is the whole test, deliberately. This path is inside our own .app, so if it\n'
	'is there at all it is ours and nobody else could have put it there.\n'
	'\n'
	'It is tempting to be stricter and require a gamedir marker underneath, a\n'
	'liblist.gam or a gameinfo.txt. That is wrong here and was tried: our payload\n'
	'carries neither on purpose. FS_ParseGameInfo registers any directory holding one\n'
	'as a Custom Game, and listdirectory does not skip dotted names, so a marker in\n'
	'the read-only root is exactly what used to put a phantom entry in the Custom Game\n'
	'list. Requiring the marker means the root is never accepted, the payload is never\n'
	'mounted, and the engine reports the game libraries missing while they sit in the\n'
	'bundle unread.\n'
	'================\n'
	'*/\n'
	'static qboolean FS_MacBundleHasPayload( const char *dir )\n'
	'{\n'
	'\tstruct stat st;\n'
	'\n'
	'\treturn stat( dir, &st ) == 0 && S_ISDIR( st.st_mode ) ? true : false;\n'
	'}\n'
	'\n'
	'/*\n'
	'================\n'
	'FS_MacBundleReadOnlyRoot\n'
	'\n'
	'Point the read-only root at the payload inside our own .app.\n'
	'\n'
	'Finder launches with cwd = "/", so the bundle has to be found from the running\n'
	'executable. We require the genuine bundle shape - <name>.app/Contents/MacOS/<exe>\n'
	'- rather than testing whether the path happens to contain ".app" anywhere, and\n'
	'we only accept the result if it really holds a gamedir.\n'
	'================\n'
	'*/\n'
	'static qboolean FS_MacBundleReadOnlyRoot( char *out, size_t size )\n'
	'{\n'
	'\tchar exe[MAX_OSPATH], candidate[MAX_OSPATH];\n'
	'\tuint32_t exelen = sizeof( exe );\n'
	'\tchar *macos, *contents;\n'
	'\n'
	'#if defined( MAC_OS_X_VERSION_MAX_ALLOWED ) && MAC_OS_X_VERSION_MAX_ALLOWED < 1040\n'
	'\t// the 10.3.9 SDK takes an unsigned long *; same width on ppc32, different type\n'
	'\tif( _NSGetExecutablePath( exe, (unsigned long *)&exelen ) != 0 )\n'
	'#else\n'
	'\tif( _NSGetExecutablePath( exe, &exelen ) != 0 )\n'
	'#endif\n'
	'\t\treturn false;\n'
	'\n'
	'\t// .../Half-Life.app/Contents/MacOS/xash3d.bin -> strip the leaf, then MacOS,\n'
	'\t// and check the two names are the ones a real bundle has.\n'
	"\tif(( macos = Q_strrchr( exe, '/' )) == NULL )\n"
	'\t\treturn false;\n'
	'\t*macos = 0;\n'
	'\n'
	"\tif(( contents = Q_strrchr( exe, '/' )) == NULL )\n"
	'\t\treturn false;\n'
	'\tif( Q_strcmp( contents + 1, "MacOS" ))\n'
	'\t\treturn false;\n'
	'\t*contents = 0;\n'
	'\n'
	'\tif( Q_strrchr( exe, \'/\' ) == NULL || Q_strcmp( Q_strrchr( exe, \'/\' ) + 1, "Contents" ))\n'
	'\t\treturn false;\n'
	'\n'
	'\tQ_snprintf( candidate, sizeof( candidate ), "%s/Resources/Half-Life", exe );\n'
	'\tCOM_FixSlashes( candidate );\n'
	'\n'
	'\tif( !FS_MacBundleHasPayload( candidate ))\n'
	'\t\treturn false;\n'
	'\n'
	'\tQ_strncpy( out, candidate, size );\n'
	'\treturn true;\n'
	'}\n'
	'#endif // XASH_APPLE && !XASH_IOS\n'
	'\n')

CALL_ANCHOR = (
	'#if XASH_IOS\n'
	'\tQ_strncpy( out, IOS_GetExecDir(), size );\n'
	'\treturn true;\n'
	'#endif\n'
	'\n'
	'\treturn false;\n'
	'}\n')

CALL_NEW = (
	'#if XASH_IOS\n'
	'\tQ_strncpy( out, IOS_GetExecDir(), size );\n'
	'\treturn true;\n'
	'#endif\n'
	'\n'
	'#if XASH_APPLE && !XASH_IOS\n'
	'\t// last, so -rodir and XASH3D_RODIR still win: a developer running from a\n'
	'\t// checkout must be able to override what the bundle happens to contain.\n'
	'\tif( FS_MacBundleReadOnlyRoot( out, size ))\n'
	'\t\treturn true;\n'
	'#endif\n'
	'\n'
	'\treturn false;\n'
	'}\n')

for f in sys.argv[1:]:
	s = open(f).read()
	if GUARD in s:
		print('already patched:', f)
		continue

	assert FUNC_ANCHOR in s, ('func anchor not found in ' + f)
	assert CALL_ANCHOR in s, ('call anchor not found in ' + f)

	s = s.replace(FUNC_ANCHOR, FUNC + FUNC_ANCHOR, 1)
	s = s.replace(CALL_ANCHOR, CALL_NEW, 1)

	open(f, 'w').write(s)
	print('patched:', f)
