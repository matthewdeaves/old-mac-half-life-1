# 3. PowerPC and Intel build from different upstream trees

Date: 2026-07-27
Status: accepted

## Context

Half-Life on Xash3D is three separately-built pieces, all of them other people's
code: the engine (`xash3d-fwgs`), the menu (`mainui_cpp`, consumed as the
engine's `3rdparty/mainui` submodule) and the game code (`hlsdk-portable`). The
retail Steam `valve` DLLs are 32-bit x86, so the game code has to be recompiled
for every slice we ship regardless.

Xash3D FWGS mainline is little-endian in places that matter to a game: the image
loader, the model loader, the save format. Running it on a PowerPC Mac needs
byte-order work across all three pieces. That work already existed, in forks:
[removed]
branch and `powerpc-mainui-fixes` menu branch.

Intel needs none of it.

## Decision

**PowerPC slices build from the big-endian forks. The Intel slice builds from
FWGS mainline. They are separate checkouts with separate pins.**

From `scripts/build-pins.sh`:

| Piece | PowerPC | Intel |
|---|---|---|
[removed]
[removed]
[removed]

`scripts/build-ppc-panther.sh:36-37` and `scripts/build-ppc-tiger.sh` read
[removed]
`scripts/build-lion.sh:61-62` reads `vendor/xash3d-fwgs-intel` and
`vendor/hlsdk-portable-intel`. Both PowerPC slices build from the same PowerPC
tree.

[removed]
(`build-pins.sh:46-50`) but contributes nothing to the shipping build. It is kept
as the reference for where the PowerPC engine work started.

## Alternatives rejected

**One tree with `#ifdef`s.** The endian work is not a handful of conditionals; it
touches the image, model and save paths throughout. Carrying it as our own
conditionals in a mainline checkout would mean maintaining the whole big-endian
port as a patch script, when two forks already carry it as source.

**Build PowerPC from mainline and patch only what breaks.** Attempted for the
mod game code and it worked there, because mainline absorbed that half of the
endian work (see Notes). It does not work for the engine: the PowerPC engine that
[removed]

[removed]
[removed]
[removed]

**Build Intel from the PowerPC fork too, for one tree instead of two.** The fork
tracks an older mainline, so the Intel slice would lose everything mainline has
gained since. It would also mean shipping endian code on a machine that cannot
exercise it.

## Consequences

**Gained**

- Neither tree carries anything for the other architecture. The Intel slice is
  ordinary mainline with a 64-bit build and a set of old-macOS patches.
- The byte-order work stays the responsibility of the people who did it, at a
  commit we can name.

**Lost**

- Two pins to bump instead of one, and two patch-script lists that are
  deliberately different (`vendor/MANIFEST.md:20-25` versus `:39-44`). A patch
  applied to one tree and forgotten on the other is an architecture-specific bug
  that only the matching hardware will show.
- The two engines are not the same version, so an upstream fix present on Intel
  may be absent on PowerPC and there is no single answer to "which Xash is this".
[removed]
  HTTP layer is plaintext; Intel enables mbedTLS via
  `scripts/patch-mbedtls-oldmac.py` (`build-lion.sh:34-40`). That gap is issue #1
  and is a direct consequence of the fork split.
- Recorded demos are same-arch only: the demo header is written in native byte
  order, so a PowerPC recording does not play back on Intel or the reverse.

**Risks accepted**

- Both PowerPC pins are personal forks, which is the fragile case ADR 0002's
  mirrors exist for.
[removed]
  bringing it forward means redoing the endian work against a newer mainline.

## Notes

The split no longer applies to the mod game code. FWGS mainline absorbed the
save/restore and node endian work, so all 25 mod branches build from
`FWGS/hlsdk-portable` for both architectures, with the PowerPC checkout getting
`scripts/graft-ppc-endian.sh` and three patch scripts on top
(`vendor/MANIFEST.md:79-82`, `docs/MODS.md:103-118`). One file was left behind by
that convergence, `cl_dll/StudioModelRenderer.cpp`, which
`scripts/patch-hlsdk-studio-endian.py` handles. `graft-ppc-endian.sh` detects
which vintage a branch carries and applies the matching treatment, so a branch
that predates upstream's work still gets the full fork graft.
