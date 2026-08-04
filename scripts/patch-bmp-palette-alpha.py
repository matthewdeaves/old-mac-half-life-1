#!/usr/bin/env python
# -*- coding: utf-8 -*-
# A BMP palette carries no alpha, so stop reading one out of it (issue #44).
#
# SYMPTOM. On PowerPC the main menu's left column is empty. The status text
# beside it draws, the background draws, the version string draws, but the nine
# menu items are not there at all. Seen on the dual G5 on 10.5.8 at 1680x1050,
# against the build of 27 July 2026 19:27. The build before it drew them as gold
# text, because that build never reached the artwork path.
#
# WHAT WAS MEASURED, on g5-desktop, before any of this was written:
#
#   - The atlas loads and uploads. `texturelist` lists #btns_0.bmp through
#     #btns_70.bmp, each 128x128 RGBA8. So CBMP::LoadFile succeeds, the atlas is
#     cut up, PIC_Load succeeds, and every button's hPic is a real handle.
#   - Every one of the 256 palette entries in gfx/shell/btns_main.bmp has a
#     fourth byte of 0. The file is 865008 bytes, 156x5538, 8bpp, palette at
#     offset 54, 1024 bytes long.
#   - gl_texture_npot is 0 on this machine: "Video: gl_texture_npot disabled for
#     Radeon (Apple)". That is why the atlas pages are 128x128.
#
# CAUSE. `Image_LoadBMP` decodes a palettised BMP by reading the palette entry's
# fourth byte as alpha:
#
#	case 8:
#		palIndex = *buf_p++;
#		red   = palette[palIndex][2];
#		green = palette[palIndex][1];
#		blue  = palette[palIndex][0];
#		alpha = palette[palIndex][3];
#
# There is no alpha there. A BMP palette entry is a Windows RGBQUAD, whose
# fourth byte is rgbReserved and is specified to be zero. So every pixel of
# every palettised BMP decodes to alpha 0.
#
# The decode is wrong wherever it runs. Whether it is VISIBLE depends on what
# the upload path then does with the zero. A palettised BMP does not itself set
# IMAGE_HAS_ALPHA (only "#logo", the menu qfont and IL_OVERVIEW do, and all
# three fill the palette's fourth byte themselves first), and without that flag
# GL_SetTextureFormat picks a three-component internal format, so the zero is
# discarded on upload and the sampler returns alpha 1. The wrong value is thrown
# away before anything samples it.
#
# Once anything does set IMAGE_HAS_ALPHA for such an image, a four-component
# internal format is chosen and the zero reaches the GPU. The buttons are drawn
# with `EngFuncs::PIC_DrawAdditive`, which is kRenderTransAdd, which is
# `glBlendFunc( GL_SRC_ALPHA, GL_ONE )`. Source alpha zero contributes nothing.
# The artwork is uploaded, bound and rasterised, and every fragment is
# multiplied by zero.
#
# So the empty column is not an endian fault and not a fault in the atlas
# cutting. INFERRED, from the four measured facts above plus the two code paths
# quoted: the fragments are transparent. Not separately instrumented.
#
# SCOPE, stated plainly rather than left implicit. The build the symptom was
# measured against carried an extra `channelMask |= IMAGE_HAS_ALPHA` for every
# PF_RGBA_32 / PF_BGRA_32 upload in GL_SetTextureFormat, present because those
# formats always carry four bytes per pixel while call sites often pass
# IMAGE_HAS_COLOR alone, and a three-component internal format uploaded with
# GL_RGBA makes macOS ATI/Apple drivers return GL_INVALID_ENUM. That forcing is
# what let the zero through, and it is why `texturelist` reported those atlas
# pages as RGBA8 rather than RGB8. The engine built here does not carry it. So
# on this engine the edit below corrects the decoder rather than repairing a
# visible symptom: the decoder still manufactures an alpha the file format says
# is not there, and any future caller that sets IMAGE_HAS_ALPHA on a palettised
# BMP gets a fully transparent image out of it.
#
# FIX. Read the reserved byte as alpha only when something upstream of the pixel
# loop has declared that this image really does carry alpha in its palette. The
# three callers that mean it all set IMAGE_HAS_ALPHA before the loop runs:
#
#   - "#logo" sprays, which overwrite the fourth byte with a gradient,
#   - the menu qfont, which is 4bpp and takes a different branch anyway,
#   - IL_OVERVIEW, which sets 0 for the green key colour and 255 for the rest.
#
# Everything else gets 255, which is exactly what upstream renders once the
# three-component internal format has thrown the zero away. The 32bpp branch is
# untouched: that alpha is real and the loop sets IMAGE_HAS_ALPHA from it.
#
# Applies to every engine tree. Ordering: independent of every other patch.
# Idempotent. Python 2.5+.
import os
import re
import sys

