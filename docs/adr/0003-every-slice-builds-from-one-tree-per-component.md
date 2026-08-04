# 3. Every slice builds from one tree per component

Date: 2026-07-27, rewritten 2026-08-04
Status: accepted. The original decision, that PowerPC and Intel build from
different upstream trees, was reversed and is recorded below as rejected.

## Context

Half-Life on Xash3D is three separately built pieces: the engine
(`xash3d-fwgs`), the menu (`mainui_cpp`, consumed as the engine's
`3rdparty/mainui` submodule) and the game code (`hlsdk-portable`). The retail
Steam `valve` DLLs are 32-bit x86, so the game code has to be recompiled for
every slice we ship regardless.

Xash3D FWGS is little-endian in places that matter to a game: the image loader,
the model loader, the save format. Running it on a PowerPC Mac needs byte-order
work across all three pieces. Intel needs none of it.

For a while that argued for two trees per component, one per architecture. It
was wrong, and how it failed is the reason this ADR is worth keeping.

## Decision

**One tree per component, and every slice builds from it.** The engine, the menu
and the game code each have exactly one branch, ours, pinned in
`scripts/build-pins.sh`. `ppc750`, `ppc7400` and `x86_64` all compile from the
same source.

Mainline turned out to need far less byte-order work than the split assumed. It
swaps studio model data in `Mod_LoadCacheFile` and `R_StudioLoadHeader`, it
composes the built-in textures with `HostFourCC` so they cannot come out
byte-reversed, and `hlsdk-portable` handles save/restore centrally in
`CSave::BufferData` through a `typesize` parameter. What was actually missing was
about fifteen fixes, most of them not endianness at all: a CPU misdetection in
waf, duplicate typedefs that a pre-C11 compiler rejects, C++11 constructs in the
menu, and SDL hints and functions that postdate the SDL 2.0.3 the PowerPC slices
link.

## Rejected: a separate tree per architecture

The case for it was that neither tree would carry anything for the other, and
that the byte-order work stayed at a commit we could name. Both were true. It
still cost more than it saved, in ways that only showed up in practice.

**A fix could be live on one architecture and absent on another**, with nothing
to catch it. Each tree had its own list of changes to apply, and the lists were
deliberately different, so "is this fix on both?" had no mechanical answer. That
happened more than once.

**Reasoning silently went stale.** A change was written for the PowerPC tree on
the premise that the engine did not byte-swap studio animation data. That was
true of the tree it was written against. Once every slice built from mainline it
was false, and the change became a second swap over bytes already in host order,
which crashed the game on every PowerPC machine as soon as a real map loaded. The
premise was never re-read because nothing forced it to be. That is written up in
`docs/port/PPC-PORT-NOTES.md`.

**There was no single answer to "which Xash is this",** because the two engines
were not the same version, so an upstream fix present on Intel could be absent on
PowerPC.

**The PowerPC side had no HTTPS**, because that tree bundled no mbedTLS and its
HTTP layer was plaintext, while Intel had it.

## Consequences

**Gained**

- That whole class of bug is structurally gone rather than guarded against. There
  is one branch per component, so a fix cannot be on one architecture and not the
  other.
- One pin to bump per component, and one answer to what version this is.
- mbedTLS is built for every slice from the same tree, so HTTPS is not an
  architecture-specific feature.

**Lost**

- Our branch now carries the PowerPC work, so bringing a new mainline forward is
  a rebase with conflicts to resolve rather than a re-clone. That is more work up
  front, and it fails loudly. `docs/adr/0012`
- The PowerPC slices compile code they cannot exercise, and the Intel slice
  compiles endian paths it never takes. Both are compiled out or dead.

**Unchanged**

- Recorded demos are same-arch only: the demo header is written in native byte
  order, so a PowerPC recording does not play back on Intel or the reverse.
- The three pieces are still three separately built trees. That structure is not
  what changed; only the number of branches per piece did.

## Notes

The mod game code was the first thing to converge, before the engine did: all 25
mod branches already built from `FWGS/hlsdk-portable` for both architectures. The
fixes those trees need stay as `scripts/patch-hlsdk-*.py`, because each mod's
branch is not ours to fork and there is no single repository for them to be
commits in. `vendor/MANIFEST.md`, `docs/MODS.md`.
