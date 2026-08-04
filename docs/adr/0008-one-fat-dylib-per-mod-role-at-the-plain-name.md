# 8. Mod game code ships as one fat dylib per role, at the plain name

Date: 2026-07-27
Status: accepted

## Context

25 mods are supported, each needing two pieces of game code: a server library and
a client library. The content is the user's; only the code is ours to build
(ADR 0006).

Xash names game libraries per architecture, through `3rdparty/library_suffix`:
`dlls/bshift_amd64.dylib`, `cl_dlls/client_ppc.dylib`. Followed literally, each
mod folder would need one file per architecture per role, and the installer would
have to write different filenames on different machines.

The mods' existing Mac releases do not use those names. They ship
`dlls/<mod>.dylib`, the plain name written in the mod's own `liblist.gam`, which
is the only name the engine actually consults for a mod
(`scripts/patch-gamedll-plain-name.py:9-17`).

## Decision

**Build each mod's code twice, `lipo` the two slices into one fat
`ppc + x86_64` file per role, and install it at the plain name from
`liblist.gam`.**

- `scripts/build-mod.sh:365-366` produces `server.dylib` and `client.dylib`, each
  fat.
- The engine has to accept the plain name, on both sides. `SV_InitGame()` retries
  `COM_GetGameDllPathFromGameInfo()` when the suffixed server dylib misses, and
  `CL_Init()` gets the mirror-image fallback, because it called `Host_Error` on
  the first failure with no retry at all. One commit on our engine branch.
- Both are strictly fallbacks. The arch-suffixed name is tried first and wins if
  present, so the existing `valve/` layout keeps working untouched
  (`patch-gamedll-plain-name.py:26-28`).
- One generic `ppc` slice covers the G3, G4 and G5: game code is loaded with
  `dlopen`, which grades a `ppc (ALL)` slice correctly on a 750 host. Only the
  engine executable needs an exact cpusubtype (`scripts/build-mod.sh:41-45`,
  `.claude/rules/build-verification.md:36-45`).
- Builds are keyed by hlsdk branch with generic filenames, and the installer does
  the final naming from the mod's own `liblist.gam`, rewriting `gamedll_osx` so
  it always names what was actually put on disk (`scripts/build-mod.sh:17-28`,
  `docs/MODS.md:167-181`).

## Alternatives rejected

**Ship arch-suffixed files, as Xash intends.** Four game dylibs per mod folder,
100 files across 25 mods, all of which the installer would have to place and the
user would have to keep. Installing a mod would stop being an overwrite of what
its own release ships.

**Name the output from the branch's `mod_options.txt`.** Rejected on evidence: a
branch's declared gamedir and library name do not always match what the mod
actually ships. `residual_point` declares `rp_pub` / `rp.dylib` and ships `rp/`
with `survivor.dylib`; `caseclosed` declares `caseclosed` and ships `cc/`; `CAd`
declares `CAd` and ships `cad/` (`scripts/build-mod.sh:21-24`). A dylib at the
branch's name is a dylib the engine never looks for.

**Build one server dylib and reuse it for several mods.** A mod's game code is
for that mod only, and the trap is concrete: `eftd` renumbers the
`func_breakable` `spawnobject` list, so indices 12 to 21 all shifted when python,
gauss and hornetgun were removed. Its own maps are authored against the new list;
a stock map asking for `spawnobject 12` would get an RPG instead of the .357
(`docs/MODS.md:183-195`).

**Have the installer rename per architecture at install time.** It would make the
installed folder machine-specific, so a folder copied between a PowerPC and an
Intel Mac would stop working, and it gives up the property that a fat file
already has.

## Consequences

**Gained**

- One file per role per mod, loading on the G3, G4, G5 and Intel alike.
- Installing a mod's code is a straight overwrite of the filename its own release
  already uses, on any platform's release of it.
- The existing `valve/` layout and the suffixed names still work; nothing changes
  unless the suffixed lookup fails.

**Lost**

- The engine patch has to be carried forever, in both trees, as four separate
  idempotent edits. Each edit is applied only if absent, so on a pin bump an edit
  whose anchor has moved silently does nothing, and the failure appears as a mod
  that will not load rather than as a build error.
- A mod installed by this project needs an engine carrying the patch. A stock
  mainline Xash finds no suffixed file and, on the client side, calls
  `Host_Error`.
- The naming decision is split across two places: `build-mod.sh` produces generic
  names and the installer resolves the real one. Neither half is complete on its
  own.

**Risks accepted**

- `installer/mods.map` is the only link from a content gamedir to a build branch,
  and a mod present in the map but missing from the other three tables installs
  unverified. Xen Warrior shipped that way in v1.4.0 and appeared in Custom Game
  as a blank entry, which is why `tests/test-repo.py` now checks all four tables
  agree (`.claude/rules/shipped-layout.md:46-50`).

## Notes

Switching mods is a separate problem with a separate fix. Picking a mod in Custom
Game makes the engine re-exec itself with a new `-game`, and Darwin refuses
`execve()` from a process with more than one thread, returning `ENOTSUP`, so on
PowerPC it silently did nothing and left a live process with no window.
`scripts/patch-sys-newinstance-fork.py` adds `Sys_RestartExec()`: try the direct
exec, and if it returns, `fork()` and exec from the child, which is
single-threaded by construction. A close-on-exec pipe tells the parent which
happened, so a genuine failure is still reported (`docs/MODS.md:56-100`).
