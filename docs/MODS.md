# Mod support

How Half-Life mods run on the old-Mac port, and how to rebuild them.

## Credit where it belongs

The mod **content** is its authors' work and this project supplies none of it.
Each mod is fetched at install time from that mod's own public release: mostly
[runthinkshootlive.com](https://www.runthinkshootlive.com), Phillip's long-running
Half-Life single-player archive, and [archive.org](https://archive.org) for the
rest. `installer/mod-sources.txt` records the URL, format, size, md5 and subtree
for every one, and the reason for each of the seven that have no usable source.

We add the game code only, rebuilt for **PowerPC** and 64-bit Intel from each
mod's own source branch; the only other Mac builds are i386 and need 10.5.8+.

## The shape of the problem

| part | what it is | size | who supplies it |
|---|---|---|---|
| content | maps, models, sounds, sprites, wads, `liblist.gam` | ~3.96 GB across 25 mods | the user |
| game code | `dlls/<mod>.dylib` + `cl_dlls/client.dylib` | ~130 MB | **us** |

Content is architecture- and OS-neutral: a Windows release has byte-identical maps
and models, and the engine derives the Mac dylib name from a Windows `gamedll` line
(`filesystem.c`). Only the code is rebuilt, ~3% of the bulk.

## One fat dylib per role

Xash normally loads game code by **arch-suffixed** name
(`dlls/bshift_amd64.dylib`, `cl_dlls/client_ppc.dylib`), one file per
architecture. We ship one, because the engine also accepts the **plain** name from
the mod's own `liblist.gam`: `SV_InitGame()` (`engine/server/sv_init.c`) tries the
suffixed name then retries `COM_GetGameDllPathFromGameInfo()`, and `CL_Init()`,
which had no retry and called `Host_Error` on the first failure, gets the
mirror-image fallback. Both are one commit on our engine branch, `mods: load game
code from liblist.gam's plain name as well as the suffixed one`.

`lipo`-ing the two slices into `dlls/bshift.dylib` gives one file that loads on G3,
G4, G5 and Intel, under the exact filename existing Mac mod releases use, so
installing is a straight overwrite. The suffixed layout still works, `valve/` is
untouched, and the fallback fires only when the suffixed name is missing. One
generic `ppc` slice covers all three PPC machines: `dlopen()` grades a `ppc (ALL)`
slice correctly on a 750, and only the engine *executable* needs an exact
cpusubtype (the ppc750 re-stamp in `build-ppc-panther.sh`).

## Switching mods: fork before you exec

Picking a mod in Custom Game re-execs the engine with a new `-game`. On PowerPC it
printed `execv(.../Contents/MacOS/xash3d.bin) failed: Operation not supported` and
left a live windowless process needing a force-quit.

**Darwin refuses `execve()` from a process with more than one thread**, returning
`ENOTSUP` (errno 45) rather than replacing the image. Measured on a G4 under
10.4.11 with a purpose-built test binary:

```
threads created: 0 -> exec succeeded
threads created: 4 -> execv FAILED: Operation not supported (errno 45)
```

`Sys_NewInstance()` runs after `Host_Shutdown`, but SDL's helper threads are still
alive, so the exec was refused every time. Two plausible culprits are **not** to
blame. Not the path: the engine already retried with `host.argv[0]`, both attempts
resolving to the same `xash3d.bin`, both failing identically. Not fat-binary
grading: the same fat binary `execv`s fine from an ordinary process on that
machine, generic `ppc` or `ppc7400` (the real Tiger fat-mis-grading bug in
`CLAUDE.md` is the obvious suspect and is not the cause).

Fix: `Sys_RestartExec()`, one commit on our engine branch, `mods: fork before exec
so "change game" can actually restart the engine`. Try the direct exec; if it
returns, `fork()` and exec from the child, single-threaded by construction. A
close-on-exec pipe tells the parent which happened, so it stands down only on real
success and a child that could not exec is still a reported failure. On hardware,
valve → gearbox re-execs in about a second and the new process logs
`FS_AddGameHierarchy( gearbox )` and brings up video.

## Big-endian: what a mod tree does and does not get

Mod game code builds from `FWGS/hlsdk-portable` mainline for **every** slice,
PowerPC included. Mainline carries the endian work: save/restore swaps centrally in
`CSave::BufferData()` via a `typesize` parameter rather than at every call site,
and `dlls/nodes.cpp` / `dlls/nodes_compat.h` are fully handled. All 25 mod branches
carry it.

**No studio-model byte swap is applied to a mod tree.** The engine already swaps
studio animation offsets and values as it loads the model, so a swap in the
client's `StudioModelRenderer.cpp` on top of that is a second swap, and a second
swap is the identity undone. It crashed the base game on map load until it was
removed: `docs/port/PPC-PORT-NOTES.md`.

## Building

On an Intel Lion mini (claim one with `scripts/pick-build-host.sh --acquire mods`):

```sh
./scripts/build-mod.sh --all        # or: ./scripts/build-mod.sh bshift opfor
./scripts/build-installer.sh        # bundles dist/mods/ into Half-Life Mods.app
```

Output is `dist/mods/<branch>/{server,client}.dylib` plus a `mod.info` recording
the branch, upstream commit and build time. Each branch is self-describing via its
`mod_options.txt`, so one driver handles all of them.

Every build is verified three ways, because waf can exit 0 with a failed compile
task and then install stale objects: log grepped for `Build failed`, artifacts
confirmed newer than the build start, `lipo -info` asked what is inside.
`.claude/rules/build-verification.md`.

### Things that bite on these machines

`CLAUDE.md` has the general Lion traps. On top of those:

- **The local mirror stays the source of truth**, even though the minis now carry
  OpenSSL 3.5.7 / curl 8.21 / git 2.55 under `~/local` and can reach GitHub.
  `vendor/hlsdk-portable-mirror.git` is preferred automatically: pinned commits are
  in `vendor/MANIFEST.md`, 57 branches clone from a local path in seconds, it works
  offline, and the PPC bench boxes still have no TLS. Refresh with
  `git -C vendor/hlsdk-portable-mirror.git remote update` from a modern Mac.
- **The build scripts put the Xcode toolchain first on `PATH`**, so the git they
  see is Xcode's 1.7.12.4 even though `~/local/bin` wins for a plain `ssh mini git`.
  That order must not be reversed: Lion's
  `/usr/bin/{install_name_tool,lipo,strings}` are stale stubs that choke on modern
  Mach-O load commands.
- **hlsdk assumes darwin implies clang.** darwin/ppc is gcc-4.0, which gets
  GNU-only `-Wl,--no-undefined`; Apple's ld rejects it and configure fails with a
  bare `Checking for required C flags : no`. `patch-hlsdk-ppc-darwin.py` drops it.
- **`--disable-altivec` is an engine option, not an hlsdk one.** Passing it makes
  hlsdk's configure print help and leave the project unconfigured.
- **gcc-4.0 is stricter than the clang used for x86_64.** Two standards-correct
  fixes in `patch-hlsdk-mod-gcc4.py`: a pointer-to-member comparison across classes
  in Spirit-derived mods (`echoes`, `halloween`), and a missing `typename` on a
  dependent type in `dmc`'s bundled ministl.

## Naming: trust `liblist.gam`, not the branch

A branch's `mod_options.txt` does **not** always match what the mod ships:

| branch | branch declares | mod actually ships |
|---|---|---|
| `residual_point` | `rp_pub` / `rp.dylib` | `rp/` + **`survivor.dylib`** |
| `caseclosed` | `caseclosed` | `cc/` |
| `CAd` | `CAd` | `cad/` |

So builds are keyed by **branch** with generic names (`server.dylib`,
`client.dylib`) and the installer does the final naming from the mod's own
`liblist.gam`, the only thing the engine consults. `installer/mods.map` maps a
content gamedir to its branch, and the installer rewrites `gamedll_osx` in the
installed `liblist.gam` so it names what is actually on disk.

## A mod's server dylib is for that mod only

`eftd` renumbers the `func_breakable` `spawnobject` list in `dlls/func_break.cpp`:
indices 12-21 all shifted when python, gauss and hornetgun were removed. Its own
maps were authored against the renumbered list, but a **stock** map asking for
`spawnobject 12` expects the .357 and would get an RPG.

The shipped layout cannot cause this: each mod's dylibs sit beside that mod's own
content and `valve/` is never given a mod's code. Written down so that "why not
reuse one server dylib" is answered before it is tried, and so the renumbering is
not mistaken for a bug and "fixed" back.

## The installer app

`installer/` builds **Half-Life Mods.app**: native Cocoa, fat ppc + x86_64,
`LSMinimumSystemVersion 10.3.0`.

Cocoa rather than Carbon because Carbon was never ported to 64-bit and so cannot
produce our x86_64 slice; rather than SDL because this should look like a Mac app.
Downloading is hand-written HTTP/1.1 with `Range:` resume over raw sockets, with
mbed TLS 3.6 built into both slices; NSURLConnection was not used because its byte
counters are 32-bit, the same flaw that makes the engine's own HTTP client unusable
here (`httpfile_t.size` is an `int`). `installer/README.md` covers the networking
and the 10.3-era Cocoa rules in full.

### What it refuses to copy

A mod folder packaged by running the mod on someone else's Mac carries that
machine's runtime state. Skipping it is a correctness feature:

| skipped | why |
|---|---|
| `video.cfg` | `fullscreen "1"`, `height "1200"`, `vid_highdpi "1"`: another machine's display state, from an `apple-i386` build. The engine execs `video.cfg` then applies `-width`/`-height`, which the launcher passes only on the G3 and Panther profiles, so elsewhere a leftover `video.cfg` is the mode the engine starts in. `vid_highdpi` is not a cvar in the engine we build. |
| `config.cfg` | the packager's keybinds, reported in the wild as "arrows don't work, only WASD" |
| `opengl.cfg`, `keyboard.cfg` | tuning for hardware two decades newer |
| `save/`, `SAVE/` | their savegames; saves are native-endian, so i386 saves are garbage on PPC |
| `*.bak`, `.xash_id` | engine backups and per-install identity |
| `dlls/`, `cl_dlls/`, `dlls 2/`, `cl_dlls 2/` | i386 game code we replace, plus packaging duplicates |

~99 MiB per full install, and the mod's *own* config (`skill.cfg`, `default.cfg`,
`server.cfg`, class and map cfgs) is kept. `installer/manifests.txt` records the
expected file and byte count per mod after those exclusions and the installer
verifies its own work against it; a mod is staged under `<gamedir>.partial` and
moved into place only once it passes, so an interrupted run never leaves a
half-copied folder that Custom Game would list.

### What is skipped, and why it is not a failure

A full run reports three skipped folders. Only Team Fortress Classic is a mod we
cannot support; the other two are German localisations, and `OMSkipReason()` names
each one rather than saying "no build shipped" for all of them.

| skipped | what it is |
|---|---|
| `tfc`, `tfc_german` | Team Fortress Classic: the shipped dylib is i386 and there is no source to rebuild it from. FWGS deleted its `tfc` branch; 43 forks still carry it and all 19 TFC server `.cpp` files in it are zero bytes. Velaron/tf15-client is client-only by design, Toodles2You/tfc needs C++17 and i386-only Steam/VGUI binaries, and Valve never released TFC source. Closed as not achievable, issue #13 |
| `gearbox_german` | a whole German localisation of a game we install in English: content only, deliberately not installed |

`bshift_hd` and `gearbox_hd` used to be in that list and **are now installed**. They
are not mods: `models/`, `sound/`, `sprites/`, no game code. The engine mounts them
over their parent, so a gearbox launch logs `FS_AddGameHierarchy( gearbox )` then
`Adding directory: gearbox/` and `Adding directory: gearbox_hd/`; skipping them
silently cost the HD models for Blue Shift and Opposing Force, for 21 MB. `OMMod`
carries a `companion` flag; a `<parent>_hd` whose parent is in `mods.map` is copied
as content only, with no dylibs, no `liblist.gam` rewrite and no manifest check,
still staged via `.partial`.

## Custom Game menu

One commit on our menu branch, `Custom Game: show each mod its own artwork and
description`, adds a preview image and description to the existing screen and stops
it truncating titles at 32 characters.

The artwork cannot be read from the mod's own folder: while the engine is running
`valve` the mod directory is not in the filesystem search path, so
`PIC_Load("bshift/game.tga")` finds nothing. Since v1.2.0 all banners and blurbs
ship INSIDE the game app, at
`Half-Life.app/Contents/Resources/Half-Life/valve/gfx/shell/mods/<gamedir>.tga`
and `.txt`, copied there by `make-universal.sh` from `installer/artwork/` and
`installer/descriptions/`. That is where the menu's own art lives, so no engine
change is needed: `COM_LoadFile` on a `gfx/shell/...` path is what
`menus/Controls.cpp` already does.

The installer used to copy them into the player's own `valve/gfx/shell/mods/`.
Shipping them in the app means we never write into the player's game data, the
artwork survives them replacing that folder, and it shows for a hand-installed mod
too.
