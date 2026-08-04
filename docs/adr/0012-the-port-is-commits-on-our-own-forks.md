# 0012. The port is commits on our own forks, not scripts run over somebody else's tree

Date: 2026-07-31
Status: accepted. Replaces the patching half of `0002-pinned-vendoring.md`.

## Context

This port used to be carried as `scripts/patch-*.py`: fifty Python scripts
string-replacing their way through a freshly cloned upstream tree at build time,
each driver running its own list against its own checkout. It produced correct
binaries and was still the wrong shape.

**Nobody could read it.** The reasoning for a fix sat in a comment above escaped
C in a Python string literal, and seeing what the port changed meant running it
and diffing the result.

**The lists drifted.** Each driver named its own scripts, so a fix could be live
on one slice and absent on another: `patch-gl-apple-context.py` was wired into
the Intel driver only, so the PowerPC slices went without it and nothing failed.

**A superseded fix could not be withdrawn.** The scripts are marker-guarded, so a
file holding an old body still carries the marker and is skipped as "already
patched". Removing a fix from this repo did not remove it from a build host that
already had it, and every check in `.claude/rules/build-verification.md` looks at
the build OUTPUT, so none could see it. That was issue #39, and it needed an
entire script, `reset-vendor-trees.sh`, to undo the damage.

**Authorship was hard to answer.** "What is yours?" had no short answer when the
answer was fifty scripts and the tree they produced.

## Decision

Every change this port makes is a commit on the `oldmac` branch of our own fork
of the relevant upstream. The build fetches a pinned commit and compiles it.
Nothing rewrites a source tree on the way to the compiler.

| we build | our fork | branched from |
|---|---|---|
| engine | `matthewdeaves/xash3d-fwgs` | `FWGS/xash3d-fwgs@f0ea3a19` |
| menu | `matthewdeaves/mainui_cpp` | `FWGS/mainui_cpp@510c30c5` |
| menu utils | `matthewdeaves/MiniUTL` | `FWGS/miniutl@048a416f` |
| backtraces | `matthewdeaves/libbacktrace` | `ianlancetaylor/libbacktrace@b9e40069` |
| game dylibs | `matthewdeaves/hlsdk-portable` | `FWGS/hlsdk-portable@8c5b2846` |
| SDL, PowerPC only | `matthewdeaves/panther-sdl2` | `alex-free/panther-sdl2@bd33187` |

Each is a real fork, so the whole upstream history is present and

    git log --oneline <upstream>..oldmac

is exactly our work and nothing else. The menu, miniutl and libbacktrace are
submodules, and our engine branch re-points them at our forks, pinned to a commit
rather than floating on a branch name.

`scripts/build-pins.sh` holds the pins, `scripts/fetch-sources.sh` puts every
tree at its pin, the drivers refuse to build a tree that is not at its pin, and
`scripts/build-all.sh` runs the whole set.

## Consequences

**The port is readable.** `git diff` shows it, and each commit carries the
reasoning that used to be a Python comment, attached to the diff it explains.

**Drift is structurally impossible.** One branch per component, every slice built
from it, so a fix cannot be live on one architecture and missing on another.

**Issue #39 is gone.** A tree is either at the pinned commit or it is not, and
`git checkout` settles it, so `reset-vendor-trees.sh` is deleted.

**Bumping upstream is now a rebase**, a real cost we accept. A new upstream used
to mean re-running scripts and finding out which anchors had moved; now it means
rebasing `oldmac` and resolving conflicts, which fails loudly where the anchors
failed quietly or matched something they should not have.

**Not everything moved.** Five patch scripts survive, all applied to the separate
source tree of each of the 25 mods we build, because there is no single
repository for them to be commits in: `patch-hlsdk-mod-bugs.py`,
`patch-hlsdk-mod-gcc4.py`, `patch-hlsdk-ppc-darwin.py`,
`patch-hlsdk-shared-clientbugs.py` and `patch-hlsdk-xcompile-ppc.py`.

**Two fixes turned out to be unnecessary and were dropped rather than carried.**
Upstream mainui now swaps the BMP header to host order in `CBMP::LoadFile`, and
its `PicButton` reaches the artwork test on every architecture, so our versions
of both had nothing left to change. Real commits made that visible, because a
commit with an empty diff cannot be created by accident.

## Related

- `0002-pinned-vendoring.md`: pinning survives, the patching does not.
- `0003-split-trees.md`: the three trees are unchanged as a structure.
- `.claude/rules/build-verification.md`: still applies in full. A readable port
  is not a built port, and waf still exits 0 on a failed task.
