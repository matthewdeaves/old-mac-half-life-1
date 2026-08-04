# 0012. The port is commits on our own forks, not scripts run over somebody else's tree

Date: 2026-07-31
Status: accepted. Replaces the patching half of `0002-pinned-vendoring.md`.

## Context

Until today this port was carried as `scripts/patch-*.py`: fifty Python scripts
that string-replaced their way through a freshly cloned upstream tree at build
time. Each build driver ran its own list of them, in its own order, against its
own vendored checkout.

It produced correct binaries. It was still the wrong shape, for four reasons, all
of which we hit in practice rather than in theory.

**Nobody could read the port.** The interesting part of a fix, the reasoning, sat
in a comment above a wall of escaped C in a Python string literal. To see what
the port actually changed you had to run it first and diff the result. A person
asked to judge whether this work was ours had no artefact to judge.

**The patch lists drifted.** Each driver named its own scripts, so a fix could be
live on one slice and absent on another with nothing to catch it.
`patch-gl-apple-context.py` was wired into the Intel driver only, so after the
PowerPC slices moved to mainline they silently lost a fix they had been getting
from elsewhere. Nothing failed. The slice was just quietly worse.

**A superseded fix could not be withdrawn.** The scripts are marker-guarded,
which is right for re-applying a fix and wrong for replacing one: a file holding
an old body still carries the marker, so the script reports "already patched" and
skips it. Removing a fix from this repo did not remove it from a build host that
already had it, and every check in `.claude/rules/build-verification.md` looks at
the build OUTPUT, so none of them could see it. That was issue #39, and it needed
an entire script, `reset-vendor-trees.sh`, whose only job was to undo the damage.

**It made an authorship question hard to answer.** The project depended on
third-party forks, and the patch scripts sat on top of them. "What is yours?" had
no short answer.

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

`scripts/build-pins.sh` holds the pins. `scripts/fetch-sources.sh` puts every
tree at its pin. The drivers refuse to build a tree that is not at its pin.

## Consequences

**The port is readable.** `git diff` shows it. Each commit carries the reasoning
that used to be a Python comment, attached to the diff it explains.

**Drift is structurally impossible.** There is one branch per component and every
slice builds from it, so a fix cannot be live on one architecture and missing on
another. That class of bug is gone rather than guarded against.

**Issue #39 is gone.** A tree is either at the pinned commit or it is not, and
`git checkout` settles it. There is no accumulated state to un-apply, so
`reset-vendor-trees.sh` has nothing left to do.

**Bumping upstream is now a rebase**, which is a real cost we accept. Previously
a new upstream meant re-running scripts and finding out which anchors had moved.
Now it means rebasing `oldmac` and resolving conflicts. That is more work up
front and it fails loudly, where the anchors failed quietly or, worse, matched
something they should not have.

**Not everything moved.** Three patch scripts survive, because they patch trees
that are not ours to fork: `patch-mbedtls-oldmac.py` for the installer's copy of
mbedTLS, and `patch-hlsdk-mod-gcc4.py` and `patch-hlsdk-mod-bugs.py`, which are
applied to the separate source tree of each of the 25 mods we build. There is no
single repository for those to be commits in.

**Two fixes turned out to be unnecessary and were dropped rather than carried.**
Upstream mainui now swaps the BMP header to host order in `CBMP::LoadFile`, and
its `PicButton` reaches the artwork test on every architecture, so our versions of
both had nothing left to change. Moving to real commits made that visible,
because a commit with an empty diff cannot be created by accident.

## Related

- `0002-pinned-vendoring.md`: pinning survives, the patching does not.
- `0003-split-trees.md`: the three trees are unchanged as a structure.
- `.claude/rules/build-verification.md`: still applies in full. A readable port
  is not a built port, and waf still exits 0 on a failed task.
