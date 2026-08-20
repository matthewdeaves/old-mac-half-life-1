# 7. The bundle's executable is a shell launcher, not the engine

Date: 2026-07-27
Status: accepted

## Context

One fat binary serves a G3 with an ATI Rage 128 on 10.3.9, a G5 on 10.5 and an
Intel mini on 10.7, which need different display settings.

`dyld` picks a slice by CPU subtype alone and cannot see the OS (ADR 0001), so
anything OS-dependent has to be decided after the slice is chosen, by something
that can read `sw_vers`.

`DYLD_LIBRARY_PATH` has to point at the bundle's `MacOS` directory before the
engine's first `dlopen`, or the engine loads the system `/usr/lib/libmenu.dylib`,
which is ncurses, has no `GetMenuAPI`, and drops the game to a console with no
menu on both architectures (`scripts/make-app.sh:58-62`).

## Decision

**`Contents/MacOS/xash3d` is a `bash` script; the Mach-O is `xash3d.bin` beside
it** (`scripts/make-app.sh:97` opens the heredoc that writes it). In order:

1. `XASH3D_BASEDIR` is set to the folder containing the `.app`,
   `DYLD_LIBRARY_PATH` to the bundle's `MacOS` (`:100-101`).
2. Refuses to run from a mounted disk image, detected with `df` plus a write
   probe, in an `osascript` dialog saying what to do (`:104-135`). `df` not
   `statfs`, to work from 10.3 to modern macOS.
3. Refuses to run with no `valve/` beside the app, same kind of dialog
   (`:208-217`).
4. Picks a display profile **by CPU capability first, then OS** (`:219-302`):
   - The **G3** (`hw.cpusubtype` 9 or `machine` reporting `ppc750`, gated on
     `uname -p = powerpc`) gets exclusive 800x600 on any OS, plus the Rage 128
     knobs `-gldepth16 -glnostencil -bilinear`. That is a fillrate decision
     about the CPU, so it is keyed on CPU and applies on every OS.
   - **Every other PowerPC machine, 10.3 through 10.5**, gets `-borderless` at
     its desktop resolution.
   - **Intel and Apple Silicon** get exclusive `-fullscreen` at the desktop
     resolution, because `-borderless` on 10.7 leaves the menu bar's top 22
     pixels unpainted as a white strip.
5. Execs `xash3d.bin` with `-console` and the profile, stdout and stderr to
   `last-run.log` beside the app (`:375`).

**10.3 is no longer a special case, and that reversal is the point of writing it
down.** Panther's `fullscreen` cvar IS broken, and 10.3 was once forced to
exclusive 800x600 for that reason. `-borderless` is SDL fullscreen-desktop and
never touches that cvar, so the premise did not reach the conclusion. Measured on
the dual G5's Panther partition (10.3.9 build 7W98, Radeon 9600):
`Window size: 1680x1050 (real 1680x1050)`, menu drawn through hardware GL. A G4
or G5 on Panther now gets its own desktop resolution like every other PowerPC
machine. Issue #41.

The 16-bit display mode is **not** a launch flag. `vid_16bit` defaults on for a
detected G3 and the player can turn it off in the video menu, where the archived
choice then sticks, which a profile flag re-applied every launch could never
allow. `-bpp 16` and `-bpp 32` remain as bench overrides
(`docs/port/POWERPC-FINDINGS.md` entry 16).

Flags, not a config file: `SetFullscreenModeFromCommandLine()` runs at video
init, after `config.cfg` is executed, so the flags win and a config reset cannot
undo them (`:72-74`).

## Alternatives rejected

- **Logic in the engine.** Repackaging-specific behaviour carried on our branch
  forever; the script reads `sw_vers` and `sysctl` without linking anything.
- **A compiled stub in Objective-C or C.** Three more slices to build and verify,
  and a second fat binary in the bundle, for five shell conditionals.
- **`LSEnvironment` in `Info.plist`.** It cannot compute a path relative to the
  bundle, which both variables need.
- **Profile by OS alone.** The earlier behaviour: a G3 booted into Tiger or
  Leopard, a real configuration here, took the native-resolution branch and
  rendered a slideshow on a Rage 128 (`:74-77`, issue #4).
- **Retrying a failed launch.** A failed launch should be visible, not masked.

## Consequences

- The profile is a shell edit rather than a rebuild, so a display fault found on
  hardware can be tested in place.
- The two failure modes that read as "the app is broken", running from the disk
  image and having no game data, name the real problem instead of quitting
  silently.
- The bundle executable is not a Mach-O, so tools need `xash3d.bin`:
  `scripts/make-app.sh:457` runs `lipo -info` on the `.bin`, and `scripts/bench.sh` looks
  for `xash3d.bin` first and falls back.
- Output goes to `last-run.log`, so a signal that kills the process without
  flushing loses it: no backtrace was ever obtained for the intermittent G5
  SIGBUS in ADR 0001, which was never root-caused.
- Exec'ing `xash3d.bin` directly bypasses environment, guards and profile, and
  benchmarking does (`scripts/bench.sh`), so benchmark conditions are not shipped
  conditions unless the flags are repeated by hand.
- Risk: the G3 branch keys on one CPU subtype number; never enumerate all
  subtypes, the G3 being the only CPU exception
  (`.claude/rules/build-verification.md`). Another machine needing its own
  profile makes this a list.
- Risk: `osascript` is assumed present from 10.3 up; both dialogs fall back to
  `echo` on stderr.
