---
description: How to verify a waf build actually succeeded, and how each slice is stamped
paths:
  - "scripts/build-*.sh"
  - "scripts/make-universal.sh"
  - "scripts/make-app.sh"
  - "scripts/patch-*.py"
---

# Build verification and slice stamping

## NEVER trust "done" or exit 0

The waf-based PPC/Intel builds can exit 0 even when a compile task FAILED
(`Build failed` / `task in xash failed with exit status 1` appears mid-log), and
the install step then silently ships STALE objects from a previous build. That is
a fake-success slice: it looks built, it installs, and it is old code.

After EVERY build you MUST:

1. `grep` the build log for `Build failed` and `error:` (ignore `--disable-werror`).
2. Confirm every expected artifact (`xash3d` + all dylibs) has a FRESH mtime from
   THIS run, not a mix of old and new.
3. Confirm arch/subtype with `lipo -info` (or `lipo -detailed_info`); where
   relevant check `LC_VERSION_MIN` and that a source patch's marker is present in
   the rebuilt output.

Run `lipo` on the dev box, for the same reason `strings` has to be run there.
An old `lipo` cannot NAME a slice newer than itself and prints its raw cputype
instead, which reads like a missing or malformed slice and is not:

- Panther's `lipo` on a correct fat prints
  `ppc750 ppc7400 (cputype (16777223) cpusubtype (-2147483645))`, naming neither
  `x86_64` nor `arm64`.
- Lion's `lipo` FUSES `arm64` correctly and prints it as
  `cputype (16777228) cpusubtype (0)`.

The dev box prints the expected `ppc750 ppc7400 i386 x86_64 arm64` for the game.
Mod dylibs, the Mods app and System Report carry `ppc i386 x86_64 arm64`.

When in doubt, force-clean the waf out dirs (`rm -rf` the `build-<target>` dirs,
e.g. `build-panther` / `build-tiger`) before rebuilding so no stale objects
survive.

`tests/test-artifact.sh` checks the shape of a finished disk image and is not a
substitute for any of the above: it runs after packaging, so a stale object that
happens to have the right architecture passes it.

## A regression test nobody has watched FAIL is not known to work

Before believing a test guards a bug, install the UNFIXED artifact and require
the test to fail on it. A test that passes on the broken build is worse than no
test, because it buys confidence that is not there.

Measured 2026-08-28, issue #21. `scripts/test-text-input.sh` was written to
catch issue #18 and could not: it typed into `ServerBrowser`'s `addressField`,
which has no `LinkCvar`, and #18 comes from `CMenuField::UpdateEditable()`
replacing the buffer from a cvar, so a field with no cvar behind it is immune by
construction. The pre-fix `libmenu.dylib` passed that script exactly as the
fixed one did. It had also never once reached its own assertion: its "reached
the menu" gate grepped for the literal `execing mainui.cfg`, and the engine
writes colour escapes inside that string, so every run reported "never reached
the menu" and exited before typing anything. That reads like a machine or
display problem, so it was treated as one for weeks.

Two rules fall out, both cheap:

- **Keep the unfixed artifact.** Both `libmenu.dylib` builds are kept in the
  session scratchpad precisely so the A/B can be re-run whenever the script
  changes. Without the old one there is nothing to prove the test works.
- **A test that cannot reach its assertion must not report PASS.** Make the
  early-exit paths say INCONCLUSIVE and exit non-zero-but-distinct, so a
  harness that never ran its check cannot be mistaken for a green one.

This generalises past text input. The same shape - "the check ran, said nothing,
and nobody noticed it was checking the wrong thing" - is what
`smoke-dmg.sh`'s `ps ax` truncation and its LaunchServices bypass both were.

### And the mirror of it: a headless test of something that needs a human

The failure above is a false PASS. This one is a false FAIL, and it is worse,
because a false fail gets pointed at someone else's work.

