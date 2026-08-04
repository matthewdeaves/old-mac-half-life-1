# 5. Cross-compile on Intel Lion, package the disk image on a Tiger G4

Date: 2026-07-27
Status: accepted

## Context

No single machine in the fleet can do the whole job. Old tools cannot read new
formats, new tools cannot write old ones, and that decides where each step runs:

- The 10.3.9 and 10.4u SDKs and the `gcc-4.0` and `gcc-4.2` that go with them are
  on the Intel Lion minis under `/Developer/SDKs`. A modern Mac has neither.
- Lion's `hdiutil` writes a UDIF container Panther's 2003-vintage
  DiskImageMounter cannot parse, reported on 10.3.9 as "no mountable file
  systems", and no `hdiutil` flag fixes it (`scripts/make-dmg.sh:25-27`). A
  Tiger-built UDZO image mounts on Panther and on everything newer (`:28-30`).
- Lion's `/usr/bin/lipo`, `install_name_tool` and `strings` are stale stubs that
  choke on modern x86_64 load commands, so the Xcode toolchain's copies have to
  win on `PATH` (`scripts/make-universal.sh:41-45`, `docs/MODS.md:149-155`).

Two Intel minis exist, `mini-intel` and `mini-intel2`, the same Macmini2,1 on
10.7.5 with the same toolchain, and several repositories and agents may want one
at once.

## Decision

**All three slices cross-compile on an Intel Lion mini. The release disk image is
packaged on a Tiger G4. The PowerPC machines are bench and test targets only.**

- `scripts/build-lion.sh`, `scripts/build-ppc-panther.sh` and
  `scripts/build-ppc-tiger.sh` run locally on that box with no ssh of their own;
  `scripts/make-universal.sh` and `scripts/make-app.sh` fuse and wrap the result
  there, as do `scripts/build-installer.sh:6-9` and
  `scripts/build-sysreport.sh:5-7`, which need the old SDKs and `lipo` too.
  `scripts/build-all.sh` runs the sequence with every step's exit status checked
  and is the supported way to do a full build.
- `scripts/make-dmg.sh` runs on the orchestration box, pulls the built bundle from
  whichever mini holds it (`:61-74`), and ships the staged contents to a Tiger
  host, first reachable of `mini-g4` then `quicksilver` (`:76-83`), which runs
  `hdiutil create -format UDZO` (`:472-475`).
- Which mini is free is asked, not assumed: `scripts/pick-build-host.sh`
  (`--status`, `--acquire LABEL`, `--release HOST`). The claim is a lock directory
  on the mini itself, `/tmp/.retro-build-lock` (`:49`); a host is busy if it holds
  a fresh lock or has compiler processes running (`:42-45`).

## Alternatives rejected

**Build natively on the PowerPC machines.** They are the slowest hardware and the
machines under test, so a build there consumes the thing being measured, and they
are where a failure has to be observed rather than caused.

**Build on the modern Apple Silicon dev box.** Current Xcode carries none of the
SDKs or compilers these targets need; this box orchestrates and never compiles a
slice.

**Package the disk image on the G3.** Rejected on evidence: on an earlier old-Mac
release a single byte flipped during that G3's `hdiutil` read-zlib-write chain and
shipped a corrupt PowerPC slice, a register-save opcode mutated into an illegal
instruction, and it passed `hdiutil verify` silently
(`scripts/make-dmg.sh:31-37`). The G3 is also the oldest hardware here.

**Package on Lion, where the build already is.** It produces an image a G3 cannot
mount, and the G3 is the machine class the image most has to reach.

**A per-checkout `flock` for build-host arbitration.** It serialises only builds
from the same checkout, and cannot see one another repository, agent or
workstation is running on the same mini (`scripts/pick-build-host.sh:21-27`),
where a lock directory on the host is visible to everyone who can ssh in. Both are
kept: `flock` still guards same-repo races.

**Hardcoding one mini.** Two identical hosts exist so two builds can run at once;
hardcoding wastes half the capacity and reintroduces the collision the lock
prevents.

## Consequences

**Gained**

- One toolchain, one set of SDKs, one machine to keep provisioned, either mini
  able to build any slice.
- The disk image mounts from 10.3.9 through modern macOS from one file.
- The lock works across repositories, agents and workstations, because it lives on
  the contended resource rather than beside one caller.

**Lost**

- Nothing can be tested where it is built, so every PowerPC verification is a
  deploy-and-observe cycle on other hardware.
- Lion's limitations become the project's. Its `strings` cannot read a modern
  x86_64 Mach-O and reports zero matches, which looks exactly like a missing
  patch, so shipped strings are checked elsewhere. The git inside the build
  scripts is Xcode 4.6.3's 1.7.12.4, so `git -C` does not exist and
  `( cd ... && git ... )` is required (`docs/MODS.md:149-155`).
- A release needs three machines reachable: an Intel mini, the orchestration box,
  and a Tiger G4. Someone with only one cannot reproduce a release, whatever ADR
  0002 makes possible on paper.

**Risks accepted**

- `hdiutil verify` only checks the container's internal checksum, not that the
  stored bytes match the source, so `make-dmg.sh` mounts the finished image and
  md5s every shipped binary against the local source, retrying up to three times
  (`:391-397`, `:465-480`). That check exists because the failure it catches has
  happened.
- A lock is reclaimed when it is older than `BUILD_LOCK_STALE_SECS`, three hours
  by default, and nothing is compiling (`pick-build-host.sh:40-45`), so a build
  running longer with an idle compiler could be interrupted.
- `pick-build-host.sh` is a distributed copy; the canonical one lives in a
  separate private repository that owns the minis (`:5-14`), so this copy can
  drift.
