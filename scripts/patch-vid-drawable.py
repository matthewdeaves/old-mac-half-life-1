#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Guard VID_GetWindowSizeInPixels against a bogus drawable/output size.
#
# On big-endian PPC (G5, Leopard) the *software* SDL_Renderer's
# SDL_GetRendererOutputSize() returns a byte-swapped / garbage pixel size
# (observed e.g. 33836644x13863). That value flows into R_SaveVideoMode ->
# surface-cache/blit sizing, corrupts the software framebuffer and drops the
# game to the console in fullscreen ("can't initialize gameui DLL"). Windowed
# happened to survive; fullscreen-desktop did not.
#
# Fix: after querying the pixel size, sanity-check it. If it is non-positive or
# implausibly large, fall back to the logical window size (SDL_GetWindowSize),
# which is always correct. No-op on little-endian (Intel), where the reported
# size is already sane. Idempotent. Python 2.5+.
import sys

GUARD = 'oldmac: guard against a bogus drawable/output size'

ANCHOR = (
    '\t\tSDL_GL_GetDrawableSize( window, w, h );\n'
    '#endif\n'
    '}\n')

NEW = (
    '\t\tSDL_GL_GetDrawableSize( window, w, h );\n'
    '#endif\n'
    '\n'
    '\t// ' + GUARD + ': on big-endian PPC the software\n'
    '\t// SDL_Renderer reports a byte-swapped/garbage pixel size (e.g. 33836644x13863),\n'
    '\t// which corrupts surface-cache sizing and drops fullscreen to the console. Fall\n'
    '\t// back to the logical window size whenever the reported size is implausible.\n'
    '\tif( *w <= 0 || *h <= 0 || *w > 16384 || *h > 16384 )\n'
    '\t{\n'
    '\t\tint ww = 0, wh = 0;\n'
    '\t\tSDL_GetWindowSize( window, &ww, &wh );\n'
    '\t\tif( ww > 0 && wh > 0 )\n'
    '\t\t{\n'
    '\t\t\t*w = ww;\n'
    '\t\t\t*h = wh;\n'
    '\t\t}\n'
    '\t}\n'
    '}\n')

for f in sys.argv[1:]:
    s = open(f).read()
    if GUARD in s:
        print('already patched:', f)
        continue
    assert ANCHOR in s, ('anchor not found in ' + f)
    s = s.replace(ANCHOR, NEW, 1)
    open(f, 'w').write(s)
    print('patched:', f)
