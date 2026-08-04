# 3. Every slice builds from one tree per component

Date: 2026-07-27, rewritten 2026-08-04
Status: accepted. The original decision, that PowerPC and Intel build from
different upstream trees, was reversed and is recorded below as rejected.

## Context

Half-Life on Xash3D is three separately built pieces: the engine
(`xash3d-fwgs`), the menu (`mainui_cpp`, consumed as the engine's
`3rdparty/mainui` submodule) and the game code (`hlsdk-portable`). The retail
Steam `valve` DLLs are 32-bit x86, so the game code is recompiled for every slice
regardless.

Xash3D FWGS is little-endian in places that matter to a game: the image loader,
the model loader, the save format. PowerPC needs byte-order work across all three
pieces, Intel needs none, and that once argued for two trees per component. It was
wrong, and how it failed is why this ADR is kept.

## Decision

**One tree per component, and every slice builds from it.** The engine, the menu
and the game code each have exactly one branch, ours, pinned in
`scripts/build-pins.sh`. `ppc750`, `ppc7400` and `x86_64` all compile from it.

Mainline needs far less byte-order work than the split assumed: it swaps studio
model data in `Mod_LoadCacheFile` and `R_StudioLoadHeader`, composes the built-in
textures with `HostFourCC` so they cannot come out byte-reversed, and
`hlsdk-portable` handles save/restore centrally in `CSave::BufferData` through a
`typesize` parameter. What was missing was about fifteen fixes, most not
endianness at all: a CPU misdetection in waf, duplicate typedefs a pre-C11
compiler rejects, C++11 constructs in the menu, and SDL hints and functions that
postdate the SDL 2.0.3 the PowerPC slices link.

## Rejected: a separate tree per architecture

The case for it was true: neither tree carried anything for the other, and the
byte-order work stayed at a commit we could name. It still cost more than it
saved.

**A fix could be live on one architecture and absent on another**, with nothing to
catch it: each tree had its own deliberately different list of changes, so "is
this fix on both?" had no mechanical answer. That happened more than once.

**Reasoning silently went stale.** A change written for the PowerPC tree assumed
the engine did not byte-swap studio animation data, true of the tree it was
written against. Once every slice built from mainline it was false: the change
became a second swap over bytes already in host order and crashed the game on
every PowerPC machine as soon as a real map loaded. Nothing forced the premise to
be re-read. `docs/port/PPC-PORT-NOTES.md`.

**There was no single answer to "which Xash is this",** because the two engines
were different versions, so an upstream fix present on Intel could be absent on
PowerPC.

**The PowerPC side had no HTTPS**, because that tree bundled no mbedTLS and its
HTTP layer was plaintext, while Intel had it.

## Consequences

**Gained**

- One branch per component, so a fix cannot be on one architecture and not the
  other. That class of bug is structurally gone rather than guarded against.
- One pin to bump per component, and one answer to what version this is.
- mbedTLS is built for every slice from the same tree, so HTTPS is not an
  architecture-specific feature.

**Lost**

- Our branch carries the PowerPC work, so bringing a new mainline forward is a
  rebase with conflicts rather than a re-clone. More work up front, and it fails
  loudly. `docs/adr/0012`
- The PowerPC slices compile code they cannot exercise, and the Intel slice
  compiles endian paths it never takes. Both are compiled out or dead.

**Unchanged**

- Recorded demos are same-arch only: the demo header is written in native byte
  order, so a PowerPC recording does not play back on Intel or the reverse.
- The three pieces are still three separately built trees. Only the number of
  branches per piece changed.

## Notes

The mod game code converged first: all 25 mod branches already built from
`FWGS/hlsdk-portable` for both architectures. The fixes they need stay as
`scripts/patch-hlsdk-*.py`, because each mod's branch is not ours to fork and
there is no single repository for them to be commits in. `vendor/MANIFEST.md`,
`docs/MODS.md`.
