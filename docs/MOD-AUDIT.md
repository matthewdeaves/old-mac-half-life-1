# Mod source audit, 2026-07-26

A source-level audit of all 25 shipped mods for big-endian (PowerPC) correctness,
prompted by the "Escape from the Darkness" segfault on the G5.

**24 of the 25 are clean on endian**, and `sohl1.2` is not covered by this audit;
it was added after it was written. One endian bug was found in a mod (DMC), and two
more in code shared by `valve` and every mod. Most of what turned up was
arch-neutral: unbounded `sprintf`s, an unchecked downcast, a wrong save-field type.

The `#NN` numbers below are this project's own task IDs. They are **not** GitHub
issue numbers, and there is no issue of that number to look up.

## Why we can audit at all

Every mod is a branch of `FWGS/hlsdk-portable`, and `scripts/build-mod.sh` compiles it
from source. `vendor/hlsdk-portable-mirror.git` holds all 57 branches. Nothing here is
a black box, so this is a reading of real code rather than an inference from binaries.

## Method

Each mod was diffed against `git merge-base master <branch>` and only the mod's OWN
added lines were audited. Code inherited unchanged from upstream was confirmed present
but not re-audited, since it is shared with the already-working `valve` build.

Everything was read in context before being reported. A first pass with
crude regexes flagged 55 pointer-cast dereferences in zombie-x alone, and every one of
them turned out to be benign or in a file the build excludes. False positives are
expensive here, because confirming one costs a physical boot of a 20-year-old machine.

Categories looked for: multi-byte reads out of byte buffers that crossed a file,
network or save-game boundary; custom binary file formats; hand-packed network
messages; byte-wise access to packed colours; integer/float union punning; x86 inline
asm; bitfields over external data; and, since the PowerPC build is 32-bit while Intel
is 64-bit, pointer-in-int and size assumptions.

## Verdicts

| Mod | Endian | Note |
|---|---|---|
| aom | clean | branch is three gameplay disables; the merge-base is not degenerate |
| asheep | clean | |
| biglolly | clean | |
| blackops | clean | two non-endian bugs, task #33 |
| bshift | clean | consistent with it playing on the G4 today |
| CAd | clean | |
| caseclosed | clean | one added line |
| dmc | **BUG** | task #32 |
| echoes | clean | shares the Spirit of Half-Life core with halloween |
| eftd | clean | yet it segfaults on PPC and not Intel: task #30 |
| half-screwed | clean | suspect FMOD code is excluded from the build |
| halloween | clean | |
| induction_1.2 | clean | |
| noffice | clean | |
| opfor | clean | one cosmetic non-endian bug, task #37 |
| poke646 | clean | one non-endian crash, task #35 |
| poke646_vendetta | clean | shares the audited code with poke646 |
| redempt | clean | consistent with it playing on the G4 today |
| residual_point | clean | |
| theyhunger | clean | see build note below |
| thegate | clean | two non-endian crashes, task #38 |
| tot | clean | one non-endian crash, task #39 |
| visitors | clean | |
| zombie-x | clean | its own code is clean; found the shared bugs in task #34 |

## Findings

Each is tracked as a task with the full reasoning and the exact fix.

**Status, 2026-07-26.** All of these are now implemented as two guarded patch scripts
wired into `build-mod.sh`, and applied to **both** trees rather than only the PowerPC
one: apart from the DMC byteswap these are arch-neutral bugs, so patching `-ppc` alone
would have shipped an Intel slice of the same mod still carrying them.

- `scripts/patch-hlsdk-shared-clientbugs.py` for #34, which is shared hlsdk code.
  This one is also wired into the three shipping engine drivers (`build-lion.sh`,
  `build-ppc-panther.sh`, `build-ppc-tiger.sh`) and into the retired
  the base game's own engine branch, because the same two faults sit in its client
  dylib. Fixing them in 25 mods and leaving them in `valve` would be inconsistent.
- `scripts/patch-hlsdk-mod-bugs.py` for the rest, keyed by branch so that a moved
  anchor is a hard error rather than a silent skip. Files such as `dlls/player.cpp`
  exist in every branch, so "anchor not found" could not safely mean "nothing to do".

A few items are deliberately still open; they are listed against their tasks. The
notable one is the DMC null check in `Dmc_TeleporterTouched`, because the endian bug
was *masking* a latent crash that Intel already had, and fixing one without the other
hands PowerPC the same fault.

