#!/usr/bin/env python
# -*- coding: utf-8 -*-
# panther-sdl2 (SDL 2.0.3) still references a few APIs that only appear in the 10.4 SDK and are
# absent from the 10.3.9 cross-SDK we use for the Panther (G3) build. They are cosmetic / unused
# by Half-Life (which sets XASH3D_BASEDIR for its write path), so we make them compile:
#   * SDL_GetPrefPath -> NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, ...):
#     NSApplicationSupportDirectory (NSSearchPathDirectory value 14) is a 10.4 addition. Define it
#     to 14 for pre-10.4 SDKs so the file compiles; on 10.3 the call simply returns an empty array
#     and SDL_GetPrefPath returns NULL (unused here).
# Guarded on MAC_OS_X_VERSION_MAX_ALLOWED < 1040, so it is a no-op on the 10.4u/10.5 SDKs. The
# separate patch-panther-sdl-displayname / patch-panther-sdl-version-guards handle the other gaps.
# Idempotent. Python 2.5+.
import sys

MARK = 'oldmac: NSApplicationSupportDirectory is 10.4+'
ANCHOR = 'char *\nSDL_GetPrefPath(const char *org, const char *app)\n{\n'
INSERT = (
	'#if MAC_OS_X_VERSION_MAX_ALLOWED < 1040 /* ' + MARK + ' (value 14) */\n'
	'#ifndef NSApplicationSupportDirectory\n'
	'#define NSApplicationSupportDirectory 14\n'
	'#endif\n'
	'#endif\n'
	'char *\nSDL_GetPrefPath(const char *org, const char *app)\n{\n')

for f in sys.argv[1:]:
	s = open(f).read()
	if MARK in s:
		print('already patched:', f)
		continue
	assert ANCHOR in s, ('anchor not found in ' + f)
	s = s.replace(ANCHOR, INSERT, 1)
	open(f, 'w').write(s)
	print('patched:', f)
