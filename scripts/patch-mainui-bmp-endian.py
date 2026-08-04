#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Check that the menu's own BMP class reads its headers little-endian
# (issue #33).
#
# SYMPTOM. On the G5, the spray-paint picker in Multiplayer > Customize offered
# one BMP entry, "xash", and that entry did nothing: no colour, and choosing it
# never produced a spray in game. Before v1.4.3 it crashed instead (#26). The
# WON picbuttons are the same defect wearing a different hat, because the atlas
# they are cut from is loaded through the same call.
#
# CAUSE. `CBMP::LoadFile` in Utils.cpp reads a `bmp_t` straight out of the file
# and then validates it:
#
#	bmp_t *bmp = (bmp_t*)EngFuncs::COM_LoadFile( filename, &length );
#	...
#	if( length < bmp->fileSize || ... )
#		return NULL;
#
# BMP headers are little-endian on disk. Without a swap, on PowerPC every field
# is read byte-reversed. logos/xash.bmp is 5174 bytes and stores fileSize as
# 36 14 00 00; read big-endian that is 907,804,672, so `length < bmp->fileSize`
# is true and LoadFile returns NULL. It returns NULL for EVERY BMP, of any size,
# because the check can only ever pass by accident.
#
# That NULL is exactly what #26 dereferenced, and what
# scripts/patch-mainui-logo-nullcheck.py guards. The guard stops the crash; it
# does not make the BMP readable. With LoadFile still returning NULL:
#
#   - the logo colour spinner stays greyed for every BMP logo,
#   - WriteNewLogo hits its own `if( !bmpFile ) return;` and never writes
#     logos/remapped.bmp, so the chosen spray never reaches the game,
#   - UI_LoadBmpButtons returns early and the WON buttons are never built.
#
# STATE OF THE MENU TREE. Both halves of this are handled in the menu source we
# build, so there is nothing here to edit:
#
#   1. Utils.cpp, `CBMP::LoadFile`, calls `CBMP::SwapBmpHdrToLE( bmp )` right
#      after the "BM" magic check and before the first field is trusted, so the
#      size validation, GetBitmapHdr, RemapLogo and GetPaletteData all read real
#      numbers.
#   2. menus/PlayerSetup.cpp, `WriteNewLogo`, writes through `CBMP::Save()`,
#      which swaps the header back to little-endian around the write. The engine
#      parses logos/remapped.bmp as little-endian and rejects a big-endian
#      header on its `planes != 1` test, so leaving host order on disk would
#      trade one broken spray for another.
#
# So this script edits nothing. It asserts both properties and reports, for two
# reasons. A menu tree that does not have them is not the tree this port builds
# against, and stopping the build says so. And
# scripts/patch-mainui-logo-picker.py inserts a preview block that swaps the
# header on the assumption that LoadFile handed back host order, so if property
# 1 ever goes away that inserted code becomes wrong as well.
#
# Ordering: independent of the other mainui patches. Idempotent, because it
# writes nothing. Python 2.5+.
import os
import sys

# CBMP::LoadFile swaps the header before it trusts a field.
LOADFILE_SWAP = 'CBMP::SwapBmpHdrToLE( bmp )'
# WriteNewLogo saves through CBMP::Save(), which swaps back for the disk.
SAVEFILE_CALL = 'bmpFile->Save( "logos/remapped.bmp" )'


def has_property(path, needle, description):
	assert os.path.isfile(path), ('no such file: %s' % path)
	src = open(path).read()
	if needle in src:
		print('ok, %s: %s' % (description, path))
		return True
	print('MISSING, %s: %s' % (description, path))
	return False


def check_tree(mainui):
	ok = has_property(os.path.join(mainui, 'Utils.cpp'), LOADFILE_SWAP,
	                  'CBMP::LoadFile swaps the header to host order')
	ok = has_property(os.path.join(mainui, 'menus', 'PlayerSetup.cpp'),
	                  SAVEFILE_CALL,
	                  'WriteNewLogo saves through CBMP::Save') and ok
	return ok


def main():
	if len(sys.argv) < 2:
		print('usage: patch-mainui-bmp-endian.py <mainui-dir> ...')
		return 1
	ok = True
	for arg in sys.argv[1:]:
		assert os.path.isdir(arg), ('not a mainui directory: %s' % arg)
		ok = check_tree(arg) and ok
	if not ok:
		print('issue #33: this menu tree cannot read a little-endian BMP header '
		      'on a big-endian host, and the spray picker and the WON buttons '
		      'will both be dead on PowerPC')
	return 0 if ok else 1


if __name__ == '__main__':
	sys.exit(main())
