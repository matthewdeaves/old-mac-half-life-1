# Bug-fix log

One entry per real bug fixed, newest first: what it was, what the fix was,
where to read more. Not a changelog. Add an entry when you fix a real bug,
not for every commit. Deep engine writeups live in
`docs/port/POWERPC-FINDINGS.md`; entries below cite its numbered findings as
`F<n>`.

## Launcher and config

- Launcher forced Radeon-measured MSAA/shadows/ripple defaults on every
  G4/G5, whatever GPU it actually had; now gated on an ioreg check for a
  Radeon-generation chip, anything else gets conservative defaults. 46a6dd8,
  issue #17.
- Unescaped backticks in the launcher-generation heredoc were command
  substitution, so generating the launcher ran `machine` and corrupted the
  output with it. Escaped; the general trap is in CLAUDE.md. 46a6dd8.
- The G3 profile expressed "no MSAA" by omitting the cvar, which inherits
  whatever is archived on the machine; it now sets `gl_msaa_samples 0`
  explicitly. 90fafa2, issue #8.

## App and packaging

- Game icon crop started 100px below Gordon's hairline, cutting off the top
  of his head at every icon size. Crop from the hairline. 42a3243, issue #16.
- Stale arm64 slices fused silently: the engine now compares the slice
  BUILD-STAMP to the pinned commit, the Mods/System Report apps carry a
  source content hash, and mod dylibs carry the hlsdk commit; a mismatch
  refuses the fuse. 61c52f2, e8c8125, d3fda6e; issue #4, ADR 0015/0016.

## Scripts and harness

- `smoke-dmg.sh` executed the launcher binary directly over ssh, which
  bypasses LaunchServices and so could never catch a Gatekeeper/quarantine/
  signature rejection a real double-click hits. Launches via `open` now; a
  LaunchServices refusal is a FAIL. Its liveness poll then used `ps ax`,
  whose COMMAND column truncates over a non-tty ssh pipe and cut the line off
  before `xash3d.bin` ever appeared, reporting every working launch as a
  crash after the full timeout; `-axww` disables the truncation. The quad
  G5's aliases (`quad-tiger`/`quad-leopard`) were also missing from the
  machine table entirely. d462f2c, e48e6aa, 154a109; issue #19.
- `deploy-dmg.sh` installed a bundle without verifying the signature
  survived, and without clearing `com.apple.quarantine` if the image arrived
  by a route that sets it. Found via a genuinely corrupted install on
  `imac-2019` (`codesign -v` failed there; a fresh `ditto` from the same
  image on the same machine was clean). Both are now checked/handled on
  every install, fatally on a bad signature. d462f2c, issue #19.
- Two re-exec guards compared `RETRO_BENCH_LOCK` to an empty expansion, so
  the guard was always true; they now compare against the target host.
  60e7e5c, issue #13.
- The bench lock carried no nonce, so a sibling session's `--release` could
  drop another session's lock unannounced. Nonce added. ea2cb0b, issue #12.
- `make-dmg.sh` pulled from a build mini without claiming it. It now claims
  the Tiger box and checks the mini's lock first. cf00d1f, issue #11.
- `test-frame.sh` put a tilde inside quotes meant for the remote shell, so it
  expanded on the caller instead. 73b6e39.
- `benchmarks/results.csv` had accreted 19 host labels for 8 machines, some
  from a `hostname -s` fallback naming no real machine; `-l` is now required
  and labels are registered. bc1d0cd, issue #15.
- The stale-arm64 error message suggested rebuilding on a host alias that
  does not resolve. 481632b, 5c6492f.

## Engine and menu (see docs/port/POWERPC-FINDINGS.md)

- `SDLash_TextInputDelivers()` was gated on Darwin major version (only
  10.3/10.4 skip SDL's text input), on the strength of one dated finding that
  a G5 on 10.5.8 typed fine. Measured hands-on on a SECOND G5 (dual PowerMac,
  g5-desktop): that finding did not generalise, and the same build produced a
  system-wide, unrecoverable beachball opening a text box. Re-gated on CPU
  architecture instead (`__ppc__`/`__ppc64__`) - every PowerPC OS version
  takes the key-derived path now, not just pre-10.5. ff64ebd3 (engine fork),
  issue #18.
- `Sys_Crash`'s dialog (`SDL_ShowSimpleMessageBox`) allocates memory and is
  not safe to call from a signal handler: if the crashing thread was already
  inside `malloc`, the handler's own attempt to allocate deadlocked on the
  same lock forever - measured live, two concurrent crashes both stuck in the
  identical deadlock trying to show their own dialogs. A crash could cost a
  hard reboot. Added a re-entrancy guard and a 5-second watchdog that
  force-exits if the dialog call hangs; the crash text is already safely on
  disk by that point either way. Apple-only. 66d5bd78 (engine fork), issue
  #18.
- The key-derived text-input path delivered a typed character, then fell
  through to normal key dispatch for the same keydown, which matched it
  against every OTHER menu item's hotkey - typing a player name could jump
  the whole menu away mid-keystroke ('g' in a name left Customize for Game
  Options). Intel never hit this: once SDL's own text input is active it
  already returns before reaching that dispatch, so only PowerPC (forced onto
  the key-derived path above) was exposed. Returns after delivering a
  character now, matching Intel; non-printable keys (Backspace, arrows,
  Enter) still fall through since `CMenuField::KeyDown`, not `Char`, handles
  those. 1bad7f77 (engine fork), issue #18.
- Guard-door freeze: Panther's `dladdr` keeps the Mach-O leading underscore,
  breaking save/restore's function-pointer name round-trip; normalize in
  `COM_NameForFunction`. F1. (The gcc-miscompile diagnosis was wrong: F10.)
- Mod switching dead on Darwin: `execve` refused from a multi-threaded
  process. F2.
- Finder launch failed: `dlopen` of a bare leaf name has no directory to
  resolve against. F3.
- Blocking `getaddrinfo` on the frame loop read as broken input. F4.
- Leopard advertises non-power-of-two textures its driver samples in
  software. F5.
- Release builds got empty backtraces from `backtrace_full`. F7.
- Menu drew token names on a missing dictionary key (`L()` returns its key on
  a miss). F8.
- Menu hint text stopped scaling at 1280 wide. F9.
- The welder went dark twice, both times by archived cvar state, and the
  single-pass world draw ran `R_CheckLightMap` before the base draw. F13, F15.
- The blue tint that was not a rendering fault at all. F14.
- Stale video-mode menu; the "syncs on every mode set" mechanism is REFUTED,
  do not republish it. F19.
