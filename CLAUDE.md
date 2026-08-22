# Half-Life old-Mac port

Half-Life 1 on Xash3D FWGS as ONE universal fat app across PowerPC and Intel
Macs, from a single `Half-Life.app`. Sticky facts only, loaded every session.
Reasoning and rejected alternatives live in `docs/adr/`; anything that dates
goes in the README or an issue.

## Commands

The build drivers run **locally on a build mini** and do no ssh of their own, so
claim a host first, then run them there. The repo is at `~/oldmac` on both minis.

```sh
scripts/pick-build-host.sh --status            # who is free
HOST=$(scripts/pick-build-host.sh --acquire LABEL)
scripts/sync-build-host.sh $HOST               # FIRST. the mini does not pull.
ssh $HOST 'cd oldmac && scripts/build-all.sh'  # THE WHOLE BUILD. Use this.
scripts/pick-build-host.sh --release $HOST

# arm64 is the ONE slice a mini cannot build. Run these HERE, before build-all:
scripts/build-arm64.sh                         # engine, Apple Silicon box only
scripts/build-mod-arm64.sh --all               # the 25 mod dylib pairs
scripts/build-installer-arm64.sh               # the Mods app's own slice
scripts/build-sysreport-arm64.sh               # the System Report app's
scripts/push-arm64-slice.sh $HOST              # carries the engine over, verifies by md5
scripts/push-mod-arm64.sh $HOST                # carries the other three over

# The Linux dedicated server is the OTHER non-mini product. Runs HERE, in a
# container, from the same pins. `docs/adr/0013`, operator docs `server/README.md`
scripts/build-server-linux.sh                  # x86_64
scripts/build-server-linux.sh --arch aarch64   # ARM VPS

scripts/make-dmg.sh [version-label]      # Tiger G4 ONLY, see the hard rules
scripts/pick-bench-host.sh --status      # bench/test boxes: who is free
scripts/deploy-dmg.sh HOST [version]     # install on a bench box as a user would
scripts/smoke-dmg.sh HOST                # does the installed app actually launch
scripts/fleet-bench.sh -l LABEL [host]   # timerefresh FPS, appends to benchmarks/
python3 tests/test-repo.py               # repo invariants, runs on this box
tests/test-artifact.sh                   # checks a built artifact
```

`build-all.sh` runs `fetch-sources.sh`, the FOUR slice drivers it can run
(`build-lion.sh` twice, for x86_64 and for i386, then both PowerPC ones),
`make-universal.sh`, `make-app.sh`, then `build-installer.sh` and
`build-sysreport.sh`, in that order, checking each exit code. It does NOT build
arm64, which no mini can, and every fuse takes whatever slices it finds: a slice
that was never pushed is simply absent from the release, which is why each fuse
SAYS so either way. It does NOT build the 25 mod dylibs either: that is
`build-mod.sh`, it takes hours, and its output is an INPUT to
`build-installer.sh`.
**Do not run those steps chained by hand.** A pipeline returns its LAST command's
status, so `driver.sh 2>&1 | tail -25 && next.sh` reads `tail`'s status, and
`tail` always succeeds. That has already happened here: all three drivers
correctly refused to build a tree at the wrong pin, and the run still finished
saying "done".

To change engine, menu or game code: commit it on the `oldmac` branch of that
fork, push, bump the pin in `scripts/build-pins.sh`, `scp` that file to the mini,
then `build-all.sh`. If a submodule changed, **the recorded commit must move**;
editing `.gitmodules` is not enough. `docs/adr/0012`

`OLDMAC_KEEP_BUILD=1` skips the clean for a fast fix-compile loop. It poisons the
`BUILD-STAMP` so the result cannot be fused. Never use it for anything shippable.

`lipo` and `strings` checks belong on **this** box, never on Lion.
**All build output lives under `~/oldmac/dist/`**, never at the repo root and never
on a Desktop; `~/Desktop/Half-Life` is a deployed game, not a build directory.

## Facts

