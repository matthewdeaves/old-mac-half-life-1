#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
patch-net-local-address.py - stop the first LAN browser open from freezing the game.

THE SYMPTOM (issue #34)
-----------------------
On the G5 (10.5), open Deathmatch Classic and then the LAN game browser: the
whole app beachballs for 10 to 15 seconds, comes back on its own, and is fine
from then on. Only the first open in a process costs anything.

THE CAUSE (measured, not guessed)
---------------------------------
Opening the browser runs `localservers`, and CL_LocalServers_f calls
NET_Config( true, true ) before it broadcasts anything. The first time
NET_Config is asked for multiplayer it runs NET_DetermineLocalAddress(), which
answers "what is this machine's own address" the hard way: gethostname(), then
a BLOCKING getaddrinfo() of that name, on the main thread, inside the frame
loop. A `sample` of a real stall on the G5 caught 712 of 862 samples (14.2 s of
a 17 s window) in exactly one place:

    main -> Host_Main -> Cbuf_ExecStuffCmds -> Cmd_ExecuteStringWithPrivilegeCheck
         -> CL_LocalServers_f -> NET_Config -> NET_StringToAdrEx
         -> NET_StringToSockaddr -> getaddrinfo -> ds_getaddrinfo
         -> LI_DSLookupQuery -> mach_msg -> mach_msg_trap

The name being looked up is the machine's own DHCP-derived hostname
(`imacg5siMacG5.lan` on the bench G5). The LAN's DNS server does not reliably
answer for it, so the query burns the resolver's full budget, 3 tries times a
5 second timeout, and returns after 15.0 seconds. Timed directly on the G5 with
a purpose-built binary, cold cache: 15.02 to 15.05 s, for the A query or the
AAAA query, whichever one missed. Warm, the same call is 10 to 30 ms, which is
why the second open is free, and NET_Config's own `bFirst` guard means
NET_DetermineLocalAddress never runs a second time in that process anyway.

Nothing about this is PowerPC specific and nothing about it is DMC specific.
Any machine on a LAN whose DNS server ignores the DHCP hostname pays it, and a
G4 or a G3 pays it for at least as long as the G5 does, because the cost is a
network timeout rather than CPU work.

THE FIX
-------
Ask the kernel, not a name server. getifaddrs() lists this machine's own
addresses out of the routing tables with no packets and no blocking, and it is
present all the way back to the 10.3.9 SDK. So when NET_DetermineLocalAddress
is about to resolve our OWN hostname, which is the default configuration, take
the first non-loopback address of the wanted family from the interface list
instead. The port still comes from getsockname() on the bound socket exactly as
before, so `net_address` and the "Server IPv4 address ..." line are unchanged.

If the user pinned `ip` or `ip6` to something specific, that string is honoured
the old way: it is nearly always a literal, which NET_StringToSockaddr parses
without touching DNS, and if they typed a hostname there they asked for the
lookup. That is the only blocking resolve left in this path.

There is deliberately no DNS fallback when the interface list yields nothing.
An empty list means there is no interface of that family up at all, so a name
server could only give an answer that is not ours, and it would give it after
the same 15 second wait that this patch exists to remove.

For IPv6 a link-local fe80::/10 address is skipped: it means nothing to anyone
off this link, so it is not something to publish as the server's address.

Applies to both engine trees. Their NET_DetermineLocalAddress bodies differ in
a couple of declarations, but every anchor this script needs is identical in
both, and each anchor must appear exactly once or the script exits non-zero.

Idempotent. Python 2.5+.

Invoke:
    python patch-net-local-address.py <engine-tree> [<engine-tree> ...]
"""
import os
import sys

MARKER = "oldmac: our own address comes from the interface list, never from DNS"

# --- 1) headers for getifaddrs() and the interface flags ---------------------
INC_ANCHOR = """#if XASH_SDL == 2
#include <SDL_thread.h>
#endif
"""
INC_NEW = """#if XASH_SDL == 2
#include <SDL_thread.h>
#endif

#if XASH_APPLE
#include <ifaddrs.h> // getifaddrs, for NET_LocalAddress (oldmac)
#include <net/if.h>  // IFF_UP, IFF_LOOPBACK
#endif
"""

# --- 2) the two helpers, placed immediately before NET_DetermineLocalAddress -
HELPER_ANCHOR = """/*
================
NET_DetermineLocalAddress

Returns the servers' ip address as a string.
================
*/
static void NET_DetermineLocalAddress( void )
{
"""

HELPER_NEW = """#if XASH_APPLE
/*
=============
NET_LocalAddressFromInterfaces

The first address of this family that belongs to an interface which is up and
is not the loopback. Comes out of the routing tables, so it costs nothing and
cannot block, which is the entire point: see NET_LocalAddress below.

A link-local IPv6 address is skipped. It is not reachable from anywhere except
this one link, so it is not an address to publish as the server's.
=============
*/
static qboolean NET_LocalAddressFromInterfaces( int family, struct sockaddr_storage *out )
{
\tstruct ifaddrs *list = NULL, *cur;
\tqboolean found = false;

\tif( getifaddrs( &list ) != 0 )
\t\treturn false;

\tmemset( out, 0, sizeof( *out ));

\tfor( cur = list; cur != NULL; cur = cur->ifa_next )
\t{
\t\tif( !cur->ifa_addr || cur->ifa_addr->sa_family != family )
\t\t\tcontinue;

\t\tif( !FBitSet( cur->ifa_flags, IFF_UP ) || FBitSet( cur->ifa_flags, IFF_LOOPBACK ))
\t\t\tcontinue;

\t\tif( family == AF_INET6 )
\t\t{
\t\t\tconst struct sockaddr_in6 *sa6 = (const struct sockaddr_in6 *)cur->ifa_addr;

\t\t\tif( IN6_IS_ADDR_LINKLOCAL( &sa6->sin6_addr ) || IN6_IS_ADDR_UNSPECIFIED( &sa6->sin6_addr ))
\t\t\t\tcontinue;

\t\t\tmemcpy( out, sa6, sizeof( struct sockaddr_in6 ));
\t\t}
\t\telse
\t\t{
\t\t\tmemcpy( out, cur->ifa_addr, sizeof( struct sockaddr_in ));
\t\t}

\t\tfound = true;
\t\tbreak;
\t}

\tfreeifaddrs( list );

\treturn found;
}
#endif // XASH_APPLE

/*
=============
NET_LocalAddress

""" + MARKER + """.

NET_DetermineLocalAddress runs on the frame loop, once, the first time the
engine is put into multiplayer, which for a player is the moment the LAN game
browser opens. Upstream answers "which address am I" by resolving our own
hostname with a blocking getaddrinfo(). On a LAN whose DNS server does not
answer for the DHCP hostname that call takes the resolver's whole budget, 3
tries times 5 seconds, and the game is frozen for all 15 of them: measured on
the bench G5, and caught in a stack sample sitting in ds_getaddrinfo. See
issue #34.

So when the name we are about to look up is our own hostname, which is the
default configuration, read the address out of the interface list instead. A
string the user pinned into `ip` or `ip6` still goes the old way: it is almost
always a literal, which is parsed with no lookup at all, and a hostname there
was asked for explicitly.
=============
*/
static qboolean NET_LocalAddress( const char *string, const char *hostname, netadr_t *adr, int family )
{
#if XASH_APPLE
\tstruct sockaddr_storage s;

\tif( !Q_strcmp( string, hostname ))
\t{
\t\tmemset( adr, 0, sizeof( *adr ));

\t\tif( !NET_LocalAddressFromInterfaces( family, &s ))
\t\t\treturn false;

\t\tNET_SockadrToNetadr( &s, adr );
\t\treturn true;
\t}
#endif // XASH_APPLE

\treturn NET_StringToAdrEx( string, adr, family );
}

""" + HELPER_ANCHOR

# --- 3) route both families' lookups through it ------------------------------
CALL4_ANCHOR = "\t\tif( NET_StringToAdrEx( buff, &net_local, AF_INET ))\n"
CALL4_NEW = "\t\tif( NET_LocalAddress( buff, hostname, &net_local, AF_INET ))\n"

CALL6_ANCHOR = "\t\tif( NET_StringToAdrEx( buff, &net6_local, AF_INET6 ))\n"
CALL6_NEW = "\t\tif( NET_LocalAddress( buff, hostname, &net6_local, AF_INET6 ))\n"

EDITS = [
    (INC_ANCHOR, INC_NEW, "ifaddrs.h include"),
    (HELPER_ANCHOR, HELPER_NEW, "NET_LocalAddress helpers"),
    (CALL4_ANCHOR, CALL4_NEW, "IPv4 lookup"),
    (CALL6_ANCHOR, CALL6_NEW, "IPv6 lookup"),
]


def patch(path):
    f = open(path, "r")
    src = f.read()
    f.close()

    if MARKER in src:
        print("  already patched: %s" % path)
        return True

    for anchor, unused, what in EDITS:
        n = src.count(anchor)
        if n != 1:
            print("  ERROR: anchor for '%s' matched %d times (want 1)" % (what, n))
            return False

    for anchor, new, what in EDITS:
        src = src.replace(anchor, new, 1)
        print("  applied: %s" % what)

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
        path = tree
        if os.path.isdir(tree):
            path = os.path.join(tree, "engine", "common", "net_ws.c")
        print("== %s ==" % path)
        if not os.path.isfile(path):
            print("  ERROR: not found")
            ok = False
            continue
        ok = patch(path) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
