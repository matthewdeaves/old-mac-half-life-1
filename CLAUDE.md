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
scripts/build-arm64.sh                         # Apple Silicon box only
scripts/push-arm64-slice.sh $HOST              # carries it over, verifies by md5

scripts/make-dmg.sh [version-label]      # Tiger G4 ONLY, see the hard rules
scripts/deploy-dmg.sh HOST [version]     # install on a bench box as a user would
scripts/smoke-dmg.sh HOST                # does the installed app actually launch
scripts/fleet-bench.sh -l LABEL [host]   # timerefresh FPS, appends to benchmarks/
python3 tests/test-repo.py               # repo invariants, runs on this box
tests/test-artifact.sh                   # checks a built artifact
```

`build-all.sh` runs `fetch-sources.sh`, the FOUR slice drivers it can run
(`build-lion.sh` twice, for x86_64 and for i386, then both PowerPC ones),
`make-universal.sh` and `make-app.sh`, in that order, checking each exit code.
It does NOT build arm64, which no mini can, and `make-universal.sh` fuses
whatever slices it finds: an arm64 slice that was never pushed is simply absent
from the release, which is why the fuse SAYS so either way.
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
  10.7 was `libc++.1.dylib`; the whole C++ runtime need is 13 ABI symbols and
  there is no STL use anywhere, so `-stdlib=libstdc++` covers it. That is the
  WIDER choice, not a compromise: `libstdc++.6.dylib` has no file on disk on
  macOS 26 but still `dlopen`s from the dyld shared cache, so the range is
  **10.6.8 through macOS 26** against libc++'s 10.7+. The one gap is
  `<cinttypes>`, supplied by `compat-include/`. Set `OLDMAC_INTEL_MIN=10.7` for
  an A/B; measured cost of the change is +0.45%, i.e. none. `docs/adr/0010`
- **`i386` is for the 2006 Core Solo and Core Duo only** (Mac mini 1,1, iMac 4,1,
  MacBook 1,1, MacBook Pro 1,1), the sole Intel Macs with no 64-bit mode. Built
  by `OLDMAC_INTEL_ARCH=i386 build-lion.sh`.
- **`arm64` is built on THIS box, not a mini**: Xcode 4.6 predates it by seven
  years. `scripts/build-arm64.sh` then `scripts/push-arm64-slice.sh HOST`. Lion's
  lipo can still FUSE it, so the fuse stays in one place. It links libc++ and a
  current SDL2, both deliberately unlike the Intel slices, and 11.0 is simply the
  floor because Apple Silicon shipped with Big Sur. Never write "not for Apple
  Silicon". The System Report app has always shipped i386 from 10.4 and x86_64
  from 10.5, deliberately below the game. `docs/adr/0010`
- **Game dylib names are NOT "arch with an underscore".**
  `COM_GenerateLibraryName` special-cases 32-bit x86 on Apple, Windows and Linux
  and gives it none, because that was Half-Life's original platform. So it is
  `hl.dylib` / `client.dylib` for i386, and `hl_ppc`, `hl_amd64`, `hl_arm64` for
  the rest. The engine `dlopen`s these BY NAME.
- **Mac OS X only, not Mac OS 9** (issue #23). Classic is out of scope.
- **Three trees:** engine (`xash3d-fwgs`), menu (`mainui_cpp`), game dylibs
  (`hlsdk-portable`). **All three slices now build from the same branch of each**,
  our own, from mainline. There is no separate PowerPC tree any more, so a fix
  cannot be live on one architecture and missing on another. `docs/adr/0012`
- **PowerPC links `panther-sdl2` 2.0.3 statically, Intel builds SDL 2.0.22 as a
  dylib, arm64 builds a current SDL2 (2.32.x).** 2.0.22 is the newest SDL Apple
  clang 4.2 will compile, which is a fact about the Lion build box and not about
  arm64; 2.0.22 does not build under clang 21 at all. `leopard-sdl2` is in no
  shipped slice. `docs/adr/0004`
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
- **Two machines multi-boot from one IP**: the G3 (`yosemite`, `yosemite-tiger`)
  and the dual G5 (`g5-panther`, `g5-tiger`, `g5-desktop`, all `powermacg5` on
  10.188.1.188). One OS at a time, so each partition needs its own alias with
  `HostKeyAlias` and `CheckHostIP no`, and the booted one mounts its neighbours
  under `/Volumes`. Switch with `bless` and reboot; `docs/BENCHMARKING.md`.

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
- `--disable-altivec` is an ENGINE option. It breaks hlsdk's configure.
- hlsdk assumes darwin means clang, so it hands gcc a `-Wl,--no-undefined`
  flag that Apple's ld rejects.
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

## Read on demand

- `README.md` public overview: fleet matrix, per-machine config, upstream credits
- `docs/MODS.md` mods and rebuilds, `docs/MOD-AUDIT.md` the source audit,
  `docs/ICONS.md` icons and the Panther size ceiling, `tests/README.md` coverage
- `docs/BENCHMARKING.md` the timerefresh harness, the ssh aliases, and the
  runbook for onboarding a new machine or partition; `docs/GL-OPTIMIZATION-CASE-STUDY.md`
  how the single-pass world draw was measured
- `docs/adr/`: 0001 CPU-capability slices, 0002 pinned vendoring, 0003 split
  trees, 0004 SDL2, 0005 Lion builds and Tiger packaging, 0006 code not content,
  0007 launcher, 0008 mod dylibs, 0009 mod installer, 0010 report-app floors,
  0011 per-mod sources + installer TLS, **0012 the port is commits on our own
  forks** (supersedes the patching half of 0002)
- `docs/port/PPC-PORT-NOTES.md`: the move onto mainline, including two
  diagnoses that were made, measured and retracted
