#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Show the main-menu "Console" button without developer mode.
#
# mainui gates the on-screen Console button on developer mode:
#   console.SetVisibility( gpGlobals->developer );   (menus/Main.cpp)
# To surface the button on every machine the launcher used to run the engine with
# -dev 1 (developer=1), whose side effect is developer messages echoed to the on-screen
# notify area during play (previously worked around with con_notifytime 0).
#
# Make the button always visible instead, so the launcher can pass plain -console
# (host.allow_console -> ~ overlay + a working Console button) with developer=0: no
# notify spam, no verbose logging, no con_notifytime workaround. Idempotent. Python 2.5+.
import sys

MARKER = 'oldmac: Console button always shown'
ANCHOR = 'console.SetVisibility( gpGlobals->developer );'
NEW = 'console.SetVisibility( true ); // ' + MARKER + ' (launcher passes -console; no -dev 1)'

for f in sys.argv[1:]:
    s = open(f).read()
    if MARKER in s:
        print('already patched:', f)
        continue
    assert ANCHOR in s, ('anchor not found in ' + f)
    s = s.replace(ANCHOR, NEW, 1)
    open(f, 'w').write(s)
    print('patched:', f)