- `dyld` grades a fat by **CPU subtype alone**, never the OS, so a slice exists
  only for a CPU capability difference. **FIVE slices** since 2026-08-08:
  **`ppc750`** (G3), **`ppc7400`** (G4 and G5), **`i386`** (Core Solo/Duo),
  **`x86_64`**, **`arm64`**. PowerPC targets 10.3.9 and runs to 10.5.
  `docs/adr/0001`
- **Intel is 10.6 Snow Leopard+**, not 10.7. The only thing that ever held it at
  10.7 was `libc++.1.dylib`, and `-stdlib=libstdc++` covers the whole C++
  runtime need. That is the WIDER choice, not a compromise: the range is
  **10.6.8 through macOS 26** against libc++'s 10.7+. The one gap is
  `<cinttypes>`, supplied by `compat-include/`. Set `OLDMAC_INTEL_MIN=10.7` for
  an A/B; measured cost is +0.45%, i.e. none. Full reasoning and the symbol
  count: `scripts/build-lion.sh:29-52`.
- **`i386` is for the 2006 Core Solo and Core Duo only** (Mac mini 1,1, iMac 4,1,
  MacBook 1,1, MacBook Pro 1,1), the sole Intel Macs with no 64-bit mode. Built
  by `OLDMAC_INTEL_ARCH=i386 build-lion.sh`. Never run on hardware: there is no
  such machine here.
- **`arm64` is built on THIS box, not a mini**: Xcode 4.6 predates it by seven
  years. FOUR drivers, one per shipped Mach-O product: `build-arm64.sh`
  (engine), `build-mod-arm64.sh` (the 25 mod dylib pairs),
  `build-installer-arm64.sh` (Mods app), `build-sysreport-arm64.sh` (System
  Report). Lion's lipo can still FUSE arm64, so every fuse stays on the mini; it
  only fails to NAME the slice, printing `cputype (16777228)`, while `otool` and
  `install_name_tool` refuse the whole file. **Never write "not for Apple
  Silicon".** `docs/adr/0001` amendment.
- **A stale arm64 slice is refused, not fused.** Nothing cleans `dist/*-arm64`
  up, so the copy on a mini can be weeks old, and the trigger is an ordinary
  commit to `installer/` or `sysreport/`, not a pin bump. The engine compares
  each slice's `BUILD-STAMP` against `PIN_ENGINE_COMMIT`. The Mods app and
  System Report cannot: they build from directories in this repo, and `~/oldmac`
  on a mini has no git in it, so their stamp is a content hash of the source
  computed by `scripts/arm64-stamp.sh`, which both sides source. Rebuild the
  arm64 slice and push it; do not work around the refusal. A vendor bump is NOT
  covered and still needs the arm64 drivers re-run by hand. The 25 mod dylib
  pairs are not covered either, issue #4. `docs/adr/0015`
- **Every shipped app runs natively on every CPU the project supports.** Game:
  `ppc750 ppc7400 i386 x86_64 arm64`. Mod dylibs, Mods app and System Report:
  `ppc i386 x86_64 arm64`, no ppc split because `dlopen` grades generic `ppc`
  correctly on a 750. In all three, `arm64` is OPTIONAL at fuse time and its
  absence is a Rosetta 2 downgrade, not a fault. The System Report app's Intel
  floors are deliberately LOWER than the game's, 10.4 for i386 and 10.5 for
  x86_64. `docs/adr/0010`
- **A Linux dedicated server ships too**, built here in a Debian 11 container
  from the same pins, so it is protocol-identical to the Mac clients by
  construction. It is an unauthenticated UDP amplifier (101x on `A2S_RULES`), so
  the firewall rules are per source address and are not optional.
  `docs/adr/0013`, `docs/adr/0014`, `server/README.md`
- **Never put `compat-include/` on a MODERN compiler's include path.** It supplies
  `<cstdint>` and `<cinttypes>` to header sets predating C++11, and `-isystem`
  puts it AHEAD of libc++, so on current clang the shim SHADOWS the real header
  instead of filling a gap: ours declares the fixed-width types in the global
  namespace only, libc++ wants `std::intmax_t`, and `is_trivially_copyable.h`
  fails to compile. It belongs on the PowerPC and libstdc++ paths, nowhere else.
