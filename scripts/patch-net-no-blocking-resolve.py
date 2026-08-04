#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
patch-net-no-blocking-resolve.py - no hostname is ever resolved on the frame loop.

THE SYMPTOM (issue #29, and the tail of #34)
--------------------------------------------
On the G4 (10.4.11), open Multiplayer, then Internet Game, then the "Add
server" box, and type. Nothing appears. Fifteen to twenty seconds later every
character arrives at once, in order. Nothing was ever dropped: the engine was
not running frames, so SDL was not draining the OS event queue, and the
keystrokes sat in it until the frame loop came back. The same stall makes a
Cmd-Q register long after it was pressed.

The shape of the symptom is the evidence for the cause: delayed and in order,
with nothing lost, is a frame-loop stall. A broken text-input client drops
characters, it does not queue them.

UNRESOLVED, and recorded rather than argued away. An earlier revision of this
docstring said the stall "is why Multiplayer > Customize, which touches no
networking at all, was always fine". scripts/patch-panther-sdl-textinput.py
says the opposite, that the Multiplayer name field accepts nothing on 10.3.9
and 10.4.11, and Multiplayer.cpp maps Customize to UI_PlayerSetup_Menu, whose
CMenuField name IS that field. Both claims cannot hold. Neither has been
re-measured since, so the sentence is withdrawn from here rather than restated.

THE CAUSE
---------
A blocking getaddrinfo() on the main thread. On a LAN whose name server does
not answer for the name being asked about, one lookup costs the resolver's
whole budget, 3 tries times a 5 second timeout, measured at 15.02 to 15.05 s
cold on the bench G5 and 8 to 30 ms once the OS has cached the answer.

net_ws.c has both an async resolver, NET_StringToAdrNB, which hands the name to
a worker thread and returns NET_EAI_AGAIN until the answer is ready, and a
blocking one, NET_StringToAdr / NET_StringToAdrEx, which is NET_StringToSockaddr
with nonblocking = false. Everything below is a use of the blocking one from
code the frame loop can reach.

scripts/patch-net-local-address.py already removed the biggest of them,
NET_DetermineLocalAddress inside NET_Config, which is what both the LAN browser
and the Internet browser hit on their first open. This script removes the rest.

WHAT THIS SCRIPT CHANGES
------------------------
1. CL_SendConnectPacket (engine/client/cl_main.c) resolves cls.servername with
   the blocking call, on the frame, every time a challenge comes back. It is
   reached from CL_ConnectionlessPacket, so it runs inside Host_Main. It does
   not need to resolve at all: CL_CheckForResend resolved that same name a
   moment earlier and stored the answer in cls.serveradr on the line before it
   sent the getchallenge this is the reply to. So a new
   CL_ServerAddressIsResolved helper reads cls.serveradr back, and the error
   path is byte for byte the one upstream had.

   Rev 1 of this script asked NET_StringToAdrNB here instead, and that was
   wrong. The async resolver has a SINGLE result slot which is consumed on read,
   CL_CheckForResend has already taken it, so the second ask always returns
   NET_EAI_AGAIN, drops the challenge and retries until CL_CONNECTION_RETRIES
   disconnects the client. Every connect by hostname bounced straight back to
   the main menu. Verified against the real state machine before the rewrite;
   see MARKER_REV below for how a tree still holding rev 1 is detected.

   An earlier draft said this was "also the reported symptom of issue #38".
   Withdrawn: #38 is a join selected from the LAN browser, which hands over an
   IP literal, and NET_StringToSockaddr takes the numeric fast path before it
   ever looks at the resolver. Rev 1 cannot fire on that path. The symptoms look
   alike and the mechanisms are unrelated.

2. CL_QueryServer_f (engine/client/cl_main.c), the "ui_queryserver" command,
   resolves whatever string the menu hands it, blocking. The menu hands it one
   per entry, in a loop, every time the Favorites or History tab is refreshed:
   see CMenuServerBrowser::QueryServerList and favlist_entry_t::QueryServer in
   3rdparty/mainui. Entries added through the "Add server" box can be hostnames.
   Uses NET_StringToAdrNB; on NET_EAI_AGAIN the query is dropped silently and the
   browser re-issues it on the next refresh.

   Be precise about what this does NOT achieve, because an earlier draft
   overclaimed it. It does not stop a browser holding unresolvable hostname
   favourites from freezing. QueryServerList calls the BLOCKING NetAPI entry on
   every entry, in the same loop, before it issues any ui_queryserver:
   ServerBrowser.cpp:892 calls pNetAPI->StringToAdr, which cl_game.c binds to
   NET_StringToAdr, and on a failure it `continue`s, so CL_QueryServer_f never
   runs for that entry at all.
   The frame still blocks once per hostname favourite, in the menu. What this
   edit does remove is the blocking resolve for entries the menu DID resolve,
   and it stops ui_queryserver being a second blocking call on the frame loop.
   Fixing the menu side means changing 3rdparty/mainui, which is a separate job.

   Also note the worker has a single slot, so with two hostname favourites each
   refresh's second ask evicts the first's pending answer and the second entry
   can be starved indefinitely. Upstream's blocking resolve queried both.

3. NET_MasterShutdown (engine/common/masterlist.c). Be clear about scope: this
   one does NOT fix the reported fault in #29. NET_MasterShutdown has exactly one
   caller, inside SV_Shutdown, so it is never on the menu frame path and cannot
   contribute to the Add Server box swallowing keystrokes. It is here because it
   is the same bug in the same file family, and it fixes a real but different
   stall: the delayed quit when shutting down a listen server. If you are
   bisecting #29, this half is not the one that matters.

   It does use the async resolver, through NET_GetMasterHostByName, and then
   throws the benefit away:

       while( NET_SendToMasters( NS_SERVER, 2, S2M_SHUTDOWN, PROTO_CURRENT ));

   NET_SendToMasters returns true while any master is still resolving, so that
   is a tight spin on the main thread until every master name has an answer or
   has failed, one name at a time, because the worker resolves one at a time.
   How long that lasts is a property of the installation, not of the code:
   NET_InitMasters registers no master ADDRESS of its own, only an HTTP base
   URL, so ml.head is filled by NET_LoadMasters from xashcomm.lst and by the
   `addmaster` command. A fresh install with an empty list never spins at all;
   one with N unreachable master names spins for N consecutive resolver
   timeouts. Replaced with a single pass that sends the shutdown notice to the
   masters whose address is already known and skips the rest. Nothing is lost: the only masters worth telling are the ones this
   server announced itself to, and announcing is what put the address in the
   cache in the first place. The packet is best effort anyway, as the comment
   above the function says.

WHAT THIS SCRIPT DELIBERATELY DOES NOT CHANGE
---------------------------------------------
NET_StringToAdr itself stays blocking, and so does the pfnStringToAdr entry in
the net_api_t table the client dll is handed. A mod calling it expects an
answer, not a maybe, and changing that would break code we do not build.

CMenuServerBrowser::AddServer in 3rdparty/mainui calls that NetAPI entry to
validate what was typed into the "Add server" box, so pressing OK on a hostname
still blocks once. That is a deliberate act with a message box for a result
rather than something the frame loop does on its own, and removing it means
adding a row to the list for an address the menu cannot yet display. Named here
so it is not mistaken for an oversight.

NET_IPSocket resolves the `ip` and `ip6` cvars, but both default to "localhost"
and are short-circuited before the lookup, so the default configuration never
gets there. cl_steam.c resolves cl_steam_broker_addr, which defaults to the
literal 127.0.0.1:27420. sv_log.c and sv_client.c resolve operator-supplied
addresses from console commands. gethostbyname appears only in
engine/platform/ios, which is gated on bld.env.IOS. getaddrinfo appears in
3rdparty/opusfile/opusfile/src/http.c, which that subproject's wscript does not
compile, and in 3rdparty/mbedtls/mbedtls/library/net_sockets.c, which IS compiled
on Intel under -DXASH_MBEDTLS but is only reached by an outbound TLS connection
rather than by the frame loop. An earlier draft also named a NET_StringToAdr in
cl_parse.c's HLTV_LISTEN case as being inside an `#if 1 ... #else`; there is no
such call and the claim is withdrawn.

Applies to every engine tree. The anchor for the connect-packet edit is the
resolve call itself rather than the `if` around it. Every anchor must appear
exactly once in each file or the script exits non-zero.

Idempotent. Python 2.5+.

Invoke:
    python patch-net-no-blocking-resolve.py <engine-tree> [<engine-tree> ...]
"""
import os
import sys

MARKER = "oldmac: no hostname is resolved on the frame loop"

# The guard has to distinguish "this fix is applied" from "SOME revision of this
# fix is applied", or it cannot correct a tree carrying a superseded body. That
# is issue #39, and rev 1 of this script is exactly the case: it shipped a
# CL_SendConnectPacket that resolved a second time and livelocked the connect
# retry loop. A tree holding rev 1 must be told, not silently accepted.
#
# So: MARKER_REV goes in the emitted comments and is what "already patched"
# tests. Bare MARKER without MARKER_REV means a superseded revision, which is an
# error rather than a skip. Bump the revision whenever the emitted C changes.
MARKER_REV = MARKER + " (rev 2)"


# =============================================================== cl_main.c ===

# --- 1) the helper, placed immediately before CL_SendConnectPacket -----------
# Anchored on the whole banner so the helper lands above it rather than between
# the banner and the function it describes.
CONNECT_HELPER_ANCHOR = """/*
=======================
CL_SendConnectPacket

We have gotten a challenge from the server, so try and
connect.
======================
*/
static void CL_SendConnectPacket( connprotocol_t proto, int challenge )
{
"""

CONNECT_HELPER_NEW = """/*
=================
CL_ServerAddressIsResolved

""" + MARKER_REV + """.

CL_SendConnectPacket runs on the frame loop, from CL_ConnectionlessPacket, and
upstream resolves cls.servername there with the blocking NET_StringToAdr. A name
the LAN's DNS server will not answer for costs the resolver's full budget, 3
tries times 5 seconds, and the engine draws nothing and reads no input for all
of it. See issue #29.

It does not need to resolve at all. The address is already known by the time we
get here, because the only way to get here is a challenge arriving in reply to
a getchallenge, and CL_CheckForResend resolved the name and stored the answer in
cls.serveradr before it sent that getchallenge, a few lines up in the same
function. The other callers are covered too: the bandwidth-test completion paths
run after CL_CheckForResend has stored it, and the local listen server branch
sets cls.serveradr to NA_LOOPBACK immediately before calling here. So read
cls.serveradr back.

Asking the async resolver a second time is what rev 1 of this patch did, and it
does not work: NET_StringToAdrNB has a SINGLE result slot which is CONSUMED on
read (net_ws.c clears nsthread.hostname on a hit). CL_CheckForResend has already
taken the answer, so the second ask finds the slot empty, re-dispatches the
worker and returns NET_EAI_AGAIN. That drops the challenge, CL_CheckForResend
sends another getchallenge, and the cycle repeats until connect_retry reaches
CL_CONNECTION_RETRIES and the client disconnects. It is not intermittent: the
async path returns AGAIN on a first ask however warm the OS cache is, because it
must hand off to the thread. The visible result was an instant bounce back to
the main menu on any connect by HOSTNAME. That is not issue #38: #38 joins from
the LAN browser, which hands over an IP literal, and NET_StringToSockaddr takes
its numeric fast path before the resolver is reached, so rev 1 could not fire
there. An earlier version of this comment claimed the link and it was wrong.

NA_UNDEFINED is the zero value of netadrtype_t, so an address nobody ever
resolved fails the test and takes the same error path upstream took.

WHAT ACTUALLY MAKES THIS SAFE, because the test above does not do it alone.
Read literally, NET_NetadrType( adr ) != NA_UNDEFINED asks "has anything been
resolved since the last CL_Disconnect", not "was it resolved for THIS request".
Every current caller is covered, but by something outside this helper:

  - the two CL_Challenge sites are behind CL_IsFromConnectingServer( from ),
    which is NET_IsLocalAddress( from ) || NET_CompareAdr( cls.serveradr, from ).
    A challenge from anywhere other than the address in cls.serveradr is dropped
    before it can get here, and a zeroed cls.serveradr matches nothing because
    NET_CompareAdr returns false as soon as the two types differ.
  - the two CL_CheckForResend sites write cls.serveradr on the immediately
    preceding lines, unconditionally.

So it is sound because all four sites happen to be guarded, not because the
predicate is self-sufficient. ANYONE ADDING A FIFTH CALL SITE must check that
cls.serveradr belongs to the server they are answering; this helper will not
tell them.
=================
*/
static qboolean CL_ServerAddressIsResolved( netadr_t *adr )
{
\t*adr = cls.serveradr;

\treturn NET_NetadrType( adr ) != NA_UNDEFINED;
}

""" + CONNECT_HELPER_ANCHOR

# --- 2) route CL_SendConnectPacket through it -------------------------------
# The anchor starts at the call, not at the `if( !` in front of it, so the
# replacement has to stay an expression that reads correctly in that position.
CONNECT_CALL_ANCHOR = """NET_StringToAdr( cls.servername, &adr ))
\t{
\t\tCon_Printf( "%s: bad server address\\n", __func__ );
\t\tcls.connect_time = 0;
\t\treturn;
\t}
"""

CONNECT_CALL_NEW = """CL_ServerAddressIsResolved( &adr )) // """ + MARKER_REV + """
\t{
\t\tCon_Printf( "%s: bad server address\\n", __func__ );
\t\tcls.connect_time = 0;
\t\treturn;
\t}
"""

# --- 3) ui_queryserver ------------------------------------------------------
QUERY_ANCHOR = """\tif( !NET_StringToAdr( Cmd_Argv( 1 ), &adr ))
\t{
\t\tCon_Printf( S_ERROR "%s: can't parse %s", __func__, Cmd_Argv( 1 ));
\t\treturn;
\t}
"""

QUERY_NEW = """\t// """ + MARKER + """. The menu issues one
\t// ui_queryserver per favourite or history entry, in a loop, and those
\t// entries can be hostnames because the "Add server" box accepts one. Each
\t// blocking resolve froze the whole engine for a resolver timeout. On
\t// NET_EAI_AGAIN say nothing and drop the query: the browser re-issues it on
\t// its next refresh, by which time the worker thread has an answer. See #29.
\tswitch( NET_StringToAdrNB( Cmd_Argv( 1 ), &adr, false ))
\t{
\tcase NET_EAI_OK:
\t\tbreak;
\tcase NET_EAI_AGAIN:
\t\treturn;
\tdefault:
\t\tCon_Printf( S_ERROR "%s: can't parse %s", __func__, Cmd_Argv( 1 ));
\t\treturn;
\t}
"""

CL_MAIN_EDITS = [
    (CONNECT_HELPER_ANCHOR, CONNECT_HELPER_NEW, "CL_ServerAddressIsResolved helper"),
    (CONNECT_CALL_ANCHOR, CONNECT_CALL_NEW, "CL_SendConnectPacket resolve"),
    (QUERY_ANCHOR, QUERY_NEW, "ui_queryserver resolve"),
]


# ============================================================ masterlist.c ===

SHUTDOWN_ANCHOR = """void NET_MasterShutdown( void )
{
\tNET_Config( true, false ); // allow remote
\twhile( NET_SendToMasters( NS_SERVER, 2, S2M_SHUTDOWN, PROTO_CURRENT ));
\tNET_ClearSendState();
}
"""

SHUTDOWN_NEW = """void NET_MasterShutdown( void )
{
\tmaster_t *m;

\tNET_Config( true, false ); // allow remote

\t// """ + MARKER + """. Upstream spins here:
\t// NET_SendToMasters returns true while any master name is still with the
\t// resolver thread, so the loop holds the main thread until every master in
\t// the list has resolved or timed out, one at a time. Quitting a listen
\t// server with no route to them cost one resolver timeout per master name,
\t// which is why a Cmd-Q could register long after it was pressed. See #29.
\t//
\t// One pass, to the masters whose address we already have. That is exactly
\t// the set worth telling, because announcing to a master is what put its
\t// address in m->adr, and the notice is best effort in any case.
\tfor( m = ml.head; m; m = m->next )
\t{
\t\tif( m->gs ) // GoldSrc masters take no shutdown notice
\t\t\tcontinue;

\t\tif( !m->adr.type ) // never resolved, so never announced to
\t\t\tcontinue;

\t\tNET_SendPacket( NS_SERVER, 2, S2M_SHUTDOWN, m->adr );
\t}

\tNET_ClearSendState();
}
"""

MASTERLIST_EDITS = [
    (SHUTDOWN_ANCHOR, SHUTDOWN_NEW, "NET_MasterShutdown spin"),
]


# Per file: relative path, its edits, and the marker that proves THIS revision
# of that file's C is present.
#
# The revision is per file, not global, and that distinction matters. Only
# cl_main.c's generated code changed between rev 1 and rev 2; masterlist.c's is
# byte identical apart from a comment. A single script-wide revision counter
# would declare masterlist.c superseded and send the operator off to reset a
# tree over a fix that never changed. So masterlist.c keeps the bare marker.
FILES = [
    (os.path.join("engine", "client", "cl_main.c"), CL_MAIN_EDITS, MARKER_REV),
    (os.path.join("engine", "common", "masterlist.c"), MASTERLIST_EDITS, MARKER),
]


def inspect(path, edits, done_marker):
    """Decide what to do with one file WITHOUT touching it.

    Returns (verdict, payload). Verdict is one of:
      'done'       already carries this revision, payload is None
      'apply'      payload is the new file contents, ready to write
      'superseded' payload is a list of message lines
      'anchor'     payload is a list of message lines

    Separating the decision from the write is the point. patch() used to write
    each file as it finished it, so a tree where cl_main.c was clean and
    masterlist.c held rev 1 got cl_main.c rewritten and THEN failed, leaving a
    tree that no re-run could ever complete: cl_main.c says "already patched"
    forever and masterlist.c errors forever. That is a worse state than the one
    the check exists to catch, and it is reachable exactly when the two files
    disagree, which is the divergence issue #39 is about.
    """
    f = open(path, "r")
    src = f.read()
    f.close()

    if done_marker in src:
        return ("done", None)

    # A bare MARKER without this file's revision means the file holds a
    # SUPERSEDED body of this same fix. The anchors it needs are gone, consumed
    # by that older edit, so re-running cannot correct it. Issue #39.
    if MARKER in src:
        return ("superseded", [
            "  ERROR: %s holds a SUPERSEDED revision of this fix." % path,
            "         Wanted: %s" % done_marker,
            "         Re-running cannot repair this: the older edit already ate",
            "         the anchors. Reset the tree and let the driver patch again:",
            "             scripts/reset-vendor-trees.sh",
            "         If that tree is not a git clone, it cannot be reset at all;",
            "         replace it with one first. See vendor/MANIFEST.md and #39.",
        ])

    for anchor, unused, what in edits:
        n = src.count(anchor)
        if n != 1:
            return ("anchor", [
                "  ERROR: anchor for '%s' matched %d times (want 1) in %s"
                % (what, n, path),
            ])

    for anchor, new, what in edits:
        src = src.replace(anchor, new, 1)

    return ("apply", src)


def patch_tree(tree):
    """Inspect every file first, then write, or write nothing at all."""
    plan = []
    problems = []

    for rel, edits, done_marker in FILES:
        path = os.path.join(tree, rel)
        if not os.path.isfile(path):
            problems.append("  ERROR: not found: %s" % path)
            continue
        verdict, payload = inspect(path, edits, done_marker)
        if verdict == "done":
            print("  already patched: %s" % path)
        elif verdict == "apply":
            plan.append((path, payload, edits))
        else:
            problems.extend(payload)

    if problems:
        for line in problems:
            print(line)
        if plan:
            print("  Nothing was written. %d file(s) would have been changed and"
                  % len(plan))
            print("  were left alone, so the tree is still in one consistent state.")
        return False

    for path, src, edits in plan:
        f = open(path, "w")
        f.write(src)
        f.close()
        for unused_anchor, unused_new, what in edits:
            print("  applied: %s" % what)
        print("  patched: %s" % path)

    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)

    ok = True
    for tree in sys.argv[1:]:
        print("== %s ==" % tree)
        if not os.path.isdir(tree):
            print("  ERROR: not an engine tree directory")
            ok = False
            continue
        ok = patch_tree(tree) and ok

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
