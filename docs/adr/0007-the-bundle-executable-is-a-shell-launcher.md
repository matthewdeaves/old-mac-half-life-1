# 7. The bundle's executable is a shell launcher, not the engine

Date: 2026-07-27
Status: accepted

## Context

One fat binary has to behave correctly on a G3 with an ATI Rage 128 under 10.3.9,
on a G5 with a built-in panel under 10.5, and on an Intel mini under 10.7. Those
machines need different display settings, and some of them need environment set
before the engine starts.

`dyld` picks a slice by CPU subtype alone and cannot act on an OS difference at
all, which is ADR 0001. So anything that depends on the OS has to be decided
after a slice has already been chosen, by something that can read `sw_vers`.

There is also environment that has to exist before the engine's first `dlopen`.
`DYLD_LIBRARY_PATH` has to point at the bundle's own `MacOS` directory or the
engine loads the system `/usr/lib/libmenu.dylib`, which is ncurses, has no
`GetMenuAPI`, and drops the game to a console with no menu on both architectures
(`scripts/make-app.sh:58-62`).

## Decision

**`Contents/MacOS/xash3d` is a `bash` script. The Mach-O is `xash3d.bin`
beside it** (`scripts/make-app.sh:53`, `:90-157`).

The script does five things, in order:

1. Sets `XASH3D_BASEDIR` to the folder containing the `.app`, and
   `DYLD_LIBRARY_PATH` to the bundle's `MacOS` directory (`:92-94`).
2. Refuses to run from a mounted disk image, detected with `df` plus a write
   probe, and says what to do in an `osascript` dialog (`:97-111`). `df` rather
   than `statfs` because this has to work on 10.3 through modern macOS.
3. Refuses to run with no `valve/` folder beside the app, with a dialog naming
   the actual problem (`:119-124`).
4. Picks a display profile by CPU capability first, then by OS (`:126-153`):
   the G3, identified by `hw.cpusubtype` 9 or `machine` reporting `ppc750` and
   gated on `uname -p = powerpc`, gets exclusive 800x600 on any OS; anything on
   10.3 gets the same, because Panther's `fullscreen` cvar is broken; PowerPC on
   10.4 and later gets `-borderless` at native resolution; Intel gets exclusive
   `-fullscreen`, because `-borderless` on 10.7 leaves the menu bar's top 22
   pixels unpainted as a white strip.
5. Execs `xash3d.bin` with `-console` and the profile, redirecting stdout and
   stderr to `last-run.log` beside the app (`:155`).

Command-line flags are used rather than a config file because
`SetFullscreenModeFromCommandLine()` runs at video init, after `config.cfg` is
executed, so the flags win and a config reset cannot undo them
(`scripts/make-app.sh:64-66`).

## Alternatives rejected

**Put the logic in the engine.** It would have to be carried as another patch
script against two separate trees (ADR 0003), for behaviour that is specific to
this repackaging and of no use to anyone else's build. A shell script also reads
`sw_vers` and `sysctl` without linking anything.

**A compiled launcher stub in Objective-C or C.** It would need building for
three slices, wrapped in the same verification every other slice gets, to do
work that is five shell conditionals. The engine binary is already fat; adding a
second fat binary to the bundle adds a build target and a failure mode.

**`LSEnvironment` in `Info.plist` for the environment variables.** It cannot
compute a path relative to the bundle, which is what both variables need, and its
behaviour across 10.3 to modern macOS is not something this project can test.

**Key the display profile on OS alone.** That was the earlier behaviour and it
was wrong: a G3 booted into Tiger or Leopard, which is a real configuration in
this fleet, took the native-resolution branch and rendered a slideshow on a Rage
128 (`scripts/make-app.sh:67-69`, issue #4).

**Retry a failed launch with different settings.** Deliberately not done: a
failed launch should be visible rather than masked (`scripts/make-app.sh:80-81`).

## Consequences

**Gained**

- One binary configures itself per machine, including for OS differences that
  `dyld` cannot see.
- The two failure modes that read as "the app is broken", running from the disk
  image and having no game data, produce a dialog that names the real problem
  instead of a silent quit.
- The profile is a shell edit rather than a rebuild, so a display fault found on
  hardware can be tested by editing the launcher in place.

**Lost**

- `Contents/MacOS/xash3d` is not a Mach-O, so every tool pointed at the bundle's
  executable has to be told about `xash3d.bin` instead. `make-app.sh:228-229`
  runs `lipo -info` on the `.bin` for that reason, and `scripts/bench.sh:80-81`
  has to look for `xash3d.bin` first and fall back.
- stdout and stderr go to `last-run.log`, so a signal that kills the process
  without flushing loses the output. That is why no backtrace was ever obtained
  for the intermittent G5 SIGBUS in ADR 0001, and why that crash was never
  root-caused.
- Anything that execs `xash3d.bin` directly bypasses the whole launcher:
  environment, guards and profile. Benchmarking does exactly this
  (`scripts/bench.sh`), so benchmark conditions are not shipped conditions unless
  the flags are repeated by hand.

**Risks accepted**

- The G3 branch keys on a specific CPU subtype number. The rule is to never
  enumerate all subtypes, because the G3 is the only CPU exception
  (`.claude/rules/build-verification.md:52-65`); if another machine ever needs its
  own profile, this becomes a list.
- `osascript` is assumed present from 10.3 up. Both dialog calls fall back to
  `echo` on stderr if it is not.