- **Game dylib names are NOT "arch with an underscore".**
  `COM_GenerateLibraryName` special-cases 32-bit x86 and gives it no suffix at
  all, that having been Half-Life's original platform. So it is `hl.dylib` /
  `client.dylib` for i386, and `hl_ppc`, `hl_amd64`, `hl_arm64` for the rest.
  The engine `dlopen`s these BY NAME, so a `_i386` suffix produces files it will
  never look for. `docs/adr/0001` amendment.
- **Bench and test machines are claimed by name**, with
  `scripts/pick-bench-host.sh --acquire HOST LABEL`. `deploy-dmg.sh` and
  `fleet-bench.sh` do it for you and refuse a busy box. It shares the build
  lock's directory on the target, so a bench and a build cannot land on the same
  mini. It also refuses a host booted into an OS its alias does not name: the
  multi-boot aliases all answer on one IP, and only the ssh host key tells them
  apart, so `deploy-dmg.sh quad-tiger` against a Leopard-booted quad would
  otherwise install onto Leopard and label the result "tiger". Canonical copy in
  `old-mac-build-host`, distributed by its `sync-build-lock.sh`.
- **Mac OS X only, not Mac OS 9** (issue #23). Classic is out of scope.
- **Three trees:** engine (`xash3d-fwgs`), menu (`mainui_cpp`), game dylibs
  (`hlsdk-portable`). **Every slice, and the Linux server, builds from the same
  branch of each**, our own, from mainline. There is no separate PowerPC tree any
  more, so a fix cannot be live on one architecture and missing on another.
  `docs/adr/0003`, `docs/adr/0012`
- **PowerPC links `panther-sdl2` 2.0.3 statically, Intel builds SDL 2.0.22 as a
  dylib, arm64 builds a current SDL2 (2.32.x).** `leopard-sdl2` is in no shipped
  slice and needs 10.5, so it can never be one. `docs/adr/0004`
- **Never use GitHub ZIPs.** Each tree is cloned `--recursive` at the pinned
  commit into a git-ignored `vendor/`. **Nothing patches it on the way to the
  compiler.** `docs/adr/0002`, `docs/adr/0012`
- **`Contents/MacOS/xash3d` is a shell launcher** that picks the display
  profile; the Mach-O beside it is `xash3d.bin`. `docs/adr/0007`

## Machines

- **This dev box is orchestration only** (Apple Silicon, macOS 26). ALL THREE
  slices cross-compile on an Intel Lion mini; the PowerPC boxes are bench/test
  targets, NOT build hosts. Drivers RUN ON the mini: `build-lion.sh`,
  `build-ppc-panther.sh` (G3), `build-ppc-tiger.sh` (G4 and G5), fused by
  `make-universal.sh` and `make-app.sh`. `docs/adr/0005`
- **TWO interchangeable Intel build minis**, either builds any slice:
  `mini-intel` (10.188.1.190, wifi), `mini-intel2` (10.188.1.164, **wired**,
  server room, wifi disabled), same Macmini2,1 /
  10.7.5 / toolchain. Ask `scripts/pick-build-host.sh` (`--status`,
  `--acquire LABEL`, `--release HOST`), never hardcode: a host is busy if it
  holds `/tmp/.retro-build-lock` or is compiling, so hand-started builds count.
- **THREE separate G5s, and they are easy to mix up.** Read the alias, not the
  word "G5", and never assume "the quad" means whichever G5 you last touched:
  - **`imac-g5`** (10.188.1.168) the iMac G5, 10.5.8
  - **`g5-panther` / `g5-tiger` / `g5-desktop`** (10.188.1.188) the **dual**
    PowerMac G5, multi-boot. `g5-desktop` is the Leopard partition, hostname
    `g5-leopard`.
  - **`quad-leopard` / `quad-tiger`** (10.188.1.120) the **QUAD** PowerMac G5,
    multi-boot, user `g5quad`.

  On 2026-08-21 a whole round of "deploy to the quad" and "quit the game on the
  quad" went to 10.188.1.188 instead, because this list previously named only
  two G5s. The quad kept running an old build and reporting the bug as unfixed,
  and the dual G5 was killed repeatedly for no reason. `ssh_config` is the
  authority for what exists; grep it before touching a machine by nickname.
- **Machines that multi-boot from one IP**: the G3 (`yosemite`,
  `yosemite-tiger`), the dual G5 and the quad G5. One OS at a time, so each
  partition needs its own alias with `HostKeyAlias` and `CheckHostIP no`, and
  the booted one mounts its neighbours under `/Volumes`. An alias for a
  partition that is not booted simply fails to connect, which looks exactly
  like the machine being off. Switch with `bless` and reboot;
  `docs/BENCHMARKING.md`.

## Lion build-box traps

- Git there is Xcode 4's 1.7, which has no `git -C`. Use `( cd DIR && git ... )`.
  Modern git, curl, OpenSSL and **ssh** live under `~/local`; the scripts prefer
  them silently. Lion's own OpenSSL cannot do TLS 1.2 and its OpenSSH is 5.6,
  which has no ed25519 and can only sign `ssh-rsa` under SHA-1, which GitHub
  stopped accepting in 2022.
- **All six forks are private.** Each mini has its own key at
  `~/.ssh/id_ed25519_github`, wired in by `core.sshCommand` plus an
  `url."git@github.com:".insteadOf` rewrite, so `build-pins.sh` can keep naming
  plain https URLs. Without that a fetch fails with "could not read Username".
- **No `pkill` on 10.7, 10.4 or 10.3 at all.** Kill by PID out of `ps`.
- The hlsdk-specific traps (`--disable-altivec` is an ENGINE option and breaks
  hlsdk's configure; hlsdk assumes darwin means clang and hands gcc a
  `-Wl,--no-undefined` Apple's ld rejects; gcc-4.0 is stricter than the x86_64
  clang) are in `docs/MODS.md`, "Things that bite on these machines", with the
  script that handles each.
- Lion's `strings` cannot read a modern x86_64 Mach-O and reports zero matches,
  which looks exactly like a missing fix. Verify strings on the dev box.
- Panther's `lipo` cannot name the x86_64 slice and prints
  `cputype (16777223) cpusubtype (-2147483645)`. That is a correct fat binary.
- This dev box runs zsh, where an **unquoted `$var` does not word-split**. Use an
  array. A `git rm $LIST` silently became one long pathspec that matched nothing.

## Working method: measure, and refute when it earns it

Work solo by default. Agents are a tool for when they pay, not a ritual.

A **refutation pass** is handing a fresh agent the diff plus the unpatched
upstream file and telling it to **refute** the fix, not approve it. It is worth
doing when a claim is load-bearing and hard to test directly: a mechanism about
endianness, the frame loop, save/restore or `dlopen`, or any "this is why it
broke" that is about to be written down as fact. Three mechanisms were published
as fact and retracted in one session; that is the failure it exists for.

**Do not run one automatically.** Judge whether it earns its cost, and when it
does, say so and ask before running it. A build-script change or a mechanical
port that the compiler and the hardware already check is not a candidate: the
build and the bench boxes are the stronger evidence.

Brief every agent: read-only unless told otherwise, label each claim measured or
inferred. A partial result from a killed agent is a lead, never a finding.

## Hard rules

- **NEVER trust a build's "done" or exit 0.** waf exits 0 on a failed task and
  then installs stale objects. Procedure, cpusubtype stamping and the launcher's
  display profiles: `.claude/rules/build-verification.md`.
- **Payload sits at the `valve/` level**, not the rodir root, or the engine's
  pre-flight check misses it. `.claude/rules/shipped-layout.md`, `docs/adr/0006`
- **We ship code, not content.** No Valve assets, no mod author's content, ever.
- **Never PR or push to upstream repos.** Changes are commits on the `oldmac`
  branch of **our own fork** of each, pinned in `scripts/build-pins.sh`. The only
  patch scripts left are the five applied to each mod's own source tree, which is
  not ours to fork. `docs/adr/0012`
- **Build the release DMG only on a Tiger G4**, never the G3 or Lion, `-format
  UDZO`; md5 every binary, `hdiutil verify` is not enough. `docs/adr/0005`
- Before a release run `python3 tests/test-repo.py` and `tests/test-artifact.sh`.
- **No em dashes anywhere**, prose or shipped strings.
- **Never rate or praise work**, ours or upstream's; attribution is a fact.
- **No Claude co-author** on commits.

## Working alongside the other repos

Five repos are worked on together: the four game ports and the private
`retro-server-infra`, which runs the servers those ports build. A session may be
open in each at once. Three rules keep them out of each other's way.

**Hardware is claimed, never assumed free.** Every script that deploys to,
benches on, or otherwise drives a fleet machine re-execs itself under
`scripts/pick-bench-host.sh --run`, so the machine is claimed for the run and
released however it ends. The lock is a directory on the target, so it is shared
with the build lock and visible to every repo, agent and workstation. Check
`scripts/pick-bench-host.sh --status` before assuming a box is idle, and never
work around a busy one. `BENCH_NO_LOCK=1` exists only for debugging the picker.

**Cross-repo work goes through GitHub, not chat.** One board covers all five
repos: <https://github.com/users/matthewdeaves/projects/8>. Columns are
`Triage / Measuring / Ready / In progress / Blocked / Done`, with `Source` and
`Evidence` fields. File cross-repo work as an issue and put it on the board:

```sh
gh issue create -R matthewdeaves/<repo> --project Retro \
  --label from:port,needs-measurement --title "..." --body "..."
```

Labels, the same four in every repo: **`from:infra`** raised by the server side
for a port to act on, **`from:port`** raised by a port for another repo,
**`needs-measurement`** the claim has no number or hardware repro behind it yet,
**`cross-port`** it affects more than one port, so expect sibling issues.

**Anything one session raises at another starts in `Triage` with
`needs-measurement`, and is not worked until a human or a measurement moves it.**
An issue written by another agent carries no more evidence than the reasoning
that produced it, and it arrives looking exactly like one backed by a bench run.
That gate is the whole reason the board has a `Measuring` column. The same
finding really does recur across ports (the PowerPC SDL2 `--disable-joystick`
issue was filed in three repos on the same day), so `cross-port` is worth using,
but file the sibling issues rather than assuming the fix transfers.

**This repo is PUBLIC. `retro-server-infra` is PRIVATE.** It describes the
topology, firewall rules and admin surface of a live host. Never copy addresses,
key material, tunnel tokens or `.env` content out of it into this repo, in code,
docs or a commit message. Referring to a server release tag is fine; describing
where it runs is not.

## Read on demand

- `README.md` public overview: fleet matrix, per-machine config, upstream credits
- `docs/MODS.md` mods and rebuilds, `docs/MOD-AUDIT.md` the source audit,
  `docs/ICONS.md` icons and the Panther size ceiling, `docs/LICENSING.md` the
  per-component terms and the one grey area, `tests/README.md` coverage
- `docs/BENCHMARKING.md` the timerefresh harness, the ssh aliases, and the
  runbook for onboarding a new machine or partition; `docs/GL-OPTIMIZATION-CASE-STUDY.md`
  how the single-pass world draw was measured
- `server/README.md` running and securing the Linux dedicated server
- `docs/adr/`: 0001 CPU-capability slices, 0002 pinned vendoring, 0003 one tree
  per component, 0004 SDL2, 0005 Lion builds and Tiger packaging, 0006 code not
  content, 0007 launcher, 0008 mod dylibs, 0009 mod installer, 0010 report-app
  floors, 0011 per-mod sources + installer TLS, **0012 the port is commits on
  our own forks** (supersedes the patching half of 0002), 0013 the Linux
  dedicated server, 0014 the server is a UDP amplifier
- `docs/port/POWERPC-FINDINGS.md`: the publishable write-up, one entry per
  finding with symptom, cause, change and the machines it was measured on,
  **including the ones that were got wrong**; `docs/port/PPC-PORT-NOTES.md`: the
  move onto mainline, including two diagnoses made, measured and retracted.
  Read both before re-diagnosing anything on this fleet: several plausible
  mechanisms in them are recorded as REFUTED and must not be republished.
