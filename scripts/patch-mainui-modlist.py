#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Tidy the Custom Game mod table: a readable Type column and more room for names.
#
# TWO REPORTED PROBLEMS, both visible with our 25 mods installed:
#
# 1. The Type column is blank for several mods. Mods declare "type" freely in
#    liblist.gam and four of ours (Cleaner's Adventures, Escape from the Darkness,
#    Opposing Force, Induction) declare nothing at all, while Afraid of Monsters
#    declares an empty string. Of the ones that DO declare something, no two agree:
#    "Single", "single", "Single Player", "single player", "A single player mod",
#    "singleplayer_only", "singeplayer_only" (their typo), "multiplayer",
#    "multiplayer_only". Printed verbatim that column is noise, and sorting on it
#    is meaningless. Normalise to Single / Multi / Both, and label a mod that
#    declares nothing as "Mod" rather than leaving a hole in the table.
#
# 2. Long names are cut off - "Half-Life: Echoes" showing as "Half-Life:". The
#    table is only 0.50 of its width for the name while giving 0.20 to Type and
#    0.15 each to Ver and Size, which is far more than those three short fields
#    need. Rebalance towards the name, which is the column people actually read.
#
# The string matching is hand-rolled rather than using strstr/tolower so this adds
# no include to a file built by four different toolchains, the oldest being
# gcc-4.0 against the 10.3.9 SDK.
#
# Applies to mainui in both trees. Idempotent, Python 2.5+.
import os
import sys

MARKER = 'oldmac: normalise the Custom Game type column'

HELPER_ANCHOR = '''/*
=================
CMenuModListModel::Update
=================
*/
void CMenuModListModel::Update( void )
'''

HELPER = '''/*
=================
OldMacModType

''' + MARKER + '''.

Mods declare "type" freely in liblist.gam, so across the 24 we ship it arrives as
"Single", "single", "Single Player", "single player", "A single player mod",
"singleplayer_only", "singeplayer_only" (the mod's own typo), "multiplayer",
"multiplayer_only" - and five declare nothing at all, which left the column empty.
Collapse all of that to one short consistent label so the column reads cleanly and
sorting on it means something.

Hand-rolled substring match: this file is built by four toolchains, the oldest
being gcc-4.0 against the 10.3.9 SDK, and this way it needs no extra include.
=================
*/
static bool OldMacTypeHas( const char *hay, const char *needle )
{
\tint i, j;

\tfor( i = 0; hay[i]; i++ )
\t{
\t\tfor( j = 0; needle[j] && hay[i + j] == needle[j]; j++ )
\t\t\t;
\t\tif( !needle[j] )
\t\t\treturn true;
\t}
\treturn false;
}

static void OldMacModType( char *out, size_t size, const char *type )
{
\tchar lower[80];
\tint i = 0;
\tbool single, multi;

\tif( type != NULL )
\t{
\t\tfor( ; type[i] && i < (int)sizeof( lower ) - 1; i++ )
\t\t{
\t\t\tchar c = type[i];
\t\t\tlower[i] = ( c >= 'A' && c <= 'Z' ) ? (char)( c + 32 ) : c;
\t\t}
\t}
\tlower[i] = 0;

\t// "singe" catches one mod's misspelling of "singleplayer_only".
\tsingle = OldMacTypeHas( lower, "single" ) || OldMacTypeHas( lower, "singe" );
\tmulti  = OldMacTypeHas( lower, "multi" ) || OldMacTypeHas( lower, "deathmatch" );

\tif( single && multi )
\t\tQ_strncpy( out, "Both", size );
\telse if( multi )
\t\tQ_strncpy( out, "Multi", size );
\telse if( single )
\t\tQ_strncpy( out, "Single", size );
\telse if( lower[0] )
\t\tQ_strncpy( out, type, size );      // something we do not recognise: show it as-is
\telse
\t\tQ_strncpy( out, "Mod", size );     // declares nothing; do not leave a hole
}

''' + HELPER_ANCHOR

TYPE_ANCHOR = '\t\tQ_strncpy( mod.type, gi->type, sizeof( mod.type ));\n'
TYPE_NEW = '\t\tOldMacModType( mod.type, sizeof( mod.type ), gi->type );\n'

COLS_ANCHOR = '''\tmodList.SetupColumn( 0, L( "GameUI_Type" ), 0.20f );
\tmodList.SetupColumn( 1, L( "Name" ), 0.50f );
\tmodList.SetupColumn( 2, L( "Ver" ),  0.15f );
\tmodList.SetupColumn( 3, L( "Size" ), 0.15f );
'''
COLS_NEW = '''\t// oldmac: more room for the name, which is the column people read. Type is now
\t// one short word (see OldMacModType) and Ver/Size are a handful of characters,
\t// so the old 0.20/0.15/0.15 split was spending half the table on nothing.
\tmodList.SetupColumn( 0, L( "GameUI_Type" ), 0.16f );
\tmodList.SetupColumn( 1, L( "Name" ), 0.60f );
\tmodList.SetupColumn( 2, L( "Ver" ),  0.11f );
\tmodList.SetupColumn( 3, L( "Size" ), 0.13f );
'''


def patch(path):
    s = open(path).read()

    if MARKER in s:
        print('already patched:', path)
        return

    for name, anchor in (('helper', HELPER_ANCHOR), ('type', TYPE_ANCHOR), ('columns', COLS_ANCHOR)):
        assert s.count(anchor) == 1, ('%s anchor not found exactly once in %s' % (name, path))

    s = s.replace(HELPER_ANCHOR, HELPER, 1)
    s = s.replace(TYPE_ANCHOR, TYPE_NEW, 1)
    s = s.replace(COLS_ANCHOR, COLS_NEW, 1)

    open(path, 'w').write(s)
    print('patched:', path)


for arg in sys.argv[1:]:
    if os.path.isdir(arg):
        patch(os.path.join(arg, 'menus', 'CustomGame.cpp'))
    else:
        patch(arg)