- **#32 DMC, endian, PPC-only.** `cl_dll/dmc/DMC_Teleporters.cpp` reads the map's BSP
  header with `fread` and no byteswap. On PowerPC the version field reads as
  503316480, the version check always fails, and the teleporter list stays empty, so
  client-side teleporter prediction is dead. Asymmetric: Intel players in the same LAN
  game are unaffected.
- **#34 shared client code, endian, PPC-only.** `hud_spectator.cpp` stores a 4-byte
  `int` through a reference bound to a 1-byte field, and `parsemsg.cpp`'s `READ_FLOAT`
  has its byteswap commented out. Both ship in `valve` and all 25 mods, and both are
  now patched in all of them.

  Reach is small. The three director commands that touch the broken code
  (`DRC_CMD_MESSAGE`, `DRC_CMD_SOUND`, `DRC_CMD_TIMESCALE`) are never sent by the
  game DLLs or the engine, only by an HLTV proxy, which was Windows and Linux only
  and has no Xash3D equivalent. What the game *does* send on player death and damage
  is `DRC_CMD_EVENT`, over `MSG_SPEC` so only spectators receive it, and that command
  reads no floats and unpacks no colours. **So this fix cannot be exercised on this
  fleet.** It is made on the strength of reading the code; treat a clean base-game
  launch as a regression check, not as verification.
- **#33 Black Ops.** A percentage saved as `FIELD_TIME`, and an unbounded `sprintf`.
- **#35 poke646 and Vendetta.** Null deref at startup on a `soundtrack.txt` whose map
  name has no extension.
- **#37 Opposing Force.** `CTFMsg` registered fixed-size 1 but sending a byte plus a
  string, so the engine drops it. Invisible in practice: there is no client handler.
- **#38 The Gate.** Two unbounded `sprintf`s into 64-byte stack buffers, one fed
  straight off the wire.
- **#39 Times of Troubles.** An unchecked downcast stored into `m_pCine`, so later
  virtual calls can dispatch through the wrong vtable.
- **#40 eftd.** Recoil recovery that never runs, a renumbered `spawnobject` list,
  transposed `AngleVectors` arguments, and a laser spot that is not save-safe.

Several of these matter more to us than to the original Windows releases, because we
ship code and the player supplies content. A `soundtrack.txt`, a map keyvalue or a
model set we have never seen is the normal case here, not an edge case.

## Checked and cleared, so nobody re-treads it

- **Save-field widths.** Roughly 950 `DEFINE_FIELD`/`DEFINE_ARRAY` entries per Spirit
  mod, and every added entry in the others, resolved against the real member
  declaration. Zero mismatches. This was the highest-value category: upstream's central
  byteswap is driven by the declared type, so a `bool` described as `FIELD_BOOLEAN`
  (4 bytes) would corrupt on PowerPC only. `BOOL` is `int` in this SDK, so
  `FIELD_BOOLEAN` is correct wherever it appears.
- **`StudioModelRenderer.cpp`**, the one known remaining shared gap where `Unaligned()`
  corrects alignment without byteswapping, is md5-identical across eftd, opfor, thegate
  and tot. No mod ships its own version, so it stays a single shared fix.
- **`UnpackRGB` and colour packing** are shift-based, not byte-addressed, so they are
  endian-neutral.
- **Weapon-bit `1 << WEAPON_*` work** is arithmetic on `int` and identical on both
  architectures. Enum insertions were checked to be at the same position in both the
  server and client headers, which is exactly the kind of thing that silently desyncs.
- **Float-to-int bit puns** through the same host's memory are byte-order-neutral, so
  the shared-random seeding stays in sync across the Intel/PowerPC boundary.
- **zombie-x's suspicious code is not built.** Both `dlls/wscript` and `cl_dll/wscript`
  exclude the entire HPB bot subsystem, including a Windows PE export-table parser and
  a waypoint reader that does byteswap-free `fread`. Those are dormant risks only if
  someone removes an entry from `excluded_files`.
- **half-screwed's FMOD bindings** are likewise excluded as dead code.

## Build note

**theyhunger must not be built with `CLIENT_WEAPONS` forced on.** `dlls/client.cpp`
references two weapon constants that are never defined and three player members the
mod deleted from `dlls/cbase.h`. It compiles only because the mod's own
`mod_options.txt` sets `CLIENT_WEAPONS=OFF`. `build-mod.sh` reads `mod_options.txt`,
so this is correct today; do not override it.

## Convention

Every fix here belongs in a guarded `scripts/patch-*.py` wired into `build-mod.sh`, in
the style of `patch-hlsdk-mod-gcc4.py`, which no-ops on trees lacking the anchor.
Never commit to a vendored tree: they stay re-clonable, and we never PR upstream.
