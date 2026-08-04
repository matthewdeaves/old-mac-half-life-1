# 9. The mod installer is a native Cocoa app written for 10.3

Date: 2026-07-27
Status: accepted

## Context

We ship code and never content (ADR 0006), so something has to fetch each mod's
content from wherever that mod is published, discard the Windows game code, and
drop our fat dylibs in at the right filenames (ADR 0008). See ADR 0011 for how
the sources are chosen; this decision is about what kind of program does it.

That something has to run on the same machines the game does, from a G3 on 10.3.9
to a modern Mac, because the person installing mods is the person playing them.

Two hard constraints come with those machines. The x86_64 slice has to exist,
because that is what modern Intel and Apple Silicon Macs load. And the networking
has to be self-contained: PowerPC has no TLS in this project, and the system TLS
on 10.3 through 10.7 cannot negotiate what modern servers require, so the app has
to bring its own (ADR 0011).

## Decision

**`Half-Life Mods.app`: native Cocoa, one fat `ppc + x86_64` binary,
`LSMinimumSystemVersion 10.3.0`, no nibs and no frameworks beyond Cocoa itself**
(`docs/MODS.md:199-200`, `installer/README.md:3-7`).

`scripts/build-installer.sh` compiles the whole app twice, Apple `gcc-4.0`
against the 10.3.9 SDK for PowerPC and Xcode clang against the 10.7 SDK for
x86_64, then `lipo`s the two together (`:57-59`, and the header at `:11-21`).

Consequences of the 10.3 target run through the whole source directory: no
`@property` or `@synthesize`, no fast enumeration, no `NSInteger`, no blocks or
GCD, no ARC, no nib (`installer/README.md:62-68`). Several things had to be
written rather than used: `OMTGA.m` decodes TGA because `NSImage` on 10.3 has
none, `OMDownload.m` is HTTP/1.1 `GET` with `Range:` resume over raw sockets, and
`OMAbout.m` reads a sound out of the player's own `pak0.pak`.

The app carries one PowerPC slice, not two. The project's rule against a generic
`ppc (ALL)` slice concerns a fat holding several PowerPC slices of differing
subtype, which Tiger and Leopard mis-grade; a plain `[ppc, x86_64]` fat is the
ordinary 2006 case (`scripts/build-installer.sh:18-21`).

## Alternatives rejected

**Carbon.** Never ported to 64-bit, so a Carbon app could not produce the x86_64
slice at all (`scripts/build-installer.sh:12-13`). That rules it out before any
question of style.

**SDL, reusing what the game already links.** SDL is available on both
architectures here, but this is a file-copying utility that should look and behave
like a Mac application, and SDL would mean drawing every control.

**A shell script or AppleScript.** It has to speak TLS, verify every download
against an md5, unpack zip and solid 7z without exhausting a 448 MB machine, copy
mods with an exclusion list, verify each against a manifest, and show progress
for all of it.
Doing that in shell puts the error handling somewhere it cannot be reviewed, and
gives the user no window.

**`NSURLConnection` for the download.** The file is about 2.5 GB, which overflows
any 32-bit byte counter. That is the same flaw that makes the engine's own HTTP
client unusable here: `httpfile_t.size` is an `int` (`docs/MODS.md:214-216`).

**Target 10.4 or 10.5 to get more of Cocoa.** It would drop the G3 on Panther,
which is the machine the port exists for.

**Copy each mod folder wholesale.** The collection was packaged by running each
mod on a Yosemite i386 Mac, so every mod folder carries that machine's runtime
state: a `video.cfg` asking for fullscreen at 1200 lines with high DPI, the
packager's `config.cfg` keybinds, and their savegames. Copying it would reproduce
the "arrow keys do nothing, only WASD works" reports on our machines, and put a
1200-line fullscreen request on a G3's Rage 128 (`docs/MODS.md:220-239`).

## Consequences

**Gained**

- One binary installs mods on every machine the game runs on, with the same code
  path on a G3 under 10.3.9 and an Intel mini under 10.7.5.
- Compiling against the 10.3.9 SDK is a real check rather than a claim. It caught
  `-longLongValue` and `-stringByReplacingOccurrencesOfString:withString:`, both
  10.5 additions, which compiled fine for Intel and would have crashed on the
  target machines (`installer/README.md:72-76`).
- Everything except the content is precompiled and verified on the build host, so
  the 20-year-old machine does the least possible
  (`scripts/build-installer.sh:32-33`).

**Lost**

- Manual `retain`/`release` throughout, and a UI built entirely in code.
  `OMController.m` is about 60 KB of source.
- 10.5-and-later API use is easy to reintroduce and invisible to the compiler
  wherever the receiver is typed `id`. `OMLongLong()` and `OMReplace()` in
  `OldMacMods.h` exist for two known cases; there is no general defence.
- Plain HTTP means the transport contributes nothing to integrity. `sources.txt`
  carries the expected size and md5, and supports a remote override so a dead
  mirror can be repointed without a new binary, but a hostile network is not
  something this app can resist.
- A fixed set of 25 mods, not "any mod you point it at": a mod with no build has
  no code to supply (`installer/README.md:19-20`).

**Risks accepted**

- The download depends on a mirror honouring `Range:` at a 2.74 GB offset. That
  was verified against `old.mac.gdn`, and `sources.txt` exists so it can be
  repointed, but a mirror that resets the connection makes the app unusable for
  its main button.
- The exclusion list is a list. A future release of the collection could carry a
  new piece of packaging-machine state that is not on it.

## Notes

Panther surfaced two faults no newer system showed, both fixed in this app rather
than worked around by the user: its `hdiutil` predates `-puppetstrings`, so
mounting failed until the app learned to retry without it, and `NSButton` on 10.3
clips an oversized image where 10.5 scales it, so the About artwork lost its head
and legs until the image was pinned to an explicit size
(`installer/README.md:112-118`).
