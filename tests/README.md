# Tests

Four layers, split by what they need to run.

| | Needs | Runs |
|---|---|---|
| `test-repo.py` | a checkout and Python 3 | anywhere; CI also runs it on every push, free on a public repo |
| `test-artifact.sh` | a Mac and a built `.dmg` | by hand before cutting a release |
| `test-mod-dylibs.sh` | a Mac and a folder of mod dylibs | on each machine in the fleet |
| `test-frame.sh` | a deployed game on a fleet machine | after a renderer change, on one machine per class |

```sh
python3 tests/test-repo.py -v
tests/test-artifact.sh dist/Half-Life-OldMac-v<version>.dmg
tests/test-mod-dylibs.sh dist/mods
tests/test-mod-dylibs.sh "/path/to/Half-Life Mods.app/Contents/Resources/mods"
tests/test-frame.sh quicksilver
tests/frame-check.py some-screenshot.png
```

The first two exit with the number of failed checks.

`test-mod-dylibs.sh` is deliberately a different SHAPE from the other two: it is
the only test here whose answer depends on which machine runs it. `dlopen` only
ever hands back the slice for the CPU it is running on, so the same command
tests the `ppc` slice on a G4, the `i386` slice on a Core Duo and the `arm64`
slice on Apple Silicon. Run it on each in turn; none of them can answer for the
others.

`lipo` says whether a slice for an architecture is present, which the build
drivers already check. It cannot say whether `dyld` will accept the file, or
whether the entry point the engine looks up is in it. Those come apart: a
version-min above the host OS leaves every slice present and correct and no mod
loading.

## Why these checks and not others

Each check corresponds to a real defect that shipped or nearly did.

- **Mod tables agree.** A mod with game code but no manifest row, artwork or
  description installs unverified and appears in Custom Game as a blank entry.
- **Every branch is pinned.** A branch with no commit in `vendor/MANIFEST.md`
  cannot be reproduced from the manifest.
- **Mod count is consistent.** The disk image, the in-app help and the number of
  mods the app installs must agree.
- **No `ppc970` in shipped strings.** There is no `ppc970` slice, so no shipped
  text may tell a G5 owner they need Leopard. The System Report app is what
  someone runs when the game will not start, so it is the worst place to be
  wrong.
- **`BUILD-INFO` matches `lipo`.** The slices declared must be the slices
  carried.
- **`BUILD-INFO` is not `+dirty`.** A release must build from a committed tree.
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
- **The System Report app reaches lower than the game.** An Intel floor equal to
  the game's makes it useless on precisely the cases the game rules out. The test
  asserts four slices (`ppc i386 x86_64 arm64`) and the exact floors, 10.4 for
  `i386` and 10.5 for `x86_64`, because a silent revert to a single high-floor
  slice would still mount, still launch here, and still look right.
- **Patch scripts are invoked, not merely named.** Whole-line comments are
  stripped before matching, so a comment that names a script does not count as
  wiring. The matcher is deliberately the simple version, not a shell tokenizer:
  the comment block above `shell_commands` in `test-repo.py` records the
  measurement behind that choice and the one shape the simple version would miss.
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
