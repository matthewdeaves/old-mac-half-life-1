# Half-Life old-Mac port

Half-Life 1 on Xash3D FWGS as one universal fat `Half-Life.app` for PowerPC, Intel and Apple Silicon.

## Traps
- waf can exit 0 after a failed task and install stale objects; verify each build (see docs/BUILD-VERIFICATION.md).
- Payload belongs at the `valve/` level, not the rodir root (see docs/SHIPPED-LAYOUT.md).
- Ship no Valve or mod-author assets (see docs/LICENSING.md).
- Engine changes belong on our forks' `oldmac` branches, pinned in `scripts/build-pins.sh`; no upstream PRs (see docs/BUILD-COMMANDS.md).
- Package release DMGs on a Tiger G4, with UDZO and binary hash checks (see docs/RELEASE.md).
- Correct a release claim in both notes and publish-script title (see docs/INCIDENTS.md, 2026-08-28).
- A person at the console is invisible to probes; the claim label must record that use (see docs/INCIDENTS.md, 2026-08-28).
- Filing puts nothing in a column: run `board-add.sh` right after (see docs/INCIDENTS.md, 2026-08-22).
- Before a release run `python3 tests/test-repo.py` and `tests/test-artifact.sh` (see docs/TESTS.md).
- Repo is public: no addresses, keys, tokens or `.env` content from retro-server-infra.
- Paste numbers from command output, never retype. No em dashes. No Claude co-author. Never rate or praise work.

## Where to look
- Docs → `docs/README.md`
- Build → `.claude/rules/build-commands.md`, `docs/BUILD-COMMANDS.md`
- Deploy → `docs/BUILD-COMMANDS.md`
- Smoke → `docs/BENCHMARKING.md`
- Bench → `docs/BENCHMARKING.md`
- Tests → `docs/TESTS.md`
- Release → `docs/RELEASE.md`
- Tickets → `docs/TICKETS.md`
- History → `BUGFIXES.md`, `docs/INCIDENTS.md`, `docs/archive/`
- Hardware → `.claude/rules/legacy-mac-hardware.md`, `docs/FLEET-HARDWARE.md`
- Slices/config → `.claude/rules/core-facts.md`, `docs/CORE-FACTS.md`
- Layout → `.claude/rules/shipped-layout.md`, `docs/SHIPPED-LAYOUT.md`
- Verification → `.claude/rules/build-verification.md`, `docs/BUILD-VERIFICATION.md`
- VM → `docs/VM-TIGER.md`: `scripts/pick-bench-host.sh --run qemu-tiger3d <label> -- <script>`, frame check `scripts/vm-frame-check.sh`
