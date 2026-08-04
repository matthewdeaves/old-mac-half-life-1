# Half-Life Mods.app

A native Cocoa installer that puts Half-Life mods onto a PowerPC or Intel Mac
running anything from **Mac OS X 10.3.9 Panther** to modern macOS, and makes them
work with the port's `Half-Life.app`.

One fat `ppc + x86_64` binary, no nibs, no frameworks beyond Cocoa itself.

![The app on startup](../docs/img/screenshots/g5-01-ready.png)

## Minimum specs

| | |
|---|---|
| OS | Mac OS X **10.3.9** or later |
| CPU | PowerPC or Intel (one fat `ppc + x86_64` binary) |
| Memory | **256 MB** minimum. The app checks at launch and refuses to start below it |
| Disk | about **6 GB** free for the full set |
| Network | needed for **Get Mods**, not for **Choose...** |

The memory figure is measured, not guessed. The largest mod, Echoes, expands to
450 MB and is stored as a single solid compressed block, so unpacking it is the
hungriest thing this app ever does. It was measured completing on a 450 MHz G3
with 448 MB of RAM, peaking at 380 MB resident. Below 256 MB a machine would
swap for hours and then fail, most likely after a long download, so `main.m`
says so in two seconds instead.

## What it actually does

Mods are two things: **content** (maps, models, sounds, `liblist.gam`) and
**game code** (`dlls/<mod>.dylib`, `cl_dlls/client.dylib`). This app supplies the
code, rebuilt as one fat `ppc + x86_64` pair per mod from that mod's own source
branch. The content comes from that mod's own public release, fetched at install
time.

**We host no content.** Not in this repository, not in the disk image, nowhere.
The same posture the project takes toward `valve/`.

For each mod: download the archive, check it against a known md5, unpack the
right subtree, discard the Windows game libraries and the packager's leftover
runtime state, drop in our dylibs, and rewrite `liblist.gam` so the engine looks
for what is actually on disk. `installer/mod-sources.txt` carries the per-mod
URL, format, size, md5 and the subtree to take.

### Of the 25 mods, three groups

**18 can be fetched automatically.** 12 arrive as `.7z`, 6 as `.zip`. The app
carries its own decoders for both.

**4 cannot: `aom`, `eftd`, `vendetta`, `TheGate`.** Their only public releases
are Windows installer programs in formats no Mac tool opens - two are Clickteam
Install Creator, one is a self-extractor 7-Zip itself cannot read, and for The
Gate no archive form was found at all. Unpack the mod on a PC, put the folder
next to `Half-Life.app`, and this app adds the game code.

**3 are not mods: `bshift`, `gearbox`, `dmc`.** Blue Shift, Opposing Force and
Deathmatch Classic are Valve products you buy. This app will not download them
from anywhere. If you own them and the folders are already there, **Get Mods**
detects them and installs the game code, and they work like everything else.

Team Fortress Classic is supported by nobody: no open server implementation
exists for this engine in any language, so there is nothing to compile. Issue #13.

## The two buttons

**Get Mods** first looks for mod folders you already have and adds game code to
those, which takes seconds and costs no bandwidth. Then it fetches everything
else in turn.

**Choose...** points at a mod folder you already have, or a folder holding
several. Content may come from any platform's release, a Windows one included:
maps, models and sounds are identical everywhere.

It **refuses what it cannot place**. We ship one build of game code per mod,
compiled from that mod's own source, and it is not interchangeable: `eftd`
renumbers the `func_breakable` `spawnobject` list, so its server dylib beside
stock content hands out an RPG where the map asked for a .357. A wrong install
would look like it worked and misbehave later, which is worse than a refusal now.

Both are resumable. Cancel or quit and run again: finished mods are skipped, and
a part-finished download continues from exactly where it stopped rather than
starting over. Archives are kept in `~/Downloads/Half-Life Mods/` so a second run
does not re-fetch them. A mod that was only part-copied is removed rather than
left looking installed.

## Networking

The app carries **its own TLS** - mbed TLS 3.6, built into both slices - because
almost every host that publishes a mod answers plain http with a `301` to https,
and 10.3 to 10.7's system TLS cannot negotiate what modern servers require. The
G3's own `curl` links OpenSSL 0.9.7b from 2003.

Verified against the live hosts from a G3 and a G5, both on 10.3.9: TLS 1.3,
ChaCha20-Poly1305, certificates checked against a shipped Mozilla root bundle,
and `Range:` resume working through the session. Throughput was 4.0 MB/s on the
G3, which is the network rather than the cipher.

archive.org is still fetched over plain http, because it works there and the md5
is the integrity check either way. ModDB is not used at all: it sits behind
Cloudflare and answers a non-browser client with `403` before TLS matters.

## Why Cocoa, and why only two slices

