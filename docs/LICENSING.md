# Licensing

This project is **GPL-3.0-or-later**; the full text is in [`LICENSE`](../LICENSE).

It combines code under several different sets of terms, and one of them is not an
open-source licence at all. If you are reusing part of this, read the section that
covers that part rather than assuming the top-level licence governs everything in
the shipped disk image.

**This is a reasoned reading, not legal advice.** The one genuine grey area is
named as such at the end.

## Why GPL-3.0-or-later, and why there was no real alternative

The engine is **Xash3D FWGS**, and its sources carry the GPLv3-or-later header:

```
This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
```

Our engine and menu changes are commits on forks of those GPLv3-or-later works, so
they are GPLv3 themselves. Most of what this repository holds is our own work: the
build drivers, the `scripts/patch-*.py` scripts, the mod installer app, the System
Report app, the tests and the documentation, and we could licence that however we
liked. Splitting the repository so that only some of it was GPLv3 would be
technically possible and practically useless, so the whole thing is GPLv3 and the
boundary problem goes away.

There is a second reason. The disk images already distributed contain a GPLv3
engine, so their recipients hold a right to the corresponding source under section
6 regardless of what this file says. Publishing under GPLv3 discharges that
obligation rather than leaving it outstanding.

## Component by component

| Component | Terms | Where it lives |
|---|---|---|
| Everything written for this project | **GPL-3.0-or-later** | this repository |
| Xash3D FWGS engine | GPL-3.0-or-later | `vendor/`, not redistributed here |
| `mainui_cpp` menu | GPL-3.0-or-later | `vendor/`, not redistributed here |
| `hlsdk-portable` game code | **Valve Half-Life 1 SDK licence** | `vendor/`, not redistributed here |
| mbed TLS 3.6 | Apache-2.0 or GPL-2.0-or-later (dual) | `vendor/mbedtls-installer` |
| zlib | zlib licence | `vendor/zlib-installer` |
| 7-Zip LZMA/7z decoder | LGPL-2.1-or-later | `vendor/lzma-installer` |
| SDL2 / `panther-sdl2` | zlib licence | `vendor/`, linked into the engine |
| Mozilla CA root list | MPL-2.0 | `installer/ca-roots.pem` |

Compatibility, briefly: Apache-2.0 can be combined into a GPLv3 work (one way only,
Apache-2.0 into GPLv3, not the reverse), and the zlib licence, MPL-2.0 and
LGPL-2.1-or-later are all compatible with GPLv3. None of them constrain the result.

**No upstream source is redistributed in this repository.** `vendor/` is
git-ignored; `scripts/fetch-sources.sh` clones each tree at the pinned commit in
`scripts/build-pins.sh`, and our changes to the engine, menu and game code are
commits on our own forks of those upstreams. See `docs/adr/0002`.

## The game dylibs are not GPL, and this matters

The per-mod game code in the disk image, `dlls/<mod>.dylib` and
`cl_dlls/client.dylib`, is built from `hlsdk-portable`, which is under **Valve's
Half-Life 1 SDK licence** whoever forks it. That is a permission grant, not an
open-source licence. Its binding term here:

> You may, free of charge, download and use the SDK to develop a modified Valve
> game running on the Half-Life 1 engine. You may distribute your modified Valve
> game in source and object code form, **but only for free.**

So those dylibs are not covered by this repository's GPLv3, may not be sold, and
carry Valve's terms with them wherever they go. Nothing here relicenses them and
nothing here may be read as trying to.

Everything else the project distributes is either GPLv3 (the engine, the menu, our
own code) or permissively licensed (SDL2, zlib, mbed TLS, the LZMA decoder).

## We ship no content, and that is a licence position as much as a design one

No maps, models, sounds, sprites or `.wad` files by Valve or by any mod author are
in this repository or in any disk image it produces. The player supplies their own
retail `valve/`, and the mod installer fetches each mod's content from that mod's
own public download at install time. So the only mod-author material this project
touches is the mod's own `liblist.gam`, which the installer edits in place on the
user's disk. See `docs/adr/0006`.

## The grey area, stated rather than avoided

The GPLv3 engine loads the Valve-SDK-licensed game dylibs at runtime through
`dlopen`, across a stable ABI that Valve defined in 1998. Whether that makes a
single combined work, which would put the two licences in conflict, or two separate
works communicating at arm's length, which would not, is a question the GoldSrc and
Quake-engine world has never settled.

The position taken here is the same one upstream Xash3D FWGS takes, and the same
one every GoldSrc engine reimplementation takes: the game library is a plugin
against a pre-existing interface, not a derivative of the engine. If that reading is
wrong then it is wrong for the entire ecosystem and not just for this project. It is
written down so that nobody has to rediscover the question.

## Credit

Attribution is recorded in [`../README.md`](../README.md), including the upstream
projects and the authors of the mods the installer fetches. Attribution is a
statement of fact about where code came from and is kept accurate independently of
what any licence requires.
