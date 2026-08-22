# 15. The arm64 app slices carry a source hash, not a commit id

Date: 2026-08-22
Status: accepted

## Context

arm64 is the one slice no build mini can produce. Xcode 4.6 on Lion predates the
architecture by seven years, so the Mods app and System Report build their arm64
slices on the dev box and have them carried to the mini by
`scripts/push-mod-arm64.sh`. The mini then fuses whatever it finds.

Until now the fuse tested only that the file existed:

    ARM64_SLICE="$ROOT/dist/installer-arm64/installer"
    if [ -f "$ARM64_SLICE" ]; then ...

Nothing cleans `dist/installer-arm64` or `dist/sysreport-arm64` up, so the copy
on the mini can be weeks old. The trigger is an ordinary commit to `installer/`
or `sysreport/`, not a pin bump: the mini rebuilds its ppc, i386 and x86_64
slices from the new source, fuses the old arm64 one, and prints `arm64 slice
present, fusing it in`. The shipped app then runs old code on Apple Silicon and
new code on the other four architectures, and nothing downstream looks.

Measured over the 30 days to 2026-08-22: 19 commits touched `installer/`, 5
touched `sysreport/`. Issue #4.

The engine does not have this problem. `build-arm64.sh` writes a `BUILD-STAMP`
holding `git rev-parse HEAD` of the pinned engine tree, and
`make-universal.sh:144-153` refuses to fuse unless every slice's stamp equals
`PIN_ENGINE_COMMIT`.

## Decision

Both arm64 app drivers write a `BUILD-STAMP` beside their slice, and both fuses
refuse to fuse unless it matches the source they are compiling.

The stamp is a **content hash of the source files**, not a commit id. It covers
the driver's own `$SOURCES` list plus the headers beside it, keyed by basename,
computed by `oldmac_src_stamp` in `scripts/arm64-stamp.sh`, which both sides
source so the two can never drift apart.

## Why not a commit id, given the engine uses one

Because the machine that has to CHECK the stamp cannot compute one.

The engine builds from a pinned clone, so a commit id fully identifies its
source and `build-pins.sh` carries the expected value to the mini. These two apps
build from directories inside this repo, and `~/oldmac` on a mini is a
hand-managed tree rather than a clone: there is no git there and nothing pulls
(`scripts/sync-build-host.sh:12`). A commit id would be a value only the dev box
could produce and only the dev box could verify.

A content hash both machines compute identically, with no git and no new
sync-side mechanism. `md5` is the one digest spelling present on 10.3 through
macOS 26, which is why this repo already leans on it
(`scripts/sync-build-host.sh:82`).

It also answers the question that actually matters. "Same commit" is a proxy;
"same source bytes" is the thing, and it stays true even when the dev box builds
a slice from a working tree that was never committed.

## What is hashed, and what is deliberately not

An explicit file list, never a glob of the directory. The mini's copy of
`installer/` arrives by `git archive HEAD` (`sync-build-host.sh:187`), i.e.
exactly the tracked files, while the dev box is a working tree that may hold
untracked junk. Hashing a directory listing would let a scratch file on one box
refuse a good build on the other.

Not hashed:

- **Resources.** `ca-roots.pem`, `mods.map`, `artwork/` and the rest are copied
  into `Contents/Resources` from the mini's own `installer/`
  (`build-installer.sh:268-288`). They never enter any slice.
- **`vendor/`.** mbedTLS, zlib and lzma are compiled into the installer, but the
  vendor trees are hand-managed per machine and are allowed to differ. Hashing
  them would refuse every legitimate build. This is a real gap: a vendor bump
  still needs the arm64 drivers re-run by hand, and this stamp will not catch it.
- **The pin values for those three.** Writing a pin into a stamp records what was
  asked for rather than what was built, which is the exact defect written up at
  `sync-build-host.sh:26`.

## The two rules inherited from old-mac-quake2

That repo added this same class of gate and hit two independent defects
(`ea922696`, then `0b526e06`, then `cabeae7e`). Both are satisfied here by
construction rather than by luck:

- Compute the stamp before any source mutation. Neither arm64 driver contains a
  `sed -i`, a `patch` or a `trap`, so there is no ordering to get wrong.
- Keep build output out of the hashed set. Output goes to `dist/`; nothing is
  written back into `installer/` or `sysreport/`.

The transfer trap does not apply either. `push-mod-arm64.sh` rsyncs whole
directories with no `--delete` and fingerprints every file in them, so
`BUILD-STAMP` travels with the slice and the copy is verified.

## Consequences

A slice built before this change carries no stamp and is refused, naming the two
commands that fix it. That is correct: such a slice is exactly the unidentifiable
artifact this ADR exists to stop shipping.

A missing arm64 slice is still not an error. Apple Silicon falls back to the
x86_64 slice under Rosetta 2, so absence stays a downgrade rather than a fault,
and the fuse still says which case it is.

The 25 mod dylib pairs are NOT covered. `fuse-mod-arm64.sh:62` also checks existence
only, and at `:68` it deliberately skips any dylib that already carries arm64
because `lipo -create` fails on a duplicate architecture, so a newer arm64 build
never replaces an already-fused older one. That is a separate defect with a
different fix and it stays open on issue #4.

## Proved in both directions

A gate that refuses good work is worse than no gate, because it gets switched
off rather than failing loudly. old-mac-quake2's version of this gate refused
every legitimate build and had only ever been run against a reproduction of the
bug it was written for.

Both arm64 drivers were run for real on the dev box, and the gate text extracted
verbatim from both fuse scripts was run against the result:

| case | expected | got |
| --- | --- | --- |
| slice built from this source | fuse it | fused, exit 0 |
| a source file edited | refuse | refused, exit 1 |
| a header edited | refuse | refused, exit 1 |
| slice with no `BUILD-STAMP` | refuse | refused, exit 1 |
| no arm64 slice at all | Rosetta 2 note, no refusal | exit 0 |
| untracked junk in the source dir | fuse it | fused, exit 0 |

The passing rows are the ones that matter. They are the ones quake2 skipped.
