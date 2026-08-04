# 6. We ship code, not content, and the code lives inside the app bundle

Date: 2026-07-27
Status: accepted

## Context

Half-Life's maps, models, sounds and WADs are Valve's. The mod content is the mod
authors' work, fetched at install time from each mod's own public release. None of it is ours to
redistribute, and none of it needs rebuilding for these machines: content is
architecture-neutral, and only the game code, about 3% of the bulk, has to be
recompiled (`docs/MODS.md:20-31`).

That settles what we may ship. It does not settle where our part goes. The
obvious layout, a `valve/` folder on the disk image holding our recompiled game
dylibs, forces the player to merge our folder into theirs, and gives them
something of ours to overwrite when they replace it.

There is also an engine constraint. `Host_CheckGameLibraries` pre-checks the game
libraries with `Platform_LibraryExists( path, true )`, and that `gamedironly` flag
restricts the search to `FS_GAMEDIR_PATH | FS_CUSTOM_PATH | FS_GAMERODIR_PATH`.
The read-only root itself is `FS_STATIC_PATH`, so dylibs sitting at that root are
invisible to the check and the engine aborts with "missing game library" even
though `dlopen` would have found them (`scripts/make-app.sh:161-167`).

## Decision

**No content of any kind ships. Everything we build lives inside
`Half-Life.app`, at the read-only root's own `valve/` level.**

- The disk image carries `Half-Life.app`, `Half-Life Mods.app`,
  `Half-Life System Report.app`, `README.txt` and `BUILD-INFO.txt`, and no
  `valve/` folder at all (`.claude/rules/shipped-layout.md:12-14`,
  `scripts/make-dmg.sh:39-46`).
- Our game dylibs, `userconfig.cfg` and the Custom Game artwork are installed at
  `Half-Life.app/Contents/Resources/Half-Life/valve/`
  (`scripts/make-app.sh:177-178`).
- The engine mounts `Contents/Resources/Half-Life` as its read-only root
  (`fs_rodir`, found by `FS_AppleBundledGameRoot`), while the writable root stays
  the folder containing the `.app` (`XASH3D_BASEDIR`), so saves and configs land
  in the player's own folder (`scripts/make-app.sh:92-93`).
- The player drops their own untouched retail `valve/` beside the app. Nothing is
  merged.
- Mod dylibs are not in the game app at all; they stay in `Half-Life Mods.app`
  and are installed beside each mod's content. The installer takes only content
  from the collection the user downloads themselves
  (`installer/README.md:13-24`).
- `installer/OMAbout.m` reads its one sound out of the player's own `pak0.pak`,
  because shipping the audio is not an option.

## Alternatives rejected

**Ship a `valve/` folder on the image containing our dylibs.** This is what
pre-v1.2.0 did. It makes installation a merge, it puts a folder named `valve` in
front of a player who already has one, and a leftover `hl_ppc.dylib` from an
older release outranks the one inside the app, because the read-only root is the
lowest-priority searchpath. `scripts/deploy-dmg.sh:113-118` still removes those
leftovers on the bench machines for exactly that reason.

**Put the payload at the read-only root rather than one level down.** The engine
aborts at startup with "missing game library", for the `FS_STATIC_PATH` reason
above, even though the dylibs are present and loadable.

**Symlink `Contents/Resources/Half-Life/valve` to the player's real `valve/`.**
The pre-v1.2.0 layout. It made the read-only root's `valve` contain the player's
`liblist.gam`, and `FS_InitStdio` registers a read-only directory as a game if it
holds `gameinfo.txt` or `liblist.gam`, so Custom Game showed a phantom second
entry (`scripts/make-app.sh:169-173`).

**Redistribute the mod content, which is freely mirrored anyway.** It is not
ours, it is several gigabytes, and the project's position on Valve's data would
not survive an exception for somebody else's.

## Consequences

**Gained**

- There is no install step beyond copying the app and putting a `valve/` folder
  next to it, and no way for a player to delete our game code by replacing their
  own folder.
- A newer build is a straight app swap. Saves and settings are in the player's
  folder and survive it.
- The read-only root is the lowest-priority searchpath, so anything the player
  supplies still wins.
- Nothing we distribute contains anyone else's assets.

**Lost**

- The app cannot be tested without the player's data, and there is no way to ship
  a runnable demo of any kind.
- The layout depends on engine internals that are not obvious from looking at it.
  Moving the payload one directory in either direction breaks it, in one case
  with an error message that names the wrong problem.
- The mod installer has to exist at all, and has to be a real application,
  because the content it needs is gigabytes of downloads it cannot include. See
  ADR 0009 for what kind of application, and ADR 0011 for where it fetches from.

**Risks accepted**

- The failure mode when a player has no `valve/` folder is deep inside filesystem
  init, on a console nobody sees, followed by a quit with no window. The launcher
  checks for the folder first and says so in a dialog instead
  (`scripts/make-app.sh:119-124`), which is a workaround for an engine behaviour
  we do not control.

## Notes

Both halves of this are checked mechanically, because both have shipped wrong.
`tests/test-artifact.sh:65-68` fails if a `valve` folder is on the image;
`:106-110` fails if the payload is not at
`Contents/Resources/Half-Life/valve`; `:114-116` fails if a `gameinfo.txt` or
`liblist.gam` sits at the read-only root.
