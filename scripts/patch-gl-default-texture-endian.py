#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Fix a big-endian colour bug in ref_gl's built-in "emo"/default (missing) texture.
#
# GL_CreateInternalTextures() paints the 16x16 default checkerboard by storing packed
# 32-bit colour CONSTANTS through a (uint *) into an RGBA byte buffer that is later
# uploaded with GL_RGBA + GL_UNSIGNED_BYTE (an endian-neutral byte array). Because the
# constants are packed uints, their in-memory byte order flips with endianness:
#   0xFFFF00FF  -> LE bytes FF,00,FF,FF = magenta (intended)
#               -> BE bytes FF,FF,00,FF = YELLOW  (blue = 0)
#   0xFF000000  -> LE bytes 00,00,00,FF = opaque black (intended)
#               -> BE bytes FF,00,00,00 = red, alpha = 0 -> TRANSPARENT
# So on PPC the default texture renders yellow + transparent -- the exact symptom seen
# on models/surfaces that fall back to it. Same bug family as the img_wad palette fix.
#
# Fix: write the four RGBA bytes explicitly, which is correct on both endians. No packed
# constant, so nothing to byte-swap. Idempotent. Python 2.5+.
import sys

GUARD = 'oldmac: write RGBA as explicit bytes'

OLD = (
	'\t\t\tif(( y < 8 ) ^ ( x < 8 ))\n'
	'\t\t\t\t((uint *)pic->buffer)[y*16+x] = 0xFFFF00FF;\n'
	'\t\t\telse ((uint *)pic->buffer)[y*16+x] = 0xFF000000;\n')

NEW = (
	'\t\t\t// ' + GUARD + ' so the emo/default texture is endian-correct.\n'
	'\t\t\t// The old packed-uint constants (0xFFFF00FF magenta, 0xFF000000 opaque\n'
	'\t\t\t// black) byte-swap on big-endian PPC to yellow (blue=0) and transparent\n'
	'\t\t\t// (alpha=0) -> the "yellowed/transparent" fallback look.\n'
	'\t\t\t{\n'
	'\t\t\t\tbyte *px = pic->buffer + ( y * 16 + x ) * 4;\n'
	'\t\t\t\tif(( y < 8 ) ^ ( x < 8 ))\n'
	'\t\t\t\t{ px[0] = 255; px[1] = 0; px[2] = 255; px[3] = 255; } // magenta\n'
	'\t\t\t\telse\n'
	'\t\t\t\t{ px[0] = 0; px[1] = 0; px[2] = 0; px[3] = 255; }     // opaque black\n'
	'\t\t\t}\n')

for f in sys.argv[1:]:
	s = open(f).read()
	if GUARD in s:
		print('already patched:', f)
		continue
	assert OLD in s, ('anchor not found in ' + f)
	s = s.replace(OLD, NEW, 1)
	open(f, 'w').write(s)
	print('patched:', f)
