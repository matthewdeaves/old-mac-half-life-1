# 8. Mod game code ships as one fat dylib per role, at the plain name

Date: 2026-07-27
Status: accepted

## Context

25 mods are supported, each needing a server library and a client library. The
content is the user's; only the code is ours to build (ADR 0006).

Xash names game libraries per architecture, through `3rdparty/library_suffix`:
`dlls/bshift_amd64.dylib`, `cl_dlls/client_ppc.dylib`. Followed literally, each
mod folder needs one file per architecture per role and the installer writes
different filenames on different machines. The mods' Mac releases instead ship
`dlls/<mod>.dylib`, the plain name in the mod's own `liblist.gam`, which is the
only name the engine consults for a mod.

## Decision

**Build each mod's code once per architecture, `lipo` the slices into one fat
`ppc + i386 + x86_64 + arm64` file per role, and install it at the plain name
from `liblist.gam`.**

- `scripts/build-mod.sh` produces fat `server.dylib` and `client.dylib`. `arm64`
  is built separately on the orchestration box (`build-mod-arm64.sh`), carried
  over by `push-mod-arm64.sh` and fused by `fuse-mod-arm64.sh`, for the reason
  in ADR 0001's amendment.
- **Four slices, not the game's five.** The game's fifth is only the
  `ppc750`/`ppc7400` split, which these do not need: `dlopen` grades a generic
  `ppc (ALL)` slice correctly on a 750 host.
- A commit on our engine branch accepts the plain name on both sides:
  `SV_InitGame()` retries `COM_GetGameDllPathFromGameInfo()` when the suffixed
  server dylib misses, and `CL_Init()` gets the mirror-image fallback, having
  called `Host_Error` on the first failure with no retry at all. Both are
  fallbacks only: the arch-suffixed name is tried first and wins if present, so
  the existing `valve/` layout is untouched.
- One generic `ppc` slice covers the G3, G4 and G5: game code is loaded with
  `dlopen`, which grades a `ppc (ALL)` slice correctly on a 750 host, and only
  the engine executable needs an exact cpusubtype
  (`.claude/rules/build-verification.md`).
- Builds are keyed by hlsdk branch with generic filenames; the installer names
  the file from the mod's own `liblist.gam` and rewrites `gamedll_osx` to match
  what it put on disk (`scripts/build-mod.sh:17-28`; `docs/MODS.md`, "Naming:
  trust `liblist.gam`, not the branch").

## Alternatives rejected

- **Arch-suffixed files, as Xash intends.** One game dylib per architecture per
  role in every mod folder, hundreds of files across 25 mods, and installing a
  mod stops being an overwrite of what its own release ships.
- **Naming from the branch's `mod_options.txt`.** A branch's declared gamedir and
  library name do not always match what the mod ships: `residual_point` declares
  `rp_pub` / `rp.dylib` and ships `rp/` with `survivor.dylib`; `caseclosed`
  declares `caseclosed` and ships `cc/`; `CAd` declares `CAd` and ships `cad/`
  (`scripts/build-mod.sh:21-24`). A dylib at the branch's name is one the engine
  never looks for.
- **One server dylib reused across mods.** `eftd` renumbers the `func_breakable`
  `spawnobject` list, shifting indices 12 to 21 when python, gauss and hornetgun
  were removed. Its maps are authored against the new list, so a stock map asking
  for `spawnobject 12` gets an RPG instead of the .357 (`docs/MODS.md`, "A
  mod's server dylib is for that mod only").
- **Renaming per architecture at install time.** The installed folder becomes
  machine-specific, so a folder copied between a PowerPC and an Intel Mac stops
  working.

## Consequences

- One file per role per mod, loading on the G3, G4, G5, both Intel classes and
  Apple Silicon, installed as a straight overwrite of the filename the mod's own
  release already uses on any platform. Nothing changes for the suffixed names or
  the existing `valve/` layout unless the suffixed lookup fails.
- The engine change is carried on our branch as long as the port exists: a mod
  installed by this project needs an engine carrying it, and a stock mainline
  Xash finds no suffixed file and, on the client side, calls `Host_Error`.
- Naming is split between `build-mod.sh`, which produces generic names, and the
  installer, which resolves the real one. Neither half is complete alone.
- Risk: `installer/mods.map` is the only link from a content gamedir to a build
  branch, and a mod in the map but missing from the other three tables installs
  unverified. Xen Warrior shipped that way in v1.4.0 and appeared in Custom Game
  as a blank entry, so `tests/test-repo.py` now checks all four tables agree
  (`.claude/rules/shipped-layout.md`).

## Notes

Switching mods is a separate problem with a separate fix. Picking a mod in Custom
Game re-execs the engine with a new `-game`, and Darwin refuses `execve()` from a
multi-threaded process with `ENOTSUP`, so on PowerPC it silently did nothing and
left a live process with no window. A commit on our engine branch adds
`Sys_RestartExec()`: try the direct exec, and if it returns, `fork()` and exec
from the single-threaded child, with a close-on-exec pipe telling the parent
which happened so a genuine failure is still reported (`docs/MODS.md`,
"Switching mods: fork before you exec").
