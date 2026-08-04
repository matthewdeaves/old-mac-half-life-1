#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Clear the palette's alpha byte on the byte that actually holds it.
#
# THE SYMPTOM. On PowerPC the fullbright centres of the Half-Life tram's
# fluorescent tubes render cyan instead of white. Nothing else is affected: the
# housing, the hazard stripes and every other palette index are correct.
#
# THE CAUSE. img_wad.c does this right after building the packed palette:
#
#	image.d_currentpal[255] &= 0xFFFFFF;
#
# The intent is to clear the ALPHA byte of palette entry 255. But the entries are
# packed by Image_SetPalette with HostFourCC, which is BigFourCC on a big-endian
# host and LittleFourCC on a little-endian one, so the byte order inside the word
# flips with the architecture:
#
#	little-endian:  a<<24 | b<<16 | g<<8 | r   -> alpha is the HIGH byte
#	big-endian:     r<<24 | g<<16 | b<<8 | a   -> alpha is the LOW byte, red is high
#
# So the literal 0xFFFFFF clears alpha on little-endian, which is what was meant,
# and clears RED on big-endian. Index 255 is the bright fullbright white, so on
# PowerPC white (255,255,255) loses its red channel and comes out cyan (0,255,255).
#
# THE FIX. Build the mask with the same macro that built the entry, rather than
# writing a literal that quietly means a different channel per architecture:
#
#	image.d_currentpal[255] &= ~HostFourCC( 0, 0, 0, 0xFF );
#
# HostFourCC puts the 0xFF wherever alpha lives on this host, so the complement is
# exactly "every byte except alpha" on both. This needs no preprocessor branch,
# which is the point: a branch here would be two expressions that have to be kept
# in agreement, and this is one expression that cannot disagree with itself.
#
# Confirmed on the iMac G5 with the software renderer.
#
# Idempotent. Python 2.5+.
import sys

GUARD = 'oldmac: clear alpha endian-correctly'

OLD = '\t\timage.d_currentpal[255] &= 0xFFFFFF;\n'
NEW = (
	'\t\t// ' + GUARD + ': these entries were packed with HostFourCC, so alpha is\n'
	'\t\t// the high byte on little-endian and the low byte on big-endian. A literal\n'
	'\t\t// 0xFFFFFF therefore clears alpha on one and RED on the other, which turned\n'
	'\t\t// fullbright white into cyan on PowerPC. Building the mask with the same\n'
	'\t\t// macro that built the entry lands it on alpha either way.\n'
	'\t\timage.d_currentpal[255] &= ~HostFourCC( 0, 0, 0, 0xFF );\n')

for f in sys.argv[1:]:
	s = open(f).read()
	if GUARD in s:
		print('already patched:', f)
		continue
	assert OLD in s, ('anchor not found in ' + f)
	s = s.replace(OLD, NEW, 1)
	open(f, 'w').write(s)
	print('patched:', f)
