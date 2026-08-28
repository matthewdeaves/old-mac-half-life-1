# Core Facts & Mechanisms

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
  pairs have their own gate: both drivers already record the hlsdk commit, in
  `mod.info` and `arm64.info`, and `fuse-mod-arm64.sh` refuses a mod whose two
  disagree. A mod already carrying a stale arm64 slice cannot be corrected by
  lipo and needs `build-mod.sh <branch>`. `docs/adr/0015`, `docs/adr/0016`
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
- **A renderer default reaches a machine by one of three routes, and the cvar's
  flags decide which.** Getting this wrong is why a feature can be "enabled" in
  the repo and off on every machine. **No flags**, like `r_shadows`: never
  archived, resets to its built-in default every launch, so it belongs in the
  launcher's per-class `PROFILE` as `+r_shadows 1`, which is also the only route
  that can differ by machine class. **`FCVAR_GLCONFIG`**, like `gl_msaa_samples`
  and `r_ripple`: archived into `valve/opengl.cfg`, which `R_Init_Video_` execs
  before the GL context exists, so the launcher can SEED it but only on an
  install that has never run, and every machine that has run the game already
  holds the key. **`FCVAR_ARCHIVE`**, like `gl_vsync` and `r_dynamic`: pin it in
  `configs/userconfig.cfg`, which is re-applied every launch and cannot be
  clobbered by a config reset. Choose by what the player should be able to
  change: a `userconfig.cfg` pin overrides their own setting every launch, which
  is why `r_ripple` is seeded rather than pinned, since mainui gives them a
  "Water ripples" checkbox. `docs/adr/`, issues #8, #9, #10.
- **Every benchmark here is taken with vsync OFF and every player runs it ON.**
  `gl_vsync` defaults to 1 (`ref_common.c:35`), `configs/userconfig.cfg` pins it
  to 1 on every machine, and `bench.sh:183` turns it off for the measurement. So
  a fps number from `benchmarks/results.csv` is the cost, not the experience.
  Measured 2026-08-23 on crossfire, same map and resolution, vsync the only
  difference: **G5 181.6 off, 60.007 on**, a hard 60 Hz cap with 3x headroom;
  **mini G4 62.9 off, 42.3 on**, which is neither 60 nor 30 because a machine
  sitting just above the refresh misses deadlines and waits. Above the cap a
  render cost is free to the player; just below it, a 1% cost can take several
  fps off the vsynced average. Quote both numbers when a decision turns on them.
- **Never copy `valve/opengl.cfg`, `config.cfg` or `video.cfg` from one machine
  to another.** They are GENERATED per machine, not retail data, and
  `opengl.cfg` holds the `FCVAR_GLCONFIG` cvars the launcher seeds ONLY on an
  install that has never run. A machine that arrives holding another machine's
  copy therefore keeps the wrong renderer settings forever, with nothing failing
  and nothing to grep. Measured 2026-08-28 provisioning `quad-tiger`: `rsync`ing
  the whole of `~/hl-assets/valve/` carried a G4's generated configs onto a quad
  G5, player name `G4testteeed` and all. Delete those three after any bulk copy,
  or copy the retail files by name. The retail data itself (`pak0.pak`, `*.wad`,
  `maps/`, `models/`, `sound/`) is fine to copy and is what that staging
  directory is for.
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
