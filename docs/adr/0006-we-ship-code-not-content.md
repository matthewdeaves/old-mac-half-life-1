# 6. We ship code, not content, and the code lives inside the app bundle

Date: 2026-07-27
Status: accepted

## Context

Half-Life's maps, models, sounds and WADs are Valve's; the mod content is the mod
authors', fetched at install time from each mod's own public release. None of it
is ours to redistribute, and none needs rebuilding: content is
architecture-neutral, and only the game code, about 3% of the bulk, is recompiled
(`docs/MODS.md`, "The shape of the problem").

Where our part goes is a separate question. A `valve/` folder on the image holding
our dylibs forces the player to merge it into theirs and gives them something of
ours to overwrite.

An engine constraint decides the rest. `Host_CheckGameLibraries` pre-checks the
libraries with `Platform_LibraryExists( path, true )`, and `gamedironly` restricts
that search to `FS_GAMEDIR_PATH | FS_CUSTOM_PATH | FS_GAMERODIR_PATH`. The
read-only root is `FS_STATIC_PATH`, so dylibs there are invisible to the check and
the engine aborts with "missing game library" though `dlopen` would have found
them (`scripts/make-app.sh`, header; `.claude/rules/shipped-layout.md`).

## Decision

**No content of any kind ships. Everything we build lives inside `Half-Life.app`,
at the read-only root's own `valve/` level.**

- The image carries `Half-Life.app`, `Half-Life Mods.app`,
  `Half-Life System Report.app`, `README.txt`, `BUILD-INFO.txt`, and no `valve/`
  at all (`.claude/rules/shipped-layout.md:12-14`, `scripts/make-dmg.sh:39-46`).
- Our game dylibs, `userconfig.cfg` and the Custom Game artwork go to
  `Half-Life.app/Contents/Resources/Half-Life/valve/`
  (`scripts/make-app.sh`).
- The engine mounts `Contents/Resources/Half-Life` as its read-only root
  (`fs_rodir`, found by `FS_AppleBundledGameRoot`); the writable root stays the
  folder containing the `.app` (`XASH3D_BASEDIR`), so saves and configs land in
  the player's folder (`scripts/make-app.sh`).
- The player drops their own untouched retail `valve/` beside the app, unmerged.
- Mod dylibs stay in `Half-Life Mods.app` and are installed beside each mod's
  content; the installer takes only content the user downloads themselves
  (`installer/README.md`).
- `installer/OMAbout.m` reads its one sound out of the player's own `pak0.pak`.

## Alternatives rejected

**Ship a `valve/` folder containing our dylibs**, as pre-v1.2.0 did. Installation
becomes a merge, it puts a folder named `valve` in front of a player who already
has one, and a leftover `hl_ppc.dylib` from an older release outranks the one
inside the app, the read-only root being the lowest-priority searchpath.
`scripts/deploy-dmg.sh` still removes those leftovers on the bench machines,
by name and never by sweep.

**Put the payload at the read-only root rather than one level down.** The engine
aborts with "missing game library" for the `FS_STATIC_PATH` reason above, even
though the dylibs are present and loadable.

**Symlink `Contents/Resources/Half-Life/valve` to the player's real `valve/`**,
the pre-v1.2.0 layout. The read-only root's `valve` then held the player's
`liblist.gam`, and `FS_InitStdio` registers a read-only directory as a game if it
holds `gameinfo.txt` or `liblist.gam`, so Custom Game showed a phantom second
entry (`scripts/make-app.sh`).

**Redistribute the mod content, freely mirrored anyway.** It is not ours, it is
several gigabytes, and our position on Valve's data would not survive an exception
for somebody else's.

## Consequences

**Gained**

- Installation is copying the app and putting a `valve/` folder next to it, and a
  newer build is a straight app swap: saves and settings are in the player's
  folder and survive it, and replacing that folder cannot delete our game code.
- The read-only root is the lowest-priority searchpath, so anything the player
  supplies still wins.
- Nothing we distribute contains anyone else's assets.

**Lost**

- The app cannot be tested without the player's data, and no runnable demo of any
  kind can ship.
- The layout depends on engine internals that are not visible in it. Moving the
  payload one directory either way breaks it, in one case with an error message
  that names the wrong problem.
- The mod installer has to exist, and to be a real application, because the
  content it needs is gigabytes of downloads it cannot include. ADR 0009 for what
  kind of application, ADR 0011 for where it fetches from.

**Risks accepted**

- With no `valve/` folder the failure is deep inside filesystem init, on a console
  nobody sees, then a quit with no window. The launcher checks for the folder
  first and says so in a dialog (`scripts/make-app.sh`), a workaround for
  engine behaviour we do not control.

## Notes

Both halves are checked mechanically, because both have shipped wrong.
`tests/test-artifact.sh:65-68` fails if a `valve` folder is on the image,
`:106-110` if the payload is not at `Contents/Resources/Half-Life/valve`,
`:114-116` if a `gameinfo.txt` or `liblist.gam` sits at the read-only root.
