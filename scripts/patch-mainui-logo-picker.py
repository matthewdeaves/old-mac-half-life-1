#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Two defects in the spray-paint picker itself (issue #33).
#
# Reported on the G5 against v1.4.3: cycling the spray-paint spinner in
# Multiplayer > Customize no longer crashes, but the "lambda" entry the picker
# opens on draws nothing and then disappears, and the "xash" entry shows no
# recognisable logo. Neither is the crash guard's doing. The PowerPC half of the
# "xash" entry, where CBMP::LoadFile misreads the header, is a separate fix in
# scripts/patch-mainui-bmp-endian.py; this script is the picker behaviour, and
# both edits here apply to Intel and PowerPC alike.
#
#
# 1. "lambda" is not a file, and never was.
#
# `cl_logofile` is registered by the engine with the default "lambda"
# (engine/client/cl_main.c). Half-Life ships no logos/lambda.bmp: it is not in
# pak0.pak, not in extras.pk3, and not on disk. Checked on the G5 and on the
# Intel mini; the only logos present are extras.pk3's four PNGs plus xash.bmp.
#
# _Init does:
#
#	logo.Setup( &logosModel );
#	logo.LinkCvar( "cl_logofile", CMenuEditable::CVAR_STRING );
#
# LinkCvar reads the cvar straight away, and CMenuSpinControl::SetCurrentValue
# for a string that is not in the model sets the index to -1 and force-displays
# the string anyway. So the picker opens showing "lambda", UpdateLogo maps the
# negative index to hImage = 0, and the preview draws "No logo". Move off it and
# it is gone for good, because the spinner's minimum is 0.
#
# It is a slot for a spray the player does not have, so the fix is to not offer
# it: snap to the first logo they do have. The list is known non-empty at that
# point, the enclosing branch already tested GetRows().
#
#
# 2. An 8 bit logo BMP previews as a grey block, not as the logo.
#
# A Half-Life spray BMP is 8 bit with a grey ramp palette, index i mapping to
# RGB (i,i,i) with the reserved byte 0. The index is the coverage, not a colour:
# imagelib turns it into alpha with
#
#	// setup gradient alpha for player decal
#	if( !Q_strncmp( name, "#logo", 5 ))
#		for( i = 0; i < bhdr.colors; i++ )
#			palette[i][3] = i;
#
# and that branch is keyed on the NAME, not on a flag. The real spray takes it,
# because custom.c loads the decal as "#logo.bmp". The menu preview does not: it
# calls PIC_Load with the plain path, so the ramp arrives as opaque grey, the
# image carries no alpha at all, and the preview is a solid block where the other
# entries (all PNGs, which carry their own alpha) show artwork.
#
# The flag the menu does set, IL_LOAD_DECAL, is honoured only by the WAD lump
# loader, and it cannot be honoured here anyway: every menu PIC_Load sets it,
# including the player model previews, which are also 8 bit BMPs and must NOT be
# turned into gradients.
#
# So the fix is at the call site: hand the same bytes back to PIC_Load under a
# name beginning with "#logo". FS_LoadImage has an explicit path for that, a '#'
# name with a buffer skips the file lookup and goes straight to the loader, and
# the loader sees the "#logo" prefix and builds the gradient. The preview then
# matches what will actually be sprayed, tint included. The load by path stays
# where it is and remains the fallback if the buffer upload does not take.
#
# The two trees keep the same CBMP under different names for the in-place header
# swap, Byteswap() in the PowerPC fork and SwapHdrToLE() in mainline, so the
# method is read out of BMPUtils.h rather than assumed. On a little-endian host
# both expand to nothing.
#
# Ordering: run AFTER scripts/patch-mainui-logo-nullcheck.py and AFTER
# scripts/patch-mainui-bmp-endian.py. Both are checked for before the edit rather
# than left for the build to discover.
#
#   - nullcheck anchors on the LoadFile call and the bit depth test being
#     adjacent, so inserting between them first would break it.
#   - bmp-endian is what makes CBMP::LoadFile hand back a header in HOST order.
#     The preview block below reads fileSize out of that header and swaps it back
#     for the PIC_Load handoff, so on a big-endian host without that fix it would
#     be swapping a header that was never swapped in, and handing the engine a
#     big-endian one. On the Intel tree bmp-endian correctly does nothing,
#     because mainline's LoadFile already calls CBMP::SwapBmpHdrToLE, so the
#     check is for the property and not for the marker: see
#     loadfile_is_host_order.
#
# Applies to both trees. Idempotent. Python 2.5+.
import os
import re
import sys

