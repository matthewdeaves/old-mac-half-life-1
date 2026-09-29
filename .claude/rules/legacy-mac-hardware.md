---
description: The fleet's machine aliases and multi-boot traps, and the Lion build-box toolchain traps
paths:
  - "scripts/build-*.sh"
  - "scripts/pick-*.sh"
  - "scripts/fleet-bench.sh"
  - "scripts/bench*.sh"
  - "scripts/hw-*.sh"
---

# Legacy Mac Hardware & Build Traps

Alias, CPU, GPU and OS tables: `docs/BENCHMARKING.md` ("Machines (SSH aliases)") and
`README.md`. Do not restate them here.

## Machines

- **Legacy slices build on Intel minis; arm64 builds locally** using the four drivers in `docs/BUILD-COMMANDS.md`. PowerPC boxes are bench/test targets and Tiger G4 DMG hosts. Legacy drivers run on the mini. `docs/adr/0005`
- **`mini-intel` and `mini-intel2` build alike but bench differently** (different
  CPU, RAM and cache, same model and OS). Never pool them into one "Intel" class for
  a measurement. Ask `scripts/pick-build-host.sh` (`--status`, `--acquire LABEL`,
  `--release HOST`) instead of hardcoding; hand-started builds hold the lock too.
- **THREE separate G5s: `imac-g5`, the dual (`g5-panther`/`g5-tiger`/`g5-desktop`)
  and the QUAD (`quad-leopard`/`quad-tiger`).** Read the alias, never "the quad"
  from memory; a round of quad deploys once hit the dual. `~/.ssh/config` is the
  authority (this repo has no `ssh_config`): grep it before touching a machine.
- **Multi-boot machines (G3, dual G5, quad G5) share one IP per machine.** An alias
  for a partition that is not booted fails exactly like a machine that is off. Each
  partition needs `HostKeyAlias` and `CheckHostIP no`. Switching with `bless` plus
  reboot: `docs/FLEET-ONBOARDING.md`.

## Lion build-box traps

- **No `git -C`** (Xcode git 1.7): use `( cd DIR && git ... )`. Modern git, curl and
  ssh live under `~/local`; the scripts prefer them.
- **Fork visibility is not established by an authentication failure.** Each mini uses `~/.ssh/id_ed25519_github`; check the URL and SSH wiring when a fetch cannot authenticate. See `docs/FLEET-HARDWARE.md`.
- **No `pkill` on 10.7, 10.4 or 10.3.** Kill by PID out of `ps`.
- **Lion's `strings` reports zero matches on a modern x86_64 Mach-O**, which looks
  like a missing fix. Verify strings on the dev box.
- **Panther's `lipo` prints `cputype (16777223) cpusubtype (-2147483645)` for the
  x86_64 slice.** That is a correct fat binary.
- **The dev box runs zsh: an unquoted `$var` does not word-split.** Use an array
  (`git rm $LIST` once became one pathspec matching nothing).
- hlsdk build traps: `docs/MODS.md`, "Things that bite on these machines".

Stories, the two-mini measurement and the G5 mix-up: `docs/FLEET-HARDWARE.md`.