Measured 2026-08-28. `retro-server-infra` asked for a client compatibility pass
against a freshly deployed dedicated server. Driving it headlessly, by appending
`connect <host>` to `userconfig.cfg` and launching via LaunchServices with
nobody at the keyboard, three clients on three machines all connected, negotiated
protocol, then stalled with no map and were timed out by the server. From that
plus a timeline where every earlier success predated their deploy, a theory was
published that their new server build was at fault.

It was not. The server had a map loaded, unchanged content, and logged nothing
unusual. The client sits somewhere that needs a keypress, stops sending, and
gets dropped. The user joined the same server by hand minutes later.

Two variables had changed at once, the server version AND the presence of a
human, and the wrong one got the blame. The rule that follows:

- **A headless run of something that normally needs a person is a false-negative
  generator.** Before reporting that it failed, ask what the human was doing in
  the working case. Here they were pressing a key at a loading screen.
- **Weight your own confound above a suggestive timeline.** The confound was
  known and stated in the same message as the accusation, and still lost to a
  neat before/after story.
- **Never hand another team a fail you have not separated from your own method.**
  Say "connection verified, in-game not demonstrated by my method" and let them
  decide, which costs nothing, rather than "your deploy broke it", which costs
  them a search.

### The common root: testing a proxy, not the real invocation

Three times on 2026-08-29, a confident negative came from a test that did not
replicate what the build or the game actually does:

1. A microphone probe timed at 0.100s and read as "does not block". It ran on a
   machine where permission was ALREADY granted, so no dialog ever appeared. The
   blocking path is the one with a dialog up, and shipping on that reading hung
   the game at launch.
2. A client/server compatibility test driven headlessly with nobody at the
   keyboard, reported as the server's new build being at fault. The client needs
   a keypress at a loading screen; the server was fine.
3. `clang++ -stdlib=libstdc++` run with NO `-isysroot`, giving "library 'stdc++'
   not found", reported as the Intel slice being unable to move to a new build
   host. `build-lion.sh` always passes `-isysroot` at the 10.7 SDK. With that one
   flag it compiles and links `/usr/lib/libstdc++.6.dylib` cleanly.

Each was a simplified stand-in for the real thing, each produced a clean
negative, and a clean negative feels like evidence in a way a clean positive
does not. Two of the three pointed at another team's work.

**Before reporting that something cannot work, diff your test command against
the command the build actually runs.** In case 3 the difference was a single
flag that the script has carried for years, with a 24-line comment above it
explaining why. Reading that comment would have been faster than the test.

## Exact cpusubtype, never generic ppc ALL

Each PPC slice MUST carry its EXACT cpusubtype: **ppc750** (G3) and **ppc7400**
(G4, and the G5). Never ship a generic `ppc (ALL)` **executable** slice. It loads
on Panther, whose 2003 dyld is lax, but Tiger and Leopard mis-grade a fat of
`[ppc ALL, ppc7400]` on a 750 host and refuse to exec, so the failure appears on
a machine other than the one you built for.

- The G3 slice is built `-arch ppc`, then its **executable's** Mach-O cpusubtype
  is re-stamped to POWERPC_750 (9) in `build-ppc-panther.sh`. The **dylibs stay
  ALL**: `dlopen` grades those fine on a 750 host.
- Only two PowerPC slices ship, `ppc750` and `ppc7400`. There is no ppc970
  slice: the G5 runs the `ppc7400` one. See
  `docs/adr/0001-slices-are-chosen-by-cpu-capability.md`.

## Display profile is chosen in the launcher, not by slice

`make-app.sh` writes a shell launcher that picks by CPU first and OS second,
because `dyld` cannot act on an OS difference at all. The profiles, the
measurements behind each, and the 10.3 special case that was measured away are
in `docs/adr/0007`. Two rules apply when editing that launcher:

- **Never enumerate all cpusubtypes.** The G3 is the only CPU exception, and it
  is keyed on subtype 9 / `machine` = `ppc750`, gated on `uname -p = powerpc`.
  A second machine needing its own profile turns this into a list.
- **The G3's 800x600 is keyed on CPU, not OS.** It is a fillrate decision about
  its Rage 128 and applies on Panther, Tiger and Leopard alike. Keying it on OS
  is the bug that shipped once already (issue #4).
