#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
patch-mainui-modart.py - show mod artwork and a description in the Custom Game menu.

The stock Custom Game screen is a bare four-column table (Type / Name / Ver /
Size) with Activate / Visit web site / Done. Everything needed to make it
informative is already there or nearly so; this adds the missing presentation:

  1) A preview image of the selected mod.
  2) A short description under it.
  3) Full mod titles - the stock code truncates anything past 32 characters to
     "Something Very Long Nam..." for no reason we care about.

WHERE THE ARTWORK COMES FROM (and why not straight from the mod folder)
-----------------------------------------------------------------------
Each mod ships its own banner at <gamedir>/game.tga. It cannot be loaded from
there: while you are running `valve`, the mod's directory is NOT in the engine's
filesystem search path, so PIC_Load("bshift/game.tga") would fail.

So the installer stages a copy inside the base game, where the search path always
reaches:

    valve/gfx/shell/mods/<gamedir>.tga     artwork
    valve/gfx/shell/mods/<gamedir>.txt     description (plain text, we write these)

That is the same trick the rest of the menu uses for its own art
(gfx/shell/head_custom and friends), and it means this patch needs no engine
change and no new file API - COM_LoadFile on a gfx/shell path is exactly what
menus/Controls.cpp already does for kb_act.lst.

A mod with no staged artwork simply shows no preview; nothing fails.

LAYOUT NOTE: the preview is placed in the empty area on the LEFT, below the
Activate/Visit/Done buttons, so the mod table on the right is untouched. Worth an
eyeball on real hardware at 800x600 (the G3 profile) as well as native res.

Idempotent, and revision-guarded: a tree holding an older body of this same fix
is reported and fails the run rather than passing as "already patched". See
MARKER_REV and issue #39. Python 2.5+.

Invoke:
    python patch-mainui-modart.py <mainui-dir>
where <mainui-dir> is the 3rdparty/mainui checkout.
"""
import os
import sys

MARKER = "oldmac: mod artwork + description"

# The guard has to tell "this fix is applied" apart from "SOME revision of this
# fix is applied", or a tree carrying a superseded body reports "already patched"
# and keeps it forever. That is issue #39, and the 2026-07-27 audit of the two
# build minis reported this script as one of three whose stale output was sitting
# on those hosts, pinned there by MARKER matching every body it has emitted.
#
# MARKER_REV goes in the emitted comments and is what "already patched" tests.
# Bare MARKER without MARKER_REV means a superseded revision, which is an error
# rather than a skip: the anchors that revision consumed are gone, so re-running
# cannot correct it. Bump the revision whenever the emitted C++ changes.
MARKER_REV = MARKER + " (rev 1)"

# --- 1) members on the menu class --------------------------------------------
MEMBERS_ANCHOR = """	CMenuTable	modList;
	CMenuModListModel modListModel;
"""
MEMBERS_NEW = """	CMenuTable	modList;
	CMenuModListModel modListModel;

	// """ + MARKER_REV + """
	CMenuBitmap	preview;         // valve/gfx/shell/mods/<gamedir>.tga
	CMenuAction	descLines[4];    // valve/gfx/shell/mods/<gamedir>.txt, wrapped
	// CMenuBaseItem::SetNameAndStatus stores the POINTER it is given, it does
	// not copy. These lines therefore have to own their text for as long as
	// they are on screen, which is until the next UpdatePreview. Passing a
	// buffer local to that function left all four items pointing into a dead
	// stack frame, redrawn every frame.
	char		descText[4][128];
"""

# --- 2) stop truncating the title --------------------------------------------
TRUNC_ANCHOR = """		if( ColorStrlen( gi->title ) > sizeof( mod.name ) - 1 ) // NAME_LENGTH
		{
			size_t s = sizeof( mod.name ) - 4;

			Q_strncpy( mod.name, gi->title, s );

			mod.name[s] = mod.name[s+1] = mod.name[s+2] = '.';
			mod.name[s+3] = 0;
		}
		else Q_strncpy( mod.name, gi->title, sizeof( mod.name ));
"""
TRUNC_NEW = """		// """ + MARKER + """: mod.name is now wide enough for any real title, so
		// keep the whole thing instead of eliding it to "Some Long Nam...".
		Q_strncpy( mod.name, gi->title, sizeof( mod.name ));
"""

# The table's name buffer has to grow to match, or the copy just truncates again.
NAMEBUF_ANCHOR = "	char name[32];\n"
NAMEBUF_NEW = "	char name[64];   // " + MARKER + ": was 32, which elided longer titles\n"

# --- 3) load artwork + description when the selection changes ----------------
EXTRAS_ANCHOR = """	go2url->onReleased.pExtra = modListModel.mods[i].webSite;
	go2url->SetGrayed( modListModel.mods[i].webSite[0] == 0 );

	msgBox.onPositive.pExtra = modListModel.mods[i].dir;
}
"""
EXTRAS_NEW = """	go2url->onReleased.pExtra = modListModel.mods[i].webSite;
	go2url->SetGrayed( modListModel.mods[i].webSite[0] == 0 );

	msgBox.onPositive.pExtra = modListModel.mods[i].dir;

	// """ + MARKER + """
	UpdatePreview( modListModel.mods[i].dir );
}

