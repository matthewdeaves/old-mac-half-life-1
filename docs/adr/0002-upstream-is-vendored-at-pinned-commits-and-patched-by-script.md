# 2. Upstream is vendored at pinned commits and patched by script

Date: 2026-07-27
Status: accepted

## Context

Every line of engine, menu and game code this project ships belongs to somebody
else. What we add is the set of changes that make those trees compile and run on
2003-era Macs, plus the packaging around them.

Two things have to be true at once. The upstream trees must be reproducible, so a
release can be rebuilt byte for byte later. And our changes must stay visible as
changes, rather than dissolving into a checkout that only exists on one machine.

The build reads five upstream trees plus a per-mod tree for each of 25 mods
(`scripts/build-pins.sh`, `vendor/MANIFEST.md`). None of that source is committed
here.

## Decision

**Clone upstream into a git-ignored `vendor/` at an exact commit, and express
every local change as a script or a captured diff in this repo.**

- Pins live in one place, `scripts/build-pins.sh`. It is sourced by
  `scripts/bootstrap-vendor.sh:21` to clone the trees, and its
  `provenance_oneline` and `provenance_table` functions (`build-pins.sh:56`,
  `:64`) stamp the same values into the shipped build string and
  `BUILD-INFO.txt`, so a disk image records what it was built from.
- `vendor/` is git-ignored except for the manifest (`.gitignore:1-8`).
- Changes are 35 `scripts/patch-*.py` scripts, each guarded so it is idempotent
  and re-runnable (`scripts/build-lion.sh:92-94`), applied by the per-arch build
  drivers. Edits that do not fit a script are captured as four diffs under
  `patches/vendor/` and re-applied by `bootstrap-vendor.sh`.
- Clones are always `--recursive` (`bootstrap-vendor.sh:47`), because GitHub ZIPs
  omit submodules (`vendor/MANIFEST.md:11`).
- Nothing is ever pushed or proposed upstream (`CLAUDE.md:79-81`).

The reproduction chain is `bootstrap-vendor.sh` (clone at pin, apply captured
hand-edits) then `build-<arch>.sh` (run the patch scripts, compile).

## Alternatives rejected

**Fork each upstream repo and commit the changes there.** A fork has to be kept
alive and rebased, and the change set stops being legible as a diff against a
known commit. It also invites the assumption that the fork is a place to send
fixes, which it is not: this is a repackaging, not an upstream release.

**Commit the vendored source into this repo.** It would make the build
self-contained, but it puts other people's code under our history, hides which
upstream commit each file came from, and makes an upstream bump a merge rather
than a pin change.

**Git submodules instead of a bootstrap script.** Submodules cannot express the
things this build needs: the `3rdparty/mainui` submodule has to be re-pointed
away from the pin recorded in the engine tree's own `.gitmodules`
(`vendor/MANIFEST.md:174-186`), and a fallback URL cannot be attached to a
submodule at all.

**GitHub ZIP downloads.** They omit submodules, which is not detectable until a
build fails somewhere unrelated.

**Relying on upstream staying online.** Four of the pins are personal forks,
which get deleted or force-pushed more often than organisation repos. They are
mirrored to private repos (`scripts/sync-mirrors.sh:22-27`), and `clone_tree`
falls back to the mirror both when the primary is unreachable and when the
primary is reachable but no longer contains the pin
(`bootstrap-vendor.sh:47-60`). The FWGS organisation repos are not mirrored
(`vendor/MANIFEST.md:166-168`).

## Consequences

**Gained**

- A release can be reconstructed from this repo alone, on a clean machine.
- Our changes are readable as changes. `scripts/patch-*.py` is the record of what
  this project actually did to the source.
- Vendored trees stay re-clonable, so bumping a pin is a pin edit plus a rebuild
  rather than a merge.
- Upstream is never sent anything, so there is no expectation to maintain.

**Lost**

- Reconstruction is a two-step chain rather than a clone, and `vendor/` cannot be
  recovered without a network.
- The patch scripts are anchored to source text. When a pin moves, an anchor can
  disappear and the script becomes a silent no-op rather than an error. That is
  why `build-lion.sh:97-100` has to note which script deliberately does not apply
  to the Intel tree, and why every build has to be verified rather than trusted
  (`.claude/rules/build-verification.md`).
- Bugs we fix stay ours. A fix that would help everyone using these trees on old
  hardware is not offered to them.
- `bootstrap-vendor.sh` needs git 1.8.5 or newer for `git -C`, so it cannot run
  on the build minis themselves (`bootstrap-vendor.sh:161`). Reconstruction and
  building are on different machines.

**Risks accepted**

- The SDL2 sources are downloads rather than clones (`vendor/MANIFEST.md:136`,
  `bootstrap-vendor.sh:150`), so they are the one input with no commit pin and no
  mirror. See ADR 0004.
- A mirror is only as current as the last `sync-mirrors.sh` run. Syncing a mirror
  does not change what the build uses, since the build is pinned
  (`sync-mirrors.sh:12-15`), but a pin bumped without a re-push leaves the new
  pin unmirrored.
