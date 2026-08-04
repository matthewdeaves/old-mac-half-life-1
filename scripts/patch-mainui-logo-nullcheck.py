#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Stop the spray-paint logo spinner crashing the game (issue #26).
#
# Observed on an iMac G5 under 10.5.8 on shipped v1.4.2, cycling the spray-paint
# image spinner in Multiplayer > Customize:
#
#   Crash: signal 10 errno 0 with code 1 at 0x4
#    2: libmenu.dylib+0x592b3   CMenuPlayerSetup::UpdateLogo() + 0x1af
#    3: libmenu.dylib+0x1444f   CMenuBaseItem::_Event(int) + 0x22b
#    4: libmenu.dylib+0x22d2f   CMenuSpinControl::KeyUp(int) + 0x25f
#    5: libmenu.dylib+0x1d8df   CMenuItemsHolder::Key(int, bool) + 0x163
#
# SIGBUS at 0x4 is a null pointer plus a member offset. CMenuPlayerSetup::
# UpdateLogo does:
#
#   CBMP *bmpFile = CBMP::LoadFile( filename );
#   if( bmpFile->GetBitmapHdr()->bitsPerPixel == 8 )
#
# and CBMP::LoadFile returns NULL on three separate paths (Utils.cpp:325-340):
# the file will not load, it is shorter than a BMP header, or it lacks the BM
# magic. Any entry in the logo list whose file is missing or is not a BMP
# therefore kills the game the moment the spinner lands on it. The default entry
# showed no preview image on both test machines, which is the same condition.
#
# This is not a fork-specific defect: both engine trees carry the identical
# unguarded dereference, so it is upstream. Intel surviving a cycle through the
# list is luck about which entry was landed on, not immunity.
#
# The fix follows the convention already in this codebase rather than inventing
# one. The other two CBMP::LoadFile call sites BOTH check their result:
#
#   Btns.cpp                            if( bmp == nullptr ) return;
#   PlayerSetup.cpp, ApplyColorToLogoPreview:
#                                       if( !bmpFile ) return;  // not valid logo BMP file
#
# UpdateLogo is the single site that forgot.
#
# Guarding the condition rather than returning early is deliberate. An early
# return would also skip the CvarSetString( "cl_logofile", ... ) and
# WriteCvar() at the end of the function, so selecting an unloadable logo would
# silently stop recording the selection. Folding the test into the existing
# condition leaves every other effect of the function intact, and `delete` on a
# null pointer is well defined.
#
# Two indentation levels are handled because the two trees nest this differently:
# mainline sets a `colorable` flag inside a deeper else branch, the PowerPC fork
# calls ApplyColorToLogoPreview() at shallower depth. The code either side is
# otherwise identical.
#
# Applies to mainui in both trees. Idempotent. Python 2.5+.
import os
import re
import sys

MARKER = 'oldmac: LoadFile returns NULL for a missing or non-BMP file'

# The second CBMP::LoadFile in this same file is already guarded, so anchoring on
# the unguarded dereference that follows is what keeps them apart.
RE_SITE = re.compile(
	r'([ \t]*)CBMP \*bmpFile = CBMP::LoadFile\( filename \);\n'
	r'([ \t]*)if\( bmpFile->GetBitmapHdr\(\)->bitsPerPixel == 8 \)'
)


def replacement(m):
	i = m.group(1)
	return (
		'%sCBMP *bmpFile = CBMP::LoadFile( filename );\n'
		'\n'
		'%s// %s,\n'
		'%s// one too short to hold a header, or one lacking the BM magic. The other\n'
		'%s// two call sites in this menu already check; this one did not, and\n'
		'%s// landing the spray spinner on such an entry crashed the game.\n'
		'%s// Guarded here rather than returning early, so the cvar writes at the\n'
		'%s// end of the function still happen. delete on NULL is fine.\n'
		'%sif( bmpFile && bmpFile->GetBitmapHdr()->bitsPerPixel == 8 )'
		% (i, i, MARKER, i, i, i, i, i, m.group(2))
	)


def patch(path):
	s = open(path).read()
	if MARKER in s:
		print('already patched: ' + path)
		return
	n = len(RE_SITE.findall(s))
	assert n == 1, ('anchor found %d times (want 1) in %s' % (n, path))
	open(path, 'w').write(RE_SITE.sub(replacement, s, 1))
	print('patched: ' + path)


def main():
	if len(sys.argv) < 2:
		print('usage: patch-mainui-logo-nullcheck.py <mainui-dir-or-PlayerSetup.cpp> ...')
		return 1
	for arg in sys.argv[1:]:
		if os.path.isdir(arg):
			patch(os.path.join(arg, 'menus', 'PlayerSetup.cpp'))
		else:
			patch(arg)
	return 0


if __name__ == '__main__':
	sys.exit(main())
