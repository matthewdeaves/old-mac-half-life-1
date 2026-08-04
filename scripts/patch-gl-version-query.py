#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Stop ref_gl asking a legacy OpenGL context for an OpenGL 3.0 enum.
#
# GL_InitExtensions() reads the context version with
#
#	pglGetIntegerv( GL_MAJOR_VERSION, &major );
#	pglGetIntegerv( GL_MINOR_VERSION, &minor );
#
# GL_MAJOR_VERSION (0x821B) and GL_MINOR_VERSION (0x821C) are OpenGL 3.0 state. A
# 1.x or 2.x context does not have it, so both calls raise GL_INVALID_ENUM and set
# the error flag. Nothing in that function clears it, and the renderer's only other
# reader of the error queue is GL_CheckTexImageError(), which runs after every
# texture upload. The first texture uploaded is the engine's built-in "*default"
# placeholder, so the stale flag was reported against it:
#
#	OpenGL Error: GL_INVALID_ENUM while uploading *default [2D]
#
# once per launch, on every machine, with no texture problem behind it. Measured
# directly with a standalone CGL program (2026-07-27):
#
#	Intel GMA 950,   GL 1.4 APPLE-7.4.1, 10.7.5    -> GL_INVALID_ENUM
#	ATI Radeon 9600, GL 2.0 ATI-1.5.48,  10.5.8 G5 -> GL_INVALID_ENUM
#
# Two queries but one report, because the GL error state is a set of flags: both
# calls set the same GL_INVALID_ENUM flag and one pglGetError() clears it.
#
# The fix reads the version STRING first and only asks the driver for the integer
# state when the context is actually 3.0 or newer. The surrounding code already
# parses the string whenever major comes back 0, so this changes no behaviour on
# any context; it only stops asking a question the driver is entitled to refuse.
#
# Applied to all three engine trees. Idempotent, marker-guarded. Python 2.5+.
import sys

GUARD = 'oldmac: GL_MAJOR_VERSION is an OpenGL 3.0 enum'

OLD = (
	'\tpglGetIntegerv( GL_MAJOR_VERSION, &major );\n'
	'\tpglGetIntegerv( GL_MINOR_VERSION, &minor );\n')

NEW = (
	'\t// ' + GUARD + ', so a 1.x or 2.x context\n'
	'\t// answers it with GL_INVALID_ENUM and leaves the flag set. Nothing here\n'
	'\t// clears it, so the next reader of the error queue picks it up: that is\n'
	'\t// GL_CheckTexImageError() on the first texture uploaded, which is why every\n'
	'\t// launch logged one bogus "GL_INVALID_ENUM while uploading *default" on\n'
	'\t// hardware 20 years apart (GL 1.4 GMA 950, GL 2.0 Radeon 9600, Rosetta 2).\n'
	'\t// The block below already falls back to the version string when major is 0,\n'
	'\t// so read the string first and only ask when the enum actually exists.\n'
	'\t{\n'
	'\t\tconst char *vstr = glConfig.version_string;\n'
	'\n'
	'\t\tif( vstr )\n'
	'\t\t{\n'
	'\t\t\twhile( *vstr && ( *vstr < \'0\' || *vstr > \'9\' )) vstr++;\n'
	'\n'
	'\t\t\tif( Q_atof( vstr ) >= 3.0f )\n'
	'\t\t\t{\n'
	'\t\t\t\tpglGetIntegerv( GL_MAJOR_VERSION, &major );\n'
	'\t\t\t\tpglGetIntegerv( GL_MINOR_VERSION, &minor );\n'
	'\t\t\t}\n'
	'\t\t}\n'
	'\t}\n')

rc = 0

for f in sys.argv[1:]:
	s = open(f).read()
	if GUARD in s:
		print('already patched: ' + f)
		continue
	if OLD not in s:
		print('ERROR: anchor not found in ' + f)
		rc = 1
		continue
	s = s.replace(OLD, NEW, 1)
	open(f, 'w').write(s)
	print('patched: ' + f)

sys.exit(rc)
