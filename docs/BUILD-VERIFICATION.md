# Build verification and test-method stories

Long form behind `.claude/rules/build-verification.md`. Covers why an exit 0 from
waf proves nothing, how to read `lipo` on old hosts, and three test-method
failures (a test nobody watched fail, a headless test of a human-driven step, a
proxy command that is not the real one). Read a section with `grep -n '^## '`
then `sed -n`.

## Never trust "done" or exit 0

The waf-based PPC/Intel builds can exit 0 even when a compile task FAILED
(`Build failed` / `task in xash failed with exit status 1` appears mid-log), and
the install step then silently ships STALE objects from a previous build. That is
a fake-success slice: it looks built, it installs, and it is old code.

After EVERY build:

1. `grep` the build log for `Build failed` and `error:` (ignore `--disable-werror`).
2. Confirm every expected artifact (`xash3d` + all dylibs) has a FRESH mtime from
   THIS run, not a mix of old and new.
3. Confirm arch/subtype with `lipo -info` (or `lipo -detailed_info`); where
   relevant check `LC_VERSION_MIN` and that a source patch's marker is present in
   the rebuilt output.

When in doubt, force-clean the waf out dirs (`rm -rf` the `build-<target>` dirs,
e.g. `build-panther` / `build-tiger`) before rebuilding so no stale objects
survive. `tests/test-artifact.sh` checks the shape of a finished disk image and is
not a substitute: it runs after packaging, so a stale object with the right
architecture passes it.

## Read lipo on the dev box

An old `lipo` cannot NAME a slice newer than itself and prints its raw cputype
instead, which reads like a missing or malformed slice and is not:

- Panther's `lipo` on a correct fat prints
  `ppc750 ppc7400 (cputype (16777223) cpusubtype (-2147483645))`, naming neither
  `x86_64` nor `arm64`.
- Lion's `lipo` FUSES `arm64` correctly and prints it as
  `cputype (16777228) cpusubtype (0)`.

The dev box prints the expected `ppc750 ppc7400 i386 x86_64 arm64` for the game.
Mod dylibs, the Mods app and System Report carry `ppc i386 x86_64 arm64`.

## A regression test nobody has watched FAIL is not known to work (issue #21)

Measured 2026-08-28. `scripts/test-text-input.sh` was written to catch issue #18
and could not: it typed into `ServerBrowser`'s `addressField`, which has no
`LinkCvar`, and #18 comes from `CMenuField::UpdateEditable()` replacing the buffer
from a cvar, so a field with no cvar behind it is immune by construction. The
pre-fix `libmenu.dylib` passed exactly as the fixed one did. It had also never
reached its own assertion: its "reached the menu" gate grepped for the literal
`execing mainui.cfg`, and the engine writes colour escapes inside that string, so
every run reported "never reached the menu" and exited before typing anything.
That read like a machine or display problem, so it was treated as one for weeks.

- **Keep the unfixed artifact.** Install the UNFIXED build and require the test to
  fail on it. Both `libmenu.dylib` builds were kept so the A/B can be re-run.
- **A test that cannot reach its assertion must not report PASS.** Early-exit
  paths say INCONCLUSIVE and exit non-zero-but-distinct.

Same shape elsewhere: `smoke-dmg.sh`'s `ps ax` truncation and its LaunchServices
bypass.

## A headless test of something that needs a human gives a false FAIL

Measured 2026-08-28. `retro-server-infra` asked for a client compatibility pass
against a freshly deployed dedicated server. Driving it headlessly (`connect
<host>` appended to `userconfig.cfg`, launched via LaunchServices with nobody at
the keyboard), three clients on three machines connected, negotiated protocol,
then stalled with no map and were timed out. A theory that their new server build
was at fault was published. It was not: the client sits somewhere that needs a
keypress at a loading screen, stops sending, and gets dropped. The user joined by
hand minutes later.

Two variables changed at once, the server version AND the presence of a human.

- Before reporting a failure of something that normally needs a person, ask what
  the human was doing in the working case.
- Weight your own stated confound above a suggestive timeline.
- Never hand another team a fail you have not separated from your own method: say
  "connection verified, in-game not demonstrated by my method".

## The common root: testing a proxy, not the real invocation

Three times on 2026-08-29 a confident negative came from a test that did not
replicate what the build or the game actually does:

1. A microphone probe timed at 0.100s and read as "does not block". It ran where
   permission was ALREADY granted, so no dialog appeared. The blocking path is the
   one with a dialog up; shipping on that reading hung the game at launch.
2. The headless client/server test above.
3. `clang++ -stdlib=libstdc++` with NO `-isysroot`, giving "library 'stdc++' not
   found", reported as the Intel slice being unable to move to a new build host.
   `build-lion.sh` always passes `-isysroot` at the 10.7 SDK; with it the link is
   clean.

**Before reporting that something cannot work, diff your test command against the
command the build actually runs.** In case 3 the difference was one flag, with a
24-line comment above it in the script explaining why.

## Exact cpusubtype, never generic ppc ALL

Each PPC slice carries its EXACT cpusubtype: **ppc750** (G3) and **ppc7400** (G4,
and the G5). A generic `ppc (ALL)` **executable** slice loads on Panther, whose
2003 dyld is lax, but Tiger and Leopard mis-grade a fat of `[ppc ALL, ppc7400]` on
a 750 host and refuse to exec, so the failure appears on a machine other than the
one you built for.

- The G3 slice is built `-arch ppc`, then its **executable's** cpusubtype is
  re-stamped to POWERPC_750 (9) in `build-ppc-panther.sh`. The **dylibs stay ALL**:
  `dlopen` grades those fine on a 750 host.
- Only two PowerPC slices ship. No ppc970 slice: the G5 runs `ppc7400`. See
  `docs/adr/0001-slices-are-chosen-by-cpu-capability.md`.

## Display profile is chosen in the launcher (issue #4)

`make-app.sh` writes a shell launcher that picks by CPU first and OS second,
because `dyld` cannot act on an OS difference. Profiles and measurements are in
`docs/adr/0007`. The G3's 800x600 is a fillrate decision about its Rage 128 and
applies on Panther, Tiger and Leopard alike; keying it on OS shipped as a bug once.
The only CPU exception is subtype 9 / `machine` = `ppc750`, gated on
`uname -p = powerpc`; a second exception turns it into a list.
