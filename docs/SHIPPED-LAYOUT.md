# Shipped layout: where everything sits and why it cannot move

The disk image carries three app bundles and no `valve/` folder. Our payload lives inside `Half-Life.app` at the `valve/` level of the engine's
read-only root, and the player's own retail `valve/` sits beside the app. This page holds the mechanisms behind the one-line rules in
`.claude/rules/shipped-layout.md`: the deployed-folder shape, why loose dylibs beat the bundle, why the payload level matters, and how phantom
Custom Game entries appear. Engine file and line references were recorded against the engine pin at the time; grep the function names, the line
numbers drift.

## What ships, and where the engine looks

The disk image carries `Half-Life.app`, `Half-Life Mods.app` and
`Half-Life System Report.app`, plus `README.txt` and `BUILD-INFO.txt`. Everything we build
lives at `Half-Life.app/Contents/Resources/Half-Life/valve/` (game dylibs,
`userconfig.cfg`, the first-run `config.cfg` with WASD binds, Custom Game artwork). The
engine mounts `Contents/Resources/Half-Life` as its READ-ONLY root (`fs_rodir`, found by
`FS_AppleBundledGameRoot`); the writable root stays the folder containing the `.app`
(`XASH3D_BASEDIR`), so saves and configs land in the player's folder. Nothing is merged and
there is nothing of ours for the player to overwrite. `docs/adr/0006`

## A deployed folder holds the app bundles and the player's valve/, nothing else

`~/Desktop/Half-Life` on a bench or build machine is a deployed game:

```
Half-Life/
  Half-Life.app                 ours, self-contained
  Half-Life Mods.app            ours, self-contained
  Half-Life System Report.app   ours, self-contained
  valve/                        theirs, retail data, never touched
  <mod gamedirs>/               theirs, installed by Half-Life Mods.app
  last-run.log                  written by the launcher
```

## Build spill beats the bundle

A loose `xash3d`, `libxash.dylib`, `libmenu.dylib`, `libref_gl.dylib`, `libref_soft.dylib`,
`filesystem_stdio.dylib` or `libSDL2-2.0.0.dylib` beside the bundle is **build spill**: since
v1.2.0 every one of those lives inside `Half-Life.app/Contents/MacOS/`. Both Intel minis
carried a set from 25 July 2026, left by `build-lion.sh` when its play-folder default was
still `~/Desktop/Half-Life` (fixed in 45d367e, "build-lion.sh: stage the play folder off the
Desktop").

Spill is loaded in preference to the bundle. The engine loads the renderer and the menu with
`COM_LoadLibrary( name, false, /*directpath*/ true )`, which reaches `FS_FindLibrary` ->
`FS_AllowDirectPaths( true )` -> `FS_FindFile( ..., FS_EXEC_PATH )`. No searchpath holds a
bare `libref_gl.dylib`, so the lookup falls through to the `fs_ext_path` branch in
`filesystem/searchpath.c` (recorded as line 836), which tries `fs_rootdir/<name>` and takes it
if the file exists. `fs_rootdir` is `XASH3D_BASEDIR` (`filesystem_engine.c:266`), which the
launcher sets to the folder containing the `.app`. So a stale `libref_gl.dylib` or
`libmenu.dylib` on the Desktop wins over the one in the bundle, silently, the way a leftover
`hl_ppc.dylib` in `valve/` used to.

`filesystem_stdio.dylib` is the exception: `FS_LoadProgs` runs (`filesystem_engine.c:370`)
before `SetCurrentDirectory` (`:377`) and before any searchpath exists, so it resolves through
`DYLD_LIBRARY_PATH` to the bundle.

## Where build output goes, and who may delete spill

Build output goes under `dist/`, the one directory `.gitignore` covers; no script writes
anything to a Desktop. `build-lion.sh` stages its runnable tree at `dist/lion-play`, the
PowerPC drivers stage at `dist/ppc-{panther,tiger}-app`, `make-universal.sh` fuses to
`dist/universal`, and the wrapped bundle goes to `dist/universal-app`, which `make-dmg.sh`
fetches.

Deleting spill is a hand operation, deliberately. `deploy-dmg.sh` NAMES what it finds and
leaves it alone. It prunes only the specific game-code files an older release put inside the
player's `valve/`, by name, because those would shadow the app. It must never grow a general
sweep of a folder full of somebody's content: that folder holds gigabytes nobody can
regenerate, and the deletion that would fix this in one line already cost installed mods once.

## The payload must be at the valve/ level, not the rodir root

`Host_CheckGameLibraries` pre-checks the libraries with `Platform_LibraryExists( path, true )`,
and `gamedironly` restricts that to `FS_GAMEDIR_PATH | FS_CUSTOM_PATH | FS_GAMERODIR_PATH`.
The rodir ROOT is `FS_STATIC_PATH`, so dylibs placed there are invisible to that check and the
engine aborts with "missing game library" even though `dlopen` would have found them.

## No phantom Custom Game entry

`FS_InitStdio` only registers a rodir directory as a game if it holds `gameinfo.txt` or
`liblist.gam`, and ours holds neither. The pre-v1.2.0 layout DID create a phantom entry,
because that path was a symlink to the player's real `valve/`.

The rodir is the LOWEST-priority searchpath, so anything the player supplies still wins. That
is also why `deploy-dmg.sh` removes game dylibs an older release left in the player's
`valve/`: a leftover `hl_ppc.dylib` there outranks the one inside the app and would silently
keep being loaded.

## Mod dylibs and the installer's registry

Mod dylibs stay in `Half-Life Mods.app` and are installed beside each mod's content.

Every mod needs an entry in `installer/mods.map`, artwork in `installer/artwork/` and a blurb
in `installer/descriptions/`. Xen Warrior shipped in v1.4.0 with only the first, so it
installed unverified and appeared in Custom Game as a blank entry.

A row in `installer/manifests.txt` is required only for a mod we FETCH. A manifest row is the
expected result of unpacking a known archive, so it can only exist where there is an archive;
the seven mods with no automatable source have none, deliberately. `tests/test-repo.py` checks
that every mod in `installer/mod-sources.txt` has a row and that no mod without a source has
one.

## Nothing beside the app may hold a liblist.gam

`FS_ParseGameInfo` (`filesystem/gameinfo.c`) builds `<dir>/liblist.gam` for every directory
`FS_InitStdio` finds and registers the ones where it exists, and `listdirectory`
(`filesystem/sys.c`) does not skip dotted names. So an interrupted install used to leave
`xenwar.staging` in the Custom Game list. The installer now unpacks inside a single
`.om-staging/` container, which has no `liblist.gam` of its own, and sweeps that plus any
stray `*.partial` before every run.
