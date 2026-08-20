# 9. The mod installer is a native Cocoa app written for 10.3

Date: 2026-07-27
Status: accepted

## Context

We ship code and never content (ADR 0006), so something has to fetch each mod's
content from wherever it is published, discard the Windows game code, and drop
our fat dylibs in at the right filenames (ADR 0008). ADR 0011 covers how the
sources are chosen; this is what kind of program does it.

It runs wherever the game does, from a G3 on 10.3.9 to a modern Mac, because the
person installing mods is the person playing them. So the x86_64 slice has to
exist, being what modern Intel and Apple Silicon Macs load, and networking has to
be self-contained: there is no project TLS on PowerPC to borrow, and the system
TLS on 10.3 through 10.7 cannot negotiate what modern servers require (ADR 0011).

## Decision

**`Half-Life Mods.app`: native Cocoa, one fat `ppc + i386 + x86_64 + arm64`
binary, `LSMinimumSystemVersion 10.3.0`, no nibs and no frameworks beyond Cocoa
itself** (`docs/MODS.md`, `installer/README.md`).

`scripts/build-installer.sh` compiles the whole app once per architecture, Apple
`gcc-4.0` against the 10.3.9 SDK for PowerPC and Xcode clang for the Intel
arches (`OLDMAC_INSTALLER_ARCHES`, `x86_64 i386` by default), then `lipo`s them
together. The `arm64` slice is built on the orchestration box by
`scripts/build-installer-arm64.sh`, carried over by `push-mod-arm64.sh`, and is
**optional**: without it Apple Silicon runs the `x86_64` slice under Rosetta 2,
so a missing slice is a downgrade rather than a fault, and the driver says which
case it is either way.

The `i386` slice matches the game and the mod dylibs. Without it a 2006 Core
Solo or Core Duo owner could run Half-Life and every mod but not the app that
installs them.

The 10.3 target runs through the whole source directory: no `@property` or
`@synthesize`, no fast enumeration, no `NSInteger`, no blocks or GCD, no ARC, no
nib (`installer/README.md`). Several things had to be written: `OMTGA.m`
decodes TGA because `NSImage` on 10.3 has none, `OMDownload.m` is HTTP/1.1 `GET`
with `Range:` resume over raw sockets, and `OMAbout.m` reads a sound out of the
player's own `pak0.pak`.

One PowerPC slice, not two: the rule against a generic `ppc (ALL)` slice concerns
a fat holding several PowerPC slices of differing subtype, which Tiger and
Leopard mis-grade. One generic `ppc` slice beside the Intel ones is the ordinary
2006 universal-binary case and grades correctly everywhere
(`scripts/build-installer.sh:18-21`).

## Alternatives rejected

- **Carbon.** Never ported to 64-bit, so it cannot produce the x86_64 slice at
  all (`scripts/build-installer.sh:12-13`).
- **SDL, reusing what the game already links.** Available on both architectures,
  but this is a file-copying utility that should behave like a Mac application,
  and SDL means drawing every control.
- **A shell script or AppleScript.** It has to speak TLS, verify every download
  against an md5, unpack zip and solid 7z without exhausting a 448 MB machine,
  copy mods with an exclusion list, verify each against a manifest, and show
  progress. In shell that error handling cannot be reviewed and there is no
  window.
- **`NSURLConnection` for the download.** The original single download was about
  2.5 GB, which overflows any 32-bit byte counter, the same flaw that makes the
  engine's own HTTP client unusable here: `httpfile_t.size` is an `int`
  (`docs/MODS.md`, "The installer app").
- **Target 10.4 or 10.5 for more of Cocoa.** It drops the G3 on Panther, the
  machine the port exists for.
- **Copying each mod folder wholesale.** A packaged mod folder carries the
  packaging machine's runtime state: a `video.cfg` asking for fullscreen at 1200
  lines with high DPI, the packager's `config.cfg` keybinds, and their savegames.
  That reproduces the "arrow keys do nothing, only WASD works" reports and puts a
  1200-line fullscreen request on a G3's Rage 128 (`docs/MODS.md`, "What it
  refuses to copy").

## Consequences

- One binary, one code path, on a G3 under 10.3.9 and a modern Mac alike.
- Compiling against the 10.3.9 SDK is a real check: it caught `-longLongValue`
  and `-stringByReplacingOccurrencesOfString:withString:`, both 10.5 additions,
  which compiled fine for Intel and would have crashed on the target machines
  (`installer/README.md`).
- Everything except the content is precompiled and verified on the build host.
- Manual `retain`/`release` throughout and a UI built entirely in code;
  `OMController.m` is about 60 KB of source.
- 10.5-and-later API use is easy to reintroduce and invisible to the compiler
  wherever the receiver is typed `id`. `OMLongLong()` and `OMReplace()` in
  `OldMacMods.h` cover two known cases; there is no general defence.
- A fixed set of 25 mods, not "any mod you point it at": a mod with no build has
  no code to supply (`installer/README.md`).
- Risk: the exclusion list is a list, and a future release of a mod could carry a
  new piece of packaging-machine state that is not on it.

## Notes

Two Panther-only faults are fixed in this app rather than worked around by the
user: its `hdiutil` predates `-puppetstrings`, so mounting failed until the app
learned to retry without it, and `NSButton` on 10.3 clips an oversized image
where 10.5 scales it, so the About artwork lost its head and legs until the image
was pinned to an explicit size (`installer/README.md`).
