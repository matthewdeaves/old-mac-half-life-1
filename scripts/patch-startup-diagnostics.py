#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Two startup lines that describe normal states as problems (issue #21).
#
# Both fire on every launch of all four bench machines, and neither reports a
# fault. Neither change hides a failure: in both cases there is no failure, and
# the existing text says otherwise.
#
# 1. "Warning: SV_LoadProgs: couldn't get physics API"
#
#    SV_InitPhysicsAPI( sv_phys.c ) has three outcomes and only two return values:
#
#      symbol absent                    clears features, returns TRUE,  silent
#      symbol present, returns FALSE    clears features, returns FALSE, warns
#      symbol present, returns TRUE     installs the interface
#
#    The first two reach an IDENTICAL end state. The engine clears
#    svgame.physFuncs, calls Host_ValidateEngineFeatures with 0, and carries on;
#    nothing whatsoever differs afterwards. Only the return value differs, and
#    with it the warning.
#
#    hlsdk-portable takes the second path deliberately, in both our trees and
#    upstream ( dlls/cbase.cpp:130-134 ):
#
#      int Server_GetPhysicsInterface( int version, server_physics_api_t *api,
#                                      physics_interface_t *interface )
#      {
#          g_fIsXash3D = true;
#          return FALSE; // do not tell engine to init physics interface, as we're not using it
#      }
#
#    It cannot answer by being absent, because the call is also how it detects
#    that it is running under Xash3D at all and sets g_fIsXash3D. Half-Life's game
#    code does not use the extended physics interface, so declining it is correct.
#
#    The result is a warning guaranteed on every launch of every Xash3D plus
#    hlsdk-portable build, stock valve included, describing an outcome the engine
#    itself treats as unremarkable. It moves to Con_Reportf, to match the other
#    "which optional interface did we get" lines. The genuinely interesting case,
#    the interface being installed, is already a Con_Reportf at sv_phys.c and is
#    untouched.
#
#    The new text names what was OBSERVED rather than why. The engine cannot tell
#    a deliberate decline from a FALSE returned over a version mismatch, so
#    calling it "declined" would be a guess printed as a fact, and wrong for any
#    third-party dylib not built from hlsdk-portable.
#
#    Not fixed here, and deliberately: that ambiguity itself. Separating the two
#    cases would mean changing the game/engine ABI, which would diverge from
#    upstream and break other games' dylibs. It is a real limitation of the
#    interface and is left as it is rather than papered over.
#
# 2. "AVI: Not supported"
#
#    Printed by AVI_Initailize when XASH_AVI == AVI_NULL, which is what
#    common/defaults.h resolves to whenever HAVE_FFMPEG is unset. No machine here
#    has FFmpeg and none is going to, so this states a fixed build configuration
#    rather than a runtime condition. The four sibling lines in the same file that
#    report which FFmpeg version was loaded are already Con_Reportf; this one
#    matches them.
#
# Applies to both engine trees. Idempotent. Python 2.5+.
import os
import sys

MARKER_PHYS = 'oldmac: declining the interface is not a failure'
MARKER_AVI = 'oldmac: build configuration, not a fault'

ANCHOR_PHYS = '\t\tCon_Printf( S_WARN "%s: couldn\'t get physics API\\n", __func__ );\n'
NEW_PHYS = (
	'\t\t// ' + MARKER_PHYS + '. hlsdk-portable exports\n'
	'\t\t// Server_GetPhysicsInterface only to detect Xash3D and returns FALSE on\n'
	'\t\t// purpose, and the engine ends up in exactly the state it would have\n'
	'\t\t// reached had the symbol been missing, which it does not warn about.\n'
	'\t\t// State what was OBSERVED, not why: the engine cannot tell a deliberate\n'
	'\t\t// decline from a FALSE returned over a version mismatch, and a\n'
	'\t\t// third-party dylib might mean the latter.\n'
	'\t\tCon_Reportf( "%s: Server_GetPhysicsInterface returned FALSE, no extended '
	'physics\\n", __func__ );\n'
)

ANCHOR_AVI = '\t\tCon_Printf( "AVI: Not supported\\n" );\n'
NEW_AVI = (
	'\t\t// ' + MARKER_AVI + ': XASH_AVI is AVI_NULL whenever\n'
	'\t\t// the engine was built without FFmpeg, so this is fixed at compile time.\n'
	'\t\tCon_Reportf( "AVI: not supported, built without FFmpeg\\n" );\n'
)


def one(path, s, marker, anchor, new, what):
	if marker in s:
		print('    already patched (%s): %s' % (what, path))
		return s
	n = s.count(anchor)
	assert n == 1, ('%s anchor found %d times (want 1) in %s' % (what, n, path))
	print('    patched (%s): %s' % (what, path))
	return s.replace(anchor, new, 1)


def patch(path, marker, anchor, new, what):
	s = open(path).read()
	out = one(path, s, marker, anchor, new, what)
	if out != s:
		open(path, 'w').write(out)


def main():
	if len(sys.argv) < 2:
		print('usage: patch-startup-diagnostics.py <engine-tree> ...')
		return 1
	for tree in sys.argv[1:]:
		if not os.path.isdir(tree):
			print('not a directory: ' + tree)
			return 1
		patch(os.path.join(tree, 'engine', 'server', 'sv_game.c'),
		      MARKER_PHYS, ANCHOR_PHYS, NEW_PHYS, 'physics interface')
		patch(os.path.join(tree, 'engine', 'client', 'avi', 'avi_ffmpeg.c'),
		      MARKER_AVI, ANCHOR_AVI, NEW_AVI, 'avi')
	return 0


if __name__ == '__main__':
	sys.exit(main())