MARKER_PHANTOM = 'oldmac: cl_logofile defaults to a logo Half-Life never shipped'
MARKER_PREVIEW = 'oldmac: preview the spray the way the engine sprays it'

# patch-mainui-logo-nullcheck.py's marker. It has to be in place first, see the
# ordering note above.
MARKER_NULLCHECK = 'oldmac: LoadFile returns NULL for a missing or non-BMP file'

# patch-mainui-bmp-endian.py's LoadFile marker, and the mainline code that makes
# that script a no-op. Either one means CBMP::LoadFile hands back a host-order
# header, which is what the preview block requires.
MARKER_BMP_ENDIAN = 'oldmac: BMP headers are little-endian on disk'
UPSTREAM_BMP_ENDIAN = 'CBMP::SwapBmpHdrToLE( bmp )'

RE_LINKCVAR = re.compile(
	r'([ \t]*)logo\.Setup\( &logosModel \);\n'
	r'([ \t]*)logo\.LinkCvar\( "cl_logofile", CMenuEditable::CVAR_STRING \);\n'
)

# UpdateLogo's CBMP::LoadFile, told apart from WriteNewLogo's by the bit depth
# test that follows it. The middle group swallows the blank and comment lines
# that patch-mainui-logo-nullcheck.py puts there, if it has already run.
RE_UPDATELOGO = re.compile(
	r'([ \t]*)CBMP \*bmpFile = CBMP::LoadFile\( filename \);\n'
	r'((?:[ \t]*(?://[^\n]*)?\n)*)'
	r'([ \t]*if\((?: bmpFile &&)? bmpFile->GetBitmapHdr\(\)->bitsPerPixel == 8 \))'
)


def phantom_block(indent):
	i = indent
	return (
		'%s// %s.\n'
		'%s// Not in pak0.pak, not in extras.pk3, not on disk. LinkCvar has just\n'
		'%s// asked the spinner for that name; a string the model does not have\n'
		'%s// leaves the index at -1 with the string force-displayed, so the picker\n'
		'%s// opens on a slot that draws "No logo", writes nothing, and cannot be\n'
		'%s// returned to once you move off it, because the minimum index is 0.\n'
		'%s// Offer only sprays the player actually has. The list is non-empty\n'
		'%s// here: the enclosing branch already tested GetRows().\n'
		'%sif( logo.GetCurrentValue() < 0 )\n'
		'%s\tlogo.SetCurrentValue( 0.0f );\n'
		% (i, MARKER_PHANTOM, i, i, i, i, i, i, i, i, i)
	)


def preview_block(indent, swapper):
	i = indent
	return (
		'%s// %s.\n'
		'%s// A Half-Life logo BMP is 8 bit with a grey ramp palette whose index is\n'
		'%s// the coverage, and imagelib only turns that index into alpha for an\n'
		'%s// image whose name starts with "#logo". The real spray gets that,\n'
		'%s// custom.c loads it as "#logo.bmp"; a preview loaded by path does not,\n'
		'%s// so it drew as a solid grey block with no alpha at all. Hand the same\n'
		'%s// bytes back under a "#logo" name and the preview matches the spray.\n'
		'%s// The load by path above stays as the fallback.\n'
		'%sif( bmpFile && bmpFile->GetBitmapHdr()->bitsPerPixel == 8 )\n'
		'%s{\n'
		'%s\tchar previewName[256];\n'
		'%s\tuint previewSize = bmpFile->GetBitmapHdr()->fileSize;\n'
		'%s\tHIMAGE hPreview;\n'
		'\n'
		'%s\tsnprintf( previewName, sizeof( previewName ), "#logo_preview_%%s", filename );\n'
		'\n'
		'%s\t// the engine parses the header little-endian and LoadFile leaves it\n'
		'%s\t// in host order, so turn it back for the handoff and then restore it.\n'
		'%s\tbmpFile->%s();\n'
		'%s\thPreview = EngFuncs::PIC_Load( previewName, bmpFile->GetBitmap(), previewSize, 0 );\n'
		'%s\tbmpFile->%s();\n'
		'\n'
		'%s\tif( hPreview )\n'
		'%s\t\tlogoImage.hImage = hPreview;\n'
		'%s}\n'
		% (i, MARKER_PREVIEW, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i,
		   swapper, i, i, swapper, i, i, i)
	)


