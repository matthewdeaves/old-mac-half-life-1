# 5. Cross-compile on Intel Lion, package the disk image on a Tiger G4

Date: 2026-07-27
Status: accepted

## Context

The fleet spans 2003 to now, and no single machine in it can do the whole job.
Old tools cannot read new formats, and new tools cannot write old ones. That
holds in both directions and it decides where each step has to run:

- The 10.3.9 and 10.4u SDKs, and the `gcc-4.0` and `gcc-4.2` that go with them,
  exist on the Intel Lion minis under `/Developer/SDKs`. A modern Mac has neither.
- Lion's `hdiutil` writes a UDIF container that Panther's 2003-vintage
  DiskImageMounter cannot parse, reported on 10.3.9 as "no mountable file
  systems". No `hdiutil` flag fixes it (`scripts/make-dmg.sh:25-27`).
- A Tiger-built UDZO image mounts on Panther and on everything newer
  (`scripts/make-dmg.sh:28-30`).
- Lion's `/usr/bin/lipo`, `install_name_tool` and `strings` are stale stubs that
  choke on modern x86_64 load commands, so the Xcode toolchain's copies have to
  win on `PATH` (`scripts/make-universal.sh:41-45`, `docs/MODS.md:149-155`).

There are two Intel minis, `mini-intel` and `mini-intel2`, the same Macmini2,1 on
10.7.5 with the same toolchain, and several repositories and agents may want one
at the same time.

## Decision

**All three slices cross-compile on an Intel Lion mini. The release disk image is
packaged on a Tiger G4. The PowerPC machines are otherwise bench and test targets
only.**

- `scripts/build-lion.sh`, `scripts/build-ppc-panther.sh` and
  `scripts/build-ppc-tiger.sh` each say in their header that they run on an Intel
  Lion mini, and each runs locally on that box with no ssh of its own
  (`build-ppc-panther.sh:2-7`). `scripts/make-universal.sh` and
  `scripts/make-app.sh` fuse and wrap the result there.
- `scripts/build-installer.sh:6-9` and `scripts/build-sysreport.sh:5-7` run there
  too, for the same reason: the old SDKs are there and `lipo` fuses the result.
- `scripts/make-dmg.sh` runs on the orchestration box, pulls the built bundle
  from whichever mini holds it (`:61-74`), and ships the staged contents to a
  Tiger host, first reachable of `mini-g4` then `quicksilver` (`:76-83`), which
  runs `hdiutil create -format UDZO` (`:472-475`).
- Which mini is free is asked, not assumed: `scripts/pick-build-host.sh`, with
  `--status`, `--acquire LABEL` and `--release HOST`. The claim is a lock
  directory on the mini itself, `/tmp/.retro-build-lock` (`:49`), and a host
  counts as busy if it holds a fresh lock or if compiler processes are running on
  it (`:42-45`).

## Alternatives rejected

**Build natively on the PowerPC machines.** They are the slowest hardware in the
fleet, they are the machines under test, and a build there would consume the
thing being measured. They are also where a failure has to be observed rather
than caused.

**Build on the modern Apple Silicon dev box.** Current Xcode carries none of the
SDKs or compilers these targets need. This box orchestrates and never compiles a
slice (`CLAUDE.md:48-52`).

**Package the disk image on the G3.** Rejected on evidence: on an earlier
old-Mac release a single byte flipped during that G3's `hdiutil`
read-zlib-write chain and shipped a corrupt PowerPC slice, a register-save opcode
mutated into an illegal instruction, and it passed `hdiutil verify` silently
(`scripts/make-dmg.sh:31-37`). The G3 is also the oldest hardware here.

**Package on Lion, where the build already is.** Produces an image a G3 cannot
mount, which is the one machine class the image most has to reach.

**A per-checkout `flock` for build-host arbitration.** It only serialises builds
started from the same checkout. It cannot see a build another repository, another
agent or another workstation is running on the same mini
(`scripts/pick-build-host.sh:21-27`). A lock directory on the host is visible to
everyone who can ssh in. Both are kept: `flock` still guards same-repo races.

**Hardcoding one mini.** Two identical hosts exist so that two builds can run at
once; hardcoding wastes half the capacity and reintroduces the collision the lock
exists to prevent.

## Consequences

**Gained**

- One toolchain, one set of SDKs, one machine to keep provisioned for compiling,
  and either mini can build any slice.
- The disk image mounts from 10.3.9 through modern macOS from one file.
- The lock works across repositories, agents and workstations, because it lives
  on the contended resource rather than beside one caller.

**Lost**

- Nothing can be tested where it is built. The build host cannot run the PowerPC
  slices it produces, so every PowerPC verification is a deploy-and-observe cycle
  on other hardware.
- Lion's own limitations become the project's. `strings` there cannot read a
  modern x86_64 Mach-O and reports zero matches, which looks exactly like a
  missing patch, so shipped strings have to be checked elsewhere
  (`CLAUDE.md:65-67`). The git that runs inside the build scripts is Xcode
  4.6.3's 1.7.12.4, so `git -C` does not exist there and `( cd ... && git ... )`
  is required (`docs/MODS.md:149-155`).
- Cutting a release needs at least three machines reachable: an Intel mini, the
  orchestration box, and a Tiger G4. Someone with only one of them cannot
  reproduce a release, whatever ADR 0002 makes possible on paper.

**Risks accepted**

- `hdiutil verify` only checks the container's internal checksum, not that the
  stored bytes match the source, so `make-dmg.sh` mounts the finished image and
  md5s every shipped binary against the local source, retrying up to three times
  (`:391-397`, `:465-480`). That check exists because the failure it catches has
  happened.
- A lock is reclaimed when it is older than `BUILD_LOCK_STALE_SECS`, three hours
  by default, and nothing is compiling (`pick-build-host.sh:40-45`). A build that
  runs longer than that with an idle compiler could be interrupted.
- `pick-build-host.sh` is a distributed copy; the canonical one lives in a
  separate private repository that owns the minis (`:5-14`). This repo's copy can
  drift from it.
