# 17. The arm64 workstation may hold real game assets for launch QA

Date: 2026-08-28
Status: accepted

## Context

`.claude/rules/legacy-mac-hardware.md` calls this box (the Apple Silicon
workstation this port's sessions run on) "orchestration only": every slice
cross-compiles on an Intel Lion mini, arm64 builds locally, and the PowerPC boxes
are bench/test targets, not this machine. Nothing here said the workstation
could not ALSO hold retail game data, but nothing said it could either, and issue
#20 was filed because `old-mac-build-host#32` made it a fleet bench-lock host
(`pick-bench-host.sh --run workstation LABEL -- CMD`, local exec, no ssh) for real
launch QA on Apple Silicon, and this repo's own tooling had no ADR to point to
for whether that host may carry the retail `valve/` a launch test needs.

ADR 0006 ("we ship code, not content") is the actual neighbour here, and it
does not forbid this: it governs what the DMG carries, not what a bench/test
machine holds locally. Every vintage machine in the fleet already has its own
untouched retail `valve/` beside the app, exactly as a player would, and that
has never been in tension with ADR 0006. The workstation is the same kind of
machine for this purpose - a bench/test target the player's own data sits
next to - it was just never named as one.

## Decision

The arm64 workstation (`pick-bench-host.sh`'s `workstation` alias) may hold a
real, untouched retail `valve/` and the built app beside it, the same as any
other bench/test machine in the fleet, for the purpose of launch QA -
confirming the arm64 slice actually launches and plays on real Apple Silicon
hardware, not just that it links.

This is scoped to that one machine and to launch QA. It does not change ADR
0006: nothing shipped in the DMG changes, and the player's retail data is
still never touched, merged, or redistributed by anything this repo builds.
`imac-2019` was already covered before this ADR - it has run the fleet's own
deploy/smoke scripts like any other bench host since it joined.

## Consequences

**Asset-provisioning tooling should treat the workstation like a fleet
target.** Per the user's 2026-08-28 directive ("all machines need the same
game data"), `deploy-dmg.sh`/`smoke-dmg.sh` should be able to target it the
same way they target the vintage fleet. Not yet measured: whether those
scripts' path assumptions (`~/Desktop/Half-Life`, ssh-based remote exec) hold
for a machine reached by `pick-bench-host.sh`'s local-exec path
(`LOCAL_ALIASES`/`run_remote()`, `old-mac-build-host#32`) instead of ssh - a
follow-up, not blocking this decision.

**Still orchestration-only for building.** This ADR does not touch the Lion
minis being the cross-compile hosts, or the workstation being where arm64
itself is built (that is `docs/adr/0001`'s amendment and
`.claude/rules/build-commands.md`, unchanged). It only says the workstation
may also carry a copy of the player's own data to launch against, the way any
other bench machine already does.

## Related

- ADR 0006, `0006-we-ship-code-not-content.md`: what the DMG carries. This ADR
  does not amend it - a bench machine holding a player's own retail data was
  never what that decision restricted.
- ADR 0005, `0005-cross-compile-on-intel-lion-package-on-a-tiger-g4.md`: the
  build topology, unchanged.
- `docs/adr/0001` amendment (arm64 slices): the workstation as the arm64 BUILD
  host, a separate role from the bench-host role this ADR adds.
- Issue #20, `old-mac-build-host#32`.
