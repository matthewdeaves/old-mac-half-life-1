#!/usr/bin/env python
# -*- coding: utf-8 -*-
# panther-sdl2's Cocoa_CreateSystemCursor (SDL_cocoamouse.m) builds SDL's system cursors by calling
# +[NSCursor <name>Cursor] class methods directly. Several of those (operationNotAllowedCursor and
# some resize/hand cursors) were added after 10.3, so on Panther the selector is unrecognized ->
# -[NSObject forward::] -> +[NSException raise:] -> _NSRaiseError -> the app dies at startup in
# SDLash_InitCursors. (10.4 Tiger has them, which is why the G4 builds don't crash.)
#
# Guard every non-10.0-guaranteed cursor selector with -respondsToSelector: and fall back to the
# arrow cursor when it's missing. Correct on ALL OS versions (present -> real cursor; absent ->
# arrow), so it's safe to apply to the shared source. Idempotent. Python 2.5+.
import sys

# selectors that may be absent on 10.3 (leave arrowCursor / IBeamCursor untouched as the fallbacks)
SELECTORS = [
	'crosshairCursor', 'closedHandCursor', 'resizeLeftRightCursor',
	'resizeUpDownCursor', 'operationNotAllowedCursor', 'pointingHandCursor',
]

MARK = 'respondsToSelector:@selector(operationNotAllowedCursor)'

for f in sys.argv[1:]:
	s = open(f).read()
	if MARK in s:
		print('already patched:', f)
		continue
	total = 0
	for sel in SELECTORS:
		old = '[NSCursor %s]' % sel
		new = ('([NSCursor respondsToSelector:@selector(%s)] '
		       '? (NSCursor *)[NSCursor performSelector:@selector(%s)] '
		       ': [NSCursor arrowCursor])') % (sel, sel)
		c = s.count(old)
		if c:
			s = s.replace(old, new)
			total += c
	assert total > 0, ('no NSCursor system-cursor calls found in ' + f)
	open(f, 'w').write(s)
	print('patched (%d cursor call(s)):' % total, f)
