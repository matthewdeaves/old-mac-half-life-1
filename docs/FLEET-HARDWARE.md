# Fleet hardware traps and the Lion build box

Which machine builds, which only benches, how the two Intel minis and the three G5s differ,
and the toolchain traps on the Lion build minis. This page holds the stories behind the
one-line rules in `.claude/rules/legacy-mac-hardware.md`. It does not repeat the machine
tables: aliases, CPUs, GPUs and OS levels are in `docs/BENCHMARKING.md` ("Machines (SSH
aliases)"), the fleet matrix is in `README.md`, and partition switching and onboarding are
in `docs/FLEET-ONBOARDING.md`.

## Roles

Legacy PowerPC and Intel build drivers run on the Intel minis; PowerPC machines are test targets and Tiger G4 packaging hosts. The local Apple Silicon host builds arm64 with `build-arm64.sh`, `build-mod-arm64.sh --all`, `build-installer-arm64.sh` and `build-sysreport-arm64.sh`, then pushes those slices before the mini's `build-all.sh`. See `docs/BUILD-COMMANDS.md` and `docs/adr/0005`.

## The two Intel build minis are not one class

`mini-intel` (wifi) and `mini-intel2` (wired, server room, wifi disabled) are both
`hw.model` Macmini2,1 on 10.7.5 with the same toolchain and a GMA 950, which is exactly why
this was once written down wrong: nothing but the CPU separates them. Measured on the
machines 2026-08-23: `mini-intel` is a Core 2 T7600 at 2.33 GHz, 4 GB, 4 MB L2;
`mini-intel2` is a T5600 at 1.83 GHz, 2 GB, 2 MB L2. That is 27% apart on clock alone.
They are interchangeable for BUILDING and not for benching, so a measurement must never
pool them into one "Intel" class.

Ask `scripts/pick-build-host.sh` (`--status`, `--acquire LABEL`, `--release HOST`) and never
hardcode a host. A host is busy if it holds `/tmp/.retro-build-lock` or is compiling, so
hand-started builds count.

## Three separate G5s

`imac-g5` is the iMac G5 (10.5.8). `g5-panther`, `g5-tiger` and `g5-desktop` are partitions
of the **dual** PowerMac G5; `g5-desktop` is the Leopard partition, hostname `g5-leopard`.
`quad-leopard` and `quad-tiger` are partitions of the **QUAD** PowerMac G5, whose user is
`g5quad`. Read the alias, not the word "G5", and never assume "the quad" means whichever G5
you last touched.

On 2026-08-21 a whole round of "deploy to the quad" and "quit the game on the quad" went to
the dual G5 instead, because this list then named only two G5s. The quad kept running an old
build and reporting the bug as unfixed, and the dual was killed repeatedly for no reason.
`~/.ssh/config` is the authority for what exists (there is no `ssh_config` in this repo);
grep it before touching a machine by nickname.

## Multi-boot from one IP

The G3 (`yosemite`, `yosemite-tiger`), the dual G5 and the quad G5 each boot one OS at a
time from one IP. Each partition needs its own alias with `HostKeyAlias` and
`CheckHostIP no`, and the booted one mounts its neighbours under `/Volumes`. An alias for a
partition that is not booted simply fails to connect, which looks exactly like the machine
being off. Switching (`bless` plus reboot) and onboarding a partition:
`docs/FLEET-ONBOARDING.md`.

## Lion build-box traps

See `docs/LION-TRAPS.md`.

## The dev box shell

See `docs/LION-TRAPS.md`.
