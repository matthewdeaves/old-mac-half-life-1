# Tests

Three layers, split by what they need to run.

| | Needs | Runs |
|---|---|---|
| `test-repo.py` | a checkout and Python 3 | anywhere, and in CI on every push |
| `test-artifact.sh` | a Mac and a built `.dmg` | by hand before cutting a release |
| `test-mod-dylibs.sh` | a Mac and a folder of mod dylibs | on each machine in the fleet |

```sh
python3 tests/test-repo.py -v
tests/test-artifact.sh dist/Half-Life-OldMac-v1.4.1.dmg
tests/test-mod-dylibs.sh dist/mods
tests/test-mod-dylibs.sh "/path/to/Half-Life Mods.app/Contents/Resources/mods"
```

The first two exit with the number of failed checks.

`test-mod-dylibs.sh` is deliberately a different SHAPE from the other two: it is
the only test here whose answer depends on which machine runs it. `dlopen` only
ever hands back the slice for the CPU it is running on, so the same command
tests the `ppc` slice on a G4, the `i386` slice on a Core Duo and the `arm64`
slice on Apple Silicon. It is worth running on each in turn, and none of them
can answer for the others.

It exists because `lipo` answers the wrong question. `lipo` says whether a slice
for this architecture is present, which is what the build drivers already check.
It cannot say whether `dyld` will accept the file, or whether the entry point
the engine looks up is in it. Those come apart: mod dylibs once shipped at
version-min 10.7 beside a 10.6 game, and on 10.6 every slice was present and
correct and no mod would load.

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
- **PowerPC slices carry no `LC_VERSION_MIN`, the Intel slices carry 10.6.** The
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
  it useless on precisely the cases the game rules out. The test asserts four
  slices (`ppc i386 x86_64 arm64`) and the exact floors, 10.4 for `i386` and
  10.5 for `x86_64`, because a silent revert to a single high-floor slice would
  still mount, still launch here, and still look right.
- **Patch scripts are invoked, not merely named.** The wiring tests used to ask
  whether a script's filename appeared anywhere in a driver.
  `patch-mainui-miniutl-endian.py` passed on the strength of a comment in
  a retired driver that said, in so many words, that it does not run it.
  Whole-line comments are now stripped before matching. That check was a
  quote-aware shell tokenizer for a while; an adversarial review measured the
  tokenizer against the simple version across every patch and driver pairing
  and found zero disagreements, so the tokenizer came out again. The comment
  block above `shell_commands` in `test-repo.py` records the measurement and
  the one shape the naive version would miss.
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
