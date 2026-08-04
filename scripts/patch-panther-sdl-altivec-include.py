#!/usr/bin/env python
# -*- coding: utf-8 -*-
# panther-sdl2's Cocoa ObjC files (SDL_cocoamessagebox.m, SDL_cocoavideo.m) pull <altivec.h>
# purely to get the vector/bool/pixel keywords, then #undef them to avoid clashing with Cocoa:
#     #if defined(__APPLE__) && defined(__POWERPC__) && !defined(__APPLE_ALTIVEC__)
#     #include <altivec.h>
# That is harmless when AltiVec is enabled, but the G3 (ppc750) build uses --disable-altivec, so
# neither -maltivec nor -faltivec is set -> altivec.h is not on the include path and this fails with
# "altivec.h: No such file or directory". Require __ALTIVEC__ (only defined when AltiVec is actually
# on) so the block vanishes for a no-AltiVec build. Inert when AltiVec is enabled (the -faltivec
# Tiger build already skips it via __APPLE_ALTIVEC__). Idempotent. Python 2.5+.
import sys

OLD = '#if defined(__APPLE__) && defined(__POWERPC__) && !defined(__APPLE_ALTIVEC__)\n'
NEW = ('#if defined(__APPLE__) && defined(__POWERPC__) && defined(__ALTIVEC__) && !defined(__APPLE_ALTIVEC__)'
       ' /* oldmac: no altivec.h when AltiVec is off */\n')

for f in sys.argv[1:]:
	s = open(f).read()
	if 'oldmac: no altivec.h when AltiVec is off' in s:
		print('already patched:', f)
		continue
	if OLD not in s:
		print('no altivec.h guard here (ok):', f)
		continue
	s = s.replace(OLD, NEW)
	open(f, 'w').write(s)
	print('patched:', f)
