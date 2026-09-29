# Half-Life old-Mac port

Half-Life 1 on Xash3D FWGS as one universal fat `Half-Life.app` (PowerPC, Intel, Apple Silicon). Fleet POLICY applies. Rules in `.claude/rules/` load when you touch a matching file.

## Rules (each from a real mistake)
- waf exits 0 on a failed task and installs stale objects: verify every build (`build-verification.md`).
- Payload sits at the `valve/` level, not the rodir root (adr/0006).
- Ship code, never content: no Valve or mod-author assets.
- Commits go on `oldmac` of our own forks, pinned in `scripts/build-pins.sh`; never PR or push upstream (adr/0012).
- Release DMG builds on a Tiger G4 only, `-format UDZO`, md5 every binary (adr/0005).
- Before a release: `python3 tests/test-repo.py`, `tests/test-artifact.sh`.
- A release claim is in the notes AND the publish script's `--title`: fix both (INCIDENTS "release claim").
- A human at a console is invisible to checks: `--acquire` with a label (INCIDENTS "human at the keyboard").
- Filing puts nothing in a column: run `board-add.sh` right after (INCIDENTS "Filing").
- Repo is public: no addresses, keys, tokens or `.env` content from retro-server-infra.
- Paste numbers from command output, never retype. No em dashes. No Claude co-author. Never rate or praise work.

## Where to look
- Build, deploy, slices, pins: `.claude/rules/build-commands.md`, then `docs/BUILD-COMMANDS.md`
- Fleet aliases, Lion limits: `legacy-mac-hardware.md`, then `docs/FLEET-HARDWARE.md`
- Subtypes, renderer defaults, generated configs, server: `core-facts.md`, then `docs/CORE-FACTS.md`
- App layout: `shipped-layout.md`, then `docs/SHIPPED-LAYOUT.md`
- Artifact checks, cpusubtype stamping, launcher profiles: `build-verification.md`, then `docs/BUILD-VERIFICATION.md`
- Bench: `docs/BENCHMARKING.md`; new Mac or G5 partition: `docs/FLEET-ONBOARDING.md`
- qemu-tiger3d loop (`scripts/pick-bench-host.sh --run qemu-tiger3d <label> -- <script>`), frame check: `docs/VM-TIGER.md`
- Mods: `docs/MODS.md`, `docs/MOD-AUDIT.md`; icons: `docs/ICONS.md`; terms: `docs/LICENSING.md`
- Porting findings, refuted mechanisms: `docs/port/POWERPC-FINDINGS.md`, `docs/port/PPC-PORT-NOTES.md`, `docs/GL-OPTIMIZATION-CASE-STUDY.md`
- Refutation pass: `docs/WORKING-METHOD.md`; why we chose X: `docs/adr/`
- Fix history: `grep -n '#NN' BUGFIXES.md`; incidents: `docs/INCIDENTS.md`; dated facts: `README.md`
