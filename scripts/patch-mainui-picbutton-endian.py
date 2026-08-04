#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Check that nothing gates the picbutton artwork on the host's byte order
# (issue #8).
#
# SYMPTOM. Activating a mod that carries its own menu lettering switched the
# menu to that lettering on Intel but not on PowerPC, where every machine kept
# the stock Half-Life look. Reported against Opposing Force, confirmed on
# ppc750, ppc7400 and ppc970.
#
# The "font" in that report is not a font. Half-Life draws its menu items from a
# bitmap atlas, gfx/shell/btns_main.bmp, three states per item stacked
# vertically. A mod ships its own copy, so its menu items are simply different
# pixels. gearbox/gfx/shell/btns_main.bmp and valve/gfx/shell/btns_main.bmp are
# both 865008 bytes, 156x5538, 8bpp, and differ in content: valve reads
# "Custom game / Activate / Install" in mixed case, gearbox reads "ACTIVATE /
# INSTALL" in caps in its own face. No TrueType file and no WAD lump is
# involved.
#
# CAUSE. `CBMP::LoadFile` in Utils.cpp reads the little-endian BMP header raw
# unless something swaps it, and then validates it against the file length. On a
# big-endian host every field comes out byte-reversed: btns_main.bmp stores
# fileSize as F0 32 0D 00, which read big-endian is 4029811968, so
# `length < bmp->fileSize` is true for a file that is exactly the size it
# claims. LoadFile returns NULL, `UI_LoadBmpButtons` returns early,
# `uiStatic.buttonsPics` stays empty, and `hPic` is NULL for every button. That
# is the same defect as the spray-logo picker in issue #33.
#
# Two things can then hide the artwork, and both have to be absent for a mod's
# lettering to appear on PowerPC:
#
#   1. the header read itself, which decides whether hPic is ever non-NULL, and
#   2. any early return in `CMenuPicButton::Draw` taken on byte order, which
#      would draw the item as plain text before the artwork test
#      `if( hPic && !uiStatic.renderPicbuttonText )` is ever reached. Such a
#      branch makes fixing the header read invisible on screen: the atlas loads
#      and is still never drawn.
#
# STATE OF THE MENU TREE. Neither is present in the menu source we build.
# CBMP::LoadFile swaps the header before it validates it, which
# scripts/patch-mainui-bmp-endian.py checks, and CMenuPicButton::Draw reaches
# the artwork test on every architecture with no byte-order branch above it.
#
# So this script edits nothing. It asserts the artwork test is there and
# reachable and reports, so that a menu tree which gates the artwork on byte
# order stops the build rather than shipping a PowerPC slice that silently
# ignores a mod's own menu lettering.
#
# Idempotent, because it writes nothing. Python 2.5+.
import os
import sys

# The one test that decides between the atlas and the text fallback.
ARTWORK_TEST = 'if( hPic && !uiStatic.renderPicbuttonText )'
# Any byte-order branch in this file would sit above that test and pre-empt it.
ENDIAN_BRANCH = 'XASH_BIG_ENDIAN'


def check_picbutton(path):
	assert os.path.isfile(path), ('no PicButton.cpp at %s' % path)
	src = open(path).read()
	n = src.count(ARTWORK_TEST)
	assert n == 1, ('picbutton artwork test found %d times (want 1) in %s'
	                % (n, path))
	if ENDIAN_BRANCH in src:
		print('MISSING, the artwork is gated on byte order: ' + path)
		return False
	print('ok, the artwork test is reached on every architecture: ' + path)
	return True


def main():
	if len(sys.argv) < 2:
		print('usage: patch-mainui-picbutton-endian.py <mainui-dir> ...')
		return 1
	ok = True
	for arg in sys.argv[1:]:
		assert os.path.isdir(arg), ('not a mainui directory: %s' % arg)
		ok = check_picbutton(os.path.join(arg, 'controls', 'PicButton.cpp')) and ok
	if not ok:
		print('issue #8: a PowerPC slice built from this menu tree would draw '
		      'the stock lettering for every mod')
	return 0 if ok else 1


if __name__ == '__main__':
	sys.exit(main())
