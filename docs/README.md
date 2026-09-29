# Documentation index

Task guides and reference documents for this repository.
Start with the task map in `CLAUDE.md`; open a reference only when that task needs it.
History lookup uses a ticket or date in the active ledger, then `docs/archive/`.

## Root references

- [BUGFIXES.md](../BUGFIXES.md)
- [README.md](../README.md)

## Task guides and topic references

- [BENCH-MEASUREMENTS.md](BENCH-MEASUREMENTS.md): Benchmark measurements
- [BENCHMARKING.md](BENCHMARKING.md): Benchmarking Half-Life on the old-Mac fleet
- [BUILD-COMMANDS.md](BUILD-COMMANDS.md): Build commands: the long-form notes
- [BUILD-VERIFICATION.md](BUILD-VERIFICATION.md): Build verification and test-method stories
- [CORE-FACTS.md](CORE-FACTS.md): Core facts and mechanisms
- [FLEET-HARDWARE.md](FLEET-HARDWARE.md): Fleet hardware traps and the Lion build box
- [FLEET-ONBOARDING.md](FLEET-ONBOARDING.md): Fleet onboarding and the dual G5
- [GL-OPTIMIZATION-CASE-STUDY.md](GL-OPTIMIZATION-CASE-STUDY.md): GL/GPU renderer optimization case study: Power Mac G3 (ATI Rage 128)
- [ICONS.md](ICONS.md): Icon pipeline - Half-Life old-Mac port
- [INCIDENTS.md](INCIDENTS.md): Incidents
- [LICENSING.md](LICENSING.md): Licensing
- [LION-TRAPS.md](LION-TRAPS.md): Lion tooling and shell traps
- [MOD-AUDIT.md](MOD-AUDIT.md): Mod source audit, 2026-07-26
- [MODS.md](MODS.md): Mod support
- [RELEASE.md](RELEASE.md): Release inputs
- [SHIPPED-LAYOUT.md](SHIPPED-LAYOUT.md): Shipped layout: where everything sits and why it cannot move
- [TESTS.md](TESTS.md): Test entry points
- [TICKETS.md](TICKETS.md): Ticket references
- [VM-TIGER.md](VM-TIGER.md): Tiger QEMU capture
- [WORKING-METHOD.md](WORKING-METHOD.md): Working method: the refutation pass
- [adr/0001-slices-are-chosen-by-cpu-capability.md](adr/0001-slices-are-chosen-by-cpu-capability.md): 1. Slices are chosen by CPU capability, not by OS version
- [adr/0002-upstream-is-vendored-at-pinned-commits-and-patched-by-script.md](adr/0002-upstream-is-vendored-at-pinned-commits-and-patched-by-script.md): 2. Upstream is vendored at pinned commits and patched by script
- [adr/0003-every-slice-builds-from-one-tree-per-component.md](adr/0003-every-slice-builds-from-one-tree-per-component.md): 3. Every slice builds from one tree per component
- [adr/0004-powerpc-links-a-legacy-sdl2-intel-builds-its-own.md](adr/0004-powerpc-links-a-legacy-sdl2-intel-builds-its-own.md): 4. PowerPC links a legacy SDL2 statically, Intel builds its own
- [adr/0005-cross-compile-on-intel-lion-package-on-a-tiger-g4.md](adr/0005-cross-compile-on-intel-lion-package-on-a-tiger-g4.md): 5. Cross-compile on Intel Lion, package the disk image on a Tiger G4
- [adr/0006-we-ship-code-not-content.md](adr/0006-we-ship-code-not-content.md): 6. We ship code, not content, and the code lives inside the app bundle
- [adr/0007-the-bundle-executable-is-a-shell-launcher.md](adr/0007-the-bundle-executable-is-a-shell-launcher.md): 7. The bundle's executable is a shell launcher, not the engine
- [adr/0008-one-fat-dylib-per-mod-role-at-the-plain-name.md](adr/0008-one-fat-dylib-per-mod-role-at-the-plain-name.md): 8. Mod game code ships as one fat dylib per role, at the plain name
- [adr/0009-the-mod-installer-is-a-native-cocoa-app-for-10-3.md](adr/0009-the-mod-installer-is-a-native-cocoa-app-for-10-3.md): 9. The mod installer is a native Cocoa app written for 10.3
- [adr/0010-the-system-report-app-targets-lower-floors-than-the-game.md](adr/0010-the-system-report-app-targets-lower-floors-than-the-game.md): 10. The System Report app targets lower floors than the game
- [adr/0011-each-mod-is-fetched-from-its-own-publisher.md](adr/0011-each-mod-is-fetched-from-its-own-publisher.md): 11. Each mod is fetched from its own publisher, and the installer carries its own TLS
- [adr/0012-the-port-is-commits-on-our-own-forks.md](adr/0012-the-port-is-commits-on-our-own-forks.md): 0012. The port is commits on our own forks, not scripts run over somebody else's tree
- [adr/0013-the-dedicated-server-is-linux-built-in-a-container.md](adr/0013-the-dedicated-server-is-linux-built-in-a-container.md): 13. The dedicated server is Linux, built in a container from the same pins
- [adr/0014-the-server-is-an-amplifier-so-it-is-allowlisted-and-sandboxed.md](adr/0014-the-server-is-an-amplifier-so-it-is-allowlisted-and-sandboxed.md): 14. The server is a UDP amplifier, so it is allowlisted, hardened and sandboxed
- [adr/0015-arm64-app-slices-are-stamped-with-a-source-hash.md](adr/0015-arm64-app-slices-are-stamped-with-a-source-hash.md): 15. The arm64 app slices carry a source hash, not a commit id
- [adr/0016-mod-arm64-slices-are-gated-by-the-hlsdk-commit.md](adr/0016-mod-arm64-slices-are-gated-by-the-hlsdk-commit.md): 16. The mod arm64 slices are gated by the hlsdk commit both sides record
- [adr/0017-the-arm64-workstation-may-hold-real-game-assets-for-qa.md](adr/0017-the-arm64-workstation-may-hold-real-game-assets-for-qa.md): 17. The arm64 workstation may hold real game assets for launch QA
- [adr/0018-a-fleet-crash-is-diagnosed-from-the-engines-own-log-first.md](adr/0018-a-fleet-crash-is-diagnosed-from-the-engines-own-log-first.md): 18. A fleet crash is diagnosed from the engine's own log, symbolized, before any mechanism is proposed
- [adr/0019-ripple-coordinates-preserve-the-original-rounding.md](adr/0019-ripple-coordinates-preserve-the-original-rounding.md): Precompute ripple sampling coordinates with the original rounding
- [adr/0020-dynamic-lights-fall-off-by-true-distance.md](adr/0020-dynamic-lights-fall-off-by-true-distance.md): Dynamic lights fall off by true distance
- [port/POWERPC-FINDINGS.md](port/POWERPC-FINDINGS.md): PowerPC findings
- [port/PPC-PORT-NOTES.md](port/PPC-PORT-NOTES.md): Porting the PowerPC build onto mainline Xash3D FWGS

## History archive

Older and superseded accounts: [archive/](archive/). Search by ticket or date.
