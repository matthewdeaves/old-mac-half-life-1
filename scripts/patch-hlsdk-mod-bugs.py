#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
patch-hlsdk-mod-bugs.py - per-mod source fixes found by the endian/quality audit.

These are bugs in the mods' own code, not in shared hlsdk (that is
patch-hlsdk-shared-clientbugs.py) and not endian plumbing (that is
patch-hlsdk-studio-endian.py). Each was confirmed by reading the source; see
docs/MOD-AUDIT.md and tasks #32-#40 for the full reasoning.

WHY THESE MATTER MORE TO US THAN TO THE ORIGINAL RELEASES
---------------------------------------------------------
We ship code and the player supplies content. A map, a soundtrack.txt or an mp3
name we have never seen is the NORMAL case here, not an edge case, so the
unbounded sprintf and the missing null checks below are considerably more
reachable in this port than they were in the original Windows builds. PowerPC also
lays out stack frames differently from x86_64, so a smash presents differently
there - exactly the kind of thing that becomes an unexplained crash report.

KEYED BY BRANCH, ON PURPOSE
---------------------------
Files like dlls/player.cpp and cl_dll/hud.cpp exist in EVERY branch, so "anchor
not found" cannot be treated as "nothing to do" - that would silently skip a real
fix if a branch moved a line. Instead the caller passes the branch name and only
that branch's fixes are attempted, and every one of them MUST apply or this exits
non-zero. The branch NAME is checked the same way, against installer/mods.map:
most mods have no fixes here, so "no audit fixes for this branch" has to stay a
quiet success, which is exactly why a name that is not a branch at all must not
be allowed to look like one.

APPLY TO BOTH TREES. Apart from the DMC byteswap these are arch-neutral, so
running this on the ppc tree only would leave the Intel slice of the same mod
still carrying the bug.

Idempotent: every fix carries its own marker.

Invoke:
    python patch-hlsdk-mod-bugs.py <branch> <hlsdk-tree>