MARKER = 'oldmac: a BMP palette entry is an RGBQUAD, and its fourth byte is not alpha'

# Anchored between the pixel buffer allocation and the row loop, so the comment
# lands once, above both the 4bpp and the 8bpp branches that need it.
RE_LOOP = re.compile(
	r'(\n([ \t]*)image\.rgba = Mem_Malloc\( host\.imagepool, image\.size \);\n)'
	r'(\n[ \t]*for\( row = rows - 1; row >= 0; row-- \)\n)'
)

# The 8bpp branch, once.
OLD_8BPP = 'alpha = palette[palIndex][3];'
NEW_8BPP = 'alpha = FBitSet( image.flags, IMAGE_HAS_ALPHA ) ? palette[palIndex][3] : 255;'

# The 4bpp branch, twice: once for the high nibble and once for the low one.
OLD_4BPP = '*pixbuf++ = palette[palIndex][3];'
NEW_4BPP = '*pixbuf++ = FBitSet( image.flags, IMAGE_HAS_ALPHA ) ? palette[palIndex][3] : 255;'


def preamble(indent):
	lines = []
	lines.append('%s// %s.' % (indent, MARKER))
	lines.append('%s// It is rgbReserved and the format says it is zero, so reading it as' % indent)
	lines.append('%s// alpha makes every palettised BMP fully transparent. Upstream gets away' % indent)
	lines.append('%s// with that: a palettised image sets no IMAGE_HAS_ALPHA, so' % indent)
	lines.append('%s// GL_SetTextureFormat picks a three-component internal format and the' % indent)
	lines.append('%s// zero is dropped on upload. Anything that sets IMAGE_HAS_ALPHA for a' % indent)
	lines.append('%s// 32-bit upload keeps the four-component format instead, and then the' % indent)
	lines.append('%s// zero reaches the GPU. The WON menu button' % indent)
	lines.append('%s// atlas is drawn with kRenderTransAdd, GL_SRC_ALPHA to GL_ONE, so the' % indent)
	lines.append('%s// whole atlas was multiplied by zero and the main menu had no items on' % indent)
	lines.append('%s// it. Issue #44. The three callers that DO put alpha in the palette,' % indent)
	lines.append('%s// "#logo", the qfont and IL_OVERVIEW, all set IMAGE_HAS_ALPHA above, so' % indent)
	lines.append('%s// they still get the byte.' % indent)
	return '\n' + '\n'.join(lines) + '\n'


def patch_img_bmp(path):
	assert os.path.isfile(path), ('no img_bmp.c at %s' % path)
	src = open(path).read()
	if MARKER in src:
		print('already patched: ' + path)
		return

	found = RE_LOOP.findall(src)
	assert len(found) == 1, ('pixel loop anchor found %d times (want 1) in %s'
	                         % (len(found), path))
	assert src.count(OLD_8BPP) == 1, ('8bpp palette alpha read found %d times (want 1) in %s'
	                                  % (src.count(OLD_8BPP), path))
	assert src.count(OLD_4BPP) == 2, ('4bpp palette alpha read found %d times (want 2) in %s'
	                                  % (src.count(OLD_4BPP), path))

	def sub(m):
		return m.group(1) + preamble(m.group(2)) + m.group(3)

	src = RE_LOOP.sub(sub, src, 1)
	src = src.replace(OLD_8BPP, NEW_8BPP)
	src = src.replace(OLD_4BPP, NEW_4BPP)
	open(path, 'w').write(src)
	print('patched: ' + path)


def main():
	if len(sys.argv) < 2:
		print('usage: patch-bmp-palette-alpha.py <img_bmp.c> ...')
		return 1
	for arg in sys.argv[1:]:
		patch_img_bmp(arg)
	return 0


if __name__ == '__main__':
	sys.exit(main())
