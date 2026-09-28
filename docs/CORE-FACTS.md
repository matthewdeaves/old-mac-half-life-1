# Core facts and mechanisms

Long-form detail behind `.claude/rules/core-facts.md`. Read a section with
`grep -n '^## '` then `sed -n`. Covers how a renderer default reaches a machine,
why generated configs are never copied between machines, why `compat-include/`
stays off modern compilers, and the arm64 build and stale-slice procedure. The
slice set, Intel floor, SDL2 linking, dylib names, server and vendoring live in
the ADRs and the build scripts, listed in the last section.

## A renderer default reaches a machine by one of three routes

The cvar's flags decide which. Getting this wrong is why a feature can be
"enabled" in the repo and off on every machine.

- **No flags**, like `r_shadows`: never archived, resets to its built-in default
  every launch, so it belongs in the launcher's per-class `PROFILE` as
  `+r_shadows 1`, which is also the only route that can differ by machine class.
- **`FCVAR_GLCONFIG`**, like `gl_msaa_samples` and `r_ripple`: archived into
  `valve/opengl.cfg`, which `R_Init_Video_` execs before the GL context exists,
  so the launcher can SEED it but only on an install that has never run, and
  every machine that has run the game already holds the key.
- **`FCVAR_ARCHIVE`**, like `gl_vsync` and `r_dynamic`: pin it in
  `configs/userconfig.cfg`, which is re-applied every launch and cannot be
  clobbered by a config reset.

Choose by what the player should be able to change: a `userconfig.cfg` pin
overrides their own setting every launch, which is why `r_ripple` is seeded
rather than pinned, since mainui gives them a "Water ripples" checkbox. See also
`docs/adr/`, issues #8, #9, #10.

## Generated configs are never copied between machines

`valve/opengl.cfg`, `config.cfg` and `video.cfg` are GENERATED per machine, not
retail data, and `opengl.cfg` holds the `FCVAR_GLCONFIG` cvars the launcher seeds
ONLY on an install that has never run. A machine that arrives holding another
machine's copy therefore keeps the wrong renderer settings forever, with nothing
failing and nothing to grep.

Measured 2026-08-28 provisioning `quad-tiger`: `rsync`ing the whole of
`~/hl-assets/valve/` carried a G4's generated configs onto a quad G5, player name
`G4testteeed` and all. Delete those three after any bulk copy, or copy the retail
files by name. The retail data itself (`pak0.pak`, `*.wad`, `maps/`, `models/`,
`sound/`) is fine to copy and is what that staging directory is for.

## compat-include stays off a modern compiler's include path

`compat-include/` supplies `<cstdint>` and `<cinttypes>` to header sets predating
C++11. `-isystem` puts it AHEAD of libc++, so on current clang the shim SHADOWS
the real header instead of filling a gap: ours declares the fixed-width types in
the global namespace only, libc++ wants `std::intmax_t`, and
`is_trivially_copyable.h` fails to compile. It belongs on the PowerPC and
libstdc++ paths, nowhere else. Why the Intel slices use libstdc++ and need only
`<cinttypes>`: `scripts/build-lion.sh:29-52`.

## arm64 is built on this box, and a stale slice is refused

Xcode 4.6 predates arm64 by seven years, so it is not built on a mini. FOUR
drivers, one per shipped Mach-O product: `build-arm64.sh` (engine),
`build-mod-arm64.sh` (the 25 mod dylib pairs), `build-installer-arm64.sh` (Mods
app), `build-sysreport-arm64.sh` (System Report). Lion's lipo can still FUSE
arm64, so every fuse stays on the mini; it only fails to NAME the slice, printing
`cputype (16777228)`, while `otool` and `install_name_tool` refuse the whole
file. **Never write "not for Apple Silicon".** `docs/adr/0001` amendment.

Nothing cleans `dist/*-arm64` up, so the copy on a mini can be weeks old, and the
trigger is an ordinary commit to `installer/` or `sysreport/`, not a pin bump.
The engine compares each slice's `BUILD-STAMP` against `PIN_ENGINE_COMMIT`. The
Mods app and System Report cannot (they build from directories in this repo, and
`~/oldmac` on a mini has no git in it), so their stamp is a content hash of the
source computed by `scripts/arm64-stamp.sh`, which both sides source. Rebuild the
arm64 slice and push it; do not work around the refusal.

- A vendor bump is NOT covered and still needs the arm64 drivers re-run by hand.
- The 25 mod dylib pairs have their own gate: both drivers record the hlsdk
  commit, in `mod.info` and `arm64.info`, and `fuse-mod-arm64.sh` refuses a mod
  whose two disagree. A mod already carrying a stale arm64 slice cannot be
  corrected by lipo and needs `build-mod.sh <branch>`.

Reasoning: `docs/adr/0015`, `docs/adr/0016`.

## Where the other core facts live

| Fact | Home |
| --- | --- |
| Five slices (`ppc750 ppc7400 i386 x86_64 arm64`), `dyld` grades by CPU subtype, `i386` is Core Solo/Duo only | `docs/adr/0001` |
| Intel floor 10.6 via `-stdlib=libstdc++`, `OLDMAC_INTEL_MIN=10.7` A/B | `scripts/build-lion.sh:29-52` |
| Game dylib names (`hl.dylib` for i386, `hl_ppc`, `hl_amd64`, `hl_arm64`) | `docs/adr/0001`, "Consequences for the game dylibs" |
| Slice sets per app, `arm64` optional (Rosetta 2 downgrade), sysreport floors | `docs/adr/0008`, `docs/adr/0010` |
| One branch per tree, our own forks, no GitHub ZIPs, nothing patches vendor | `docs/adr/0002`, `docs/adr/0003`, `docs/adr/0012` |
| `panther-sdl2` 2.0.3 static on PowerPC, SDL 2.0.22 dylib on Intel, 2.32.x on arm64, why `leopard-sdl2` is in no slice | `docs/adr/0004` |
| `xash3d` is a shell launcher, `xash3d.bin` the Mach-O | `docs/adr/0007` |
| Linux server, UDP amplifier (101x on `A2S_RULES`), per-source-address firewall | `docs/adr/0013`, `docs/adr/0014`, `server/README.md` |
| Vsync OFF in every benchmark, ON for every player, measured numbers | `docs/BENCHMARKING.md`, "Every row here is vsync OFF" |
| Mac OS X only, not Mac OS 9 (issue #23) | `README.md` |