"""
import io
import os
import sys

# Each fix: ( relative path, marker, old, new, label )
# `old` must occur exactly once unless the entry sets count explicitly below.
FIXES = {}

# ---------------------------------------------------------------- #32 dmc --
# The mod's OWN bsp reader, so the engine's byteswapping does not cover it. On
# PowerPC header.version for a BSP30 map reads back as 0x1E000000 = 503316480,
# the version check always fires and the teleporter list stays permanently empty:
# client-side teleport prediction is dead, with a visible lag-snap and no local
# sound. Intel players in the same game are unaffected, so it is an asymmetric
# PPC-only regression.
FIXES["dmc"] = [
    (
        os.path.join("cl_dll", "dmc", "DMC_Teleporters.cpp"),
        "// oldmac: BSP lumps are little-endian on disk",
        "\t// Check the version\n\ti = header.version;\n",
        "\t// oldmac: BSP lumps are little-endian on disk and this is the mod's own\n"
        "\t// reader, so nothing has swapped them. On PowerPC a BSP30 header reads\n"
        "\t// back as 0x1E000000 and the check below always fires, leaving the\n"
        "\t// teleporter list empty and killing client-side teleport prediction.\n"
        "\t// LittleToHostSW is an empty macro on little-endian, so Intel is a no-op.\n"
        "\t{\n"
        "\t\tint lump;\n"
        "\n"
        "\t\tLittleToHostSW( header.version );\n"
        "\t\tfor( lump = 0; lump < HEADER_LUMPS; lump++ )\n"
        "\t\t{\n"
        "\t\t\tLittleToHostSW( header.lumps[lump].fileofs );\n"
        "\t\t\tLittleToHostSW( header.lumps[lump].filelen );\n"
        "\t\t}\n"
        "\t}\n"
        "\n"
        "\t// Check the version\n\ti = header.version;\n",
        "dmc: byteswap the BSP header",
    ),
    (
        os.path.join("cl_dll", "dmc", "DMC_Teleporters.cpp"),
        '#include "byteswap.h"',
        '#include "hud.h"\n',
        '#include "hud.h"\n#include "byteswap.h"\t// oldmac: LittleToHostSW\n',
        "dmc: include byteswap.h",
    ),
    # This guard is NOT optional and must not be separated from the byteswap
    # above. Dmc_FindTarget returns NULL when a trigger_teleport names a
    # destination the map does not contain, and the lines that follow dereference
    # it immediately. On PowerPC that was unreachable only BECAUSE of the endian
    # bug: the teleporter list stayed empty, so this code never ran. Fixing the
    # byteswap populates the list and makes the null deref reachable on PowerPC
    # for the first time, so shipping one without the other would trade a dead
    # feature for a crash. Intel could always reach it.
    (
        os.path.join("cl_dll", "dmc", "DMC_Teleporters.cpp"),
        "// oldmac: Dmc_FindTarget returns NULL",
        "\ttarget = Dmc_FindTarget( pTele->target, numtele, pTeles );\n"
        "\n"
        "\tfor ( i = 0; i < 3; i++ )\n",
        "\ttarget = Dmc_FindTarget( pTele->target, numtele, pTeles );\n"
        "\n"
        "\t// oldmac: Dmc_FindTarget returns NULL when a trigger_teleport names a\n"
        "\t// destination this map does not contain, and everything below\n"
        "\t// dereferences it. Reachable on PowerPC only once the byteswap above\n"
        "\t// stops the teleporter list coming out empty, which is why the two\n"
        "\t// changes belong together.\n"
        "\tif ( !target )\n"
        "\t\treturn;\n"
        "\n"
        "\tfor ( i = 0; i < 3; i++ )\n",
        "dmc: guard the teleport destination lookup",
    ),
    # The other half of what the byteswap woke up. Deathmatch Classic threw the
    # player across the map on any movement key or mouse fire; `cl_nopred 1`
    # stopped it completely, which places it in this client-side predictor and
    # rules out everything server-side. See GitHub issue #32.
    #
    # WHAT IS ESTABLISHED
    #
    # Every trigger_teleport's bounding box arrives from the SERVER in
    # gmsgInitHUD: dlls/player.cpp UpdateClientData writes it, cl_dll/hud_msg.cpp
    # MsgFunc_InitHUD reads it. Nothing else on the client ever writes
    # g_iTeleNum or g_vecTeleMins/Maxs. An instrumented build on a G5 listen
    # server on capturephobolis showed the predictor running before that message
    # arrives:
    #
    #   Touch call=1 numtele=10 g_iTeleNum=0 loaded=0 fired=-1 org=(-960 -776 -651)
    #   InitHUD  iSize=73 g_iTeleNum=6
    #   Touch call=2 numtele=10 g_iTeleNum=6 loaded=1 fired=-1
    #
    # So on call 1 the loop below copies the still-zero g_vecTeleMins into every
    # teleporter and runs the overlap test against boxes the server has not
    # described. A zeroed entry padded by the 1.0f either side is a unit box at
    # the WORLD ORIGIN, which is a place a player can stand.
    #
    # WHAT IS NOT ESTABLISHED
    #
    # That run did not reproduce the warp: fired was -1 on all 20 logged calls,
    # and the player was about 1400 units from the origin the whole time, so
    # nothing matched. Reproducing it needs someone pressing a movement key,
    # which could not be driven remotely. Treat the exact trigger as OPEN. What
    # is fixed here is prediction against bounds that do not exist, which is
    # wrong on its own terms whether or not it is the whole of #32.
    #
    # None of this was reachable on PowerPC before the byteswap above, because
    # the teleporter list was always empty and the predictor never ran. That is
    # why the G4, still on the older dylib pair, plays correctly. It is not
    # PowerPC-specific in itself.
    #
    # A second defect goes with it: the index into g_vecTeleMins is the count of
    # trigger_teleports the CLIENT found in the map's entity lump, while
    # g_iTeleNum is the count the SERVER actually spawned and described. Nothing
    # makes those equal. The index stays in bounds either way, since MAX_TELES is
    # 256 and g_iTeleNum comes from a READ_BYTE, but past g_iTeleNum it reads
    # entries the server never filled: zero on the first map of a session, and
    # the previous map's boxes after that.
    #
    # NOT DONE, deliberately. Clearing g_bLoadedTeles in Dmc_LoadTeleporters
    # looks like the obvious companion change and is actively harmful. On the
    # second map of a session, in the window before that map's InitHUD arrives,
    # g_iTeleNum still holds the PREVIOUS map's count, so the early return below
    # does not fire; clearing the flag there would copy the previous map's boxes
    # onto this map's teleporters at real, walkable coordinates. Leaving the flag
    # set is what makes those entries keep the zero box Dmc_ParseTeleporter
    # memset them to, which the degenerate-box skip below then ignores.
    (
        os.path.join("cl_dll", "dmc", "DMC_Teleporters.cpp"),
        "// oldmac: the server has not described the teleporters yet",
        "\tint\t\t\tiTeleNum = 0;\n"
        "\t\n"
        "\n"
        "\t// Determine player's bbox\n",
        "\tint\t\t\tiTeleNum = 0;\n"
        "\n"
        "\t// oldmac: the server has not described the teleporters yet, so there is\n"
        "\t// nothing to predict against. Without this the loop below builds every\n"
        "\t// teleporter a unit box out of the zeroed g_vecTeleMins, which sits at the\n"
        "\t// world origin, and then tests the player against it. g_iTeleNum is only\n"
        "\t// ever set by MsgFunc_InitHUD, and it is negative if that message was\n"
        "\t// truncated, since READ_BYTE returns -1 on a short read. See issue #32.\n"
        "\tif ( g_iTeleNum <= 0 )\n"
        "\t\treturn;\n"
        "\n"
        "\t// Determine player's bbox\n",
        "dmc: do not predict teleports before the bounds arrive",
    ),
    (
        os.path.join("cl_dll", "dmc", "DMC_Teleporters.cpp"),
        "// oldmac: iTeleNum counts what THIS side found",
        "\t\tif ( !g_bLoadedTeles )\n"
        "\t\t{\n"
        "\t\t\tfor( j = 0; j < 3; j++ )\n"
        "\t\t\t{\n"
        "\t\t\t\tpTele->absmin[ j ] = g_vecTeleMins[ iTeleNum ][ j ] - 1.0f;\n"
        "\t\t\t\tpTele->absmax[ j ] = g_vecTeleMaxs[ iTeleNum ][ j ] + 1.0f;\n"
        "\t\t\t}\n"
        "\t\t\tiTeleNum++;\n"
        "\t\t\t\n"
        "\t\t\t//Done going thru all the teleporters\n"
        "\t\t\tif ( iTeleNum == g_iTeleNum )\n"
        "\t\t\t\t g_bLoadedTeles = true;\t\n"
        "\t\t}\n",
        "\t\tif ( !g_bLoadedTeles )\n"
        "\t\t{\n"
        "\t\t\t// oldmac: iTeleNum counts what THIS side found in the map's entity\n"
        "\t\t\t// lump; g_iTeleNum is how many the SERVER spawned and described.\n"
        "\t\t\t// Nothing makes those equal. The index stays in bounds either way,\n"
        "\t\t\t// but past g_iTeleNum it reads entries the server never filled:\n"
        "\t\t\t// zero on the first map of a session, the previous map's boxes\n"
        "\t\t\t// after that. Leave those teleporters holding the zero box\n"
        "\t\t\t// Dmc_ParseTeleporter memset them to, so the skip below ignores\n"
        "\t\t\t// them instead of matching them somewhere arbitrary.\n"
        "\t\t\tif ( iTeleNum >= g_iTeleNum )\n"
        "\t\t\t\tcontinue;\n"
        "\n"
        "\t\t\tfor( j = 0; j < 3; j++ )\n"
        "\t\t\t{\n"
        "\t\t\t\tpTele->absmin[ j ] = g_vecTeleMins[ iTeleNum ][ j ] - 1.0f;\n"
        "\t\t\t\tpTele->absmax[ j ] = g_vecTeleMaxs[ iTeleNum ][ j ] + 1.0f;\n"
        "\t\t\t}\n"
        "\t\t\tiTeleNum++;\n"
        "\t\t\t\n"
        "\t\t\t//Done going thru all the teleporters\n"
        "\t\t\tif ( iTeleNum == g_iTeleNum )\n"
        "\t\t\t\t g_bLoadedTeles = true;\t\n"
        "\t\t}\n"
        "\n"
        "\t\t// oldmac: a box nobody filled in. Server-described bounds are padded by\n"
        "\t\t// a unit on each side, so their span is at least 2.0 on every axis and\n"
        "\t\t// they can never be degenerate, even for a teleporter whose sent mins\n"
        "\t\t// and maxs are identical. Only a memset entry reads 0 == 0 on all\n"
        "\t\t// three. Matching one of those would teleport the player whenever they\n"
        "\t\t// stood over the world origin.\n"
        "\t\tif ( pTele->absmin[0] == pTele->absmax[0]\n"
        "\t\t\t&& pTele->absmin[1] == pTele->absmax[1]\n"
        "\t\t\t&& pTele->absmin[2] == pTele->absmax[2] )\n"
        "\t\t\tcontinue;\n",
        "dmc: never test a teleporter the server did not describe",
    ),
    # The reported fault in issue #32: Deathmatch Classic threw the player to a
    # random info_player_deathmatch on essentially every frame while a movement
    # key or fire was held, which reads as being thrown around the map. This is
    # the fix for that. The teleport-predictor entries above are a different
    # defect and were never the cause; see the correction on the issue.
    #
    # WHAT IS PROVEN
    #
    # CBasePlayer::Spawn implements "read the MOTD before you play" by parking a
    # first-time player at pev->deadflag = DEAD_RESPAWNABLE, movetype NONE,
    # solid NOT, when m_bHadFirstSpawn is false and the server has a motd.txt
    # (g_bHaveMOTD). Nothing about that state says MOTD: it is the same deadflag
    # a corpse waiting to respawn carries. PreThink routes any deadflag >=
    # DEAD_DYING into PlayerDeathThink, and PlayerDeathThink respawns on any
    # button down. respawn() calls Spawn() again, Spawn() still finds
    # m_bHadFirstSpawn false and re-enters the hold, and the next frame does it
    # all again for as long as a button is held. Spawn() asks
    # GetPlayerSpawnSpot() before that test, so every pass lands on a different
    # random spawn point, and every pass leaves a corpse via CopyToBodyQue.
    #
    # Only the _firstspawn client command sets m_bHadFirstSpawn, and our client
    # only sends it from CL_ButtonBits when attack is pressed while the MOTD is
    # on screen. So the loop runs from the moment the player connects until they
    # fire, and cannot recur on that connection afterwards. It comes back on the
    # next map, because ClientPutInServer clears the flag again.
    #
    # Measured headlessly, +forward latched in dmc/userconfig.cfg on a listen
    # server, player origin logged every predicted command:
    #   G5, capturephobolis: origin cycles through that map's six
    #     info_player_deathmatch entities, several times a second
    #   G5, dmc_dm3: same, so this is not CTF-specific
    #   G5, the_cistern: same, and that map's entity lump holds ZERO
    #     trigger_teleport and zero info_teleport_destination, with the client
    #     logging numtele=0 g_iTeleNum=0 throughout. The teleporter code cannot
    #     be involved in this at all.
    #   Intel Lion, dmc_dm3: the same six origins as the G5, so this is not
    #     endianness and not PowerPC
    #   G5, +forward and +attack together: two jumps, then the origin advances
    #     smoothly forward and settles on the ground
    #   G5, motd.txt moved aside: smooth forward walk from the first frame
    # cl_nopred 1 changes nothing, as expected for a server-side respawn. That
    # was checked properly rather than assumed: dmc/config.cfg carries
    # cl_nopred "0", so the cvar was polled from the console once a second
    # during the run and printed "cl_nopred" is "1" the whole time while the
    # origin kept cycling. The hands-on report that it cured the warp is most
    # likely the one-shot nature above: once the player has fired, nothing they
    # change afterwards can bring the warp back on that connection.
    #
    # WHAT IS NOT ESTABLISHED
    #
    # Only listen servers were tested; a client joining a remote server was not.
    # The original Windows release was not tested, so whether players saw this in
    # 2001 is unknown. mp_forcerespawn was 0 throughout: with it on, the same
    # loop should run with no input at all, since PlayerDeathThink respawns on
    # the timer too, but that was not measured.
    #
    # THE FIX
    #
    # End the MOTD hold here as well as in _firstspawn, so a button press
    # respawns the player once instead of once per frame. Blocking the respawn
    # outright is closer to the intent but has no exit if the client never shows
    # the MOTD: g_bHaveMOTD is true whenever motd.txt merely opens, while
    # SendMOTDToClient sends nothing at all for an empty file and reads the
    # motdfile cvar rather than motd.txt, so a server can hold a player behind a
    # MOTD the client is never given the chance to dismiss. Releasing on a button
    # cannot deadlock, and it lands the player in exactly the state the fire
    # button would have.
    (
        os.path.join("dlls", "player.cpp"),
        "// oldmac: this is the MOTD hold, not a corpse",
        "\tpev->button = 0;\n"
        "\tm_flRespawnTimer = 0;\n"
        "\n"
        '\t//ALERT( at_console, "Respawn\\n" );\n',
        "\tpev->button = 0;\n"
        "\tm_flRespawnTimer = 0;\n"
        "\n"
        "\t// oldmac: this is the MOTD hold, not a corpse. Spawn() parks a first-time\n"
        "\t// player at DEAD_RESPAWNABLE until they dismiss the MOTD, and PreThink\n"
        "\t// cannot tell that state from a dead one. Without this, respawn() below\n"
        "\t// re-enters the hold and the next frame with a button down throws the\n"
        "\t// player to another random spawn point, and the next, and the next. See\n"
        "\t// issue #32.\n"
        "\tif( !m_bHadFirstSpawn && g_bHaveMOTD )\n"
        "\t\tm_bHadFirstSpawn = true;\n"
        "\n"
        '\t//ALERT( at_console, "Respawn\\n" );\n',
        "dmc: a button press ends the MOTD hold instead of respawning forever",
    ),
    # Jump does nothing in dmc. The mod's client-side autojump strips the jump
    # bit off every command it thinks is already airborne:
    #
    #	if( cl_autojump->value != 0.0f )
    #	{
    #		bool should_release_jump = ( !g_onground && !g_inwater && g_walking );
    #		...
    #		if( should_release_jump )
    #			cmd->buttons &= ~IN_JUMP;
    #	}
    #
    # cl_autojump is registered "1", so that runs by default. The three globals
    # start as g_onground = false, g_inwater = false, g_walking = true, and the
    # ONLY place any of them is written is the client's copy of PM_Move, at
    # pm_shared.c:2815. That runs solely as part of client-side prediction. So
    # until a predicted move happens, and forever if none ever does, the test
    # reads "not on ground, not in water, walking", which is the airborne case,
    # and IN_JUMP is removed from every single command before it is sent.
    #
    # The initialiser is the bug. Before the first move nothing knows the
    # player's movetype, and the comment on the line says as much: it is meant
    # to mean MOVETYPE_WALK, which is not established yet. Of the two possible
    # starting guesses only one is safe, because they fail in different ways:
    # true disables jumping outright, false merely disables the autojump release
    # until prediction reports otherwise, which is vanilla behaviour. PM_Move
    # overwrites all three on its first run, so with prediction on this is a
    # one-frame difference and nothing else.
    #
    # NOT asserted here: why prediction is off on this fleet. A console poll
    # during the teleport work above read cl_nopred as 1 throughout a session
    # whose dmc/config.cfg sets it to 0, and that has not been explained. This
    # fix does not depend on the answer: the initialiser is wrong either way.
    (
        os.path.join("cl_dll", "input.cpp"),
        "// oldmac: nothing has established the movetype yet",
        "\tint g_walking = true; // Movetype == MOVETYPE_WALK."
        " Filters out noclip, being on ladder, etc.\n",
        "\t// oldmac: nothing has established the movetype yet, and guessing WALK\n"
        "\t// here is the guess that breaks. With g_onground and g_inwater both\n"
        "\t// starting false too, the autojump test below reads as airborne and\n"
        "\t// strips IN_JUMP from every command, so jump does nothing at all until\n"
        "\t// the client's PM_Move writes these, and forever if prediction is off.\n"
        "\t// Guessing false only costs the autojump release. Issue #32.\n"
        "\tint g_walking = false; // Movetype == MOVETYPE_WALK."
        " Filters out noclip, being on ladder, etc.\n",
        "dmc: jump is stripped from every command before the first predicted move",
    ),
]

# ------------------------------------------------------------ #33 blackops --
# FIELD_TIME makes the save system subtract gpGlobals->time on write and re-add it
# on read. m_flNVGBattery is a 0-100 percentage, so a saved night-vision charge
# restores as garbage. m_flNVGUpdate and m_flInfraredUpdate really are timestamps
# and are correctly FIELD_TIME, so this is a one-line slip, not a pattern.
FIXES["blackops"] = [
    (
        os.path.join("dlls", "player.cpp"),
        "// oldmac: a 0-100 percentage, not a timestamp",
        "\tDEFINE_FIELD( CBasePlayer, m_flNVGBattery, FIELD_TIME ),\n",
        "\t// oldmac: a 0-100 percentage, not a timestamp. FIELD_TIME would have the\n"
        "\t// save system subtract gpGlobals->time on write and re-add it on read, so\n"
        "\t// night-vision charge restored as instantly full or instantly flat.\n"
        "\tDEFINE_FIELD( CBasePlayer, m_flNVGBattery, FIELD_FLOAT ),\n",
        "blackops: NVG battery save field type",
    ),
    (
        os.path.join("cl_dll", "hud.cpp"),
        "// oldmac: pszSound is server-supplied",
        '\t\tsprintf( cmd, "mp3 play media/%s\\n", pszSound );\n',
        "\t\t// oldmac: pszSound is server-supplied via READ_STRING and cmd is a\n"
        "\t\t// 64-byte stack buffer, so this was an unbounded write.\n"
        '\t\tsnprintf( cmd, sizeof( cmd ), "mp3 play media/%s\\n", pszSound );\n',
        "blackops: bound the PlayMP3 sprintf",
    ),
]

# ---------------------------------------------- #35 poke646 / poke646_vendetta --
# Runs from GameDLLInit(). A soundtrack.txt listing a map with no extension makes
# strchr return NULL and the server dies at startup. The file is byte-identical
# between the two branches.
_POKE646_SOUND = (
    os.path.join("dlls", "sound.cpp"),
    "// oldmac: a soundtrack.txt entry with no extension",
    "\t\tpos = strchr( g_soundtracklist[j].mapname, '.' );\n\t\t*pos = '\\0';\n",
    "\t\t// oldmac: a soundtrack.txt entry with no extension (po_c1m1 rather than\n"
    "\t\t// po_c1m1.bsp) makes strchr return NULL, and this runs from GameDLLInit,\n"
    "\t\t// so the server died at startup. The player supplies this file, so a\n"
    "\t\t// malformed one is a case we have to survive.\n"
    "\t\tpos = strchr( g_soundtracklist[j].mapname, '.' );\n"
    "\t\tif( pos )\n\t\t\t*pos = '\\0';\n",
    "poke646: survive a soundtrack.txt entry with no extension",
)
FIXES["poke646"] = [_POKE646_SOUND]
FIXES["poke646_vendetta"] = [_POKE646_SOUND]

# -------------------------------------------------------------- #37 opfor --
# Fixed size 1, but all eight send sites write a byte AND a null-terminated
# string. FWGS validates fixed-size user messages in SV_MessageEnd and drops any
# that do not match, with console spam. -1 means variable length, as DeathMsg and
# ShowMenu already use for byte-plus-string payloads.
FIXES["opfor"] = [
    (
        os.path.join("dlls", "player.cpp"),
        "// oldmac: variable length",
        '\tgmsgCTFMsgs = REG_USER_MSG( "CTFMsg", 1 );\n',
        "\t// oldmac: variable length. Every send site writes a byte AND a string, so\n"
        "\t// registering it as fixed size 1 made FWGS drop the message and log an\n"
        "\t// error on every CTF flag event.\n"
        '\tgmsgCTFMsgs = REG_USER_MSG( "CTFMsg", -1 );\n',
        "opfor: CTFMsg is variable length",
    ),
]

# ------------------------------------------------------------ #38 thegate --
FIXES["thegate"] = [
    (
        os.path.join("cl_dll", "hud.cpp"),
        "// oldmac: pszSound comes off the wire",
        '\t\tsprintf( cmd, "mp3 loop sound/mp3/%s\\n", pszSound );\n',
        "\t\t// oldmac: pszSound comes off the wire and cmd was 64 bytes with a\n"
        "\t\t// 21-character prefix, so any name over ~42 characters smashed the stack.\n"
        '\t\tsnprintf( cmd, sizeof( cmd ), "mp3 loop sound/mp3/%s\\n", pszSound );\n',
        "thegate: bound the mp3-loop sprintf",
    ),
    (
        os.path.join("cl_dll", "hud.cpp"),
        "// oldmac: same wire string, same buffer",
        '\t\tsprintf( cmd, "sound/mp3/%s", pszSound );\n',
        "\t\t// oldmac: same wire string, same buffer.\n"
        '\t\tsnprintf( cmd, sizeof( cmd ), "sound/mp3/%s", pszSound );\n',
        "thegate: bound the music-stream sprintf",
    ),
    (
        os.path.join("dlls", "TheGate", "command.cpp"),
        "// oldmac: netname is a map keyvalue",
        "\tif( !pev->netname )\n\t\treturn;\n\n"
        '\tsprintf( cmd, "%s\\n", STRING( pev->netname ) );\n',
        "\t// oldmac: netname is a map keyvalue, so its length is the mapper's choice\n"
        "\t// and cmd is a 64-byte stack buffer. FStringNull is the correct emptiness\n"
        "\t// test for a string_t; !pev->netname only catches offset zero.\n"
        "\tif( FStringNull( pev->netname ) )\n\t\treturn;\n\n"
        '\tsnprintf( cmd, sizeof( cmd ), "%s\\n", STRING( pev->netname ) );\n',
        "thegate: bound the command sprintf and fix the null test",
    ),
    (
        os.path.join("cl_dll", "TheGate", "scope.cpp"),
        "// oldmac: integer division",
        "\tfloat ratio = iWidth / iHeight;\n",
        "\t// oldmac: integer division, so ratio was only ever 0.0 or 1.0 and the\n"
        "\t// widescreen branch below never fired.\n"
        "\tfloat ratio = (float)iWidth / (float)iHeight;\n",
        "thegate: widescreen scope ratio",
    ),
]

# ---------------------------------------------------------------- #39 tot --
# UTIL_FindEntityByTargetname returns any CBaseEntity. Whatever it finds is stored
# into pTarget->m_pCine and every later virtual call through m_pCine dispatches
# through that vtable, so an entity of the wrong class is a wild virtual call.
FIXES["tot"] = [
    (
        os.path.join("dlls", "scripted.cpp"),
        "// oldmac: verify the class before trusting the downcast",
        '\t\t\t\tCCineMonster *pSeq = (CCineMonster*)UTIL_FindEntityByTargetname( NULL, "jan_osprey3" );\n',
        "\t\t\t\t// oldmac: verify the class before trusting the downcast.\n"
        "\t\t\t\t// UTIL_FindEntityByTargetname returns any CBaseEntity, and the result\n"
        "\t\t\t\t// is stored into m_pCine, through which every later virtual call\n"
        "\t\t\t\t// dispatches. The wrong class here is a wild virtual call.\n"
        '\t\t\t\tCBaseEntity *pFound = UTIL_FindEntityByTargetname( NULL, "jan_osprey3" );\n'
        "\t\t\t\tCCineMonster *pSeq = ( pFound && FClassnameIs( pFound->pev, \"scripted_sequence\" ) )\n"
        "\t\t\t\t                     ? (CCineMonster *)pFound : NULL;\n",
        "tot: guard the osprey downcast",
    ),
]

# --------------------------------------------------------------- #40 eftd --
# gpGlobals->frametime is ~0.016 at 60fps, so "frametime > next + 0.44" is false
# forever: the recoil decay never runs, and m_flBulletSpreadCoefficient is only
# ever incremented, so pistol accuracy degrades permanently after the first shot.
_EFTD_SPREAD_ASSIGN = (
    os.path.join("dlls", "player.cpp"),
    None,   # must NOT reuse the marker above: it is already in the file by now
    "m_flNextBulletSpreadRandTime = gpGlobals->frametime;",
    "m_flNextBulletSpreadRandTime = gpGlobals->time;",
    "eftd: recoil timer stamps wall time",
)
FIXES["eftd"] = [
    (
        os.path.join("dlls", "player.cpp"),
        "// oldmac: gpGlobals->time, not frametime",
        "\t\tif( gpGlobals->frametime > m_flNextBulletSpreadRandTime + 0.44f )\n",
        "\t\t// oldmac: gpGlobals->time, not frametime. frametime is ~0.016 at 60fps,\n"
        "\t\t// so this test was 0.016 > 0.456 and false forever: recoil recovery never\n"
        "\t\t// ran and pistol accuracy degraded permanently after the first shot.\n"
        "\t\tif( gpGlobals->time > m_flNextBulletSpreadRandTime + 0.44f )\n",
        "eftd: recoil recovery (ducking)",
    ),
    (
        os.path.join("dlls", "player.cpp"),
        None,   # covered by the marker above
        "\t\t\tif( gpGlobals->frametime > m_flNextBulletSpreadRandTime + 0.6f )\n",
        "\t\t\tif( gpGlobals->time > m_flNextBulletSpreadRandTime + 0.6f )\n",
        "eftd: recoil recovery (jumping)",
    ),
    (
        os.path.join("dlls", "player.cpp"),
        None,
        "\t\telse if( gpGlobals->frametime > m_flNextBulletSpreadRandTime + 0.47f )\n",
        "\t\telse if( gpGlobals->time > m_flNextBulletSpreadRandTime + 0.47f )\n",
        "eftd: recoil recovery (standing)",
    ),
    _EFTD_SPREAD_ASSIGN + ( 3, ),   # three identical assignments, varying indent
    # The recoil fix above is only half a fix without these. The spread state is
    # not in m_playerSaveData, so it resets to zero on every load: fixing the decay
    # timer while leaving the value unsaved means accuracy still jumps around a
    # save/restore, just differently.
    (
        os.path.join("dlls", "player.cpp"),
        "// oldmac: without these the recoil state resets on every load",
        "\t//DEFINE_FIELD( CBasePlayer, m_nCustomSprayFrames, FIELD_INTEGER ),"
        " // Don't need to restore\n",
        "\t//DEFINE_FIELD( CBasePlayer, m_nCustomSprayFrames, FIELD_INTEGER ),"
        " // Don't need to restore\n"
        "\t// oldmac: without these the recoil state resets on every load, so the\n"
        "\t// decay fixed above would still not survive a save/restore.\n"
        "\tDEFINE_FIELD( CBasePlayer, m_flBulletSpreadCoefficient, FIELD_FLOAT ),\n"
        "\tDEFINE_FIELD( CBasePlayer, m_flNextBulletSpreadRandTime, FIELD_TIME ),\n",
        "eftd: save the recoil spread state",
    ),
    (
        os.path.join("cl_dll", "ev_hldm.cpp"),
        "// oldmac: AngleVectors is (angles, forward, right, up)",
        "\t\t\tAngleVectors( angles, forward, up, right );\n",
        "\t\t\t// oldmac: AngleVectors is (angles, forward, right, up), so the smoke\n"
        "\t\t\t// puff velocity was using up where it wanted right.\n"
        "\t\t\tAngleVectors( angles, forward, right, up );\n",
        "eftd: AngleVectors argument order",
    ),
]


def apply_fix(tree, fix):
    relpath, marker, old, new, label = fix[:5]
    expect = fix[5] if len(fix) > 5 else 1

    path = os.path.join(tree, relpath)
    if not os.path.isfile(path):
        print("  %s: ERROR missing %s" % (label, relpath))
        return False

    f = io.open(path, "r", encoding="latin-1")
    src = f.read()
    f.close()

    if marker is not None and marker in src:
        print("  %s: already patched" % label)
        return True
    if marker is None and new in src and old not in src:
        print("  %s: already patched" % label)
        return True

    n = src.count(old)
    if n != expect:
        print("  %s: ERROR expected %d anchor(s) in %s, found %d"
              % (label, expect, relpath, n))
        return False

    f = io.open(path, "w", encoding="latin-1")
    f.write(src.replace(old, new))
    f.close()
    print("  %s: patched%s" % (label, "" if expect == 1 else " (%d sites)" % expect))
    return True


# --------------------------------------------------------- branch validation --
# "anchor not found is not nothing to do" applies one level up as well. A branch
# name this table does not know is indistinguishable here from a mod that has no
# audit fixes, and most mods have none, so the quiet exit 0 below is right for
# them and wrong for a typo. Same silent skip, whole mod instead of one fix:
# `dmcc` in place of `dmc` dropped all six #32 fixes and exited 0.
#
# installer/mods.map is the single source of truth for branch names (build-mod.sh
# reads column 2 of the same file in all_branches()), so it is what a name is
# checked against. See GitHub issue #39.
MODMAP = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      os.pardir, "installer", "mods.map")


def known_branches(path=MODMAP):
    """Column 2 of every mods.map row, or None if the file cannot be read.

    Mirrors all_branches() in build-mod.sh: skip lines whose first non-space
    character is '#', take field 2 of any line with at least three fields.
    """
    try:
        f = io.open(path, "r", encoding="latin-1")
    except (IOError, OSError):
        return None
    names = []
    try:
        for line in f:
            if line.lstrip().startswith("#"):
                continue
            cols = line.split()
            if len(cols) >= 3:
                names.append(cols[1])
    finally:
        f.close()
    return names


def one_edit_apart(a, b):
    """True if a and b differ by a single insertion, deletion or substitution.

    Deliberately NOT a prefix or substring test. Those would fire on a genuinely
    new branch whose name extends one that has fixes, and a false positive here
    aborts a build that is fine.
    """
    if a == b:
        return True
    if abs(len(a) - len(b)) > 1:
        return False
    if len(a) == len(b):
        return len([1 for i in range(len(a)) if a[i] != b[i]]) == 1
    short, long_ = (a, b) if len(a) < len(b) else (b, a)
    for i in range(len(long_)):
        if long_[:i] + long_[i + 1:] == short:
            return True
    return False


def check_branch_name(branch):
    """Called only for a branch with no fixes. Returns True if that is expected.

    A branch that mods.map lists and this table does not is the normal case, and
    stays quiet. A branch mods.map has never heard of, or one that is a single
    edit away from a branch that DOES have fixes, is a name that has gone wrong
    somewhere and must not pass for "nothing to do".
    """
    known = known_branches()
    if known is None:
        # Not fatal on purpose. `build-mod.sh <branch>` with an explicit name has
        # never needed mods.map, so failing here would abort builds that work
        # today over a file this script only consults for advice.
        print("== %s: WARNING cannot read %s, branch name not checked =="
              % (branch, MODMAP))
        return True

    withfixes = sorted(FIXES.keys())
    if branch not in known:
        print("ERROR: '%s' is not a branch in installer/mods.map." % branch)
        near = [k for k in withfixes if one_edit_apart(branch, k)]
        if not near:
            near = [k for k in sorted(known) if one_edit_apart(branch, k)]
        if near:
            print("       Did you mean: %s?" % ", ".join(near))
        print("       Refusing to report 'no audit fixes' for a name that is not a")
        print("       branch we build: that reads as success while every fix for the")
        print("       real branch is skipped. See GitHub issue #39.")
        return False

    near = [k for k in withfixes if one_edit_apart(branch, k)]
    if near:
        print("ERROR: '%s' has no fixes but is one edit from %s, which does."
              % (branch, ", ".join(near)))
        print("       That is what a renamed branch looks like from here: mods.map")
        print("       moved on and the FIXES key did not, so the fixes are dropped")
        print("       silently. Rename the key too, or if the two really are")
        print("       different mods, add the new one to FIXES with its own fixes.")
        return False

    return True


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    branch, tree = sys.argv[1], sys.argv[2]

    fixes = FIXES.get(branch)
    if not fixes:
        if not check_branch_name(branch):
            sys.exit(1)
        print("== %s: no audit fixes for this branch ==" % branch)
        sys.exit(0)

    print("== %s: %d audit fix(es) ==" % (branch, len(fixes)))
    ok = True
    for fix in fixes:
        ok = apply_fix(tree, fix) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