/*
=================
CMenuCustomGame::UpdatePreview

Show the selected mod's banner and blurb. Both live under the BASE game's
gfx/shell/mods/, because while we are running `valve` the mod's own directory is
not in the filesystem search path. The installer stages them there.
=================
*/
void CMenuCustomGame::UpdatePreview( const char *dir )
{
	char path[256];
	char *text;
	int i;

	for( i = 0; i < 4; i++ )
		descLines[i].SetNameAndStatus( "", "" );

	if( !dir || !dir[0] )
	{
		preview.SetPicture( "" );
		return;
	}

	snprintf( path, sizeof( path ), "gfx/shell/mods/%s", dir );
	preview.SetPicture( path );

	snprintf( path, sizeof( path ), "gfx/shell/mods/%s.txt", dir );
	text = (char *)EngFuncs::COM_LoadFile( path, NULL );
	if( text )
	{
		// Plain text, one display line per source line, first four shown.
		char *p = text;
		for( i = 0; i < 4 && *p; i++ )
		{
			char *line = descText[i];
			int n = 0;

			while( *p && *p != '\\n' && *p != '\\r' && n < (int)sizeof( descText[i] ) - 1 )
				line[n++] = *p++;
			line[n] = 0;
			while( *p == '\\n' || *p == '\\r' )
				p++;

			// into the item's own storage, never a stack buffer: see descText
			descLines[i].SetNameAndStatus( line, "" );
		}
		EngFuncs::COM_FreeFile( text );
	}
}
"""

# --- 4) declare the new method ------------------------------------------------
DECL_ANCHOR = "	void UpdateExtras( );\n"
DECL_NEW = ("	void UpdateExtras( );\n"
            "	void UpdatePreview( const char *dir );   // " + MARKER + "\n")

# --- 5) create the widgets ----------------------------------------------------
INIT_ANCHOR = """	AddItem( modList );
"""
INIT_NEW = """	AddItem( modList );

	// """ + MARKER + """
	// Left-hand column, below the Activate/Visit/Done buttons. The mod table on the
	// right keeps its original geometry so nothing existing shifts.
	preview.SetRect( 72, 415, 224, 168 );
	preview.SetPicture( "" );
	// Decoration only. CMenuBitmap is normally a clickable item, and
	// CMenuItemsHolder::AdjustCursor skips an item ONLY for QMF_INACTIVE /
	// QMF_MOUSEONLY / hidden - so without this the artwork becomes a dead stop in
	// the keyboard tab order between Done and the mod table.
	preview.iFlags |= QMF_INACTIVE;
	AddItem( preview );

	for( int d = 0; d < 4; d++ )
	{
		descLines[d].SetRect( 72, 595 + d * 20, 264, 20 );
		descLines[d].SetNameAndStatus( "", "" );
		descLines[d].iFlags |= QMF_INACTIVE | QMF_DROPSHADOW;
		AddItem( descLines[d] );
	}
"""

EDITS = [
    (MEMBERS_ANCHOR, MEMBERS_NEW, "menu class members"),
    (NAMEBUF_ANCHOR, NAMEBUF_NEW, "widen the title buffer"),
    (TRUNC_ANCHOR, TRUNC_NEW, "stop truncating titles"),
    (DECL_ANCHOR, DECL_NEW, "declare UpdatePreview"),
    (EXTRAS_ANCHOR, EXTRAS_NEW, "load artwork on selection"),
    (INIT_ANCHOR, INIT_NEW, "create preview widgets"),
]



def patch(path):
    f = open(path, "r")
    src = f.read()
    f.close()

    if MARKER_REV in src:
        print("  already patched: %s" % path)
        return True

    # A bare MARKER without the revision means this file holds a SUPERSEDED body
    # of this same fix, and the anchors below are gone, consumed by that older
    # edit. Re-running cannot correct it. Say so and fail, rather than the
    # "already patched, exit 0" that kept the dangling-pointer body of the
    # description lines alive on a build mini. Issue #39. The tree has to be
    # reset to its pin and patched again.
    #
    # This replaces an in-place upgrade path that swapped that one known body
    # for the current one. It could only ever correct the bodies it enumerated,
    # so it repaired the case it was written for and silently accepted every
    # other; git history has it if a future upgrade path is wanted.
    if MARKER in src:
        print("  ERROR: %s holds a SUPERSEDED revision of this fix." % path)
        print("         Wanted: %s" % MARKER_REV)
        print("         This cannot be repaired in place: reset the tree to its")
        print("         pinned commit (vendor/MANIFEST.md) and re-run the driver.")
        return False

    for anchor, _new, what in EDITS:
        if anchor not in src:
            print("  ERROR: anchor for '%s' not found in %s" % (what, path))
            return False

    for anchor, new, what in EDITS:
        src = src.replace(anchor, new, 1)
        print("  applied: %s" % what)

    # Bitmap.h is not pulled in by CustomGame.cpp's existing includes.
    if '#include "Bitmap.h"' not in src:
        src = src.replace('#include "PicButton.h"',
                          '#include "Bitmap.h"\n#include "PicButton.h"', 1)
        print("  applied: include Bitmap.h")

    f = open(path, "w")
    f.write(src)
    f.close()
    print("  patched: %s" % path)
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    ok = True
    for tree in sys.argv[1:]:
        # accept either the mainui dir or the .cpp itself
        path = tree
        if os.path.isdir(tree):
            path = os.path.join(tree, "menus", "CustomGame.cpp")
        print("== %s ==" % path)
        if not os.path.isfile(path):
            print("  ERROR: not found")
            ok = False
            continue
        ok = patch(path) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
