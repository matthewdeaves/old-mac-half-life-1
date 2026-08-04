#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Make ref_soft's screenshot readback endian-independent.
#
# VID_ScreenShot() builds a PF_BGRA_32 image by calling Get8888PixelAt() and
# storing the returned uint32 straight into the buffer with a 32-bit store. That
# only yields B,G,R,A memory bytes on a LITTLE-endian CPU. On big-endian PPC the
# same uint32 stores as A,R,G,B, so every saved screenshot comes out with the
# channels scrambled (the whole image turns solid blue). Worse, the bpp==4 path
# of Get8888PixelAt returns vid.screen32[...] verbatim - that value is in the SDL
# surface's native channel layout (swblit.r/g/b mask), NOT a canonical RGB.
#
# Fix, endian-safe on both archs (and identical output on little-endian, so it
# can be validated on Intel before the ppc cross-build):
#   1. Get8888PixelAt bpp 3/4 path: decode vid.screen32 via the swblit masks into
#      a canonical 0x00RRGGBB (bpp==2 already produces canonical RGB).
#   2. VID_ScreenShot: write the four channels as explicit B,G,R,A bytes to match
#      PF_BGRA_32, instead of a byte-order-dependent 32-bit store.
#
# Idempotent. Python 2.5+ (runs on the Lion mini).
import sys

GUARD = 'oldmac: endian-safe screenshot readback'

OLD_GETPIX = (
	'\tcase 3:\n'
	'\tcase 4:\n'
	'\tdefault:\n'
	'\t\ts = vid.screen32[vid.buffer[start + u]];\n'
	'\t\tbreak;\n'
	'\t}\n')

NEW_GETPIX = (
	'\tcase 3:\n'
	'\tcase 4:\n'
	'\tdefault:\n'
	'\t{\n'
	'\t\t// ' + GUARD + ': vid.screen32 holds the pixel in the SDL\n'
	'\t\t// surface\'s native channel layout (swblit.r/g/b mask), whose byte order\n'
	'\t\t// differs by endianness. Decode via the masks to a canonical 0x00RRGGBB\n'
	'\t\t// so the writer below is endian-independent (this turned ppc shots blue).\n'
	'\t\tuint32_t v = vid.screen32[vid.buffer[start + u]];\n'
	'\t\tuint rsh = FIRST_BIT( swblit.rmask ), gsh = FIRST_BIT( swblit.gmask ), bsh = FIRST_BIT( swblit.bmask );\n'
	'\t\tuint rbits = COUNT_BITS( swblit.rmask ), gbits = COUNT_BITS( swblit.gmask ), bbits = COUNT_BITS( swblit.bmask );\n'
	'\t\tuint r = ( v & swblit.rmask ) >> rsh;\n'
	'\t\tuint g = ( v & swblit.gmask ) >> gsh;\n'
	'\t\tuint b = ( v & swblit.bmask ) >> bsh;\n'
	'\t\tr = rbits ? r * 255 / ( BIT( rbits ) - 1 ) : 0;\n'
	'\t\tg = gbits ? g * 255 / ( BIT( gbits ) - 1 ) : 0;\n'
	'\t\tb = bbits ? b * 255 / ( BIT( bbits ) - 1 ) : 0;\n'
	'\t\ts = r << 16 | g << 8 | b;\n'
	'\t\tbreak;\n'
	'\t}\n'
	'\t}\n')

# Byte-wise stores (PF_BGRA_32 = B,G,R,A) replacing the endian-dependent uint32 store.
OLD_STORE_ROT = '\t\t\t\tpbuf[d] = Get8888PixelAt( u, start );\n'
NEW_STORE_ROT = (
	'\t\t\t\t{ // ' + GUARD + '\n'
	'\t\t\t\t\tuint32_t px = Get8888PixelAt( u, start );\n'
	'\t\t\t\t\tbyte *pb = (byte *)&pbuf[d];\n'
	'\t\t\t\t\tpb[0] = px; pb[1] = px >> 8; pb[2] = px >> 16; pb[3] = px >> 24;\n'
	'\t\t\t\t}\n')

OLD_STORE_LIN = '\t\t\t\tpbuf[dstart + u] = Get8888PixelAt( u, start );\n'
NEW_STORE_LIN = (
	'\t\t\t\t{ // ' + GUARD + '\n'
	'\t\t\t\t\tuint32_t px = Get8888PixelAt( u, start );\n'
	'\t\t\t\t\tbyte *pb = (byte *)&pbuf[dstart + u];\n'
	'\t\t\t\t\tpb[0] = px; pb[1] = px >> 8; pb[2] = px >> 16; pb[3] = px >> 24;\n'
	'\t\t\t\t}\n')

for f in sys.argv[1:]:
	s = open(f).read()
	if GUARD in s:
		print('already patched:', f)
		continue
	assert OLD_GETPIX in s, ('Get8888PixelAt anchor not found in ' + f)
	assert OLD_STORE_ROT in s, ('rotate store anchor not found in ' + f)
	assert OLD_STORE_LIN in s, ('linear store anchor not found in ' + f)
	s = s.replace(OLD_GETPIX, NEW_GETPIX, 1)
	s = s.replace(OLD_STORE_ROT, NEW_STORE_ROT, 1)
	s = s.replace(OLD_STORE_LIN, NEW_STORE_LIN, 1)
	open(f, 'w').write(s)
	print('patched:', f)
