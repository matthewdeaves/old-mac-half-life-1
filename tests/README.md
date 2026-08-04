# Tests

Two layers, split by what they need to run.

| | Needs | Runs |
|---|---|---|
| `test-repo.py` | a checkout and Python 3 | anywhere, and in CI on every push |
| `test-artifact.sh` | a Mac and a built `.dmg` | by hand before cutting a release |

```sh
python3 tests/test-repo.py -v
tests/test-artifact.sh dist/Half-Life-OldMac-v1.4.1.dmg
```

Both exit with the number of failed checks.

## Why these checks and not others

This project's failure mode is not a crash in a function. It is a build that
completes, an image that mounts, an app that launches on the machine in front of
you, and a claim somewhere that stopped being true. Several of those shipped.

Each check corresponds to a real defect:

- **Mod tables agree.** Xen Warrior shipped in v1.4.0 with its game code but no
  manifest row, no artwork and no description, so it installed unverified and
  appeared in Custom Game as a blank entry.
- **Every branch is pinned.** `sohl1.2` shipped with no commit recorded in
  `vendor/MANIFEST.md`, so that release could not be reproduced from the manifest.
- **Mod count is consistent.** v1.4.0's disk image and in-app help both said 24
  while the app installed 25.
- **No `ppc970` in shipped strings.** The slice was dropped in v1.4.0, but the
  System Report app still told a G5 owner they needed Leopard, which was the
  exact thing that release fixed. That app is what someone runs when the game
  will not start, so it was the worst place for it to be wrong.
- **`BUILD-INFO` matches `lipo`.** v1.4.0 declared four slices and carried three.
- **`BUILD-INFO` is not `+dirty`.** v1.4.0 was built from an uncommitted tree, one
  commit before the change that defined it.
- **Exact cpusubtypes, no generic `ppc (ALL)` executable slice.** Tiger and
  Leopard mis-grade a fat that mixes generic and specific PowerPC slices and
  refuse to exec on a 750 host, so this one is invisible until a G3 owner reports
  that nothing happens.
- **PowerPC slices carry no `LC_VERSION_MIN`, `x86_64` carries 10.7.** The
  PowerPC OS floor cannot be read off the binary at all, which is why it has to
  be established by comparing undefined symbols. See
  [ADR 0001](../docs/adr/0001-slices-are-chosen-by-cpu-capability.md).
- **Payload at the `valve/` level.** Above it, the rodir root is `FS_STATIC_PATH`,
  which `Host_CheckGameLibraries` cannot see, and the engine aborts with "missing
  game library" even though `dlopen` would have found the dylibs.
- **No `gameinfo.txt` or `liblist.gam` at the rodir root.** Either one registers a
  phantom Custom Game entry in the menu.
- **No `valve/` folder on the image.** We ship code, not content.
- **The menu dictionary is present and is shipped.** mainui's `L()` returns the
  key itself when the dictionary has no entry, so a missing dictionary does not
  degrade quietly: every `GameUI_*` token is drawn as its own name. Retail
  Half-Life ships no `resource/*_english.txt` and mainui bundles none, so nothing
  supplies these but us. The file existing and the copy step existing are two
  separate things, and having one without the other looks exactly like having
  neither.
- **The System Report app reaches lower than the game.** Its whole purpose is the
  machine nobody in the fleet owns, so an Intel floor equal to the game's makes
  it useless on precisely the two cases the game rules out. The test asserts
  three slices and the exact floors, because a silent revert to a single
  10.7 x86_64 slice would still mount, still launch here, and still look right.
- **Patch scripts are invoked, not merely named.** The wiring tests used to ask
  whether a script's filename appeared anywhere in a driver.
  `patch-mainui-miniutl-endian.py` passed on the strength of a comment in
  `build-ppc.sh` that said, in so many words, that the driver does not run it. A
  driver is now reduced to the text that executes (comments cut, heredoc bodies
  dropped, backslash continuations joined), split into shell words, and the name
  has to be the argument of an interpreter standing in command position. A
  self-test in the same file feeds the matcher a comment, an `echo` and a heredoc
  and asserts none of them count, so the hardening cannot rot back.
- **No patch script is an orphan.** `patch-mainui-*` and `patch-net-*` are the
  only families the wiring tests police by name. Everything else in
  `scripts/patch-*.py` is wired by one line in one driver, so losing that line
  leaves a file that is still in the tree, still in review, and no longer run.
  The orphan check asserts every patch script is invoked by some `scripts/*.sh`.
- **No em dashes.** A project convention, and shipped strings stay greppable with
  `strings`.

## What is not covered

Nothing here launches the game, so nothing here can tell you a slice actually
runs on the machine it was built for. That still needs the hardware: a G3 on
10.3.9, a G4 and a G5 on Tiger and Leopard, an Intel mini on Lion. These tests
narrow what hardware testing has to look for; they do not replace it.

There is also no test that a mod plays, only that its parts are present and the
right shape.
