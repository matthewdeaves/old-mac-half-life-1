#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Stop asking SDL's Cocoa backend for a GL profile it cannot provide (issue #21).
#
# Every launch logged:
#   Error: VID_CreateWindow: SDL_GL_CreateContext: Failed creating OpenGL context
#          at version requested
#   Error: VID_SetMode: couldn't create GL context with safegl level 0: ...
#
# GL_SetupAttributes( safegl ) asks for REF_GL_CONTEXT_PROFILE_COMPATIBILITY at
# safegl 0 without naming a version. SDL's Cocoa backend implements no
# compatibility-profile path at all, so a profile_mask that is neither 0 nor CORE
# falls straight through to SDL_SetError( "Failed creating OpenGL context at
# version requested" ) and no context is created.
#
# What made this worth fixing rather than ignoring is what the engine does next.
# It retries at the following safegl level. SAFE_NOMSAA (1) sorts before
# SAFE_NOACC (2) and gl_msaa_samples is 0, so the retry lands on SAFE_NOACC,
# which is precisely the level that stops requesting REF_GL_ACCELERATED_VISUAL.
# The context we actually ran on was therefore the unaccelerated fallback of a
# first attempt that could never have succeeded. Removing the impossible request
# lets the first attempt succeed, and the accelerated visual is asked for as
# intended.
#
# The two branches were mutually exclusive on !safegl and safegl, so dropping
# only the profile hint on Apple needs no second copy of the version lines: the
# guard goes around the hint alone and the safegl branch is shared. Every other
# platform compiles to exactly what it had before.
#
# Idempotent. Python 2.5+.
import os
import sys

MARKER = 'oldmac: no profile hint on Apple'

ANCHOR = (
	'\telse\n'
	'\t{\n'
	'\t\tif( !safegl )\n'
	'\t\t\tgEngfuncs.GL_SetAttribute( REF_GL_CONTEXT_PROFILE_MASK, REF_GL_CONTEXT_PROFILE_COMPATIBILITY );\n'
	'\t\telse\n'
	'\t\t{\n'
	'\t\t\tgEngfuncs.GL_SetAttribute( REF_GL_CONTEXT_MAJOR_VERSION, 1 );\n'
	'\t\t\tgEngfuncs.GL_SetAttribute( REF_GL_CONTEXT_MINOR_VERSION, 1 );\n'
	'\t\t}\n'
	'\t}\n'
)

NEW = (
	'\telse\n'
	'\t{\n'
	'\t\t// ' + MARKER + ': the Cocoa backend has no compatibility-profile\n'
	'\t\t// path, so asking for one fails context creation outright, and the retry\n'
	'\t\t// then lands on the safegl level that also drops the accelerated visual.\n'
	'\t\t// Ask for no profile there and take the system legacy context.\n'
	'#if !defined( __APPLE__ )\n'
	'\t\tif( !safegl )\n'
	'\t\t\tgEngfuncs.GL_SetAttribute( REF_GL_CONTEXT_PROFILE_MASK, REF_GL_CONTEXT_PROFILE_COMPATIBILITY );\n'
	'#endif\n'
	'\t\tif( safegl )\n'
	'\t\t{\n'
	'\t\t\tgEngfuncs.GL_SetAttribute( REF_GL_CONTEXT_MAJOR_VERSION, 1 );\n'
	'\t\t\tgEngfuncs.GL_SetAttribute( REF_GL_CONTEXT_MINOR_VERSION, 1 );\n'
	'\t\t}\n'
	'\t}\n'
)


def patch(path):
	s = open(path).read()
	if MARKER in s:
		print('already patched: ' + path)
		return
	n = s.count(ANCHOR)
	assert n == 1, ('anchor found %d times (want 1) in %s' % (n, path))
	s = s.replace(ANCHOR, NEW, 1)
	open(path, 'w').write(s)
	print('patched: ' + path)


def main():
	if len(sys.argv) < 2:
		print('usage: patch-gl-apple-context.py <engine-tree-or-gl_opengl.c> ...')
		return 1
	for arg in sys.argv[1:]:
		if os.path.isdir(arg):
			patch(os.path.join(arg, 'ref', 'gl', 'gl_opengl.c'))
		else:
			patch(arg)
	return 0


if __name__ == '__main__':
	sys.exit(main())