Carbon was never ported to 64-bit, so a Carbon app could not produce the `x86_64`
slice at all. Cocoa has everything this UI needs as far back as 10.3:
`NSProgressIndicator`, `NSTextView`, `NSImageView` and real buttons.

Only **one** PowerPC slice is built here. The project's rule against a generic
`ppc (ALL)` slice exists because Tiger and Leopard mis-grade a fat binary
containing *several* `ppc` slices; a plain `[ppc, x86_64]` app is the ordinary
case and grades correctly on every machine in the fleet.

## Writing code for 10.3

Targeting Panther rules out most of modern Cocoa. Throughout this directory:

- no `@property` / `@synthesize`, no fast enumeration, no `NSInteger` (10.5)
- no blocks, no GCD (10.6) - `NSThread` plus `performSelectorOnMainThread`
- no ARC - manual `retain`/`release`
- no nibs - the UI is built in code, so there is no nib format to keep working
  across 10.3 to 26

Two traps:

- **`-longLongValue` and `-stringByReplacingOccurrencesOfString:withString:` are
  10.5 additions.** Where the receiver is typed `id` the compiler cannot even
  warn, so they are easy to reintroduce. `OMLongLong()` and `OMReplace()` in
  `OldMacMods.h` are 10.0-only replacements. Compiling against the 10.3.9 SDK is
  what catches these.
- **Do not name an action `-showHelp:`.** `NSApplication` already implements it,
  and it sits ahead of the app delegate in the responder chain, so a nil-targeted
  `-showHelp:` silently opens the system Help Viewer instead of your window. The
  same applies to any selector `NSApplication` or `NSResponder` responds to.

## Files

| File | |
|---|---|
| `OMController.m` | UI, worker thread, log and help text |
| `OMFetch.m` | one mod: download, md5, unpack, stage |
| `OMInstaller.m` | copying a mod, injecting the dylibs, fixing `liblist.gam` |
| `OMDownload.m` | HTTP/1.1 `GET` with `Range:` resume and 64-bit sizes |
| `OMTLS.m` | TLS over that socket, via vendored mbed TLS |
| `OMArchive.m` | zip reader; dispatches 7z to `om7z.c` |
| `om7z.c` | 7z reader, pure C so it never meets Carbon's `MacTypes.h` |
| `OMUtil.m` | subprocess, free space, md5 |
| `OMTGA.m` | TGA decoder, because `NSImage` on 10.3 has no TGA reader |
| `OMAbout.m` | reads one sound out of the player's own `pak0.pak` |
| `mods.map` | content gamedir to build branch |
| `mod-sources.txt` | per-mod URL, format, size, md5 and subtree |

Built by `scripts/build-installer.sh`, which compiles the whole app twice - Apple
gcc-4.0 against the 10.3.9 SDK for PowerPC, Xcode clang against the 10.7 SDK for
`x86_64` - and `lipo`s the results together.

## One binary, both architectures

The same code path on a Power Mac G3 running 10.3.9 and on an Intel mini running
10.7.5:

| | |
|---|---|
| ![On Panther](../docs/img/screenshots/panther-01-ready.png) | ![Intel, installing](../docs/img/screenshots/intel-04-installing-induction.png) |
| Panther, 10.3.9 | Lion, 10.7.5 |

Panther is where two 10.3-only faults surfaced that no newer system showed.
`hdiutil` there predates `-puppetstrings`, so mounting failed outright until the
app learned to retry without it; and `NSButton` on 10.3 *clips* an oversized image
where 10.5 scales it, so the About artwork lost its head and legs until the image
was pinned to an explicit size. It is also why the log is styled by line shape
rather than set in one face: headings stand out, prose reads as prose, and the
two-column list keeps its alignment because those lines stay fixed-pitch.

## There is an easter egg

![About](../docs/img/screenshots/g5-02-about-box.png)

Gordon is a button. Clicking him plays a line out of **your own** `pak0.pak` -
which is the only way to do it, because we ship no game audio and never will.
If the game data is not there yet, nothing happens and nothing complains.

## Credit for the content

**Every mod belongs to the people who made it.** This app supplies game code and
nothing else; each mod's maps, models, sounds and sprites are its authors' work,
fetched from that mod's own public release at install time. `mod-sources.txt`
records where each one comes from.

Two hosts carry most of it and neither is ours:

- **[runthinkshootlive.com](https://www.runthinkshootlive.com)**, Phillip's
  long-running Half-Life single-player archive, which mirrors most of these mods
  as plain archives with working resume.
- **[archive.org](https://archive.org)**, for the rest.

Fetching per mod means the catalogue no longer depends on one file on one
mirror, and no Valve retail game passes through here at any point.

---

PowerPC screenshots taken on an iMac G5 running Mac OS X 10.5.8 Leopard; Panther
ones on a Power Mac G3 running 10.3.9; Intel ones on a Mac mini running 10.7.5
Lion. The mod artwork visible in them belongs to the respective mod authors and
is shown as it appears in the app.
