# Mod source audit, 2026-07-26

A source-level audit of all 25 shipped mods for big-endian (PowerPC) correctness,
prompted by the "Escape from the Darkness" segfault on the G5.

**24 of the 25 are clean on endian**; `sohl1.2` was added later and is not covered.
One endian bug was found in a mod (DMC) and two more in code shared by `valve` and
every mod. The rest was arch-neutral: unbounded `sprintf`s, an unchecked downcast,
a wrong save-field type.

The `#NN` numbers below are this project's own task IDs, **not** GitHub issues.

## Method

Every mod is a branch of `FWGS/hlsdk-portable` that `scripts/build-mod.sh` compiles
from source (`vendor/hlsdk-portable-mirror.git` holds all 57), so this is a reading
of real code, not an inference from binaries. Each mod was diffed against
`git merge-base master <branch>` and only the mod's OWN added lines were audited;
inherited code was confirmed present but not re-audited, being shared with the
already-working `valve` build. A first regex pass flagged 55 pointer-cast
dereferences in zombie-x alone, all benign or in files the build excludes, so
everything was read in context: confirming a false positive costs a physical boot of
a 20-year-old machine.

Categories looked for: multi-byte reads out of byte buffers crossing a file, network
or save-game boundary; custom binary file formats; hand-packed network messages;
byte-wise access to packed colours; integer/float union punning; x86 inline asm;
bitfields over external data; and pointer-in-int and size assumptions, the PowerPC
build being 32-bit and Intel 64-bit.

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

**Status, 2026-07-26.** All are implemented as two guarded patch scripts wired into
`build-mod.sh` and applied to **both** trees, not only the PowerPC one: apart from
the DMC byteswap these are arch-neutral, so patching `-ppc` alone would ship an
Intel slice still carrying them.

- `scripts/patch-hlsdk-shared-clientbugs.py` for #34, shared hlsdk code. The same
  two faults sit in the base game's own client dylib, fixed there by a commit on our
  hlsdk fork, `client: big-endian faults on the director and HLTV path`.
- `scripts/patch-hlsdk-mod-bugs.py` for the rest, keyed by branch so a moved anchor
  is a hard error rather than a silent skip: files such as `dlls/player.cpp` exist in
  every branch, so "anchor not found" could not safely mean "nothing to do".

A few items are deliberately still open against their tasks. The notable one is the
DMC null check in `Dmc_TeleporterTouched`: the endian bug was *masking* a latent
crash Intel already had, and fixing one without the other hands PowerPC the same
fault.

- **#32 DMC, endian, PPC-only.** `cl_dll/dmc/DMC_Teleporters.cpp` reads the map's BSP
  header with `fread` and no byteswap. On PowerPC the version field reads as
  503316480, the version check always fails and the teleporter list stays empty, so
  client-side teleporter prediction is dead. Intel players in the same LAN game are
  unaffected.
- **#34 shared client code, endian, PPC-only.** `hud_spectator.cpp` stores a 4-byte
  `int` through a reference bound to a 1-byte field, and `parsemsg.cpp`'s
  `READ_FLOAT` has its byteswap commented out. Both ship in `valve` and all 25 mods
  and are now fixed in all of them.

  Reach is small. The three director commands that touch the broken code
  (`DRC_CMD_MESSAGE`, `DRC_CMD_SOUND`, `DRC_CMD_TIMESCALE`) are sent only by an HLTV
  proxy, Windows and Linux only with no Xash3D equivalent, never by the game DLLs or
  the engine. What the game *does* send on death and damage is `DRC_CMD_EVENT`, over
  `MSG_SPEC` so only spectators receive it, and it reads no floats and unpacks no
  colours. **So this fix cannot be exercised on this fleet.** It rests on reading the
  code; a clean base-game launch is a regression check, not verification.
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

These matter more to us than to the original Windows releases: we ship code and the
player supplies content, so a `soundtrack.txt`, map keyvalue or model set we have
never seen is the normal case, not an edge case.

## Checked and cleared, so nobody re-treads it

- **Save-field widths**, the highest-value category, since upstream's central
  byteswap is driven by the declared type: a `bool` described as `FIELD_BOOLEAN`
  (4 bytes) would corrupt on PowerPC only. Roughly 950
  `DEFINE_FIELD`/`DEFINE_ARRAY` entries per Spirit mod, and every added entry in the
  others, resolved against the real member declaration; zero mismatches. `BOOL` is
  `int` in this SDK, so `FIELD_BOOLEAN` is correct wherever it appears.
- **`StudioModelRenderer.cpp`** is md5-identical across eftd, opfor, thegate and tot,
  and no mod ships its own. Its `Unaligned()` corrects alignment without
  byteswapping, which is right: the engine swaps studio animation data before the
  client sees it, and swapping again here crashed map load.
  `docs/port/PPC-PORT-NOTES.md`.
- **`UnpackRGB` and colour packing** are shift-based, not byte-addressed, so they are
  endian-neutral.
- **Weapon-bit `1 << WEAPON_*` work** is arithmetic on `int` and identical on both
  architectures. Enum insertions were checked to sit at the same position in the
  server and client headers, exactly the kind of thing that silently desyncs.
- **Float-to-int bit puns** through the same host's memory are byte-order-neutral, so
  shared-random seeding stays in sync across the Intel/PowerPC boundary.
- **zombie-x's suspicious code is not built.** Both `dlls/wscript` and
  `cl_dll/wscript` exclude the entire HPB bot subsystem, including a Windows PE
  export-table parser and a waypoint reader that does byteswap-free `fread`. A
  dormant risk only if someone removes an entry from `excluded_files`.
- **half-screwed's FMOD bindings** are likewise excluded as dead code.

## Build note

**theyhunger must not be built with `CLIENT_WEAPONS` forced on.** `dlls/client.cpp`
references two weapon constants that are never defined and three player members the
mod deleted from `dlls/cbase.h`. It compiles only because the mod's own
`mod_options.txt` sets `CLIENT_WEAPONS=OFF`, which `build-mod.sh` reads; do not
override it.

## Convention

A mod's branch is not ours to fork, so every fix here belongs in a guarded
`scripts/patch-*.py` wired into `build-mod.sh`, in the style of
`patch-hlsdk-mod-gcc4.py`, which no-ops on trees lacking the anchor. Never commit
into a checked-out mod tree: those stay re-clonable, and we never PR upstream.
