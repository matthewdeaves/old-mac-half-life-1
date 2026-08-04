# Mod support

How Half-Life mods run on the old-Mac port, and how to rebuild them.

## Credit where it belongs

The mod **content** is its authors' work, and this project supplies none of it.
Each mod is fetched at install time from that mod's own public release, from
wherever it is published: mostly
[runthinkshootlive.com](https://www.runthinkshootlive.com), Phillip's long-running
Half-Life single-player archive, and [archive.org](https://archive.org) for the
rest. `installer/mod-sources.txt` records the URL, format, size, md5 and subtree
for every one, and the reason for each of the seven that have no usable source.

This project adds one narrow thing: the game code, rebuilt for **PowerPC** and
64-bit Intel from each mod's own source branch, where the only Mac builds that
otherwise exist are i386 and need 10.5.8 or later.

## The shape of the problem

A mod is two things:

| part | what it is | size | who supplies it |
|---|---|---|---|
| content | maps, models, sounds, sprites, wads, `liblist.gam` | ~3.96 GB across 25 mods | the user |
| game code | `dlls/<mod>.dylib` + `cl_dlls/client.dylib` | ~130 MB | **us** |

Content is architecture- and OS-neutral - a Windows release contains byte-identical
maps and models, and the engine even derives the Mac dylib name from a Windows
`gamedll` line (`filesystem.c`). Only the code has to be rebuilt, and it is ~3% of
the bulk. So we build code and never redistribute content, the same posture the
project takes toward `valve/`.

## One fat dylib per role

Xash normally loads game code by **arch-suffixed** name - `dlls/bshift_amd64.dylib`,
`cl_dlls/client_ppc.dylib` - which would mean one file per architecture. We ship one
instead, because the engine also accepts the **plain** name from the mod's own
`liblist.gam`:

- **server**: `SV_InitGame()` (`engine/server/sv_init.c`) tries the suffixed name,
[removed]
  PPC fork (commit `c9b012c7`); `patch-gamedll-plain-name.py` ports it to mainline.
- **client**: `CL_Init()` had no retry at all - it called `Host_Error` on the first
  failure. The same patch adds the mirror-image fallback to both trees.

So `lipo`-ing the two slices into `dlls/bshift.dylib` gives one file that loads on
G3, G4, G5 and Intel - and it is the exact filename existing Mac mod releases use,
so installing is a straight overwrite. The old suffixed layout still works and
`valve/` is untouched; the fallback only fires when the suffixed name is missing.

One generic `ppc` slice covers all three PPC machines: game dylibs are loaded with
`dlopen()`, which grades a `ppc (ALL)` slice correctly on a 750. Only the engine
*executable* needs an exact cpusubtype (see the ppc750 re-stamp in
`build-ppc-panther.sh`).

## Switching mods: fork before you exec

Picking a mod in Custom Game does not load it in place - the engine re-execs
itself with a new `-game`. On PowerPC that silently did nothing:

```
Note: Issuing host shutdown due to reason "change game to 'Opposing Force'"
CL_Shutdown()
Error: Failed to restart the engine
execv(.../Contents/MacOS/xash3d.bin) failed: Operation not supported
```

leaving a live process with no window, needing a force-quit.

**Darwin refuses `execve()` from a process that has more than one thread.** It
returns `ENOTSUP` (errno 45) rather than replacing the image. Measured on a G4
under 10.4.11 with a purpose-built test binary:

```
threads created: 0 -> exec succeeded
threads created: 4 -> execv FAILED: Operation not supported (errno 45)
```

`Sys_NewInstance()` runs after `Host_Shutdown`, but SDL's helper threads are
still alive, so the exec was refused every single time.

Two plausible culprits are **not** to blame:

- **Not the path.** The engine already retried with `host.argv[0]`; both attempts
  resolve to the same `xash3d.bin` and both failed identically.
- **Not fat-binary grading.** `execv`ing that same fat binary succeeds from
  an ordinary process on the same machine, whether the caller is built generic
  `ppc` or `ppc7400`. This project has a real Tiger fat-mis-grading bug (see
  `CLAUDE.md`), which makes it the obvious suspect here. It is not the cause.

`patch-sys-newinstance-fork.py` adds `Sys_RestartExec()`: try the direct exec
first, and if it returns, `fork()` and exec from the child - single-threaded by
construction, so the restriction does not apply. A close-on-exec pipe tells the
parent which happened, so it only stands down on a real success; if the child
could not exec either, the caller still reports a genuine failure rather than
leaving the user with no engine and no message.

Verified on hardware: valve → gearbox now re-execs in about a second, and the new
process logs `FS_AddGameHierarchy( gearbox )` and brings up video.

## Big-endian: mostly upstream's problem now

[removed]
now largely obsolete: **FWGS master has absorbed the endian work**. Save/restore
swaps centrally in `CSave::BufferData()` via a new `typesize` parameter rather
than at every call site, and `dlls/nodes.cpp` /
`dlls/nodes_compat.h` are fully handled. All 25 mod branches carry it.

One file was left behind: `cl_dll/StudioModelRenderer.cpp` reads compressed
animation values through `Unaligned()`, which fixes alignment but does **not**
byteswap, so models animate wildly on PPC. `patch-hlsdk-studio-endian.py` switches
those reads to `ULittleToHost()` - the unaligned-*and*-swapped helper mainline
already provides.

`graft-ppc-endian.sh` detects which vintage a branch is and applies the right thing;
the full 6-file fork graft (`patches/ppc-hlsdk-big-endian-legacy.diff`) is kept as a
fallback for any branch that predates upstream's work.

## Building

On an Intel Lion mini (claim one with `scripts/pick-build-host.sh --acquire mods`):

```sh
./scripts/build-mod.sh --all        # or: ./scripts/build-mod.sh bshift opfor
./scripts/build-installer.sh        # bundles dist/mods/ into Half-Life Mods.app
```

Output is `dist/mods/<branch>/{server,client}.dylib` plus a `mod.info` recording the
branch, upstream commit and build time.

Each branch is self-describing via its `mod_options.txt`, so one driver handles all
of them. Every build is verified three ways before it counts - log grepped for
`Build failed`, artifacts confirmed newer than the build start, and `lipo -info`
asked what is actually inside. waf can exit 0 with a failed compile task and then
install stale objects. Full procedure in `.claude/rules/build-verification.md`.

### Things that bite on these machines

- **The mirror is the source of truth, even though the minis can now reach GitHub.**
  Historically Xcode 4's git linked an OpenSSL too old for TLS 1.2 and every clone
  died with `SSL23_GET_SERVER_HELLO:tlsv1 alert protocol version`. Fixed 2026-07-26:
  the minis carry OpenSSL 3.5.7 / curl 8.21 / git 2.55 built from source under
  `~/local`, outside the Xcode toolchain. The local `--mirror` clone at
  `vendor/hlsdk-portable-mirror.git` is kept anyway and still preferred
  automatically. The build pins exact commits in `vendor/MANIFEST.md`, 57 branches
  clone from a local path in seconds, it works with no internet at all, and the PPC
  bench boxes still have no TLS. Refresh from a modern Mac with
  `git -C vendor/hlsdk-portable-mirror.git remote update`.
- **The git that runs inside the build scripts is still 1.7.12.4**, so `git -C` does
  not exist there, so use `( cd … && git … )`. This is *not* stale advice. `~/local/bin`
  wins for a plain `ssh mini git`, but the build scripts deliberately put the Xcode
  toolchain first on `PATH`, and Xcode 4.6.3 ships its own git 1.7.12.4. That
  ordering must not be reversed: Lion's `/usr/bin/{install_name_tool,lipo,strings}`
  are stale stubs that choke on modern Mach-O load commands, so the Xcode copies
  have to win. Old git is the price of correct binary tooling.
- **hlsdk assumes darwin implies clang.** We build darwin/ppc with gcc-4.0, which
  gets GNU-only `-Wl,--no-undefined`; Apple's ld rejects it and configure fails with
  a bare `Checking for required C flags : no`. `patch-hlsdk-ppc-darwin.py` drops it.
- **`--disable-altivec` is an engine option, not an hlsdk one.** Passing it makes
  hlsdk's configure print help and leave the project unconfigured.
- **gcc-4.0 is stricter than the clang used for x86_64.** Two mods needed real
  (standards-correct) fixes, handled by `patch-hlsdk-mod-gcc4.py`: a
  pointer-to-member comparison across classes in Spirit-derived mods
  (`echoes`, `halloween`), and a missing `typename` on a dependent type in `dmc`'s
  bundled ministl.

## Naming: trust `liblist.gam`, not the branch

A branch's `mod_options.txt` does **not** always match what the mod ships:

| branch | branch declares | mod actually ships |
|---|---|---|
| `residual_point` | `rp_pub` / `rp.dylib` | `rp/` + **`survivor.dylib`** |
| `caseclosed` | `caseclosed` | `cc/` |
| `CAd` | `CAd` | `cad/` |

So builds are keyed by **branch** with generic names (`server.dylib`,
`client.dylib`), and the installer does the final naming from the mod's own
`liblist.gam` - the only thing the engine actually consults. `installer/mods.map`
maps a content gamedir to its branch. The installer also rewrites `gamedll_osx` in
the installed `liblist.gam` so it always names what was actually put on disk.

## A mod's server dylib is for that mod only

Obvious, but there is a concrete trap behind it. `eftd` renumbers the
`func_breakable` `spawnobject` list in `dlls/func_break.cpp`: indices 12-21 all
shifted when python, gauss and hornetgun were removed from it. Its own maps were
authored against the renumbered list so they are correct, but a **stock** map
asking for `spawnobject 12` expects the .357 and would get an RPG.

Nothing in the shipped layout can cause this, because each mod's dylibs are
installed beside that mod's own content and `valve/` is never given a mod's code.
It is written down so that a future "why not just reuse one server dylib" idea is
answered before it is tried, and so the renumbering is not mistaken for a bug and
"fixed" back.

## The installer app

`installer/` builds **Half-Life Mods.app** - native Cocoa, fat ppc + x86_64,
`LSMinimumSystemVersion 10.3.0`.

Cocoa rather than Carbon because Carbon was never ported to 64-bit and so cannot
produce our x86_64 slice; rather than SDL because this should look like a Mac app.
Everything needed exists on 10.3, but that rules out a lot: no `@property`, no fast
enumeration, no `NSInteger`, no blocks/GCD, no ARC, and no nib. Compiling against
the 10.3.9 SDK is the check that keeps this honest - it caught `-longLongValue` and
`-stringByReplacingOccurrencesOfString:` (both 10.5+) that would have crashed on the
target machines while compiling fine for Intel.

Downloading is plain HTTP with `Range:` resume over raw sockets. Not a preference -
PPC has no TLS and 10.3-10.7 system TLS cannot negotiate modern ciphers, so https is
simply unreachable. `old.mac.gdn` serves the bundle over plain HTTP and honours
Range at a 2.74 GB offset (verified), so resume works. `sources.txt`
carries the mirrors, expected size and md5, and supports a remote override so a dead
mirror can be repointed without a new binary. NSURLConnection was not used: the file
is ~2.5 GB, which overflows any 32-bit byte counter - the same flaw that makes the
engine's own HTTP client unusable here (`httpfile_t.size` is an `int`).

### What it refuses to copy

The widely-circulated bundle was packaged by running each mod on a Yosemite i386
Mac, so each mod folder carries that machine's runtime state. Skipping it is a
correctness feature:

| skipped | why |
|---|---|
| `video.cfg` | `fullscreen "1"`, `height "1200"`, `vid_highdpi "1"` - that machine's own display state, from an `apple-i386` build. The engine execs `video.cfg` and then applies `-width`/`-height` from the command line, and the launcher passes those only on the G3 and Panther profiles, so on any other machine a leftover `video.cfg` is the mode the engine starts in. `vid_highdpi` is not a cvar in either engine we build. |
| `config.cfg` | the packager's keybinds. The bundle's own download page has a user reporting "arrows don't work, only WASD" |
| `opengl.cfg`, `keyboard.cfg` | tuning for hardware two decades newer |
| `save/`, `SAVE/` | their savegames; saves are native-endian, so i386 saves are garbage on PPC |
| `*.bak`, `.xash_id` | engine backups and per-install identity |
| `dlls/`, `cl_dlls/`, `dlls 2/`, `cl_dlls 2/` | i386 game code we replace, plus packaging duplicates |

~99 MiB per full install, and the mod's *own* config (`skill.cfg`, `default.cfg`,
`server.cfg`, class and map cfgs) is kept. `installer/manifests.txt` records the
expected file and byte count per mod after those exclusions, and the installer
verifies its own work against it; a mod is staged under `<gamedir>.partial` and only
moved into place once it passes, so an interrupted run never leaves a half-copied
folder that Custom Game would happily list.

### What is skipped, and why it is not a failure

A full run reports three skipped folders. Only Team Fortress Classic is a mod we
cannot support; the other two are German localisations. `OMSkipReason()` names each one rather
than saying "no build shipped" for all of them.

| skipped | what it is |
|---|---|
| `tfc`, `tfc_german` | Team Fortress Classic - the shipped dylib is i386 and there is no source to rebuild it from. FWGS deleted its `tfc` branch; 43 forks still carry it and all 19 TFC server `.cpp` files in it are zero bytes. Velaron/tf15-client is client-only by design, Toodles2You/tfc needs C++17 and i386-only Steam/VGUI binaries, and Valve never released TFC source. Closed as not achievable, issue #13 |
| `gearbox_german` | a whole German localisation of a game we install in English - content only, deliberately not installed |

`bshift_hd` and `gearbox_hd` used to be in that list and **are now installed**.
They are not mods: `models/`, `sound/`, `sprites/`, no game code at all. The
engine mounts them over their parent - a gearbox launch logs

```
FS_AddGameHierarchy( gearbox )
Adding directory: gearbox/
Adding directory: gearbox_hd/
```

so skipping them was silently costing the HD models for Blue Shift and Opposing
Force, for 21 MB. `OMMod` carries a `companion` flag; a `<parent>_hd` whose parent
is in `mods.map` is copied as content only - no dylibs, no `liblist.gam` rewrite,
no manifest check - still staged via `.partial` like everything else.

## Custom Game menu

`patch-mainui-modart.py` adds a preview image and description to the existing Custom
Game screen and stops it truncating titles at 32 characters.

The artwork cannot be read from the mod's own folder: while the engine is running
`valve`, the mod directory is not in the filesystem search path, so
`PIC_Load("bshift/game.tga")` finds nothing. Since v1.2.0 all banners and blurbs
are shipped INSIDE the game app instead, where the menu can always reach them:

```
Half-Life.app/Contents/Resources/Half-Life/valve/gfx/shell/mods/<gamedir>.tga
Half-Life.app/Contents/Resources/Half-Life/valve/gfx/shell/mods/<gamedir>.txt
```

That is the same location the menu's own art lives in, so no engine change is
needed - `COM_LoadFile` on a `gfx/shell/...` path is what `menus/Controls.cpp`
already does.

They used to be copied into the player's own `valve/gfx/shell/mods/` by the
installer. Shipping them in the app instead means we never write into the player's
game data, the artwork survives them replacing that folder, and it shows for a mod
installed by hand as well as one the installer put there. `make-universal.sh` copies
them from `installer/artwork/` and `installer/descriptions/`.