def swapper_name(mainui):
	"""Which in-place header swap the tree's CBMP offers."""
	path = os.path.join(mainui, 'BMPUtils.h')
	assert os.path.isfile(path), ('no BMPUtils.h beside %s' % mainui)
	src = open(path).read()
	if 'void Byteswap()' in src:
		return 'Byteswap'
	if 'void SwapHdrToLE()' in src:
		return 'SwapHdrToLE'
	raise AssertionError('CBMP in %s has neither Byteswap() nor SwapHdrToLE()' % path)


def loadfile_is_host_order(mainui):
	"""Does CBMP::LoadFile hand this tree's callers a host-order BMP header?

	Asserting patch-mainui-bmp-endian.py's marker on its own would be wrong. On
	the Intel tree that script prints "already little-endian safe upstream, left
	alone" and writes nothing, because mainline's LoadFile already calls
	CBMP::SwapBmpHdrToLE, so the marker is legitimately absent there and every
	Intel build would fail the assert. The dependency is on the property, not on
	who provided it, so both spellings count. The same test is what bmp-endian
	itself uses to decide it has nothing to do.
	"""
	path = os.path.join(mainui, 'Utils.cpp')
	assert os.path.isfile(path), ('no Utils.cpp beside %s' % mainui)
	src = open(path).read()
	return MARKER_BMP_ENDIAN in src or UPSTREAM_BMP_ENDIAN in src


def patch_phantom(src, path):
	if MARKER_PHANTOM in src:
		print('already patched (phantom entry): ' + path)
		return src
	found = RE_LINKCVAR.findall(src)
	assert len(found) == 1, ('cl_logofile LinkCvar anchor found %d times (want 1) in %s'
	                         % (len(found), path))

	def sub(m):
		return m.group(0) + '\n' + phantom_block(m.group(2))

	return RE_LINKCVAR.sub(sub, src, 1)


def patch_preview(src, path, mainui, swapper):
	if MARKER_PREVIEW in src:
		print('already patched (preview upload): ' + path)
		return src
	assert MARKER_NULLCHECK in src, (
		'run scripts/patch-mainui-logo-nullcheck.py before this one: %s' % path)
	assert loadfile_is_host_order(mainui), (
		'run scripts/patch-mainui-bmp-endian.py before this one: CBMP::LoadFile in '
		'%s/Utils.cpp still hands back the header in the file\'s little-endian '
		'order, and the preview block swaps it as if it were host order' % mainui)
	found = RE_UPDATELOGO.findall(src)
	assert len(found) == 1, ('UpdateLogo bit depth anchor found %d times (want 1) in %s'
	                         % (len(found), path))

	def sub(m):
		# patch-mainui-logo-nullcheck.py, if it ran first, already left a blank
		# line and its own comment here. If it did not, supply the blank line.
		tail = m.group(2) or '\n'
		return ('%sCBMP *bmpFile = CBMP::LoadFile( filename );\n\n%s%s%s'
		        % (m.group(1), preview_block(m.group(1), swapper),
		           tail, m.group(3)))

	return RE_UPDATELOGO.sub(sub, src, 1)


def patch_tree(mainui):
	swapper = swapper_name(mainui)
	path = os.path.join(mainui, 'menus', 'PlayerSetup.cpp')
	src = open(path).read()
	out = patch_preview(patch_phantom(src, path), path, mainui, swapper)
	if out == src:
		return
	open(path, 'w').write(out)
	print('patched: ' + path)


def main():
	if len(sys.argv) < 2:
		print('usage: patch-mainui-logo-picker.py <mainui-dir> ...')
		return 1
	for arg in sys.argv[1:]:
		assert os.path.isdir(arg), ('not a mainui directory: %s' % arg)
		patch_tree(arg)
	return 0


if __name__ == '__main__':
	sys.exit(main())
