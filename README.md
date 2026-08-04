# Half-Life on old Macs

Half-Life 1 on PowerPC and Intel Macs, from one universal `Half-Life.app`, using
the open-source [Xash3D FWGS](https://github.com/FWGS/xash3d-fwgs) engine in
place of the retail GoldSrc one. It runs on a G3 from 2003 through a modern
Intel Mac, picks the right code and display settings for whatever machine it
finds itself on, and plays 25 Half-Life mods as well as the base game. This repo
holds the porting glue, not the game: no Valve assets, no upstream source.

**Mac OS X and macOS only, 10.3.9 up. Not Mac OS 9 / Classic**, at least not yet
([#23](https://github.com/matthewdeaves/old-mac-halflife/issues/23)). For Classic,
[removed]
[removed]

![Anatomy of the fat binary: three source trees build into three CPU slices that lipo fuses into one Half-Life.app](docs/img/fat-binary.svg)

## Download

Grab the latest `.dmg` from the
[**Releases page**](https://github.com/matthewdeaves/old-mac-halflife/releases/latest),
copy `Half-Life.app` out of it into any folder, and drop your own retail `valve/`
folder in beside it. That is the whole install.

**Which Macs it runs on.** Every PowerPC Mac from Mac OS X 10.3.9 up, and every
64-bit Intel Mac from Mac OS X 10.7 up.

Proven on the hardware below:

| CPU | macOS | Slice |
|---|---|---|
| G3 (PowerPC 750) | 10.3.9, 10.4 | `ppc750` |
| G4 (PowerPC 7400 / 7450) | 10.4 | `ppc7400` |
| G5 (PowerPC 970) | 10.5 | `ppc7400` |
| Intel, 64-bit | 10.7 | `x86_64` |
| Apple Silicon | macOS 26 | `x86_64` under Rosetta 2 |

**Untested**, only because I have no machine set up that way. A report either way
is useful:

| CPU | macOS | What should happen |
|---|---|---|
| G5 | 10.3, 10.4 | the same `ppc7400` slice a G4 takes ([#14](https://github.com/matthewdeaves/old-mac-halflife/issues/14)) |
| G4 | 10.3.9 | its own `ppc7400` slice, which needs nothing 10.3 lacks |
| G3 | 10.5 | `ppc750`, which targets 10.3 |
| any PowerPC | 10.6 PPC builds | graded by subtype; every target is older than 10.6 |

`dyld` picks a slice by CPU capability alone and never looks at the OS, so a slice
is only added where the instruction set differs: the G3's 750 has no AltiVec unit
and the G4 and G5 both do. The G5 had its own `ppc970` slice until v1.4.0; it was
measured 6% slower on the G5 than the G4's, and dropping it is what lets a G5 run
10.3 and 10.4. See
[the decision record](docs/adr/0001-slices-are-chosen-by-cpu-capability.md).

Three cases are known not to work, from reading the binary rather than from
testing. **Intel on 10.6** gets nothing: the `x86_64` slice links `libc++`, which
shipped with 10.7, and carries `LC_VERSION_MIN 10.7`
([#16](https://github.com/matthewdeaves/old-mac-halflife/issues/16)). There is no
i386 slice yet, so **32-bit-only Intel Macs** (Core Solo / Core Duo) are out for
now ([#22](https://github.com/matthewdeaves/old-mac-halflife/issues/22)), and no
native arm64 one yet either
([#2](https://github.com/matthewdeaves/old-mac-halflife/issues/2)). Each PowerPC
slice carries its exact CPU subtype, because Tiger and Leopard mis-grade a fat
that mixes generic and specific PowerPC slices and refuse to launch it at all.

### If it does not launch

Run **Half-Life System Report.app**, also on the disk image. It says what your Mac
is and which slice it would load, and copies that to the clipboard in one press to
paste into an
[issue](https://github.com/matthewdeaves/old-mac-halflife/issues). It reads only
and sends nothing.

It deliberately reaches lower than the game, because the machines worth hearing
about are the ones the game will not start on. It carries three slices: PowerPC
from 10.3, 32-bit Intel from 10.4 and 64-bit Intel from 10.5, against the game's
10.3.9 and 10.7. So it still runs on a Core Solo or Core Duo, and on 64-bit Intel
under 10.6, which are the two cases the game has no slice for
([#24](https://github.com/matthewdeaves/old-mac-halflife/issues/24)). It can do
that because it is plain Objective-C against Cocoa: the game's Intel floor comes
from the menu needing libc++, and this has no C++ in it at all. On an Apple
Silicon Mac it reports the machine as arm64 under Rosetta 2 rather than as Intel.

### No game content here, only the engine

This ships no Valve content. You supply your own retail `valve/` folder and drop
it in exactly as it came off your copy: everything this project builds stays
inside `Half-Life.app`, so there is no merge step and nothing to overwrite. Saves
and settings are written to your folder as you play, so a newer build can be
swapped in without losing anything.

Tested against the retail **Game of the Year** `valve/`; a Steam install's works
the same way. It needs at least `liblist.gam`, `pak0.pak`, the `.wad` files, and
the `maps/ models/ sound/ sprites/ gfx/` directories.

## How it runs on each machine

![Per-machine matrix: CPU, macOS, slice, byte order, SDL2, renderer and window mode for G3, G4, G5 and Intel](docs/img/per-machine.svg)

Every machine renders with **hardware OpenGL**, from the G5's Radeon 9600 down to
the G3's ATI Rage 128, with the software renderer left in as an automatic
fallback. The world is drawn in a **single multitexture pass** rather than the
stock two, worth roughly **30% more frames** on the fillrate-bound G3.

The launcher then picks a display mode by CPU and OS. The G3 gets exclusive
fullscreen at 800×600, which suits its Rage 128, as does any machine on Panther,
where the `fullscreen` cvar is broken. A G4 or G5 on 10.4 or later fills the
screen at the display's own native resolution with no mode switch, which is what a
machine with a built-in panel, the iMac G5 above all, should do. Intel takes
exclusive fullscreen instead, because borderless on 10.7 leaves the menu bar's top
22 pixels unpainted as a white strip. A small config shipped inside the app re-applies
renderer-safe defaults on every launch, so a config reset cannot undo them, and
the console is available everywhere without developer mode.

LAN multiplayer works across the endian boundary: a PowerPC Mac and an Intel one
can host or join each other, and a three-way game between an Intel mini, a G5 and
a G4 has been played end to end.

## Mods

25 mods run on the same universal app, on PowerPC as well as Intel: Blue Shift,
Opposing Force, They Hunger, Poke 646, Echoes, Residual Point and the rest.

**We ship code, not content.** A mod is content (maps, models, sounds, the mod
authors' work) plus the game code that drives it, and only the code, about 3% of
the bulk, needs rebuilding for these machines. Each mod's code is built from its
own [hlsdk-portable](https://github.com/FWGS/hlsdk-portable) branch as a single
fat `ppc + x86_64` dylib, so one file serves every machine here.

**Half-Life Mods.app** does the install. Press *Get Mods* and it fetches the
content, mounts it and assembles each mod beside `Half-Life.app`; *Choose…* does
the same from a copy you already have. Installed mods appear under **Custom Game**
in the main menu with artwork and a description. It skips the packaging machine's
leftover `video.cfg`, `config.cfg` and savegames. That `video.cfg` was written on
a Yosemite i386 Mac and asks for fullscreen at 1200 lines with high DPI, and that
`config.cfg` carries the same machine's key bindings, which is why the bundle's
own download page has a user reporting that the arrow keys do nothing and only
WASD works.

![The mod installer part way through a run, showing the current mod's artwork and a log of what has been installed](docs/img/screenshots/intel-04-installing-induction.png)

The content comes from **each mod's own public release**, fetched at install
time from wherever its author published it. We host none of it, and the installer
carries a per-mod URL, size and checksum rather than one prepackaged bundle. Most
of it is mirrored by
[runthinkshootlive.com](https://www.runthinkshootlive.com) and
[archive.org](https://archive.org); every mod belongs to the people who made it.

Not all 25 can be fetched automatically. Four have no public release in a format
any Mac tool can open - their only downloads are Windows installer programs - and
three are not mods at all: **Blue Shift**, **Opposing Force** and **Deathmatch
Classic** are Valve products you buy, so the installer never downloads them. For
all seven, put the folder next to `Half-Life.app` yourself and the installer adds
the game code it needs.

**Team Fortress Classic** cannot be done at all.
No open TFC server implementation exists anywhere, in any language, for GoldSrc,
so there is nothing to rebuild from
([#13](https://github.com/matthewdeaves/old-mac-halflife/issues/13)).
See [`docs/MODS.md`](docs/MODS.md) to build them yourself, and
[`docs/MOD-AUDIT.md`](docs/MOD-AUDIT.md) for the source audit of them all.

## What is in this repo

![Repo map: public upstream repos are cloned at pinned commits into a git-ignored vendor directory, patched and built into one universal app; this repo tracks only the glue](docs/img/repo-map.svg)

Half-Life splits into three separately-built parts, and all three are other
people's code: the **engine** ([`xash3d-fwgs`](https://github.com/FWGS/xash3d-fwgs)),
the **menu** ([`mainui_cpp`](https://github.com/FWGS/mainui_cpp)) and the **game
code** ([`hlsdk-portable`](https://github.com/FWGS/hlsdk-portable)). The stock
Steam `valve` DLLs are 32-bit x86 and unusable, so the game code is recompiled for
every slice. PowerPC additionally needs big-endian forks and a set of local
patches; Intel needs only a forced 64-bit build.

None of that source is committed here. Upstream is cloned at pinned commits into
a git-ignored `vendor/`, patched and built, so what this repo actually tracks is:

- `scripts/build-*.sh` per-arch build drivers, one per slice
- `scripts/patch-*.py` the source patches, which are the record of our changes
- `scripts/make-universal.sh` + `make-app.sh` fuse the slices and wrap the app
- `scripts/bootstrap-vendor.sh` + `vendor/MANIFEST.md` rebuild `vendor/` from scratch
- `installer/` the mod installer app ([its own README](installer/README.md))
- `configs/`, `docs/` sticky settings, [how mods work](docs/MODS.md), the
  [mod audit](docs/MOD-AUDIT.md), the [icon pipeline](docs/ICONS.md) and a
  [renderer case study](docs/GL-OPTIMIZATION-CASE-STUDY.md)

### Upstream

| Project | Used for |
|---|---|
| [`FWGS/xash3d-fwgs`](https://github.com/FWGS/xash3d-fwgs) | engine, Intel slice |
[removed]
[removed]
| [`FWGS/mainui_cpp`](https://github.com/FWGS/mainui_cpp) | menu, Intel slice |
[removed]
| [`FWGS/hlsdk-portable`](https://github.com/FWGS/hlsdk-portable) | game code, Intel dylibs |
[removed]
| [alex-free legacy SDL2](https://forums.macrumors.com/threads/2262878/) | native-Cocoa SDL2 for old macOS; modern SDL2 refuses to build pre-10.6 |

Exact pinned commits are in [`vendor/MANIFEST.md`](vendor/MANIFEST.md).

**This is an independent repackaging, not an upstream release.** Report problems
with this build [here](https://github.com/matthewdeaves/old-mac-halflife/issues),
never on anyone else's release page.

## Credits

- **[FWGS](https://github.com/FWGS)** for the Xash3D engine, menu and HLSDK.
[removed]
  the PowerPC build and menu fixes our PPC slices are built from. Without them
  there would be no PowerPC half of this binary, and the Intel half carries their
  work too: the fix that stopped every Intel launch failing its first OpenGL
  context came from their fork, where it had been solved for PowerPC first. Their
[removed]
  covers **Mac OS 9 / Classic**, which this build deliberately drops, so if you
  need Classic support, that is the one you want.
[removed]
  big-endian PowerPC forks.
- **The authors of all 25 mods**, whose maps, models and sounds are their own
  work. This project supplies game code and no content whatsoever.
- **[runthinkshootlive.com](https://www.runthinkshootlive.com)** and
  **[archive.org](https://archive.org)** for keeping those releases downloadable
  decades on.
[removed]
  the PowerPC work above.
- **[alex-free](https://github.com/alex-free)** for the
  [legacy native-Cocoa SDL2](https://forums.macrumors.com/threads/2262878/).

Every project credited above is separately maintained. This one is an
independent repackaging and is not affiliated with any of them.

Half-Life and the `valve/` game data are © Valve, and this ships neither. The
game app's icon is an AI-edited derivative of Little Red Zombies' "HλLF-LIFE:
Gordon (UE4)" MetaHuman render, not that render as published. The mod installer's
icon and its About picture are AI-generated images made for this project. Gordon Freeman is Valve's character. An unofficial
fan project, not endorsed by Valve, and any of this artwork comes out or gets
replaced on request.

## More old-Mac game builds

The same one-universal-binary treatment, applied to other engines:
[**Quake**](https://github.com/matthewdeaves/old-mac-quakespasm) (QuakeSpasm),
[**Quake II**](https://github.com/matthewdeaves/old-mac-quake2) (yquake2) and
[**Quake III Arena**](https://github.com/matthewdeaves/old-mac-quake3) (ioquake3).

## Tested on

These are the only setups this has run on. Built with AI (Claude Code) under my
direction, and every build tested on the real hardware below. The Apple Silicon
row runs the `x86_64` slice through Rosetta 2; there is no native arm64 build.

| Machine | CPU | GPU | macOS |
|---|---|---|---|
| Power Mac G3 (Yosemite) | PowerPC 750 @ 450 MHz | ATI Rage 128 | 10.3.9 Panther |
| Power Mac G3 (2nd partition) | PowerPC 750 @ 450 MHz | ATI Rage 128 | 10.4.11 Tiger |
| Power Mac G4 (Quicksilver) | PowerPC 7450 @ 733 MHz | ATI Radeon 9000 | 10.4.11 Tiger |
| Mac mini G4 | PowerPC 7450 @ 1.25 GHz | ATI Radeon 9200 | 10.4.11 Tiger |
| iMac G5 | PowerPC 970 @ 2.0 GHz | ATI Radeon 9600 | 10.5.8 Leopard |
| Mac mini (Intel) | Core 2 Duo @ 2.33 GHz | Intel GMA 950 | 10.7.5 Lion |
| MacBook Air (M5) | Apple M5 | Apple integrated | macOS 26, via Rosetta 2 |

### Being added

A second G5 is joining the bench: a **Power Mac G5 (`PowerMac7,3`, Early 2005),
dual 2.7 GHz**, with a Radeon 9650 256 MB and 2.5 GB of RAM, which makes it the
only dual-CPU machine here. It is a bench and test target, never a build host:
all three slices cross-compile on the Intel Lion minis, and no PowerPC box builds
anything.

It is partitioned to boot **10.3, 10.4 and 10.5 side by side** off its
original 10.3.5 install disc, one OS booted at a time, the way the G3 already
carries Panther and Tiger on separate partitions. So it takes a row per OS
rather than one row for the machine, and each row moves into the table above
once that partition has actually run the game. All three take the `ppc7400`
slice, the same one a G4 takes, since there is no `ppc970` slice; 10.3 and 10.4
on a G5 are the untested case listed further up
([#14](https://github.com/matthewdeaves/old-mac-halflife/issues/14)).

| Machine | CPU | GPU | macOS |
|---|---|---|---|
| Power Mac G5 (dual, partition 1) | dual PowerPC 970 @ 2.7 GHz | ATI Radeon 9650 | 10.3.9 Panther, onboarded, not yet run |
| Power Mac G5 (dual, partition 2) | dual PowerPC 970 @ 2.7 GHz | ATI Radeon 9650 | 10.4.11 Tiger, onboarded, not yet run |
| Power Mac G5 (dual, partition 3) | dual PowerPC 970 @ 2.7 GHz | ATI Radeon 9650 | 10.5.8 Leopard, onboarded, runs |

The drive is one 465.8 GB disk cut into three 155.1 GB HFS+ volumes named
Panther, Tiger and Leopard, and all three now carry a system.

All three partitions are onboarded as bench targets, with the ssh aliases
`g5-panther`, `g5-tiger` and `g5-desktop`: key login, passwordless sudo, sleep and
disk spindown disabled, each named after its alias, and each with the release
image and a retail `valve/` staged on its Desktop. The machine is at
10.188.1.188 by DHCP; all three partitions share the one NIC and so the one
address, which is what lets an alias per partition hardcode it.

The game has been run on the Leopard partition and it renders far slower than
the single-CPU iMac G5 does, which is not yet explained. The measurements and
what they rule out, plus the machine's full specs, are in
[`docs/BENCHMARKING.md`](docs/BENCHMARKING.md).
