# 2. Upstream is vendored at pinned commits and patched by script

Date: 2026-07-27
Status: accepted for the pinning. ADR 0012 supersedes the patching half: nothing
rewrites a source tree at build time any more. The file keeps its name.

## Context

Every line of engine, menu and game code we ship began as somebody else's. Two
things have to be true at once: the upstream trees must be reproducible, so a
release can be rebuilt byte for byte later, and our changes must stay visible as
changes rather than dissolving into a checkout that exists on one machine.

The build reads pinned upstream trees plus a per-mod tree for each of 25 mods
(`scripts/build-pins.sh`, `vendor/MANIFEST.md`). None of that source is committed
here.

## Decision

**Put every source tree at an exact commit in a git-ignored `vendor/`, and let
nothing rewrite one on the way to the compiler.**

- Pins live only in `scripts/build-pins.sh`. `scripts/fetch-sources.sh` sources it
  and puts each tree at its pin; `provenance_oneline` and `provenance_table` stamp
  the same values into the build string and `BUILD-INFO.txt`, so a disk image
  records what it was built from.
- `vendor/` is git-ignored except for the manifest (`.gitignore:1-8`).
- Our changes are commits on the `oldmac` branch of our own fork of each upstream
  (`docs/adr/0012`). Nothing is pushed or proposed to an upstream project.
- `fetch-sources.sh --status` is a gate, not a report: non-zero unless every tree
  is at its pin with no edited tracked file. `scripts/build-all.sh` runs it as a
  step, so a tree moved by hand between fetch and build is caught, not built.
- Clones carry full history, no `--depth`, so `git log <upstream>..oldmac` is
  exactly our own work.
- Submodules are checked by recorded commit, not by "did the update run". The
  engine's `.gitmodules` once named our miniutl fork while the recorded commit
  still pointed at upstream's, every check passed, and the build compiled unported
  source.

## Alternatives rejected

**Commit the vendored source here.** It puts other people's code under our
history, hides which upstream commit each file came from, and makes an upstream
bump a merge rather than a pin change.

**Git submodules of this repo instead of a fetch script.** `3rdparty/mainui` has
to be re-pointed away from the pin recorded in the engine tree's own
`.gitmodules`, and a fallback URL cannot be attached to a submodule at all.

**GitHub ZIP downloads.** They omit submodules, undetectably until a build fails
somewhere unrelated.

**Cloning the 25 mod branches from GitHub.** They come from a local
`vendor/hlsdk-portable-mirror.git`: 57 branches clone from a local path in
seconds, it works with no internet, and the PowerPC bench boxes have no usable TLS
(`vendor/MANIFEST.md`).

## Consequences

**Gained**

- A release can be reconstructed from the pins here, and our changes read as a
  diff against a named upstream commit.
- Bumping a pin is a pin edit plus a rebuild, not a merge.
- Upstream is never sent anything, so there is no expectation to maintain.

**Lost**

- `vendor/` needs a network, and our forks are private, so a build host needs
  credentials. `fetch-sources.sh` fails loudly when a fetch fails and the pin is
  not already in the tree; it used to carry on and report "ok" with the fatal
  still on screen a line above.
- Bugs we fix stay ours, and are not offered to everyone else running these trees
  on old hardware.
- Bumping an upstream is a rebase of `oldmac`, not a re-clone (`docs/adr/0012`).

**Risks accepted**

- The Intel slice's SDL 2.0.22 is a tarball downloaded by `scripts/build-lion.sh`,
  the one input with no commit pin. ADR 0004.
- `fetch-sources.sh` resets hard and discards local edits, because a build has to
  be a pure function of the pin.
- The mod mirror is only as current as its last `remote update`. A pin bumped
  without a refresh leaves the new pin unmirrored.
